#!/usr/bin/env bash
# providers/pfsense/fetch_pfblockerng.sh
# Core pfBlockerNG provider (pfsense domain, same SSH target as fetch_pfsense.sh).
# Collects pfBlockerNG IP block totals and DNSBL hit totals via SSH and writes
# shared/pfsense/{profile}/pfblockerng.json.
#
# Runs on the same pfSense host as fetch_pfsense.sh but is gated independently
# (runtime/pfblockerng/ssh_state) so a tripped pfBlockerNG poll — these queries
# are heavier (pfctl rule walk + two sqlite3 reads) and run on a slower cadence
# — can never block the fast interfaces/CPU/MEM poll in fetch_pfsense.sh, or
# vice versa. Do not route this script's SSH calls through the pfsense gate.
set -euo pipefail

PROFILE_ID="${1:-main_router}"
CONFIG_ROOT="${GTEX62_CONFIG_DIR:-${GTEX62_CONKY_CONFIG_DIR:-$HOME/.config/gtex62-core}}"
CACHE_ROOT="${GTEX62_CACHE_DIR:-${GTEX62_CONKY_CACHE_DIR:-$HOME/.cache/gtex62-core}}"
PROFILE_TOML="$CONFIG_ROOT/profiles/pfsense/${PROFILE_ID}.toml"
SITE_TOML="$CONFIG_ROOT/site.toml"
OUT_DIR="$CACHE_ROOT/shared/pfsense/${PROFILE_ID}"
PFB_JSON="$OUT_DIR/pfblockerng.json"
TMP_DIR="$CACHE_ROOT/tmp"
GATE_DIR="$CACHE_ROOT/runtime/pfblockerng"
GATE_SCRIPT="$(dirname "$0")/pf-ssh-gate.sh"
mkdir -p "$OUT_DIR" "$TMP_DIR" "$GATE_DIR"

parse_root_value() {
  local path="$1"
  local key="$2"
  [[ -f "$path" ]] || return 0
  awk -F= -v key="$key" '
    /^[[:space:]]*\[/ { if (in_section) exit; next }
    $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      v=$2
      sub(/^[[:space:]]+/, "", v)
      sub(/[[:space:]]+$/, "", v)
      gsub(/^"|"$/, "", v)
      print v
      exit
    }
  ' "$path"
}

parse_section_value() {
  local path="$1"
  local section="$2"
  local key="$3"
  [[ -f "$path" ]] || return 0
  awk -F= -v section="$section" -v key="$key" '
    /^[[:space:]]*\[/ {
      in_section = ($0 == "[" section "]")
      next
    }
    in_section && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      v=$2
      sub(/^[[:space:]]+/, "", v)
      sub(/[[:space:]]+$/, "", v)
      gsub(/^"|"$/, "", v)
      print v
      exit
    }
  ' "$path"
}

gate_status() {
  GATE_STATE_DIR="$GATE_DIR" "$GATE_SCRIPT" status
}

write_status() {
  local state="$1"
  local note="$2"
  local ssh_target="$3"
  local gate="$4"
  local tripped="false"
  local left="0"
  local reason=""
  if [[ "$gate" == TRIPPED* ]]; then
    tripped="true"
    left="$(printf '%s' "$gate" | awk -F'[=|]' '{for(i=1;i<=NF;i++) if($i=="left") {print $(i+1); exit}}')"
    reason="$(printf '%s' "$gate" | awk -F'[=|]' '{for(i=1;i<=NF;i++) if($i=="reason") {print $(i+1); exit}}')"
  fi
  jq -n \
    --arg state       "$state" \
    --arg profile     "$PROFILE_ID" \
    --arg collector   "pfblockerng" \
    --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg note        "$note" \
    --arg ssh_target  "$ssh_target" \
    --arg gate_status "$gate" \
    --arg reason      "$reason" \
    --argjson tripped "$tripped" \
    --argjson left    "${left:-0}" \
    '{
      state:$state,
      profile:$profile,
      collector:$collector,
      generated_at:$generated_at,
      note:$note,
      ssh_target:$ssh_target,
      ssh_gate:{status:$gate_status, tripped:$tripped, left_seconds:$left, reason:$reason}
    }' > "$PFB_JSON"
}

# -------------------------------------------------------------------------
# Pre-flight checks
# -------------------------------------------------------------------------

ENABLED="$(parse_section_value "$PROFILE_TOML" pfblockerng enabled || true)"

# Same host as fetch_pfsense.sh; allow a pfblockerng-specific override, then
# fall back to the standard pfsense ssh_target resolution chain.
SSH_TARGET="$(parse_section_value "$PROFILE_TOML" pfblockerng ssh_target || true)"
SSH_TARGET="${SSH_TARGET:-$(parse_root_value "$PROFILE_TOML" ssh_target || true)}"
SSH_TARGET="${SSH_TARGET:-$(parse_root_value "$SITE_TOML" ssh_target || true)}"
SSH_TARGET="${SSH_TARGET:-$(parse_section_value "$SITE_TOML" pfsense ssh_target || true)}"

if [[ "${ENABLED:-true}" != "true" ]]; then
  write_status "disabled" "profile disabled" "${SSH_TARGET:-}" "$(gate_status)"
  exit 0
fi

if [[ -z "$SSH_TARGET" ]]; then
  write_status "error" "no ssh_target configured" "" "$(gate_status)"
  exit 0
fi

# -------------------------------------------------------------------------
# Gate check (own state dir — never shares runtime/pfsense/ssh_state)
# -------------------------------------------------------------------------

GATE="$(gate_status)"
if [[ "$GATE" == TRIPPED* ]]; then
  write_status "degraded" "ssh gate tripped" "$SSH_TARGET" "$GATE"
  exit 0
fi

# -------------------------------------------------------------------------
# Cache TTL
# -------------------------------------------------------------------------

CACHE_TTL="$(parse_section_value "$PROFILE_TOML" pfblockerng cache_ttl_sec || true)"
CACHE_TTL="${CACHE_TTL:-300}"

if [[ -f "$PFB_JSON" ]]; then
  now_ts="$(date +%s)"
  file_ts="$(stat -c %Y "$PFB_JSON" 2>/dev/null || echo 0)"
  age=$(( now_ts - file_ts ))
  if [[ "$age" -lt "$CACHE_TTL" ]]; then
    exit 0
  fi
fi

# -------------------------------------------------------------------------
# SSH telemetry collection
# -------------------------------------------------------------------------

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5 -o ConnectionAttempts=1 \
          -o ServerAliveInterval=5 -o ServerAliveCountMax=1 -o LogLevel=ERROR)
TMP_RAW="$TMP_DIR/pfblockerng_raw_$$.txt"

_ssh_rc=0
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" \
  'IP_PACKETS=$(pfctl -vvsr 2>/dev/null | awk '"'"'
     /label "USER_RULE: pfB_/ && $0 !~ /pfB_DNSBL_/ {flag=1}
     flag && /^[[:space:]]*\[ Evaluations:/ {
       for (i=1;i<=NF;i++) if ($i=="Packets:") {p += $(i+1); break}
       flag=0
     }
     END{print p+0}
   '"'"')
   printf "IP_TOTAL\t%s\n" "$IP_PACKETS"

   DNSBL_PACKETS=$(sqlite3 /var/unbound/pfb_py_dnsbl.sqlite \
     "SELECT COALESCE(SUM(counter),0) FROM dnsbl;" 2>/dev/null)
   printf "DNSBL_TOTAL\t%s\n" "${DNSBL_PACKETS:-0}"

   RESOLVER_TOTAL=$(sqlite3 /var/unbound/pfb_py_resolver.sqlite \
     "SELECT COALESCE(totalqueries,0)+COALESCE(queries,0) FROM resolver WHERE row=0;" 2>/dev/null)
   printf "RESOLVER_TOTAL\t%s\n" "${RESOLVER_TOTAL:-0}"' > "$TMP_RAW" 2>/dev/null || _ssh_rc=$?
if [[ $_ssh_rc -ne 0 ]]; then
  GATE_STATE_DIR="$GATE_DIR" "$GATE_SCRIPT" trip PFBLOCKERNG_SSH_FAIL
  GATE="$(gate_status)"
  write_status "degraded" "ssh failed" "$SSH_TARGET" "$GATE"
  rm -f "$TMP_RAW"
  exit 0
fi

GATE_STATE_DIR="$GATE_DIR" "$GATE_SCRIPT" reset
GATE="$(gate_status)"

# -------------------------------------------------------------------------
# Build pfblockerng.json from collected data
# -------------------------------------------------------------------------

python3 - "$TMP_RAW" "$PFB_JSON" \
  "$PROFILE_ID" "$SSH_TARGET" "$GATE" \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" <<'PY'
import json, sys, os

raw_path, out_path, profile_id, ssh_target, gate_str, generated_at = sys.argv[1:7]

ip_total       = 0
dnsbl_total    = 0
resolver_total = 0

with open(raw_path, "r", encoding="utf-8") as fh:
    for line in fh:
        parts = line.rstrip("\n").split("\t")
        if not parts:
            continue
        tag = parts[0]
        if tag == "IP_TOTAL" and len(parts) == 2:
            try:
                ip_total = int(float(parts[1]))
            except (ValueError, TypeError):
                pass
        elif tag == "DNSBL_TOTAL" and len(parts) == 2:
            try:
                dnsbl_total = int(float(parts[1]))
            except (ValueError, TypeError):
                pass
        elif tag == "RESOLVER_TOTAL" and len(parts) == 2:
            try:
                resolver_total = int(float(parts[1]))
            except (ValueError, TypeError):
                pass

dnsbl_pct = round((dnsbl_total / resolver_total) * 100, 2) if resolver_total > 0 else 0.0

tripped = gate_str.startswith("TRIPPED")
left    = 0
reason  = ""
if tripped:
    for part in gate_str.split("|"):
        if part.startswith("left="):
            try:
                left = int(part[5:])
            except ValueError:
                pass
        elif part.startswith("reason="):
            reason = part[7:]

payload = {
    "state":        "ok",
    "profile":      profile_id,
    "collector":    "pfblockerng",
    "generated_at": generated_at,
    "ssh_target":   ssh_target,
    "ssh_gate": {
        "status":       gate_str,
        "tripped":      tripped,
        "left_seconds": left,
        "reason":       reason,
    },
    "pfb_ip_total":    ip_total,
    "pfb_dnsbl_total": dnsbl_total,
    "pfb_dnsbl_pct":   dnsbl_pct,
    "resolver_total":  resolver_total,
}

tmp = out_path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, separators=(",", ":"))
os.replace(tmp, out_path)
PY

rm -f "$TMP_RAW"
