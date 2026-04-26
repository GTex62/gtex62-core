#!/usr/bin/env bash
set -euo pipefail

PROFILE_ID="${1:-local}"
CONFIG_ROOT="${GTEX62_CONFIG_DIR:-${GTEX62_CONKY_CONFIG_DIR:-$HOME/.config/gtex62-core}}"
CACHE_ROOT="${GTEX62_CACHE_DIR:-${GTEX62_CONKY_CACHE_DIR:-$HOME/.cache/gtex62-core}}"
PROFILE_TOML="$CONFIG_ROOT/profiles/time/${PROFILE_ID}.toml"
OUT_DIR="$CACHE_ROOT/shared/time/${PROFILE_ID}"
CURRENT_JSON="$OUT_DIR/current.json"
STATUS_JSON="$OUT_DIR/status.json"
TMP_DIR="$CACHE_ROOT/tmp"
mkdir -p "$OUT_DIR" "$TMP_DIR"

parse_root_value() {
  local path="$1"
  local key="$2"
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

write_status() {
  local state="$1"
  local note="$2"
  jq -n \
    --arg state "$state" \
    --arg profile "$PROFILE_ID" \
    --arg collector "time" \
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

TMP_CURRENT="$TMP_DIR/time_current_${PROFILE_ID}.tmp"

python3 - "$PROFILE_TOML" "$TMP_CURRENT" <<'PY'
import json
import sys
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

profile_path = sys.argv[1]
out_path = sys.argv[2]

DEFAULT_ZONES = [
    {"tz": "UTC", "name": "UNIVERSAL TIME COORDINATED"},
    {"tz": "America/Chicago", "name": "CENTRAL TIME"},
    {"tz": "America/Los_Angeles", "name": "PACIFIC TIME"},
    {"tz": "Europe/Berlin", "name": "CENTRAL EUROPEAN TIME"},
    {"tz": "Asia/Tokyo", "name": "JAPAN STANDARD TIME"},
]

zones = []
enabled = True
current_section = None
with open(profile_path, "r", encoding="utf-8") as handle:
    for raw in handle:
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if line.startswith("[") and line.endswith("]"):
            current_section = line[1:-1]
            continue
        if current_section is None:
            if "=" in line:
                key, value = [part.strip() for part in line.split("=", 1)]
                value = value.strip('"')
                if key == "enabled":
                    enabled = value.lower() == "true"
            continue
        if current_section == "zones":
            if "=" in line:
                key, value = [part.strip() for part in line.split("=", 1)]
                value = value.strip('"')
                if value:
                    zones.append({"tz": key, "name": value})

if not zones:
    zones = DEFAULT_ZONES

now_utc = datetime.now(timezone.utc)
local_now = datetime.now().astimezone()

rows = []
for spec in zones:
    tz_name = spec["tz"]
    display_name = spec["name"]
    now = now_utc.astimezone(ZoneInfo(tz_name))
    offset = now.strftime("%z")
    offset_display = offset[:3] if offset else ""
    rows.append({
        "tz": tz_name,
        "zone": now.strftime("%Z").upper(),
        "off": offset_display,
        "time": now.strftime("%H:%M"),
        "date": now.strftime("%b %d").upper(),
        "name": display_name.upper(),
    })

payload = {
    "generated_at": now_utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
    "local": {
        "zone": local_now.strftime("%Z").upper(),
        "time": local_now.strftime("%H:%M:%S"),
        "date": local_now.strftime("%a, %b %d, %Y").upper(),
    },
    "rows": rows,
}

with open(out_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY

mv -f "$TMP_CURRENT" "$CURRENT_JSON"
write_status "ok" ""
