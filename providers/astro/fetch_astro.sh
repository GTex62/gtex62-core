#!/usr/bin/env bash
set -euo pipefail

PROFILE_ID="${1:-home}"
CONFIG_ROOT="${GTEX62_CONFIG_DIR:-${GTEX62_CONKY_CONFIG_DIR:-$HOME/.config/gtex62-core}}"
CACHE_ROOT="${GTEX62_CACHE_DIR:-${GTEX62_CONKY_CACHE_DIR:-$HOME/.cache/gtex62-core}}"
PROFILE_TOML="$CONFIG_ROOT/profiles/astro/${PROFILE_ID}.toml"
SITE_TOML="$CONFIG_ROOT/site.toml"
OUT_DIR="$CACHE_ROOT/shared/astro/${PROFILE_ID}"
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
  jq -n \
    --arg state "$1" \
    --arg profile "$PROFILE_ID" \
    --arg collector "astro" \
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

LAT="$(parse_section_value "$PROFILE_TOML" location lat || true)"
LON="$(parse_section_value "$PROFILE_TOML" location lon || true)"
TIMEZONE_NAME="$(parse_root_value "$PROFILE_TOML" timezone || true)"
LAT="${LAT:-$(parse_section_value "$SITE_TOML" location.home lat || true)}"
LON="${LON:-$(parse_section_value "$SITE_TOML" location.home lon || true)}"
TIMEZONE_NAME="${TIMEZONE_NAME:-$(parse_section_value "$SITE_TOML" location.home timezone || true)}"
TIMEZONE_NAME="${TIMEZONE_NAME:-$(date +%Z)}"

if [[ -z "$LAT" || -z "$LON" ]]; then
  write_status "error" "missing location"
  exit 0
fi

TMP_OUT="$TMP_DIR/astro_current_${PROFILE_ID}.tmp"
python3 - "$TMP_OUT" "$PROFILE_ID" "$LAT" "$LON" "$TIMEZONE_NAME" <<'PY'
import json
import math
import sys
import time
from datetime import datetime, timezone

import ephem

_, out_path, profile, lat, lon, timezone_name = sys.argv
lat = float(lat)
lon = float(lon)

def deg(value):
    return float(value) * 180.0 / math.pi

def ts(ephem_date):
    if ephem_date is None:
        return None
    return int(ephem_date.datetime().replace(tzinfo=timezone.utc).timestamp())

def safe_event(fn, body):
    try:
        return fn(body)
    except (ephem.AlwaysUpError, ephem.NeverUpError):
        return None

def body_payload(observer, body_id, body_name, body):
    current_date = observer.date
    prev_rise = safe_event(observer.previous_rising, body)
    prev_set = safe_event(observer.previous_setting, body)
    next_rise = safe_event(observer.next_rising, body)
    next_set = safe_event(observer.next_setting, body)
    observer.date = current_date
    body.compute(observer)
    az = deg(body.az)
    alt = deg(body.alt)
    return {
        "id": body_id,
        "name": body_name,
        "altitude_deg": round(alt, 3),
        "azimuth_deg": round(az, 3),
        "is_above_horizon": alt > 0,
        "prev_rise_ts": ts(prev_rise),
        "prev_set_ts": ts(prev_set),
        "next_rise_ts": ts(next_rise),
        "next_set_ts": ts(next_set),
        "heading_deg": int(round((az + 90) % 360)),
        "legacy_theta_deg": round((az - 90) % 360, 3),
    }

observer = ephem.Observer()
observer.lat = str(lat)
observer.lon = str(lon)
observer.elevation = 0
observer.date = ephem.now()

bodies = {
    "mercury": ("Mercury", ephem.Mercury()),
    "venus": ("Venus", ephem.Venus()),
    "mars": ("Mars", ephem.Mars()),
    "jupiter": ("Jupiter", ephem.Jupiter()),
    "saturn": ("Saturn", ephem.Saturn()),
}

payload = {
    "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "profile": profile,
    "observer": {"lat": lat, "lon": lon, "timezone": timezone_name},
    "sun": body_payload(observer, "sun", "Sun", ephem.Sun()),
    "moon": body_payload(observer, "moon", "Moon", ephem.Moon()),
    "planets": {key: body_payload(observer, key, name, body) for key, (name, body) in bodies.items()},
    "status": {"state": "ok"},
}

with open(out_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY

mv -f "$TMP_OUT" "$CURRENT_JSON"
write_status "ok" ""
