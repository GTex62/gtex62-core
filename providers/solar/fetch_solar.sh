#!/usr/bin/env bash
set -euo pipefail

PROFILE_ID="${1:-home}"
CONFIG_ROOT="${GTEX62_CONFIG_DIR:-${GTEX62_CONKY_CONFIG_DIR:-$HOME/.config/gtex62-core}}"
CACHE_ROOT="${GTEX62_CACHE_DIR:-${GTEX62_CONKY_CACHE_DIR:-$HOME/.cache/gtex62-core}}"
PROFILE_TOML="$CONFIG_ROOT/profiles/solar/${PROFILE_ID}.toml"
SITE_TOML="$CONFIG_ROOT/site.toml"
OUT_DIR="$CACHE_ROOT/shared/solar/${PROFILE_ID}"
CURRENT_JSON="$OUT_DIR/current.json"
STATUS_JSON="$OUT_DIR/status.json"
LOG_FILE="$OUT_DIR/fetch.log"
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
  local provider_ts="$2"
  local note="$3"
  jq -n \
    --arg state "$state" \
    --arg profile "$PROFILE_ID" \
    --arg provider "weather-derived" \
    --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg provider_updated_at "$provider_ts" \
    --arg note "$note" \
    '{state:$state, profile:$profile, provider:$provider, generated_at:$generated_at, provider_updated_at:$provider_updated_at, note:$note}' > "$STATUS_JSON"
}

if [[ ! -f "$PROFILE_TOML" ]]; then
  write_status "error" "" "missing profile toml"
  exit 0
fi

ENABLED="$(parse_root_value "$PROFILE_TOML" enabled || true)"
if [[ "${ENABLED:-true}" != "true" ]]; then
  write_status "disabled" "" "profile disabled"
  exit 0
fi

SOURCE="$(parse_root_value "$PROFILE_TOML" source || true)"
WEATHER_PROFILE="$(parse_root_value "$PROFILE_TOML" weather_profile || true)"
LAT="$(parse_section_value "$PROFILE_TOML" location lat || true)"
LON="$(parse_section_value "$PROFILE_TOML" location lon || true)"
TZ_NAME="$(parse_section_value "$PROFILE_TOML" location timezone || true)"
WEATHER_PROFILE="${WEATHER_PROFILE:-home}"
SOURCE="${SOURCE:-weather-derived}"
LAT="${LAT:-$(parse_section_value "$SITE_TOML" location.home lat || true)}"
LON="${LON:-$(parse_section_value "$SITE_TOML" location.home lon || true)}"
TZ_NAME="${TZ_NAME:-$(parse_section_value "$SITE_TOML" location.home timezone || true)}"

WEATHER_DIR="$CACHE_ROOT/shared/weather/${WEATHER_PROFILE}"
WEATHER_CURRENT="$WEATHER_DIR/current.json"
WEATHER_RAW="$WEATHER_DIR/raw_current.json"
for _ in {1..40}; do
  [[ -f "$WEATHER_RAW" || -f "$WEATHER_CURRENT" ]] && break
  sleep 0.5
done

if [[ ! -f "$WEATHER_RAW" && ! -f "$WEATHER_CURRENT" ]]; then
  write_status "waiting" "" "waiting for weather cache"
  exit 0
fi

INPUT_RAW="$WEATHER_RAW"
if [[ ! -f "$INPUT_RAW" ]]; then
  INPUT_RAW="$TMP_DIR/solar_${PROFILE_ID}_empty_weather_raw.json"
  printf '{}\n' > "$INPUT_RAW"
fi

INPUT_CURRENT="$WEATHER_CURRENT"
if [[ ! -f "$INPUT_CURRENT" ]]; then
  INPUT_CURRENT="$TMP_DIR/solar_${PROFILE_ID}_empty_weather_current.json"
  printf '{}\n' > "$INPUT_CURRENT"
fi

if ! jq -n \
  --slurpfile raw "$INPUT_RAW" \
  --slurpfile cur "$INPUT_CURRENT" \
  --arg profile "$PROFILE_ID" \
  --arg provider "$SOURCE" \
  --arg weather_profile "$WEATHER_PROFILE" \
  --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg lat "$LAT" \
  --arg lon "$LON" \
  --arg timezone "$TZ_NAME" \
  '
  def clamp($lo; $hi):
    if . < $lo then $lo elif . > $hi then $hi else . end;
  def round2: (. * 100 | round) / 100;
  def iso($ts): if ($ts | type) == "number" and $ts > 0 then ($ts | strftime("%Y-%m-%dT%H:%M:%SZ")) else "" end;

  ($raw[0] // {}) as $r |
  ($cur[0] // {}) as $c |
  (($r.dt // ($c.provider_updated_at | fromdateiso8601?)) // now) as $ts |
  (($r.sys.sunrise // empty) // 0) as $sunrise |
  (($r.sys.sunset // empty) // 0) as $sunset |
  (($r.clouds.all // $c.cloud_percent // 0) | tonumber | clamp(0; 100)) as $clouds |
  (($r.main.temp // $c.temp_f // 0) | tonumber) as $temp |
  ((($temp - 32) * 5 / 9) | round2) as $temp_c |
  (
    if ($sunrise > 0 and $sunset > $sunrise and $ts >= $sunrise and $ts <= $sunset) then
      (($ts - $sunrise) / ($sunset - $sunrise) * 3.141592653589793 | sin | clamp(0; 1))
    else 0
    end
  ) as $sun_factor |
  ((1 - ($clouds / 100)) | clamp(0; 1)) as $cloud_factor |
  (($sun_factor * $cloud_factor) | clamp(0; 1)) as $visible_factor |
  (($temp - 20) / 80 | clamp(0; 1)) as $temp_factor |
  (($sun_factor * ((0.65 * $cloud_factor) + (0.35 * $temp_factor))) | clamp(0; 1)) as $ir_factor |
  {
    profile: $profile,
    provider: $provider,
    source: "openweather-derived",
    timestamp: $ts,
    generated_at: $generated_at,
    provider_updated_at: iso($ts),
    weather_profile: $weather_profile,
    location: {
      lat: (($lat | tonumber?) // ($r.coord.lat // $c.location.lat // empty)),
      lon: (($lon | tonumber?) // ($r.coord.lon // $c.location.lon // empty)),
      timezone: $timezone
    },
    labels: ["UV", "VI", "IR", "CL", "RAD"],
    values: {
      UV: ((11 * $sun_factor) | round2),
      VI: ((100 * $visible_factor) | round2),
      IR: ((100 * $ir_factor) | round2),
      CL: ($clouds | round2),
      RAD: ((1000 * $visible_factor) | round2)
    },
    norm: {
      UV: ($sun_factor | round2),
      VI: ($visible_factor | round2),
      IR: ($ir_factor | round2),
      CL: (($clouds / 100) | round2),
      RAD: ($visible_factor | round2)
    },
    meta: {
      source_weather_profile: $weather_profile,
      timestamp: $ts,
      sunrise: $sunrise,
      sunset: $sunset,
      clouds: $clouds,
      temp_f: $temp,
      temp_c: $temp_c
    }
  }
  ' > "$CURRENT_JSON"; then
  echo "$(date -Is) solar derive failed for profile ${PROFILE_ID}" >> "$LOG_FILE"
  write_status "error" "" "solar derive failed"
  exit 0
fi

PROVIDER_TS="$(jq -r '.provider_updated_at // empty' "$CURRENT_JSON" 2>/dev/null || true)"
write_status "ok" "$PROVIDER_TS" ""
