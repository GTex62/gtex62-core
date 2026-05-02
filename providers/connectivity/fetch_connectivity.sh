#!/usr/bin/env bash
set -euo pipefail

PROFILE_ID="${1:-default}"
CONFIG_ROOT="${GTEX62_CONFIG_DIR:-${GTEX62_CONKY_CONFIG_DIR:-$HOME/.config/gtex62-core}}"
CACHE_ROOT="${GTEX62_CACHE_DIR:-${GTEX62_CONKY_CACHE_DIR:-$HOME/.cache/gtex62-core}}"
PROFILE_TOML="$CONFIG_ROOT/profiles/connectivity/${PROFILE_ID}.toml"
SITE_TOML="$CONFIG_ROOT/site.toml"
OUT_DIR="$CACHE_ROOT/shared/connectivity/${PROFILE_ID}"
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

write_status() {
  local state="$1"
  local note="$2"
  jq -n \
    --arg state "$state" \
    --arg profile "$PROFILE_ID" \
    --arg collector "connectivity" \
    --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg note "$note" \
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

ping_ms() {
  local host="$1"
  ping -n -c1 -W1 "$host" 2>/dev/null | grep -o 'time=[0-9.]*' | head -n1 | cut -d= -f2 || true
}

speedtest_json() {
  local server_id="$1"
  if ! command -v speedtest >/dev/null 2>&1; then
    return 1
  fi
  if [[ -n "$server_id" ]]; then
    speedtest -f json --accept-license --accept-gdpr -s "$server_id" 2>/dev/null
  else
    speedtest -f json --accept-license --accept-gdpr 2>/dev/null
  fi
}

PRIMARY_HOST="$(parse_section_value "$PROFILE_TOML" ping primary_host || true)"
SECONDARY_HOST="$(parse_section_value "$PROFILE_TOML" ping secondary_host || true)"
SPEED_ENABLED="$(parse_section_value "$PROFILE_TOML" speedtest enabled || true)"
BASELINE_DOWN="$(parse_section_value "$PROFILE_TOML" speedtest baseline_down_mbps || true)"
FALLBACK_DOWN="$(parse_section_value "$PROFILE_TOML" speedtest fallback_down_mbps || true)"
MAX_AGE_DAYS="$(parse_section_value "$PROFILE_TOML" speedtest max_age_days || true)"
SERVER_ID="$(parse_section_value "$PROFILE_TOML" speedtest server_id || true)"
BASELINE_DOWN="${BASELINE_DOWN:-$(parse_section_value "$SITE_TOML" speedtest baseline_down_mbps || true)}"
FALLBACK_DOWN="${FALLBACK_DOWN:-$(parse_section_value "$SITE_TOML" speedtest fallback_down_mbps || true)}"
SERVER_ID="${SERVER_ID:-$(parse_section_value "$SITE_TOML" speedtest server_id || true)}"
PRIMARY_HOST="${PRIMARY_HOST:-8.8.8.8}"
SECONDARY_HOST="${SECONDARY_HOST:-1.1.1.1}"
SPEED_ENABLED="${SPEED_ENABLED:-true}"
BASELINE_DOWN="${BASELINE_DOWN:-500}"
FALLBACK_DOWN="${FALLBACK_DOWN:-500}"
MAX_AGE_DAYS="${MAX_AGE_DAYS:-14}"

PING_PRIMARY_MS="$(ping_ms "$PRIMARY_HOST")"
PING_SECONDARY_MS="$(ping_ms "$SECONDARY_HOST")"
TMP_SPEED="$TMP_DIR/connectivity_speedtest_${PROFILE_ID}.json"
SPEED_STATE="disabled"
SPEED_NOTE=""
if [[ "$SPEED_ENABLED" == "true" ]]; then
  if [[ -s "$CURRENT_JSON" ]] && jq -e --argjson max "$MAX_AGE_DAYS" '
      (.speedtest.raw.timestamp // .speedtest.raw.result.timestamp // null) as $ts
      | $ts != null and ((now - ($ts | fromdateiso8601)) / 86400) < $max
    ' "$CURRENT_JSON" >/dev/null 2>&1; then
    jq '.speedtest.raw // {}' "$CURRENT_JSON" > "$TMP_SPEED" 2>/dev/null || : > "$TMP_SPEED"
    SPEED_STATE="ok"
  elif speedtest_json "$SERVER_ID" > "$TMP_SPEED"; then
    SPEED_STATE="ok"
  else
    SPEED_STATE="error"
    SPEED_NOTE="speedtest failed or unavailable"
    : > "$TMP_SPEED"
  fi
else
  : > "$TMP_SPEED"
fi

TMP_OUT="$TMP_DIR/connectivity_current_${PROFILE_ID}.tmp"
python3 - "$TMP_SPEED" "$TMP_OUT" "$PROFILE_ID" "$PRIMARY_HOST" "$PING_PRIMARY_MS" "$SECONDARY_HOST" "$PING_SECONDARY_MS" "$BASELINE_DOWN" "$FALLBACK_DOWN" "$MAX_AGE_DAYS" "$SPEED_STATE" "$SPEED_NOTE" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

_, speed_path, out_path, profile, primary_host, primary_ms, secondary_host, secondary_ms, baseline_down, fallback_down, max_age_days, speed_state, speed_note = sys.argv

def fnum(value):
    try:
        return float(value)
    except Exception:
        return None

def inum(value):
    try:
        return int(round(float(value)))
    except Exception:
        return None

def mbps(section):
    if isinstance(section, dict) and section.get("bandwidth") is not None:
        try:
            return int(round((float(section["bandwidth"]) * 8) / 1_000_000))
        except Exception:
            return None
    return None

def age_label(seconds):
    if seconds is None:
        return None
    try:
        seconds = max(0, int(seconds))
    except Exception:
        return None
    minutes = seconds // 60
    if minutes < 1440:
        hours = minutes // 60
        mins = minutes % 60
        return f"{hours:02d}:{mins:02d}"
    days = minutes // 1440
    return f"{days:02d}d"

now = datetime.now(timezone.utc)
data = {}
if os.path.exists(speed_path) and os.path.getsize(speed_path) > 0:
    try:
        with open(speed_path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except Exception:
        data = {}

timestamp = None
if isinstance(data.get("result"), dict):
    timestamp = data["result"].get("timestamp") or data["result"].get("date")
timestamp = timestamp or data.get("timestamp")

age_days = None
age_seconds = None
if timestamp:
    try:
        ts = datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
        age_seconds = int((now - ts).total_seconds())
        if age_seconds < 0:
            age_seconds = 0
        age_days = age_seconds // 86400
        if age_days < 0:
            age_days = 0
    except Exception:
        age_days = None
        age_seconds = None

download = mbps(data.get("download"))
upload = mbps(data.get("upload"))
fallback = inum(fallback_down) or 0
baseline = inum(baseline_down) or fallback
display_down = download if download is not None else fallback
delta = display_down - baseline if display_down is not None else None

payload = {
    "generated_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
    "profile": profile,
    "ping": {
        "primary": {"host": primary_host, "ms": fnum(primary_ms), "reachable": fnum(primary_ms) is not None},
        "secondary": {"host": secondary_host, "ms": fnum(secondary_ms), "reachable": fnum(secondary_ms) is not None},
    },
    "speedtest": {
        "state": speed_state,
        "note": speed_note,
        "download_mbps": download,
        "upload_mbps": upload,
        "display_down_mbps": display_down,
        "baseline_down_mbps": baseline,
        "fallback_down_mbps": fallback,
        "download_delta_mbps": delta,
        "age_seconds": age_seconds,
        "age_label": age_label(age_seconds),
        "age_days": age_days,
        "max_age_days": inum(max_age_days),
        "raw": data if data else None,
    },
}

with open(out_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY

mv -f "$TMP_OUT" "$CURRENT_JSON"
rm -f "$TMP_SPEED"
write_status "ok" ""
