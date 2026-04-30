#!/usr/bin/env bash
set -euo pipefail

PROFILE_ID="${1:-local}"
CONFIG_ROOT="${GTEX62_CONFIG_DIR:-${GTEX62_CONKY_CONFIG_DIR:-$HOME/.config/gtex62-core}}"
CACHE_ROOT="${GTEX62_CACHE_DIR:-${GTEX62_CONKY_CACHE_DIR:-$HOME/.cache/gtex62-core}}"
PROFILE_TOML="$CONFIG_ROOT/profiles/network/${PROFILE_ID}.toml"
SITE_TOML="$CONFIG_ROOT/site.toml"
OUT_DIR="$CACHE_ROOT/shared/network/${PROFILE_ID}"
CURRENT_JSON="$OUT_DIR/current.json"
STATUS_JSON="$OUT_DIR/status.json"
TMP_DIR="$CACHE_ROOT/tmp"
mkdir -p "$OUT_DIR" "$TMP_DIR"

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

parse_array_value() {
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
      gsub(/^\[/, "", v)
      gsub(/\]$/, "", v)
      gsub(/"/, "", v)
      print v
      exit
    }
  ' "$path"
}

write_status() {
  jq -n \
    --arg state "$1" \
    --arg profile "$PROFILE_ID" \
    --arg collector "network" \
    --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg note "$2" \
    '{state:$state, profile:$profile, collector:$collector, generated_at:$generated_at, note:$note}' > "$STATUS_JSON"
}

if [[ ! -f "$PROFILE_TOML" ]]; then
  write_status "error" "missing profile toml"
  exit 0
fi

ENABLED="$(parse_root_value "$PROFILE_TOML" enabled || true)"
if [[ "${ENABLED:-true}" != "true" ]]; then
  write_status "disabled" "profile disabled"
  exit 0
fi

detect_iface() {
  local configured
  configured="$(parse_root_value "$PROFILE_TOML" primary_interface || true)"
  configured="${configured:-$(parse_section_value "$SITE_TOML" network primary_interface || true)}"
  if [[ -n "$configured" ]]; then
    printf '%s\n' "$configured"
    return
  fi
  ip route show default 2>/dev/null | awk '/default/ {for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}'
}

normalize() {
  printf '%s' "${1:-}" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
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

nic_model() {
  local devpath pci modaline
  devpath="$(readlink -f "/sys/class/net/$1/device" 2>/dev/null || true)"
  if [[ -n "$devpath" ]]; then
    pci="${devpath##*/}"
    modaline="$(lspci -s "$pci" 2>/dev/null | sed -E 's/^[0-9a-f:.]+[[:space:]]+[^:]+:[[:space:]]+//')"
    if [[ -n "$modaline" ]]; then
      echo "$modaline"
      return
    fi
  fi
  ethtool -i "$1" 2>/dev/null | awk -F': ' '/driver:/{print "Driver: "$2; exit}' || echo "$1"
}

nic_alias() {
  local iface="$1" pci model alias
  pci="$(pci_id_for_iface "$iface" 2>/dev/null || true)"
  if [[ -n "$pci" ]] && alias_by_pci "$pci" >/dev/null 2>&1; then
    alias="$(alias_by_pci "$pci")"
  else
    model="$(nic_model "$iface")"
    alias="$(echo "$model" | sed -E 's/^[Ii]ntel [Cc]orporation /Intel /; s/[Ee]thernet (C|c)ontroller:?[[:space:]]*//; s/^[[:space:]]+//')"
  fi
  printf '%s\n' "${alias:-$iface}"
}

mask_from_cidr() {
  local cidr="${1##*/}" m
  m=$(( 0xffffffff << (32 - cidr) & 0xffffffff ))
  printf "%d.%d.%d.%d\n" $(( (m>>24) & 255 )) $(( (m>>16) & 255 )) $(( (m>>8) & 255 )) $(( m & 255 ))
}

public_ip() {
  local url ip
  if command -v curl >/dev/null 2>&1; then
    for url in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
      ip="$(curl -4fsS --max-time 2 "$url" 2>/dev/null | tr -d '\r' | head -n1 || true)"
      [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && { echo "$ip"; return; }
    done
  fi
  if command -v dig >/dev/null 2>&1; then
    dig +short -4 myip.opendns.com @resolver1.opendns.com 2>/dev/null | head -n1 || true
  fi
}

ping_ms() {
  ping -n -c1 -W1 "$1" 2>/dev/null | grep -o 'time=[0-9.]*' | head -n1 | cut -d= -f2 || true
}

IFACE="$(detect_iface)"
IFACE="${IFACE:-eno1}"
STATE="$(ip link show "$IFACE" 2>/dev/null | grep -q "state UP" && echo "online" || echo "offline")"
IPCIDR="$(ip -o -f inet addr show dev "$IFACE" 2>/dev/null | awk '{print $4}' | head -n1)"
LAN_IP="${IPCIDR%%/*}"
[[ "$LAN_IP" == "$IPCIDR" ]] && LAN_IP=""
SUBNET=""
[[ -n "$IPCIDR" ]] && SUBNET="$(mask_from_cidr "$IPCIDR")"
DNS="$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf 2>/dev/null || true)"
if [[ "$DNS" == "127.0.0.53" ]] && command -v resolvectl >/dev/null 2>&1; then
  DNS="$(resolvectl dns "$IFACE" 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)"
fi
GATEWAY="$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')"
TITLE="$(normalize "$(nic_alias "$IFACE")")"
WAN_IP="$(normalize "$(public_ip)")"
VLAN_HOSTS="$(parse_array_value "$PROFILE_TOML" vlan hosts || true)"
VLAN_LABELS="$(parse_array_value "$PROFILE_TOML" vlan labels || true)"
VLAN_HOSTS="${VLAN_HOSTS:-$(parse_array_value "$SITE_TOML" vlan hosts || true)}"
VLAN_LABELS="${VLAN_LABELS:-$(parse_array_value "$SITE_TOML" vlan labels || true)}"

TMP_OUT="$TMP_DIR/network_current_${PROFILE_ID}.tmp"
python3 - "$TMP_OUT" "$PROFILE_ID" "$IFACE" "$TITLE" "$STATE" "$LAN_IP" "$DNS" "$SUBNET" "$GATEWAY" "$WAN_IP" "$VLAN_HOSTS" "$VLAN_LABELS" <<'PY'
import json
import subprocess
import sys
from datetime import datetime, timezone

_, out_path, profile, iface, title, state, lan_ip, dns, subnet, gateway, wan_ip, vlan_hosts, vlan_labels = sys.argv

hosts = [item.strip() for item in vlan_hosts.split(",") if item.strip()]
labels = [item.strip() for item in vlan_labels.split(",") if item.strip()]
rows = []
for idx, host in enumerate(hosts):
    label = labels[idx] if idx < len(labels) else host
    ms = None
    try:
        out = subprocess.check_output(["ping", "-n", "-c1", "-W1", host], stderr=subprocess.DEVNULL, text=True)
        marker = "time="
        if marker in out:
            ms = float(out.split(marker, 1)[1].split()[0])
    except Exception:
        pass
    rows.append({"label": label, "host": host, "ms": ms, "reachable": ms is not None})

payload = {
    "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "profile": profile,
    "interface": {
        "name": iface,
        "title": title,
        "state": state,
        "is_online": state == "online",
        "lan_ip": lan_ip or None,
        "dns": dns or None,
        "subnet": subnet or None,
        "gateway": gateway or None,
        "wan_ip": wan_ip or None,
    },
    "vlan_hosts": rows,
}
with open(out_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY

mv -f "$TMP_OUT" "$CURRENT_JSON"
write_status "ok" ""
