#!/usr/bin/env bash
set -euo pipefail

PROFILE_ID="${1:-home}"
CONFIG_ROOT="${GTEX62_CONFIG_DIR:-${GTEX62_CONKY_CONFIG_DIR:-$HOME/.config/gtex62-core}}"
CACHE_ROOT="${GTEX62_CACHE_DIR:-${GTEX62_CONKY_CACHE_DIR:-$HOME/.cache/gtex62-core}}"
PROFILE_TOML="$CONFIG_ROOT/profiles/air/${PROFILE_ID}.toml"
SITE_TOML="$CONFIG_ROOT/site.toml"
OUT_DIR="$CACHE_ROOT/shared/air/${PROFILE_ID}"
CURRENT_JSON="$OUT_DIR/current.json"
STATUS_JSON="$OUT_DIR/status.json"
RAW_OWM="$OUT_DIR/raw_openweather.json"
RAW_AIRNOW_DATA="$OUT_DIR/raw_airnow_data.json"
RAW_AIRNOW_OBS="$OUT_DIR/raw_airnow_observation.json"
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
    --arg provider "air" \
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

LAT="$(parse_section_value "$PROFILE_TOML" location lat || true)"
LON="$(parse_section_value "$PROFILE_TOML" location lon || true)"
TZ_NAME="$(parse_section_value "$PROFILE_TOML" location timezone || true)"
TTL="$(parse_section_value "$PROFILE_TOML" cache ttl_sec || true)"
OWM_ENABLED="$(parse_section_value "$PROFILE_TOML" openweather enabled || true)"
OWM_API_KEY="$(parse_section_value "$PROFILE_TOML" openweather api_key || true)"
AIRNOW_ENABLED="$(parse_section_value "$PROFILE_TOML" airnow enabled || true)"
AIRNOW_API_KEY="$(parse_section_value "$PROFILE_TOML" airnow api_key || true)"
AIRNOW_DISTANCE="$(parse_section_value "$PROFILE_TOML" airnow distance_miles || true)"
AIRNOW_WINDOW_HOURS="$(parse_section_value "$PROFILE_TOML" airnow window_hours || true)"
AIRNOW_MAX_AGE="$(parse_section_value "$PROFILE_TOML" airnow max_age_sec || true)"
AIRNOW_OWM_TOLERANCE="$(parse_section_value "$PROFILE_TOML" airnow owm_tolerance_sec || true)"
LAT="${LAT:-$(parse_section_value "$SITE_TOML" location.home lat || true)}"
LON="${LON:-$(parse_section_value "$SITE_TOML" location.home lon || true)}"
TZ_NAME="${TZ_NAME:-$(parse_section_value "$SITE_TOML" location.home timezone || true)}"
OWM_API_KEY="${OWM_API_KEY:-$(parse_section_value "$SITE_TOML" credentials openweather_api_key || true)}"
AIRNOW_API_KEY="${AIRNOW_API_KEY:-$(parse_section_value "$SITE_TOML" credentials airnow_api_key || true)}"

TTL="${TTL:-900}"
OWM_ENABLED="${OWM_ENABLED:-true}"
AIRNOW_ENABLED="${AIRNOW_ENABLED:-false}"
AIRNOW_DISTANCE="${AIRNOW_DISTANCE:-25}"
AIRNOW_WINDOW_HOURS="${AIRNOW_WINDOW_HOURS:-6}"
AIRNOW_MAX_AGE="${AIRNOW_MAX_AGE:-3600}"
AIRNOW_OWM_TOLERANCE="${AIRNOW_OWM_TOLERANCE:-3600}"

if [[ -z "$LAT" || -z "$LON" ]]; then
  write_status "error" "" "missing air profile coordinates"
  exit 0
fi

is_true() {
  case "${1,,}" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

is_fresh() {
  local path="$1"
  [[ -f "$path" ]] || return 1
  local mtime
  mtime="$(stat -c %Y "$path" 2>/dev/null || echo 0)"
  [[ $(( $(date +%s) - mtime )) -lt $TTL ]]
}

fetch_url() {
  local url="$1"
  local out="$2"
  curl -fsS --max-time 10 "$url" > "$out" 2>>"$LOG_FILE"
}

TMP_OWM="$TMP_DIR/air_${PROFILE_ID}_openweather.tmp"
TMP_AIRNOW_DATA="$TMP_DIR/air_${PROFILE_ID}_airnow_data.tmp"
TMP_AIRNOW_OBS="$TMP_DIR/air_${PROFILE_ID}_airnow_obs.tmp"

if is_true "$OWM_ENABLED"; then
  if [[ -z "$OWM_API_KEY" ]]; then
    write_status "error" "" "missing openweather air api key"
    exit 0
  fi
  if ! is_fresh "$RAW_OWM"; then
    OWM_URL="https://api.openweathermap.org/data/2.5/air_pollution?lat=${LAT}&lon=${LON}&appid=${OWM_API_KEY}"
    if fetch_url "$OWM_URL" "$TMP_OWM" && jq -e '.list and .coord' "$TMP_OWM" >/dev/null 2>&1; then
      mv -f "$TMP_OWM" "$RAW_OWM"
    else
      rm -f "$TMP_OWM"
    fi
  fi
fi

airnow_active=0
if is_true "$AIRNOW_ENABLED" && [[ -n "$AIRNOW_API_KEY" ]]; then
  airnow_active=1
fi

if [[ $airnow_active -eq 1 ]]; then
  if [[ "$AIRNOW_WINDOW_HOURS" =~ ^[0-9]+$ && "$AIRNOW_WINDOW_HOURS" -gt 1 ]]; then
    AIRNOW_START="$(date -u -d "$((AIRNOW_WINDOW_HOURS - 1)) hour ago" +%Y-%m-%dT%H)"
  else
    AIRNOW_START="$(date -u +%Y-%m-%dT%H)"
  fi
  AIRNOW_END="$(date -u -d '1 hour' +%Y-%m-%dT%H)"
  AIRNOW_BBOX="$(
    LAT="$LAT" LON="$LON" AIRNOW_DISTANCE="$AIRNOW_DISTANCE" python3 - <<'PY'
import math
import os

lat = float(os.environ.get("LAT", "0"))
lon = float(os.environ.get("LON", "0"))
dist = float(os.environ.get("AIRNOW_DISTANCE", "25"))
dlat = dist / 69.0
dlon = dist / (69.0 * math.cos(math.radians(lat))) if abs(lat) < 89 else 0.0
print(f"{lon - dlon:.4f},{lat - dlat:.4f},{lon + dlon:.4f},{lat + dlat:.4f}")
PY
  )"
  AIRNOW_DATA_URL="https://www.airnowapi.org/aq/data/?startDate=${AIRNOW_START}&endDate=${AIRNOW_END}&parameters=OZONE,PM25,PM10,CO,NO2,SO2&BBOX=${AIRNOW_BBOX}&dataType=C&format=application/json&verbose=0&monitorType=2&includerawconcentrations=1&API_KEY=${AIRNOW_API_KEY}"
  AIRNOW_OBS_URL="https://www.airnowapi.org/aq/observation/latLong/current/?format=application/json&latitude=${LAT}&longitude=${LON}&distance=${AIRNOW_DISTANCE}&API_KEY=${AIRNOW_API_KEY}"

  if ! is_fresh "$RAW_AIRNOW_DATA"; then
    if fetch_url "$AIRNOW_DATA_URL" "$TMP_AIRNOW_DATA" && jq -e 'type == "array"' "$TMP_AIRNOW_DATA" >/dev/null 2>&1; then
      mv -f "$TMP_AIRNOW_DATA" "$RAW_AIRNOW_DATA"
    else
      rm -f "$TMP_AIRNOW_DATA"
    fi
  fi

  if ! is_fresh "$RAW_AIRNOW_OBS"; then
    if fetch_url "$AIRNOW_OBS_URL" "$TMP_AIRNOW_OBS" && jq -e 'type == "array"' "$TMP_AIRNOW_OBS" >/dev/null 2>&1; then
      mv -f "$TMP_AIRNOW_OBS" "$RAW_AIRNOW_OBS"
    else
      rm -f "$TMP_AIRNOW_OBS"
    fi
  fi
fi

if [[ ! -f "$RAW_OWM" && ! -f "$RAW_AIRNOW_DATA" && ! -f "$RAW_AIRNOW_OBS" ]]; then
  write_status "error" "" "air fetch failed; no cache"
  exit 0
fi

INPUT_OWM="$RAW_OWM"
INPUT_AIRNOW_DATA="$RAW_AIRNOW_DATA"
INPUT_AIRNOW_OBS="$RAW_AIRNOW_OBS"
if [[ ! -f "$INPUT_OWM" ]]; then
  INPUT_OWM="$TMP_DIR/air_${PROFILE_ID}_empty_openweather.json"
  printf '{}\n' > "$INPUT_OWM"
fi
if [[ ! -f "$INPUT_AIRNOW_DATA" ]]; then
  INPUT_AIRNOW_DATA="$TMP_DIR/air_${PROFILE_ID}_empty_airnow_data.json"
  printf '[]\n' > "$INPUT_AIRNOW_DATA"
fi
if [[ ! -f "$INPUT_AIRNOW_OBS" ]]; then
  INPUT_AIRNOW_OBS="$TMP_DIR/air_${PROFILE_ID}_empty_airnow_obs.json"
  printf '[]\n' > "$INPUT_AIRNOW_OBS"
fi

jq -n \
  --arg profile "$PROFILE_ID" \
  --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg timezone "$TZ_NAME" \
  --argjson lat "$LAT" \
  --argjson lon "$LON" \
  --arg airnow_enabled "$AIRNOW_ENABLED" \
  --argjson airnow_max_age "$AIRNOW_MAX_AGE" \
  --argjson airnow_owm_tolerance "$AIRNOW_OWM_TOLERANCE" \
  --slurpfile owm "$INPUT_OWM" \
  --slurpfile airnow_data "$INPUT_AIRNOW_DATA" \
  --slurpfile airnow_obs "$INPUT_AIRNOW_OBS" \
  '
  def iso($ts): if ($ts // 0) > 0 then ($ts | strftime("%Y-%m-%dT%H:%M:%SZ")) else "" end;
  def epoch_from_airnow:
    if . == null then null
    elif type == "number" then .
    else
      (tostring
      | if test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}$") then strptime("%Y-%m-%dT%H:%M") | mktime
        elif test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}$") then strptime("%Y-%m-%dT%H") | mktime
        else null end)
    end;
  def key_for:
    (tostring | ascii_upcase) as $p |
    if $p == "PM2.5" or $p == "PM2_5" or $p == "PM25" then "pm2_5"
    elif $p == "PM10" then "pm10"
    elif $p == "OZONE" or $p == "O3" then "o3"
    elif $p == "NO2" or $p == "NO" then "no2"
    elif $p == "SO2" or $p == "SO" then "so2"
    elif $p == "CO" then "co"
    else empty end;
  def ugm3($key; $unit; $value):
    ($unit // "" | tostring | ascii_upcase) as $u |
    if $value == null then null
    elif $u == "UG/M3" or $u == "UG/M^3" or $u == "UG/M³" then $value
    elif $u == "MG/M3" or $u == "MG/M^3" then ($value * 1000)
    elif $u == "PPB" and $key == "o3" then ($value * 1.96)
    elif $u == "PPB" and $key == "no2" then ($value * 1.88)
    elif $u == "PPB" and $key == "so2" then ($value * 2.62)
    elif $u == "PPM" and $key == "co" then ($value * 1145)
    else null end;

  ($owm[0] // {}) as $o |
  ($o.list[0] // {}) as $olist |
  ($olist.dt // null) as $owm_ts |
  (now | floor) as $now |
  (
    ($airnow_data[0] // [])
    | map(.UTC | epoch_from_airnow)
    | map(select(. != null))
    | max
  ) as $anw_latest_data_ts |
  (
    ($airnow_data[0] // [])
    | map(
        (.Parameter | key_for) as $key |
        (.RawConcentration // .Value // null) as $raw_value |
        (.UTC | epoch_from_airnow) as $ts |
        select($key != null and $raw_value != null and $ts != null) |
        ($now - $ts) as $age |
        select($age >= 0 and $age <= $airnow_max_age) |
        (ugm3($key; .Unit; ($raw_value | tonumber)) // null) as $value |
        select($value != null and $value >= 0) |
        {key:$key, value:$value, ts:$ts, age:$age}
      )
    | group_by(.key)
    | map(sort_by(.age) | .[0])
  ) as $anw_values |
  (
    ($airnow_obs[0] // [])
    | map(select(.AQI != null) | {aqi:(.AQI | tonumber), ts:((.UTC // .DateObserved) | epoch_from_airnow)})
    | map(select(.ts != null))
    | sort_by(.ts)
    | last
  ) as $anw_aqi |
  ($anw_values | map(.ts) | max) as $anw_observed_ts |
  ($anw_aqi.ts // $anw_observed_ts // $anw_latest_data_ts) as $anw_latest_ts |
  {
    profile: $profile,
    generated_at: $generated_at,
    provider_updated_at: (iso(($anw_latest_ts // $owm_ts // 0))),
    location: {lat:$lat, lon:$lon, timezone:$timezone},
    openweather: {
      enabled: ($owm | length > 0),
      valid: (($olist | length) > 0),
      observed_ts: $owm_ts,
      observed_at: iso(($owm_ts // 0)),
      aqi: ($olist.main.aqi // null),
      components: ($olist.components // {})
    },
    airnow: {
      enabled: ($airnow_enabled == "true"),
      valid: (($anw_values | length) > 0 or $anw_aqi != null),
      observed_ts: $anw_observed_ts,
      observed_at: iso(($anw_observed_ts // 0)),
      latest_ts: $anw_latest_ts,
      latest_at: iso(($anw_latest_ts // 0)),
      aqi: ($anw_aqi.aqi // null),
      aqi_ts: ($anw_aqi.ts // null),
      aqi_at: iso(($anw_aqi.ts // 0)),
      values: ($anw_values | map({(.key): .value}) | add // {}),
      timestamps: ($anw_values | map({(.key): .ts}) | add // {})
    },
    selected: (
      ($olist.components // {}) as $base |
      ($anw_values | map({(.key): .value}) | add // {}) as $overlay |
      ($base + $overlay)
    )
  }
  ' > "$CURRENT_JSON"

PROVIDER_TS="$(jq -r '.provider_updated_at // empty' "$CURRENT_JSON" 2>/dev/null || true)"
if [[ -n "$PROVIDER_TS" ]]; then
  write_status "ok" "$PROVIDER_TS" ""
else
  write_status "partial" "" "air cache has no provider timestamp"
fi
