#!/usr/bin/env bash
set -euo pipefail

PROFILE_ID="${1:-local}"
CONFIG_ROOT="${GTEX62_CONFIG_DIR:-${GTEX62_CONKY_CONFIG_DIR:-$HOME/.config/gtex62-core}}"
CACHE_ROOT="${GTEX62_CACHE_DIR:-${GTEX62_CONKY_CACHE_DIR:-$HOME/.cache/gtex62-core}}"
XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
PROFILE_TOML="$CONFIG_ROOT/profiles/calendar/${PROFILE_ID}.toml"
SITE_TOML="$CONFIG_ROOT/site.toml"
OUT_DIR="$CACHE_ROOT/shared/calendar/${PROFILE_ID}"
EVENTS_JSON="$OUT_DIR/events.json"
SEASONAL_JSON="$OUT_DIR/seasonal.json"
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
    --arg collector "calendar" \
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

TIMEZONE="$(parse_root_value "$PROFILE_TOML" timezone || true)"
TIMEZONE="${TIMEZONE:-$(parse_section_value "$SITE_TOML" calendar timezone || true)}"
TIMEZONE="${TIMEZONE:-$(parse_section_value "$SITE_TOML" location.home timezone || true)}"
EXTRA_EVENTS_FILE="$(parse_section_value "$PROFILE_TOML" events extra_events_file || true)"
EVENT_CACHE_FILE="$(parse_section_value "$PROFILE_TOML" events cache_file || true)"
DEFAULT_EVENT_CACHE="$CACHE_ROOT/shared/calendar/${PROFILE_ID}/events_cache.txt"
EVENT_CACHE_FILE="${EVENT_CACHE_FILE:-$DEFAULT_EVENT_CACHE}"
LEGACY_EVENT_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/conky/events_cache.txt"

if [[ "$EVENT_CACHE_FILE" == "$DEFAULT_EVENT_CACHE" && ! -s "$EVENT_CACHE_FILE" && -s "$LEGACY_EVENT_CACHE" ]]; then
  cp "$LEGACY_EVENT_CACHE" "$EVENT_CACHE_FILE"
fi

TMP_EVENTS="$TMP_DIR/calendar_events_${PROFILE_ID}.tmp"
TMP_SEASONAL="$TMP_DIR/calendar_seasonal_${PROFILE_ID}.tmp"

python3 - "$EVENTS_JSON" "$TIMEZONE" "$EVENT_CACHE_FILE" "$EXTRA_EVENTS_FILE" "$TMP_EVENTS" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

_, _, timezone_name, event_cache_file, extra_events_file, out_path = sys.argv

seen = {}

def add_events(path):
    if not path or not os.path.exists(path):
        return
    try:
        with open(path, "r", encoding="utf-8") as handle:
            for raw in handle:
                line = raw.split("#", 1)[0].strip()
                if not line or "|" not in line:
                    continue
                date_text, name = line.split("|", 1)
                date_text = date_text.strip()
                name = name.split("|", 1)[0]
                name = " ".join(name.strip().split())
                if not date_text or not name:
                    continue
                key = (date_text, name)
                seen[key] = {
                    "date": date_text,
                    "name": name,
                }
    except OSError:
        return

add_events(event_cache_file)
add_events(extra_events_file)

events = sorted(seen.values(), key=lambda item: (item["date"], item["name"]))

payload = {
    "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "timezone": timezone_name,
    "events": events,
}

with open(out_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY

mv -f "$TMP_EVENTS" "$EVENTS_JSON"

jq -n \
  --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg timezone "$TIMEZONE" \
  '{generated_at:$generated_at, timezone:$timezone}' > "$TMP_SEASONAL"
mv -f "$TMP_SEASONAL" "$SEASONAL_JSON"

write_status "ok" ""
