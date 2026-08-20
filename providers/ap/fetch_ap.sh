#!/usr/bin/env bash
# providers/ap/fetch_ap.sh
# Core AP provider (Zyxel access points — WBE530/NWA-series, password auth).
# Collects model, CPU%, and associated-station MAC/IPv4 pairs from each AP in
# a single SSH session per device (was 3 sessions/AP in the legacy scripts),
# joins client IPs against the IP->Name map, and writes
# shared/pfsense/{profile}/ap_status.json and ap_clients.json.
#
# Zyxel APs do not support key-based SSH. Auth is via sshpass reading a
# password file at a fixed path (same convention as the legacy
# gtex62-tech-hud/scripts/zyxel_cmd.sh transport it replaces) — this is a
# permanent hardware constraint, not a TODO, and the path is intentionally
# not made TOML-configurable so there is exactly one place credentials live.
#
# Gated independently (runtime/ap/ssh_state) from the pfSense/Pi-hole gates —
# a tripped AP domain must never block or be blocked by an unrelated one, even
# though this shares no host with any pfSense-domain SSH target at all.
set -euo pipefail

PROFILE_ID="${1:-main_router}"
CONFIG_ROOT="${GTEX62_CONFIG_DIR:-${GTEX62_CONKY_CONFIG_DIR:-$HOME/.config/gtex62-core}}"
CACHE_ROOT="${GTEX62_CACHE_DIR:-${GTEX62_CONKY_CACHE_DIR:-$HOME/.cache/gtex62-core}}"
PROFILE_TOML="$CONFIG_ROOT/profiles/pfsense/${PROFILE_ID}.toml"
SITE_TOML="$CONFIG_ROOT/site.toml"
OUT_DIR="$CACHE_ROOT/shared/pfsense/${PROFILE_ID}"
STATUS_JSON="$OUT_DIR/ap_status.json"
CLIENTS_JSON="$OUT_DIR/ap_clients.json"
TMP_DIR="$CACHE_ROOT/tmp"
GATE_DIR="$CACHE_ROOT/runtime/ap"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
GATE_SCRIPT="$SCRIPT_DIR/../pfsense/pf-ssh-gate.sh"
PASSFILE="$HOME/.config/zyxel_ap/.pass"
mkdir -p "$OUT_DIR" "$TMP_DIR" "$GATE_DIR"

parse_root_value() {
  local path="$1" key="$2"
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
  local path="$1" section="$2" key="$3"
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
    printf 'TRIPPED|left=%s|reason=%s\n' "$left" "${reason:-AP_SSH_FAIL}"
  else
    printf 'OK\n'
  fi
}

should_trip_gate() {
  local msg="${1-}"
  [[ "$msg" =~ [Pp]ermission\ denied ]] && return 0
  [[ "$msg" =~ [Aa]uthentication\ failed ]] && return 0
  [[ "$msg" =~ [Aa]ccess\ denied ]] && return 0
  [[ "$msg" =~ [Tt]oo\ many\ authentication\ failures ]] && return 0
  [[ "$msg" =~ [Hh]ost\ key\ verification\ failed ]] && return 0
  return 1
}

write_stub() {
  local state="$1" note="$2" gate="$3"
  local tripped="false" left="0" reason=""
  if [[ "$gate" == TRIPPED* ]]; then
    tripped="true"
    left="$(printf '%s' "$gate" | awk -F'[=|]' '{for(i=1;i<=NF;i++) if($i=="left") {print $(i+1); exit}}')"
    reason="$(printf '%s' "$gate" | awk -F'[=|]' '{for(i=1;i<=NF;i++) if($i=="reason") {print $(i+1); exit}}')"
  fi
  for out in "$STATUS_JSON" "$CLIENTS_JSON"; do
    collector="ap_status"; [[ "$out" == "$CLIENTS_JSON" ]] && collector="ap_clients"
    jq -n \
      --arg state       "$state" \
      --arg profile     "$PROFILE_ID" \
      --arg collector   "$collector" \
      --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg note        "$note" \
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
        ssh_target:"ap-fleet",
        ssh_gate:{status:$gate_status, tripped:$tripped, left_seconds:$left, reason:$reason},
        aps:[]
      }' > "$out"
  done
}

# -------------------------------------------------------------------------
# Pre-flight checks
# -------------------------------------------------------------------------

ENABLED="$(parse_section_value "$PROFILE_TOML" ap enabled || true)"
ENABLED="${ENABLED:-$(parse_section_value "$SITE_TOML" ap enabled || true)}"
if [[ "${ENABLED:-true}" != "true" ]]; then
  write_stub "disabled" "profile disabled" "$(gate_status)"
  exit 0
fi

IPS_CSV="$(parse_section_value "$SITE_TOML" ap ips || true)"
LABELS_CSV="$(parse_section_value "$SITE_TOML" ap labels || true)"
if [[ -z "$IPS_CSV" ]]; then
  write_stub "error" "no ap ips configured" "$(gate_status)"
  exit 0
fi
if [[ ! -s "$PASSFILE" ]]; then
  write_stub "error" "password file not found: $PASSFILE" "$(gate_status)"
  exit 0
fi

DEVICES_TOML="$CONFIG_ROOT/devices.toml"

IFS=',' read -r -a AP_IPS <<< "$IPS_CSV"
IFS=',' read -r -a AP_LABELS <<< "$LABELS_CSV"

# -------------------------------------------------------------------------
# Gate check (own state dir — never shares runtime/pfsense or runtime/pihole)
# -------------------------------------------------------------------------

GATE="$(gate_status)"
if [[ "$GATE" == TRIPPED* ]]; then
  write_stub "degraded" "ssh gate tripped" "$GATE"
  exit 0
fi

# -------------------------------------------------------------------------
# Cache TTL
# -------------------------------------------------------------------------

CACHE_TTL="$(parse_section_value "$PROFILE_TOML" ap cache_ttl_sec || true)"
CACHE_TTL="${CACHE_TTL:-$(parse_section_value "$SITE_TOML" ap cache_ttl_sec || true)}"
CACHE_TTL="${CACHE_TTL:-120}"

if [[ -f "$STATUS_JSON" ]]; then
  now_ts="$(date +%s)"
  file_ts="$(stat -c %Y "$STATUS_JSON" 2>/dev/null || echo 0)"
  age=$(( now_ts - file_ts ))
  if [[ "$age" -lt "$CACHE_TTL" ]]; then
    exit 0
  fi
fi

# -------------------------------------------------------------------------
# SSH collection — one session per AP: version + cpu + station info batched
# -------------------------------------------------------------------------

SSH_OPTS=(-o ConnectTimeout=5 -o ConnectionAttempts=1 -o ServerAliveInterval=5 \
          -o ServerAliveCountMax=1 -o LogLevel=ERROR -o PubkeyAuthentication=no \
          -o KbdInteractiveAuthentication=yes \
          -o PreferredAuthentications=keyboard-interactive,password \
          -o NumberOfPasswordPrompts=1 -o StrictHostKeyChecking=accept-new)

MANIFEST="$TMP_DIR/ap_manifest_$$.tsv"
: > "$MANIFEST"
trap 'rm -f "$MANIFEST" "$TMP_DIR"/ap_raw_$$_*.txt' EXIT

for idx in "${!AP_IPS[@]}"; do
  ip="${AP_IPS[$idx]}"
  label="${AP_LABELS[$idx]:-AP$((idx+1))}"
  raw="$TMP_DIR/ap_raw_${$}_${idx}.txt"
  errf="$TMP_DIR/ap_err_${$}_${idx}.txt"

  GATE="$(gate_status)"
  if [[ "$GATE" == TRIPPED* ]]; then
    printf '%s\t%s\t%s\t0\t1\t%s\n' "$idx" "$label" "$ip" "$raw" >> "$MANIFEST"
    : > "$raw"
    continue
  fi

  rc=0
  sshpass -f "$PASSFILE" ssh "${SSH_OPTS[@]}" -tt admin@"$ip" \
    > "$raw" 2>"$errf" <<'EOC' || rc=$?
show version
show cpu status
show wireless-hal station info
exit
EOC

  if [[ $rc -ne 0 ]]; then
    errtext="$(tr -d '\r' < "$errf")"
    if should_trip_gate "$errtext"; then
      GATE_STATE_DIR="$GATE_DIR" "$GATE_SCRIPT" trip AP_SSH_FAIL
    fi
    printf '%s\t%s\t%s\t1\t%s\t%s\n' "$idx" "$label" "$ip" "$rc" "$raw" >> "$MANIFEST"
  else
    GATE_STATE_DIR="$GATE_DIR" "$GATE_SCRIPT" reset
    printf '%s\t%s\t%s\t1\t0\t%s\n' "$idx" "$label" "$ip" "$raw" >> "$MANIFEST"
  fi
  rm -f "$errf"
done

GATE_FINAL="$(gate_status)"
FINAL_STATE="ok"
FINAL_NOTE=""
if [[ "$GATE_FINAL" == TRIPPED* ]]; then
  FINAL_STATE="degraded"
  FINAL_NOTE="ssh gate tripped during poll"
fi

# -------------------------------------------------------------------------
# Build ap_status.json and ap_clients.json from collected raw output
# -------------------------------------------------------------------------

python3 - "$MANIFEST" "$DEVICES_TOML" "$STATUS_JSON" "$CLIENTS_JSON" \
  "$PROFILE_ID" "$FINAL_STATE" "$FINAL_NOTE" "$GATE_FINAL" \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" <<'PY'
import json, os, re, sys, tomllib

(manifest_path, devices_path, status_out, clients_out,
 profile_id, final_state, final_note, gate_str, generated_at) = sys.argv[1:10]

MODEL_RE  = re.compile(r'^model\s*:\s*(.+?)\s*$', re.MULTILINE)
CPU_RE    = re.compile(r'^CPU utilization:\s*([0-9]+(?:\.[0-9]+)?)', re.MULTILINE)
MAC_RE    = re.compile(r'^\s{2}MAC:\s*(\S+)\s*$')
IPV4_RE   = re.compile(r'^\s{2}IPv4:\s*(\S+)\s*$')

def load_devicemap(path):
    """Returns {mac (lowercase): display_name}, joined across all VLANs.
    The 2 ip:-keyed WLED entries (no MAC) are skipped by design — they
    never show up as AP clients anyway."""
    name_by_mac = {}
    if not os.path.isfile(path):
        return name_by_mac
    with open(path, "rb") as fh:
        data = tomllib.load(fh)
    for vlan in data.get("vlan", {}).values():
        for dev in vlan.get("devices", {}).values():
            mac = dev.get("mac", "")
            name = dev.get("display_name", "")
            if mac and name:
                name_by_mac[mac.lower()] = name
    return name_by_mac

def parse_ap_output(text):
    """Returns (model, cpu_pct, mac_count, pairs) from one AP's raw session output."""
    model_m = MODEL_RE.search(text)
    cpu_m = CPU_RE.search(text)
    model = model_m.group(1) if model_m else None
    cpu_pct = None
    if cpu_m:
        try:
            v = float(cpu_m.group(1))
            cpu_pct = int(v) if v.is_integer() else v
        except ValueError:
            cpu_pct = None

    pairs = []
    mac_count = 0
    pending_mac = None
    for line in text.splitlines():
        m = MAC_RE.match(line)
        if m:
            mac_count += 1
            pending_mac = m.group(1)
            continue
        ip_m = IPV4_RE.match(line)
        if ip_m and pending_mac:
            pairs.append((pending_mac, ip_m.group(1)))
            pending_mac = None

    return model, cpu_pct, mac_count, pairs

name_by_mac = load_devicemap(devices_path)

aps_status = []
aps_clients = []

with open(manifest_path, "r", encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        idx, label, ip, attempted, rc, raw_path = line.split("\t")
        attempted = attempted == "1"
        online = attempted and rc == "0"

        model = cpu_pct = None
        client_count = 0
        known = []
        unknown = []

        if online and os.path.isfile(raw_path):
            with open(raw_path, "r", encoding="utf-8", errors="replace") as rf:
                text = rf.read().replace("\r", "")
            model, cpu_pct, client_count, pairs = parse_ap_output(text)
            for mac, cip in pairs:
                if cip == "0.0.0.0" or cip.startswith("172.29."):
                    continue
                name = name_by_mac.get(mac.lower())
                if name:
                    known.append({"mac": mac, "ip": cip, "name": name})
                else:
                    unknown.append(cip)
            known.sort(key=lambda c: c["name"])
            unknown = sorted(set(unknown))

        aps_status.append({
            "label": label,
            "ip": ip,
            "online": online,
            "model": model,
            "cpu_pct": cpu_pct,
            "clients": client_count,
        })
        aps_clients.append({
            "label": label,
            "ip": ip,
            "online": online,
            "clients": known,
            "unknown": unknown,
        })

tripped = gate_str.startswith("TRIPPED")
left = 0
reason = ""
if tripped:
    for part in gate_str.split("|"):
        if part.startswith("left="):
            try:
                left = int(part[5:])
            except ValueError:
                pass
        elif part.startswith("reason="):
            reason = part[7:]

def envelope(collector, extra):
    payload = {
        "state": final_state,
        "profile": profile_id,
        "collector": collector,
        "generated_at": generated_at,
        "ssh_target": "ap-fleet",
        "ssh_gate": {
            "status": gate_str,
            "tripped": tripped,
            "left_seconds": left,
            "reason": reason,
        },
    }
    if final_note:
        payload["note"] = final_note
    payload.update(extra)
    return payload

status_payload = envelope("ap_status", {"aps": aps_status})
clients_payload = envelope("ap_clients", {"aps": aps_clients})

for out_path, payload in ((status_out, status_payload), (clients_out, clients_payload)):
    tmp = out_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, separators=(",", ":"))
    os.replace(tmp, out_path)
PY
