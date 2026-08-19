#!/usr/bin/env bash
# providers/pfsense/fetch_router.sh
# Core pfSense router-system provider (pfsense domain, same SSH target as
# fetch_pfsense.sh). Collects router uptime, load average, firmware version,
# hardware model, and BIOS identity via SSH and writes
# shared/pfsense/{profile}/router.json.
#
# Named router.json, not system.json: gtex62-core/providers/system/ already
# owns current.json for the *host* machine (CPU/mem/GPU/board/bios via
# fetch_system.sh). This file is pfSense's own router-side data — a
# different machine, different cache directory (shared/pfsense/{profile}/
# vs shared/system/{profile}/) — router.json avoids the naming collision.
#
# Runs on the same pfSense host as fetch_pfsense.sh but is gated
# independently (runtime/router/ssh_state), same reasoning as
# fetch_pfblockerng.sh: an unrelated poll on this host must never trip or be
# tripped by the fast interfaces/CPU/MEM poll in fetch_pfsense.sh. Do not
# route this script's SSH calls through the pfsense gate.
#
# CPU%/MEM% utilization are intentionally NOT collected here — they are
# already produced by fetch_pfsense.sh's `top` sample into status.json
# (cpu_pct/mem_pct). Duplicating that here would be a second source of
# truth for the same numbers.
set -euo pipefail

PROFILE_ID="${1:-main_router}"
CONFIG_ROOT="${GTEX62_CONFIG_DIR:-${GTEX62_CONKY_CONFIG_DIR:-$HOME/.config/gtex62-core}}"
CACHE_ROOT="${GTEX62_CACHE_DIR:-${GTEX62_CONKY_CACHE_DIR:-$HOME/.cache/gtex62-core}}"
PROFILE_TOML="$CONFIG_ROOT/profiles/pfsense/${PROFILE_ID}.toml"
SITE_TOML="$CONFIG_ROOT/site.toml"
OUT_DIR="$CACHE_ROOT/shared/pfsense/${PROFILE_ID}"
ROUTER_JSON="$OUT_DIR/router.json"
TMP_DIR="$CACHE_ROOT/tmp"
GATE_DIR="$CACHE_ROOT/runtime/router"
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
    --arg collector   "router" \
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
    }' > "$ROUTER_JSON"
}

# -------------------------------------------------------------------------
# Pre-flight checks
# -------------------------------------------------------------------------

ENABLED="$(parse_section_value "$PROFILE_TOML" router enabled || true)"

# Same host as fetch_pfsense.sh; allow a router-specific override, then fall
# back to the standard pfsense ssh_target resolution chain.
SSH_TARGET="$(parse_section_value "$PROFILE_TOML" router ssh_target || true)"
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

CACHE_TTL="$(parse_section_value "$PROFILE_TOML" router cache_ttl_sec || true)"
CACHE_TTL="${CACHE_TTL:-60}"

if [[ -f "$ROUTER_JSON" ]]; then
  now_ts="$(date +%s)"
  file_ts="$(stat -c %Y "$ROUTER_JSON" 2>/dev/null || echo 0)"
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
TMP_RAW="$TMP_DIR/router_raw_$$.txt"

# Query logic ported from gtex62-tech-hud's legacy pf-fetch-basic.sh (medium
# mode, section=system) — same commands, restructured to tab-delimited raw
# output for the Python assembly step below instead of the legacy script's
# flat key=value stdout. One deliberate deviation: the legacy script's boot
# time regex (`.*sec[[:space:]]*=...`) greedily matches "usec" inside
# `{ sec = N, usec = N }`, extracting the microseconds field instead of the
# boot epoch and producing a garbage uptime_seconds. Fixed here by anchoring
# the match to `^\{ sec = `. The legacy script's copy of this bug is left
# untouched — gtex62-tech-hud is read-only and headed for full replacement,
# not further maintenance.
_ssh_rc=0
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" \
  'boot=$(sysctl -n kern.boottime 2>/dev/null | sed -E "s/^\{ sec = ([0-9]+),.*/\1/")
   case "$boot" in ""|*[!0-9]*) boot="" ;; esac
   now=$(date +%s 2>/dev/null || printf "")
   if [ -n "$boot" ] && [ -n "$now" ] && [ "$now" -ge "$boot" ] 2>/dev/null; then
     printf "UPTIME_SEC\t%s\n" "$((now - boot))"
   else
     printf "UPTIME_SEC\t\n"
   fi

   upt=$(uptime)
   load_part="${upt##*load averages: }"
   if [ "$load_part" = "$upt" ]; then load_part="${upt##*load average: }"; fi
   if [ "$load_part" != "$upt" ]; then
     l1=$(printf "%s" "$load_part" | cut -d, -f1 | tr -d " ")
     l5=$(printf "%s" "$load_part" | cut -d, -f2 | tr -d " ")
     l15=$(printf "%s" "$load_part" | cut -d, -f3 | tr -d " ")
     printf "LOAD\t%s\t%s\t%s\n" "$l1" "$l5" "$l15"
   else
     printf "LOAD\t\t\t\n"
   fi

   printf "PHYSMEM\t%s\n" "$(sysctl -n hw.physmem 2>/dev/null)"
   printf "NCPU\t%s\n" "$(sysctl -n hw.ncpu 2>/dev/null)"
   printf "HWMODEL\t%s\n" "$(sysctl -n hw.model 2>/dev/null)"
   printf "VERSION\t%s\n" "$(cat /etc/version 2>/dev/null | tr -d "\r")"

   bven=$(kenv smbios.bios.vendor 2>/dev/null)
   bver=$(kenv smbios.bios.version 2>/dev/null)
   bdat=$(kenv smbios.bios.reldate 2>/dev/null)
   bios="$bver"
   if [ -n "$bven" ]; then bios="$bven${bver:+ $bver}"; fi
   if [ -n "$bdat" ]; then bios="$bios ($bdat)"; fi
   printf "BIOS\t%s\n" "$bios"' > "$TMP_RAW" 2>/dev/null || _ssh_rc=$?
if [[ $_ssh_rc -ne 0 ]]; then
  GATE_STATE_DIR="$GATE_DIR" "$GATE_SCRIPT" trip ROUTER_SSH_FAIL
  GATE="$(gate_status)"
  write_status "degraded" "ssh failed" "$SSH_TARGET" "$GATE"
  rm -f "$TMP_RAW"
  exit 0
fi

GATE_STATE_DIR="$GATE_DIR" "$GATE_SCRIPT" reset
GATE="$(gate_status)"

# -------------------------------------------------------------------------
# Build router.json from collected data
# -------------------------------------------------------------------------

python3 - "$TMP_RAW" "$ROUTER_JSON" \
  "$PROFILE_ID" "$SSH_TARGET" "$GATE" \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" <<'PY'
import json, sys, os

raw_path, out_path, profile_id, ssh_target, gate_str, generated_at = sys.argv[1:7]

uptime_seconds = None
load           = {"l1": 0.0, "l5": 0.0, "l15": 0.0}
physmem_bytes  = None
ncpu           = None
hw_model       = ""
version        = ""
bios_version   = ""

with open(raw_path, "r", encoding="utf-8") as fh:
    for line in fh:
        parts = line.rstrip("\n").split("\t")
        if not parts:
            continue
        tag = parts[0]
        if tag == "UPTIME_SEC" and len(parts) == 2:
            try:
                uptime_seconds = int(parts[1])
            except (ValueError, TypeError):
                pass
        elif tag == "LOAD" and len(parts) == 4:
            try:
                load = {
                    "l1":  float(parts[1]),
                    "l5":  float(parts[2]),
                    "l15": float(parts[3]),
                }
            except (ValueError, TypeError):
                pass
        elif tag == "PHYSMEM" and len(parts) == 2:
            try:
                physmem_bytes = int(parts[1])
            except (ValueError, TypeError):
                pass
        elif tag == "NCPU" and len(parts) == 2:
            try:
                ncpu = int(parts[1])
            except (ValueError, TypeError):
                pass
        elif tag == "HWMODEL" and len(parts) == 2:
            hw_model = parts[1]
        elif tag == "VERSION" and len(parts) == 2:
            version = parts[1]
        elif tag == "BIOS" and len(parts) == 2:
            bios_version = parts[1]

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
    "collector":    "router",
    "generated_at": generated_at,
    "ssh_target":   ssh_target,
    "ssh_gate": {
        "status":       gate_str,
        "tripped":      tripped,
        "left_seconds": left,
        "reason":       reason,
    },
    "uptime_seconds": uptime_seconds,
    "load":            load,
    "version":         version,
    "hw_model":        hw_model,
    "ncpu":            ncpu,
    "physmem_bytes":   physmem_bytes,
    "bios_version":    bios_version,
}

tmp = out_path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, separators=(",", ":"))
os.replace(tmp, out_path)
PY

rm -f "$TMP_RAW"
