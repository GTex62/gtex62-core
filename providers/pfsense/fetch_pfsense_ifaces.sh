#!/usr/bin/env bash
# providers/pfsense/fetch_pfsense_ifaces.sh
# Fast-cadence pfSense interface byte-counter poller (~1s), split out of
# fetch_pfsense.sh's status.json so the NET panel's VLAN bidir meters can
# poll interface counters independently of status.json's 60s CPU/MEM/
# gateway cycle. fetch_pfsense.sh's own interfaces collection in
# status.json is UNCHANGED — this script duplicates that collection at a
# faster cadence into its own file, it does not replace it. See
# docs/pfsense-provider-status.md for the two-writer rationale.
#
# Own cache file (ifaces.json), own SSH gate namespace
# (runtime/pfsense_ifaces) — a fast-poll SSH hiccup here must never trip
# the shared runtime/pfsense gate that status.json's CPU/MEM/gateway/ARP/
# leases/history all depend on, and vice versa.
#
# SSH approach: a plain per-poll `ssh` call, same BatchMode/key options as
# fetch_pfsense.sh — no ControlMaster/multiplexing. This matches what
# gtex62-tech-hud's pf_widget.lua actually does for its 1s interface poll
# (confirmed: no ControlMaster anywhere in its scripts or ~/.ssh/config).
# Live-measured against the real pfSense box before writing this script: a
# fresh key-based SSH handshake + single command averaged ~0.12s over 5
# runs (vs ~0.01-0.02s with ControlMaster/ControlPersist tested the same
# way) — well inside a 1s budget with room to spare, so the added
# lifecycle complexity of a persistent control socket isn't earning its
# keep here. Revisit if this cadence is ever pushed faster or the remote
# command grows heavier.
#
# Rate computation (diff against the previous cycle, 32-bit-wrap guard,
# null on cold start) is duplicated here from fetch_pfsense.sh rather than
# shared, since this script now owns the byte counters at this cadence —
# same diff logic, own previous-sample state (this file, not status.json).
set -euo pipefail

PROFILE_ID="${1:-main_router}"
CONFIG_ROOT="${GTEX62_CONFIG_DIR:-${GTEX62_CONKY_CONFIG_DIR:-$HOME/.config/gtex62-core}}"
CACHE_ROOT="${GTEX62_CACHE_DIR:-${GTEX62_CONKY_CACHE_DIR:-$HOME/.cache/gtex62-core}}"
PROFILE_TOML="$CONFIG_ROOT/profiles/pfsense/${PROFILE_ID}.toml"
SITE_TOML="$CONFIG_ROOT/site.toml"
OUT_DIR="$CACHE_ROOT/shared/pfsense/${PROFILE_ID}"
IFACES_JSON="$OUT_DIR/ifaces.json"
TMP_DIR="$CACHE_ROOT/tmp"
GATE_DIR="$CACHE_ROOT/runtime/pfsense_ifaces"
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

# write_ifaces_stub mirrors fetch_pfsense.sh's write_status()'s envelope
# shape, deliberately omitting the "interfaces" key entirely (not even an
# empty {}) on non-ok states — same convention status.json's own degraded/
# error/disabled stub uses, which the cold-start fallback in the rate-diff
# logic below already relies on (missing key == cold start).
write_ifaces_stub() {
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
    --arg collector   "ifaces" \
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
    }' > "$IFACES_JSON"
}

# -------------------------------------------------------------------------
# Pre-flight checks
# -------------------------------------------------------------------------

if [[ ! -f "$PROFILE_TOML" ]]; then
  write_ifaces_stub "error" "missing profile toml" "" "$(gate_status)"
  exit 0
fi

ENABLED="$(parse_root_value "$PROFILE_TOML" enabled || true)"
SSH_TARGET="$(parse_root_value "$PROFILE_TOML" ssh_target || true)"
SSH_TARGET="${SSH_TARGET:-$(parse_root_value "$SITE_TOML" ssh_target || true)}"
SSH_TARGET="${SSH_TARGET:-$(parse_section_value "$SITE_TOML" pfsense ssh_target || true)}"

if [[ "${ENABLED:-true}" != "true" ]]; then
  write_ifaces_stub "disabled" "profile disabled" "${SSH_TARGET:-}" "$(gate_status)"
  exit 0
fi

if [[ -z "$SSH_TARGET" ]]; then
  write_ifaces_stub "error" "no ssh_target configured" "" "$(gate_status)"
  exit 0
fi

# -------------------------------------------------------------------------
# Gate check (own state dir — never shares runtime/pfsense/ssh_state)
# -------------------------------------------------------------------------

GATE="$(gate_status)"
if [[ "$GATE" == TRIPPED* ]]; then
  write_ifaces_stub "degraded" "ssh gate tripped" "$SSH_TARGET" "$GATE"
  exit 0
fi

# -------------------------------------------------------------------------
# Cache TTL — default 1s, independent of status.json's cache_ttl_sec.
# -------------------------------------------------------------------------

IFACES_TTL="$(parse_root_value "$PROFILE_TOML" ifaces_cache_ttl_sec || true)"
IFACES_TTL="${IFACES_TTL:-$(parse_section_value "$SITE_TOML" pfsense ifaces_cache_ttl_sec || true)}"
IFACES_TTL="${IFACES_TTL:-1}"

if [[ -f "$IFACES_JSON" ]]; then
  now_ts="$(date +%s)"
  file_ts="$(stat -c %Y "$IFACES_JSON" 2>/dev/null || echo 0)"
  age=$(( now_ts - file_ts ))
  if [[ "$age" -lt "$IFACES_TTL" ]]; then
    exit 0
  fi
fi

# -------------------------------------------------------------------------
# Interface name resolution — same profile -> site.toml -> default chain
# as fetch_pfsense.sh's read_iface().
# -------------------------------------------------------------------------

read_iface() {
  local name="$1"
  local default="$2"
  local val
  val="$(parse_section_value "$PROFILE_TOML" interfaces "$name" || true)"
  [[ -z "$val" ]] && val="$(parse_section_value "$SITE_TOML" "pfsense.interfaces" "$name" || true)"
  printf '%s' "${val:-$default}"
}

IF_WAN="$(read_iface   wan   igc0)"
IF_HOME="$(read_iface  home  igc1.10)"
IF_IOT="$(read_iface   iot   igc1.20)"
IF_GUEST="$(read_iface guest igc1.30)"
IF_INFRA="$(read_iface infra igc1.40)"
IF_CAM="$(read_iface   cam   igc1.50)"

# -------------------------------------------------------------------------
# SSH telemetry collection — interfaces only, no CPU/MEM/gateway/ARP/
# leases/history. Deliberately the smallest remote command that still
# gets all 6 VLAN byte counters, to keep the per-poll round trip short.
# -------------------------------------------------------------------------

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5 -o ConnectionAttempts=1 \
          -o ServerAliveInterval=5 -o ServerAliveCountMax=1 -o LogLevel=ERROR)
TMP_RAW="$TMP_DIR/pf_ifaces_raw_$$.txt"

REMOTE_CMD="for spec in WAN:${IF_WAN} HOME:${IF_HOME} IOT:${IF_IOT} GUEST:${IF_GUEST} INFRA:${IF_INFRA} CAM:${IF_CAM}; do
     key=\${spec%%:*}; ifn=\${spec#*:}
     netstat -I \"\$ifn\" -b -n 2>/dev/null | awk -v k=\"\$key\" -v ifn=\"\$ifn\" \
       'NR==2{printf \"IF\t%s\t%s\t%s\t%s\n\",k,ifn,\$8,\$11}'
   done"

# shellcheck disable=SC2029  # interface names expand on client side intentionally
_ssh_rc=0
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "$REMOTE_CMD" > "$TMP_RAW" 2>/dev/null || _ssh_rc=$?
if [[ $_ssh_rc -ne 0 ]]; then
  GATE_STATE_DIR="$GATE_DIR" "$GATE_SCRIPT" trip PF_IFACES_SSH_FAIL
  GATE="$(gate_status)"
  write_ifaces_stub "degraded" "ssh failed" "$SSH_TARGET" "$GATE"
  rm -f "$TMP_RAW"
  exit 0
fi

GATE_STATE_DIR="$GATE_DIR" "$GATE_SCRIPT" reset
GATE="$(gate_status)"

# -------------------------------------------------------------------------
# Build ifaces.json from collected data
# -------------------------------------------------------------------------

python3 - "$TMP_RAW" "$IFACES_JSON" \
  "$PROFILE_ID" "$SSH_TARGET" "$GATE" \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" <<'PY'
import json, sys, os

raw_path, out_path, profile_id, ssh_target, gate_str, generated_at = sys.argv[1:7]

interfaces = {}
# Float, not int — deliberate divergence from fetch_pfsense.sh's copy of
# this logic. At status.json's 60s cadence, integer-second quantization is
# noise; at this script's ~1s cadence it isn't — a real 1.05s gap between
# polls can round to a 1s or 2s delta_t depending on where the two
# timestamps fall relative to the second boundary, producing up to a ~2x
# rate error on that sample. fetch_pfsense.sh's own fetched_at is left as
# int, unchanged, on purpose (see docs/pfsense-provider-status.md's
# ifaces.json schema section) — do not "helpfully" re-sync the two.
fetched_at = __import__("time").time()

# Previous ifaces.json's interfaces, read before this cycle overwrites the
# file below — same cold-start convention as fetch_pfsense.sh's copy of
# this logic: missing file, unparsable JSON, or a previous degraded/error/
# disabled stub (no "interfaces" key) all fall through to an empty dict,
# which the diff loop below treats as cold start (null rates, no error).
prev_interfaces = {}
try:
    with open(out_path, "r", encoding="utf-8") as fh:
        prev_interfaces = json.load(fh).get("interfaces") or {}
except (OSError, ValueError):
    pass

with open(raw_path, "r", encoding="utf-8") as fh:
    for line in fh:
        parts = line.rstrip("\n").split("\t")
        if not parts:
            continue
        if parts[0] == "IF" and len(parts) == 5:
            _, key, ifname, ibytes, obytes = parts
            try:
                interfaces[key] = {
                    "ifname":     ifname,
                    "ibytes":     int(float(ibytes)),
                    "obytes":     int(float(obytes)),
                    "fetched_at": fetched_at,
                }
            except (ValueError, TypeError):
                pass

# Per-VLAN instantaneous rate — same diff/wrap-guard/cold-start logic as
# fetch_pfsense.sh, against this file's own previous sample.
for _key, _cur in interfaces.items():
    _rate_i = _rate_o = _prev_fetched_at = None
    _prev = prev_interfaces.get(_key)
    if isinstance(_prev, dict):
        _prev_ibytes = _prev.get("ibytes")
        _prev_obytes = _prev.get("obytes")
        _prev_ts     = _prev.get("fetched_at")
        if (isinstance(_prev_ibytes, int) and isinstance(_prev_obytes, int)
                and isinstance(_prev_ts, (int, float)) and _prev_ts > 0):
            _delta_t = _cur["fetched_at"] - _prev_ts
            if _delta_t > 0:
                _prev_fetched_at = _prev_ts
                if _cur["ibytes"] >= _prev_ibytes:
                    _rate_i = (_cur["ibytes"] - _prev_ibytes) / _delta_t
                if _cur["obytes"] >= _prev_obytes:
                    _rate_o = (_cur["obytes"] - _prev_obytes) / _delta_t
    _cur["rate_ibytes_per_sec"] = _rate_i
    _cur["rate_obytes_per_sec"] = _rate_o
    _cur["prev_fetched_at"] = _prev_fetched_at

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
    "collector":    "ifaces",
    "generated_at": generated_at,
    "ssh_target":   ssh_target,
    "ssh_gate": {
        "status":       gate_str,
        "tripped":      tripped,
        "left_seconds": left,
        "reason":       reason,
    },
    "interfaces": interfaces,
}

tmp = out_path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, separators=(",", ":"))
os.replace(tmp, out_path)
PY

rm -f "$TMP_RAW"
