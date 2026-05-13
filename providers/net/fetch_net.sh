#!/usr/bin/env bash
set -euo pipefail

PROFILE_ID="${1:-local}"
CONFIG_ROOT="${GTEX62_CONFIG_DIR:-${GTEX62_CONKY_CONFIG_DIR:-$HOME/.config/gtex62-core}}"
CACHE_ROOT="${GTEX62_CACHE_DIR:-${GTEX62_CONKY_CACHE_DIR:-$HOME/.cache/gtex62-core}}"
CORE_DIR="${GTEX62_CORE_DIR:-${GTEX62_CONKY_ENGINE_DIR:-$HOME/.config/conky/gtex62-core}}"
SITE_TOML="$CONFIG_ROOT/site.toml"
PROFILE_TOML="$CONFIG_ROOT/profiles/net/${PROFILE_ID}.toml"
OUT_DIR="$CACHE_ROOT/shared/net/${PROFILE_ID}"
STATE_OUT="$OUT_DIR/state.vars"
VLAN_OUT="$OUT_DIR/vlan.tsv"
STATUS_JSON="$OUT_DIR/status.json"
LOG_FILE="$OUT_DIR/fetch.log"
TMP_DIR="$CACHE_ROOT/tmp"
mkdir -p "$OUT_DIR" "$TMP_DIR"

STATE_TMP="$TMP_DIR/net_state_${PROFILE_ID}_$$.tmp"
VLAN_TMP="$TMP_DIR/net_vlan_${PROFILE_ID}_$$.tmp"

parse_toml_value() {
  local path="$1" key="$2"
  [[ -f "$path" ]] || return 0
  awk -F= -v key="$key" '
    /^[[:space:]]*\[/ { exit }
    $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      v=$2; sub(/^[[:space:]]+/,"",v); sub(/[[:space:]]+$/,"",v); gsub(/^"|"$/,"",v)
      print v; exit
    }
  ' "$path"
}

parse_section_value() {
  local path="$1" section="$2" key="$3"
  [[ -f "$path" ]] || return 0
  awk -F= -v section="$section" -v key="$key" '
    /^[[:space:]]*\[/ { in_section = ($0 == "[" section "]"); next }
    in_section && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      v=$2; sub(/^[[:space:]]+/,"",v); sub(/[[:space:]]+$/,"",v); gsub(/^"|"$/,"",v)
      print v; exit
    }
  ' "$path"
}

json_value() {
  local path="$1" filter="$2"
  [[ -s "$path" ]] || return 0
  jq -r "$filter" "$path" 2>/dev/null | awk 'NF {print; exit}'
}

write_status() {
  local state="$1" note="${2:-}"
  jq -n \
    --arg state "$state" \
    --arg profile "$PROFILE_ID" \
    --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg note "$note" \
    '{state:$state,profile:$profile,generated_at:$generated_at,note:$note}' > "$STATUS_JSON"
}

ENABLED="$(parse_toml_value "$PROFILE_TOML" enabled || true)"
if [[ "${ENABLED:-true}" == "false" ]]; then
  write_status "disabled" "profile disabled"
  exit 0
fi

normalize() {
  printf '%s' "${1:-}" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

escape_value() {
  printf '%s' "${1:-}" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

# ── Interface detection ──────────────────────────────────────────────────────

detect_iface() {
  local env_iface route_iface
  env_iface="${GTEX62_NET_PRIMARY_IFACE:-${NET_PRIMARY_IFACE:-}}"
  if [[ -n "$env_iface" ]]; then printf '%s\n' "$env_iface"; return; fi

  local site_iface
  site_iface="$(parse_section_value "$SITE_TOML" network primary_interface || true)"
  if [[ -n "$site_iface" ]]; then printf '%s\n' "$site_iface"; return; fi

  route_iface="$(
    ip route show default 2>/dev/null \
      | awk '/default/ {for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'
  )"
  if [[ -n "$route_iface" ]]; then printf '%s\n' "$route_iface"; return; fi
  printf 'eno1\n'
}

# ── NIC identification ───────────────────────────────────────────────────────

alias_by_pci() {
  case "$1" in
    8086:15b8|8086:15b7|8086:15b9|8086:15fa|8086:0d4f) echo "Intel I219-V"; return ;;
    8086:15f3|8086:3100) echo "Intel I225-V"; return ;;
    8086:125b|8086:125c) echo "Intel I226-V"; return ;;
    8086:1533) echo "Intel I210"; return ;;
    8086:1521|8086:1523) echo "Intel I350"; return ;;
    10ec:8125) echo "Realtek 2.5GbE (RTL8125)"; return ;;
    10ec:8168) echo "Realtek GbE (RTL8111/8168)"; return ;;
  esac
  return 1
}

pci_id_for_iface() {
  local path vendor device
  path="$(readlink -f "/sys/class/net/$1/device" 2>/dev/null || true)"
  [[ -n "$path" ]] || return 1
  vendor="$(tr -d '\n' < "$path/vendor" 2>/dev/null | sed 's/^0x//')"
  device="$(tr -d '\n' < "$path/device" 2>/dev/null | sed 's/^0x//')"
  [[ -n "$vendor" && -n "$device" ]] || return 1
  echo "${vendor}:${device}" | tr '[:upper:]' '[:lower:]'
}

nic_model() {
  local devpath pci modaline
  devpath="$(readlink -f "/sys/class/net/$1/device" 2>/dev/null || true)"
  if [[ -n "$devpath" ]]; then
    pci="${devpath##*/}"
    modaline="$(lspci -s "$pci" 2>/dev/null | sed -E 's/^[0-9a-f:.]+[[:space:]]+[^:]+:[[:space:]]+//')"
    [[ -n "$modaline" ]] && { echo "$modaline"; return; }
  fi
  ethtool -i "$1" 2>/dev/null | awk -F': ' '/driver:/{print "Driver: "$2; exit}' || echo "$1"
}

nic_alias_from_model() {
  local model
  model="$(echo "$1" | sed -E 's/^[Ii]ntel [Cc]orporation /Intel /; s/[Ee]thernet (C|c)ontroller:?[[:space:]]*//; s/^[[:space:]]+//')"
  if echo "$model" | grep -Eqi 'I[0-9]{3}(-[A-Z])?'; then
    echo "Intel $(echo "$model" | grep -Eio 'I[0-9]{3}(-[A-Z])?' | head -n1)"; return
  fi
  echo "$model" | grep -qi 'RTL8125' && { echo "Realtek 2.5GbE (RTL8125)"; return; }
  echo "$model" | grep -qi 'RTL8111' && { echo "Realtek GbE (RTL8111)"; return; }
  echo "$model"
}

nic_friendly() {
  local iface="$1" pci model
  pci="$(pci_id_for_iface "$iface" 2>/dev/null || true)"
  if [[ -n "$pci" ]] && alias_by_pci "$pci" >/dev/null 2>&1; then
    alias_by_pci "$pci"; return
  fi
  model="$(nic_model "$iface")"
  nic_alias_from_model "$model"
}

# ── VPN / WAN ────────────────────────────────────────────────────────────────

vpn_state() {
  if command -v piactl >/dev/null 2>&1; then
    case "$(piactl get connectionstate 2>/dev/null || true)" in
      Connected) printf 'ON\n'; return ;;
      *) printf 'OFF\n'; return ;;
    esac
  fi
  if ip -o -4 addr show 2>/dev/null | awk '$2 ~ /^wg/ {found=1; exit} END {exit !found}'; then
    printf 'ON\n'; return
  fi
  if ip link show tun0 >/dev/null 2>&1 && ip addr show tun0 2>/dev/null | grep -q "inet "; then
    printf 'ON\n'; return
  fi
  printf 'UNKNOWN\n'
}

pick_vpn_iface() {
  ip link show wg0 >/dev/null 2>&1 && ip addr show wg0 2>/dev/null | grep -q "inet " && { echo "wg0"; return; }
  ip link show tun0 >/dev/null 2>&1 && ip addr show tun0 2>/dev/null | grep -q "inet " && { echo "tun0"; return; }
  echo ""
}

fetch_wan_ip() {
  local iface url ip
  iface="$(pick_vpn_iface)"
  local -a curl_args=()
  [[ -n "$iface" ]] && curl_args+=(--interface "$iface")
  if command -v curl >/dev/null 2>&1; then
    for url in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
      ip="$(curl -4fsS --max-time 3 "${curl_args[@]}" "$url" 2>/dev/null | tr -d '\r' | head -n1 || true)"
      [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && { printf '%s\n' "$ip"; return 0; }
    done
  fi
  if command -v dig >/dev/null 2>&1; then
    ip="$(dig +short -4 myip.opendns.com @resolver1.opendns.com 2>/dev/null | head -n1 || true)"
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && { printf '%s\n' "$ip"; return 0; }
  fi
  return 1
}

# ── Network info ─────────────────────────────────────────────────────────────

lan_status() {
  ip link show "$1" 2>/dev/null | grep -q "state UP" && echo "Online" || echo "Offline"
}

dns_primary() {
  local iface="$1" dns
  dns="$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf 2>/dev/null || true)"
  if [[ "$dns" == "127.0.0.53" ]] && command -v resolvectl >/dev/null 2>&1; then
    dns="$(resolvectl dns "$iface" 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1 || true)"
    if [[ -z "$dns" ]]; then
      dns="$(resolvectl status 2>/dev/null | awk '/DNS Servers:/ {print; exit}' | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1 || true)"
    fi
  fi
  [[ -n "$dns" ]] && echo "$dns" || echo "-"
}

subnet_mask() {
  local iface="$1" ipcidr cidr m
  ipcidr="$(ip -o -f inet addr show dev "$iface" 2>/dev/null | awk '{print $4}' | head -n1 || true)"
  [[ -n "$ipcidr" ]] || { echo "-"; return; }
  cidr="${ipcidr##*/}"
  m=$(( 0xffffffff << (32 - cidr) & 0xffffffff ))
  printf "%d.%d.%d.%d\n" $(( (m>>24)&255 )) $(( (m>>16)&255 )) $(( (m>>8)&255 )) $(( m&255 ))
}

# ── Pings ────────────────────────────────────────────────────────────────────

parse_ping_ms() {
  local host="$1" out
  out="$(ping -n -c1 -W1 "$host" 2>/dev/null | grep -o 'time=[0-9.]*' | head -n1 | cut -d= -f2 || true)"
  printf '%s\n' "$out"
}

speed_ratio() {
  awk -v ms="${1:-}" 'BEGIN {
    if (ms=="" || ms=="---") { print 0; exit }
    numeric=ms+0; max_ms=0.5
    if (numeric>max_ms) numeric=max_ms
    printf "%.6f\n", 1-(numeric/max_ms)
  }'
}

# ── SSH gate ─────────────────────────────────────────────────────────────────

gate_state() {
  SSH_TRIPPED="0"; SSH_STATUS="OK"; SSH_REASON=""; SSH_LEFT="0"
  local gate="$CORE_DIR/providers/pfsense/pf-ssh-gate.sh"
  [[ -x "$gate" ]] || return
  SSH_STATUS="$("$gate" status 2>/dev/null || printf 'OK')"
  if [[ "$SSH_STATUS" == TRIPPED* ]]; then
    SSH_TRIPPED="1"
    SSH_LEFT="$(printf '%s' "$SSH_STATUS" | awk -F'[=|]' '{for(i=1;i<=NF;i++) if($i=="left"){print $(i+1);exit}}')"
    SSH_REASON="$(printf '%s' "$SSH_STATUS" | awk -F'[=|]' '{for(i=1;i<=NF;i++) if($i=="reason"){print $(i+1);exit}}')"
    SSH_LEFT="${SSH_LEFT:-0}"; SSH_REASON="${SSH_REASON:-PF_SSH_FAIL}"
  fi
}

# ── Resolve profiles from suite TOML (used for reading existing provider JSON) ──

SUITE_ID="${GTEX62_SUITE_ID:-${GTEX62_CONKY_SUITE_ID:-}}"
SUITE_TOML="${CONFIG_ROOT}/suites/${SUITE_ID}.toml"
NETWORK_PROFILE="$(parse_section_value "$SUITE_TOML" profiles network || true)"
CONNECTIVITY_PROFILE="$(parse_section_value "$SUITE_TOML" profiles connectivity || true)"
PFSENSE_PROFILE="$(parse_section_value "$SUITE_TOML" profiles pfsense || true)"
NETWORK_PROFILE="${NETWORK_PROFILE:-local}"
CONNECTIVITY_PROFILE="${CONNECTIVITY_PROFILE:-default}"
PFSENSE_PROFILE="${PFSENSE_PROFILE:-main_router}"

NETWORK_JSON="$CACHE_ROOT/shared/network/$NETWORK_PROFILE/current.json"
CONNECTIVITY_JSON="$CACHE_ROOT/shared/connectivity/$CONNECTIVITY_PROFILE/current.json"
PFSENSE_STATUS_JSON="$CACHE_ROOT/shared/pfsense/$PFSENSE_PROFILE/status.json"
SPEEDTEST="$CORE_DIR/providers/connectivity/speedtest_snapshot.sh"

# ── Main ─────────────────────────────────────────────────────────────────────

IFACE="$(json_value "$NETWORK_JSON" '.interface.name // empty' || true)"
IFACE="${IFACE:-$(detect_iface)}"

gate_state

TITLE="$(normalize "$(json_value "$NETWORK_JSON" '.interface.title // empty' || true)")"
TITLE="${TITLE:-$(nic_friendly "$IFACE" 2>/dev/null || true)}"
STATUS="$(normalize "$(json_value "$NETWORK_JSON" '.interface.state // empty' || true)")"
STATUS="${STATUS:-$(lan_status "$IFACE")}"
STATUS_UPPER="$(printf '%s' "${STATUS:-OFFLINE}" | tr '[:lower:]' '[:upper:]')"
LIVE_PERCENT="$(  [[ "$STATUS_UPPER" == "ONLINE" ]] && echo "100" || echo "0" )"

SPEEDTEST_DOWN="$(json_value "$CONNECTIVITY_JSON" '.speedtest.display_down_mbps // .speedtest.download_mbps // empty' || true)"
# shellcheck disable=SC2016
SPEEDTEST_AGE="$(json_value "$CONNECTIVITY_JSON" '
  def zpad: tostring | if length==1 then "0"+. else . end;
  def agefmt($s): ($s|tonumber|floor) as $sec
    | if $sec < 86400 then (($sec/3600)|floor|zpad)+":"+(($sec%3600/60)|floor|zpad)
      else (($sec/86400)|floor|zpad)+"d" end;
  if (.speedtest.raw.timestamp//.speedtest.raw.result.timestamp//.speedtest.raw.result.date//null)!=null then
    ((now-((.speedtest.raw.timestamp//.speedtest.raw.result.timestamp//.speedtest.raw.result.date)|fromdateiso8601))|if.<0 then 0 else . end|agefmt(.))
  elif .speedtest.age_seconds!=null then agefmt(.speedtest.age_seconds)
  elif .speedtest.age_label then .speedtest.age_label
  elif .speedtest.age_days!=null then (.speedtest.age_days|tonumber|floor|zpad)+"d"
  else empty end
' || true)"
SPEEDTEST_DELTA="$(json_value "$CONNECTIVITY_JSON" 'if .speedtest.download_delta_mbps==null then empty else .speedtest.download_delta_mbps|if .>=0 then "+"+tostring else tostring end end' || true)"
if [[ -z "$SPEEDTEST_DOWN" || -z "$SPEEDTEST_AGE" || -z "$SPEEDTEST_DELTA" ]]; then
  SPEED_PAIR="$("$SPEEDTEST" read 500 500 7 2>/dev/null || true)"
  SPEEDTEST_DOWN="${SPEEDTEST_DOWN:-$(printf '%s' "$SPEED_PAIR" | awk -F'|' 'NF>=1{print $1;exit}')}"
  SPEEDTEST_AGE="${SPEEDTEST_AGE:-$(printf '%s' "$SPEED_PAIR" | awk -F'|' 'NF>=2{print $2;exit}')}"
  SPEEDTEST_DELTA="${SPEEDTEST_DELTA:-$(printf '%s' "$SPEED_PAIR" | awk -F'|' 'NF>=3{print $3;exit}')}"
fi
SPEEDTEST_DOWN="${SPEEDTEST_DOWN:-500}"
SPEEDTEST_AGE="${SPEEDTEST_AGE:---:--}"
SPEEDTEST_DELTA="${SPEEDTEST_DELTA:----}"
if [[ "$SPEEDTEST_DELTA" =~ ^[+-]?[0-9]+$ ]]; then
  printf -v SPEEDTEST_DELTA "%+04d" "$SPEEDTEST_DELTA"
fi

VPN_STATE="$(normalize "$(vpn_state)")"
WAN_IP="$(normalize "$(json_value "$NETWORK_JSON" '.interface.wan_ip // empty' || true)")"
if [[ -z "$WAN_IP" ]]; then
  WAN_IP="$(fetch_wan_ip 2>>"$LOG_FILE" || true)"
fi
if [[ "$VPN_STATE" == "ON" ]]; then
  VPN_WAN_IP="$(piactl get vpnip 2>/dev/null | tr -d '[:space:]' || true)"
  [[ -n "$VPN_WAN_IP" ]] && WAN_IP="$VPN_WAN_IP"
fi

LAN_IP="$(normalize "$(json_value "$NETWORK_JSON" '.interface.lan_ip // empty' || true)")"
LAN_IP="${LAN_IP:-$(ip -o -4 addr show dev "$IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)}"
DNS="$(normalize "$(json_value "$NETWORK_JSON" '.interface.dns // empty' || true)")"
DNS="${DNS:-$(dns_primary "$IFACE")}"
SUBNET="$(normalize "$(json_value "$NETWORK_JSON" '.interface.subnet // empty' || true)")"
SUBNET="${SUBNET:-$(subnet_mask "$IFACE")}"
GATEWAY="$(normalize "$(json_value "$NETWORK_JSON" '.interface.gateway // empty' || true)")"
GATEWAY="${GATEWAY:-$(ip route show default 2>/dev/null | awk '/default/{print $3;exit}' || true)}"

# Pings (parallel)
PING_WORK_DIR="$TMP_DIR/net_ping_${PROFILE_ID}_$$"
mkdir -p "$PING_WORK_DIR"
( parse_ping_ms "1.1.1.1" > "$PING_WORK_DIR/cf_1111_ms" ) &
( parse_ping_ms "8.8.8.8" > "$PING_WORK_DIR/google_8888_ms" ) &
wait
CF_1111_MS="$(cat "$PING_WORK_DIR/cf_1111_ms" 2>/dev/null || true)"
GOOGLE_8888_MS="$(cat "$PING_WORK_DIR/google_8888_ms" 2>/dev/null || true)"
rm -rf "$PING_WORK_DIR"

# Pfsense gate override
PFSENSE_TRIPPED="$(json_value "$PFSENSE_STATUS_JSON" 'if .ssh_gate.tripped then "1" else "0" end' || true)"
PFSENSE_STATUS="$(json_value "$PFSENSE_STATUS_JSON" '.ssh_gate.status // empty' || true)"
PFSENSE_REASON="$(json_value "$PFSENSE_STATUS_JSON" '.ssh_gate.reason // empty' || true)"
PFSENSE_LEFT="$(json_value "$PFSENSE_STATUS_JSON" '.ssh_gate.left_seconds // empty' || true)"
SSH_TRIPPED="${PFSENSE_TRIPPED:-$SSH_TRIPPED}"
SSH_STATUS="${PFSENSE_STATUS:-$SSH_STATUS}"
SSH_REASON="${PFSENSE_REASON:-$SSH_REASON}"
SSH_LEFT="${PFSENSE_LEFT:-$SSH_LEFT}"

{
  printf 'GENERATED_AT=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'IFACE=%s\n'            "$(escape_value "$IFACE")"
  printf 'TITLE=%s\n'            "$(escape_value "${TITLE:-NIC UNKNOWN}")"
  printf 'STATUS=%s\n'           "$(escape_value "$STATUS_UPPER")"
  printf 'LIVE_PERCENT=%s\n'     "$(escape_value "$LIVE_PERCENT")"
  printf 'SPEEDTEST_DOWN=%s\n'   "$(escape_value "$SPEEDTEST_DOWN")"
  printf 'SPEEDTEST_AGE=%s\n'    "$(escape_value "$SPEEDTEST_AGE")"
  printf 'SPEEDTEST_DELTA=%s\n'  "$(escape_value "$SPEEDTEST_DELTA")"
  printf 'WAN_IP=%s\n'           "$(escape_value "${WAN_IP:--}")"
  printf 'VPN_STATE=%s\n'        "$(escape_value "$VPN_STATE")"
  printf 'LAN_IP=%s\n'           "$(escape_value "${LAN_IP:--}")"
  printf 'DNS=%s\n'              "$(escape_value "${DNS:--}")"
  printf 'SUBNET=%s\n'           "$(escape_value "${SUBNET:--}")"
  printf 'GATEWAY=%s\n'          "$(escape_value "${GATEWAY:--}")"
  printf 'CF_1111_MS=%s\n'       "$(escape_value "${CF_1111_MS:-}")"
  printf 'GOOGLE_8888_MS=%s\n'   "$(escape_value "${GOOGLE_8888_MS:-}")"
  printf 'SSH_TRIPPED=%s\n'      "$(escape_value "$SSH_TRIPPED")"
  printf 'SSH_STATUS=%s\n'       "$(escape_value "$SSH_STATUS")"
  printf 'SSH_REASON=%s\n'       "$(escape_value "$SSH_REASON")"
  printf 'SSH_LEFT=%s\n'         "$(escape_value "$SSH_LEFT")"
} > "$STATE_TMP"
mv -f "$STATE_TMP" "$STATE_OUT"

# VLAN pings (parallel)
: > "$VLAN_TMP"
if [[ -s "$NETWORK_JSON" ]]; then
  mapfile -t VLAN_HOSTS < <(jq -r '.vlan_hosts[]?.host // empty' "$NETWORK_JSON" 2>/dev/null || true)
else
  VLAN_HOSTS=()
fi
if [[ "${#VLAN_HOSTS[@]}" -eq 0 ]]; then
  # fallback: read from site.toml [vlan] hosts array
  mapfile -t VLAN_HOSTS < <(
    awk '/^\[vlan\]/{in_s=1;next} /^\[/{in_s=0} in_s && /^hosts[[:space:]]*=/{
      gsub(/.*\[/,""); gsub(/\].*/,""); gsub(/"/,""); gsub(/,/,"\n"); print
    }' "$SITE_TOML" 2>/dev/null | tr -d ' ' | grep -v '^$' || true
  )
fi
if [[ "${#VLAN_HOSTS[@]}" -eq 0 ]]; then
  VLAN_HOSTS=(192.168.10.1 192.168.20.1 192.168.30.1 192.168.40.1 192.168.50.1)
fi

VLAN_WORK_DIR="$TMP_DIR/net_vlan_${PROFILE_ID}_$$"
mkdir -p "$VLAN_WORK_DIR"
idx=0
for gateway in "${VLAN_HOSTS[@]}"; do
  [[ -n "$gateway" ]] || continue
  idx=$((idx + 1))
  (
    ms="$(parse_ping_ms "$gateway")"
    if [[ -n "${ms:-}" ]]; then
      ms_display="$(printf '%.2f' "$ms")"
      ratio="$(speed_ratio "$ms")"
    else
      ms_display="---"
      ratio="0"
    fi
    printf '%s\t%s\t%s\n' "$gateway" "$ratio" "$ms_display" > "$VLAN_WORK_DIR/$(printf '%03d' "$idx").tsv"
  ) &
done
wait
for row_file in "$VLAN_WORK_DIR"/*.tsv; do
  [[ -f "$row_file" ]] && cat "$row_file" >> "$VLAN_TMP"
done
rm -rf "$VLAN_WORK_DIR"
mv -f "$VLAN_TMP" "$VLAN_OUT"

write_status "ok"
