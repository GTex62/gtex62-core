#!/usr/bin/env bash
# providers/pfsense/fetch_pihole.sh
# Core Pi-hole provider (pfsense domain, separate SSH target).
# Collects Pi-hole FTL service state, load, and query/block totals via SSH
# and writes shared/pfsense/{profile}/pihole.json.
#
# Pi-hole lives on its own host (pi5), reached over its own SSH session and
# gated by its own circuit breaker state (runtime/pihole/ssh_state) so a
# tripped pfSense connection can never block Pi-hole polling, or vice versa.
# Do not route this script's SSH calls through the pfSense gate/session.
set -euo pipefail

PROFILE_ID="${1:-main_router}"
CONFIG_ROOT="${GTEX62_CONFIG_DIR:-${GTEX62_CONKY_CONFIG_DIR:-$HOME/.config/gtex62-core}}"
CACHE_ROOT="${GTEX62_CACHE_DIR:-${GTEX62_CONKY_CACHE_DIR:-$HOME/.cache/gtex62-core}}"
PROFILE_TOML="$CONFIG_ROOT/profiles/pfsense/${PROFILE_ID}.toml"
SITE_TOML="$CONFIG_ROOT/site.toml"
OUT_DIR="$CACHE_ROOT/shared/pfsense/${PROFILE_ID}"
PIHOLE_JSON="$OUT_DIR/pihole.json"
TMP_DIR="$CACHE_ROOT/tmp"
GATE_DIR="$CACHE_ROOT/runtime/pihole"
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
  local file="$GATE_DIR/ssh_state"
  local tripped=0 reason="" until=0 now left=0
  now="$(date +%s)"
  if [[ -f "$file" ]]; then
    while IFS='=' read -r key value; do
      case "$key" in
        tripped) tripped="${value:-0}" ;;
        reason)  reason="${value:-}"   ;;
        until)   until="${value:-0}"   ;;
      esac
    done < "$file"
  fi
  if [[ "$tripped" == "1" && "$now" -lt "$until" ]]; then
    left=$((until - now))
    printf 'TRIPPED|left=%s|reason=%s\n' "$left" "${reason:-PIHOLE_SSH_FAIL}"
  else
    printf 'OK\n'
  fi
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
    --arg collector   "pihole" \
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
    }' > "$PIHOLE_JSON"
}

# -------------------------------------------------------------------------
# Pre-flight checks
# -------------------------------------------------------------------------

ENABLED="$(parse_section_value "$PROFILE_TOML" pihole enabled || true)"
SSH_TARGET="$(parse_section_value "$PROFILE_TOML" pihole ssh_target || true)"
SSH_TARGET="${SSH_TARGET:-$(parse_section_value "$SITE_TOML" pihole ssh_target || true)}"

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

CACHE_TTL="$(parse_section_value "$PROFILE_TOML" pihole cache_ttl_sec || true)"
CACHE_TTL="${CACHE_TTL:-300}"

if [[ -f "$PIHOLE_JSON" ]]; then
  now_ts="$(date +%s)"
  file_ts="$(stat -c %Y "$PIHOLE_JSON" 2>/dev/null || echo 0)"
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
TMP_RAW="$TMP_DIR/pihole_raw_$$.txt"

_ssh_rc=0
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" \
  'active=$(systemctl is-active pihole-FTL 2>/dev/null)
   if [ "$active" = "active" ]; then
     printf "ACTIVE\t1\n"
   else
     printf "ACTIVE\t0\n"
   fi
   read -r l1 l5 l15 _ < /proc/loadavg 2>/dev/null || true
   printf "LOAD\t%s\t%s\t%s\n" "${l1:-0}" "${l5:-0}" "${l15:-0}"
   total=$(sudo -n sqlite3 /etc/pihole/pihole-FTL.db "select value from counters where id=0;" 2>/dev/null)
   blocked=$(sudo -n sqlite3 /etc/pihole/pihole-FTL.db "select value from counters where id=1;" 2>/dev/null)
   domains=$(sudo -n sqlite3 /etc/pihole/gravity.db "select count(distinct domain) from gravity;" 2>/dev/null)
   printf "TOTAL\t%s\n" "${total:-0}"
   printf "BLOCKED\t%s\n" "${blocked:-0}"
   printf "DOMAINS\t%s\n" "${domains:-0}"' > "$TMP_RAW" 2>/dev/null || _ssh_rc=$?
if [[ $_ssh_rc -ne 0 ]]; then
  GATE_STATE_DIR="$GATE_DIR" "$GATE_SCRIPT" trip PIHOLE_SSH_FAIL
  GATE="$(gate_status)"
  write_status "degraded" "ssh failed" "$SSH_TARGET" "$GATE"
  rm -f "$TMP_RAW"
  exit 0
fi

GATE_STATE_DIR="$GATE_DIR" "$GATE_SCRIPT" reset
GATE="$(gate_status)"

# -------------------------------------------------------------------------
# Build pihole.json from collected data
# -------------------------------------------------------------------------

python3 - "$TMP_RAW" "$PIHOLE_JSON" \
  "$PROFILE_ID" "$SSH_TARGET" "$GATE" \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" <<'PY'
import json, sys, os

raw_path, out_path, profile_id, ssh_target, gate_str, generated_at = sys.argv[1:7]

active   = False
load     = {"l1": 0.0, "l5": 0.0, "l15": 0.0}
total    = 0
blocked  = 0
domains  = 0

with open(raw_path, "r", encoding="utf-8") as fh:
    for line in fh:
        parts = line.rstrip("\n").split("\t")
        if not parts:
            continue
        tag = parts[0]
        if tag == "ACTIVE" and len(parts) == 2:
            active = parts[1] == "1"
        elif tag == "LOAD" and len(parts) == 4:
            try:
                load = {
                    "l1":  float(parts[1]),
                    "l5":  float(parts[2]),
                    "l15": float(parts[3]),
                }
            except (ValueError, TypeError):
                pass
        elif tag == "TOTAL" and len(parts) == 2:
            try:
                total = int(float(parts[1]))
            except (ValueError, TypeError):
                pass
        elif tag == "BLOCKED" and len(parts) == 2:
            try:
                blocked = int(float(parts[1]))
            except (ValueError, TypeError):
                pass
        elif tag == "DOMAINS" and len(parts) == 2:
            try:
                domains = int(float(parts[1]))
            except (ValueError, TypeError):
                pass

blocked_pct = round((blocked / total) * 100, 2) if total > 0 else 0.0

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
    "collector":    "pihole",
    "generated_at": generated_at,
    "ssh_target":   ssh_target,
    "ssh_gate": {
        "status":       gate_str,
        "tripped":      tripped,
        "left_seconds": left,
        "reason":       reason,
    },
    "active":          active,
    "load":            load,
    "queries_total":   total,
    "queries_blocked": blocked,
    "blocked_pct":     blocked_pct,
    "domains_blocked": domains,
}

tmp = out_path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, separators=(",", ":"))
os.replace(tmp, out_path)
PY

rm -f "$TMP_RAW"
