#!/usr/bin/env bash
# providers/pfsense/fetch_pfsense.sh
# Core pfSense provider.
# Collects VLAN interface counters, CPU%, MEM%, and gateway reachability
# via SSH and writes shared/pfsense/{profile}/status.json.
# Interface names are resolved from profile TOML → site.toml → defaults.
set -euo pipefail

PROFILE_ID="${1:-main_router}"
CONFIG_ROOT="${GTEX62_CONFIG_DIR:-${GTEX62_CONKY_CONFIG_DIR:-$HOME/.config/gtex62-core}}"
CACHE_ROOT="${GTEX62_CACHE_DIR:-${GTEX62_CONKY_CACHE_DIR:-$HOME/.cache/gtex62-core}}"
PROFILE_TOML="$CONFIG_ROOT/profiles/pfsense/${PROFILE_ID}.toml"
SITE_TOML="$CONFIG_ROOT/site.toml"
OUT_DIR="$CACHE_ROOT/shared/pfsense/${PROFILE_ID}"
STATUS_JSON="$OUT_DIR/status.json"
TMP_DIR="$CACHE_ROOT/tmp"
GATE_DIR="$CACHE_ROOT/runtime/pfsense"
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
    printf 'TRIPPED|left=%s|reason=%s\n' "$left" "${reason:-PF_SSH_FAIL}"
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
    --arg collector   "pfsense" \
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
    }' > "$STATUS_JSON"
}

# -------------------------------------------------------------------------
# Pre-flight checks
# -------------------------------------------------------------------------

if [[ ! -f "$PROFILE_TOML" ]]; then
  write_status "error" "missing profile toml" "" "$(gate_status)"
  exit 0
fi

ENABLED="$(parse_root_value "$PROFILE_TOML" enabled || true)"
SSH_TARGET="$(parse_root_value "$PROFILE_TOML" ssh_target || true)"
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
# Gate check
# -------------------------------------------------------------------------

GATE="$(gate_status)"
if [[ "$GATE" == TRIPPED* ]]; then
  write_status "degraded" "ssh gate tripped" "$SSH_TARGET" "$GATE"
  exit 0
fi

# -------------------------------------------------------------------------
# Cache TTL
# -------------------------------------------------------------------------

CACHE_TTL="$(parse_root_value "$PROFILE_TOML" cache_ttl_sec || true)"
CACHE_TTL="${CACHE_TTL:-60}"

if [[ -f "$STATUS_JSON" ]]; then
  now_ts="$(date +%s)"
  file_ts="$(stat -c %Y "$STATUS_JSON" 2>/dev/null || echo 0)"
  age=$(( now_ts - file_ts ))
  if [[ "$age" -lt "$CACHE_TTL" ]]; then
    exit 0
  fi
fi

# -------------------------------------------------------------------------
# Interface name resolution
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
# SSH telemetry collection
# -------------------------------------------------------------------------

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5 -o ConnectionAttempts=1 \
          -o ServerAliveInterval=5 -o ServerAliveCountMax=1 -o LogLevel=ERROR)
TMP_RAW="$TMP_DIR/pf_raw_$$.txt"

# shellcheck disable=SC2029  # interface names expand on client side intentionally
_ssh_rc=0
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" \
  "for spec in WAN:${IF_WAN} HOME:${IF_HOME} IOT:${IF_IOT} GUEST:${IF_GUEST} INFRA:${IF_INFRA} CAM:${IF_CAM}; do
     key=\${spec%%:*}; ifn=\${spec#*:}
     netstat -I \"\$ifn\" -b -n 2>/dev/null | awk -v k=\"\$key\" -v ifn=\"\$ifn\" \
       'NR==2{printf \"IF\t%s\t%s\t%s\t%s\n\",k,ifn,\$8,\$11}'
   done
   top -b -n 1 2>/dev/null | awk '
     /^CPU:/ {
       idle=0
       for(i=2;i<=NF;i++) if(\$(i)==\"idle\") { v=\$(i-1); gsub(/%/,\"\",v); idle=v+0 }
       printf \"CPU_PCT\t%.0f\n\", 100-idle
     }
     /^Mem:/ {
       used=0; free=0
       for(i=1;i<=NF;i++) {
         v=\$(i); u=substr(v,length(v),1); n=v+0
         if(u==\"K\") n=n/1024; else if(u==\"G\") n=n*1024
         if(\$(i+1)~/^Active/) used+=n
         if(\$(i+1)~/^Wired/)  used+=n
         if(\$(i+1)~/^Inact/)  used+=n
         if(\$(i+1)~/^Free/)   free=n
       }
       total=used+free
       if(total>0) printf \"MEM_PCT\t%.0f\n\", (used/total)*100
       else        printf \"MEM_PCT\t0\n\"
     }
   '
   gw=\$(route -n get -inet default 2>/dev/null | awk '/gateway:/{print \$2}')
   if [ -n \"\$gw\" ] && ping -c1 -t2 \"\$gw\" >/dev/null 2>&1; then
     printf 'GW\t1\t%s\n' \"\$gw\"
   else
     printf 'GW\t0\t%s\n' \"\${gw:-}\"
   fi" > "$TMP_RAW" 2>/dev/null || _ssh_rc=$?
if [[ $_ssh_rc -ne 0 ]]; then
  "$GATE_SCRIPT" trip PF_SSH_FAIL
  GATE="$(gate_status)"
  write_status "degraded" "ssh failed" "$SSH_TARGET" "$GATE"
  rm -f "$TMP_RAW"
  exit 0
fi

"$GATE_SCRIPT" reset
GATE="$(gate_status)"

# -------------------------------------------------------------------------
# Build status.json from collected data
# -------------------------------------------------------------------------

python3 - "$TMP_RAW" "$STATUS_JSON" \
  "$PROFILE_ID" "$SSH_TARGET" "$GATE" \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" <<'PY'
import json, sys, os

raw_path, out_path, profile_id, ssh_target, gate_str, generated_at = sys.argv[1:7]

interfaces = {}
cpu_pct    = None
mem_pct    = None
gateway    = {"online": False, "ip": ""}

fetched_at = int(__import__("time").time())

with open(raw_path, "r", encoding="utf-8") as fh:
    for line in fh:
        parts = line.rstrip("\n").split("\t")
        if not parts:
            continue
        tag = parts[0]
        if tag == "IF" and len(parts) == 5:
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
        elif tag == "CPU_PCT" and len(parts) == 2:
            try:
                cpu_pct = int(parts[1])
            except (ValueError, TypeError):
                pass
        elif tag == "MEM_PCT" and len(parts) == 2:
            try:
                mem_pct = int(parts[1])
            except (ValueError, TypeError):
                pass
        elif tag == "GW" and len(parts) >= 2:
            gateway["online"] = parts[1] == "1"
            gateway["ip"]     = parts[2] if len(parts) > 2 else ""

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
    "collector":    "pfsense",
    "generated_at": generated_at,
    "ssh_target":   ssh_target,
    "ssh_gate": {
        "status":       gate_str,
        "tripped":      tripped,
        "left_seconds": left,
        "reason":       reason,
    },
    "cpu_pct":    cpu_pct,
    "mem_pct":    mem_pct,
    "gateway":    gateway,
    "interfaces": interfaces,
}

tmp = out_path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, separators=(",", ":"))
os.replace(tmp, out_path)
PY

rm -f "$TMP_RAW"
