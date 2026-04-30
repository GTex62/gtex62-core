#!/usr/bin/env bash
set -euo pipefail

PROFILE_ID="${1:-home}"
CONFIG_ROOT="${GTEX62_CONFIG_DIR:-${GTEX62_CONKY_CONFIG_DIR:-$HOME/.config/gtex62-core}}"
CACHE_ROOT="${GTEX62_CACHE_DIR:-${GTEX62_CONKY_CACHE_DIR:-$HOME/.cache/gtex62-core}}"
PROFILE_TOML="$CONFIG_ROOT/profiles/weather/${PROFILE_ID}.toml"
SITE_TOML="$CONFIG_ROOT/site.toml"
OUT_DIR="$CACHE_ROOT/shared/weather/${PROFILE_ID}"
STATUS_JSON="$OUT_DIR/status.json"
CURRENT_JSON="$OUT_DIR/current.json"
FORECAST_JSON="$OUT_DIR/forecast_daily.json"
RAW_CURRENT="$OUT_DIR/raw_current.json"
RAW_FORECAST="$OUT_DIR/raw_forecast.json"
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
    --arg provider "openweather" \
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

PROVIDER="$(parse_root_value "$PROFILE_TOML" provider || true)"
LAT="$(parse_section_value "$PROFILE_TOML" location lat || true)"
LON="$(parse_section_value "$PROFILE_TOML" location lon || true)"
TZ_NAME="$(parse_section_value "$PROFILE_TOML" location timezone || true)"
UNITS="$(parse_section_value "$PROFILE_TOML" request units || true)"
LANG="$(parse_section_value "$PROFILE_TOML" request lang || true)"
TTL="$(parse_section_value "$PROFILE_TOML" request cache_ttl_sec || true)"
API_KEY="$(parse_section_value "$PROFILE_TOML" credentials owm_api_key || true)"
LAT="${LAT:-$(parse_section_value "$SITE_TOML" location.home lat || true)}"
LON="${LON:-$(parse_section_value "$SITE_TOML" location.home lon || true)}"
TZ_NAME="${TZ_NAME:-$(parse_section_value "$SITE_TOML" location.home timezone || true)}"
API_KEY="${API_KEY:-$(parse_section_value "$SITE_TOML" credentials openweather_api_key || true)}"

PROVIDER="${PROVIDER:-openweather}"
UNITS="${UNITS:-imperial}"
LANG="${LANG:-en}"
TTL="${TTL:-300}"

if [[ -z "$API_KEY" || -z "$LAT" || -z "$LON" ]]; then
  write_status "error" "" "missing weather credentials or coordinates"
  exit 0
fi

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
  curl -fsS --max-time 8 "$url" > "$out" 2>>"$LOG_FILE"
}

TMP_CURRENT="$TMP_DIR/weather_${PROFILE_ID}_current.tmp"
TMP_FORECAST="$TMP_DIR/weather_${PROFILE_ID}_forecast.tmp"
URL_CURRENT="https://api.openweathermap.org/data/2.5/weather?lat=${LAT}&lon=${LON}&units=${UNITS}&lang=${LANG}&appid=${API_KEY}"
URL_FORECAST="https://api.openweathermap.org/data/2.5/forecast?lat=${LAT}&lon=${LON}&units=${UNITS}&lang=${LANG}&appid=${API_KEY}"

if ! is_fresh "$RAW_CURRENT"; then
  if fetch_url "$URL_CURRENT" "$TMP_CURRENT" && jq -e '.weather and .main and .wind and .clouds' "$TMP_CURRENT" >/dev/null 2>&1; then
    mv -f "$TMP_CURRENT" "$RAW_CURRENT"
  else
    rm -f "$TMP_CURRENT"
  fi
fi

if ! is_fresh "$RAW_FORECAST"; then
  if fetch_url "$URL_FORECAST" "$TMP_FORECAST" && jq -e '.list and .city' "$TMP_FORECAST" >/dev/null 2>&1; then
    mv -f "$TMP_FORECAST" "$RAW_FORECAST"
  else
    rm -f "$TMP_FORECAST"
  fi
fi

if [[ ! -f "$RAW_CURRENT" || ! -f "$RAW_FORECAST" ]]; then
  write_status "error" "" "weather fetch failed; no cache"
  exit 0
fi

jq -n \
  --slurpfile cur "$RAW_CURRENT" \
  --arg profile "$PROFILE_ID" \
  --arg provider "$PROVIDER" \
  --arg timezone "$TZ_NAME" \
  --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '
  ($cur[0]) as $c |
  {
    profile: $profile,
    provider: $provider,
    generated_at: $generated_at,
    provider_updated_at: (($c.dt // 0) | strftime("%Y-%m-%dT%H:%M:%SZ")),
    location: {
      name: ($c.name // ""),
      lat: ($c.coord.lat // empty),
      lon: ($c.coord.lon // empty),
      timezone: $timezone
    },
    temp_f: ($c.main.temp // empty),
    humidity_pct: ($c.main.humidity // empty),
    pressure_hpa: ($c.main.pressure // empty),
    cloud_percent: ($c.clouds.all // empty),
    wind_deg: ($c.wind.deg // empty),
    wind_mph: ($c.wind.speed // empty),
    wx_code: ($c.weather[0].id // empty),
    icon: ($c.weather[0].icon // empty),
    description: ($c.weather[0].description // "")
  }
  ' > "$CURRENT_JSON"

jq -n \
  --slurpfile fc "$RAW_FORECAST" \
  --slurpfile cur "$RAW_CURRENT" \
  --arg timezone "$TZ_NAME" \
  --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '
  ($fc[0]) as $root |
  ($cur[0]) as $current |
  ($root.city.timezone // 0) as $tz |
  (now + $tz | gmtime | strftime("%Y-%m-%d")) as $today |
  {
    generated_at: $generated_at,
    timezone: $timezone,
    days: (
      $root.list
      | map(. + {
          local_dt: (.dt + $tz),
          local_day: ((.dt + $tz) | gmtime | strftime("%Y-%m-%d")),
          local_hour: ((.dt + $tz) | gmtime | strftime("%H") | tonumber)
        })
      | group_by(.local_day)
      | map(select(.[0].local_day >= $today))
      | map(
          ([ .[] | select(.local_hour >= 10 and .local_hour <= 16) ]) as $mid |
          ($mid[0] // .[0]) as $rep |
          ([ .[] | (.weather[0].id // empty) ] | map(tonumber)) as $all_wx |
          (max_by(.main.temp).main.temp) as $raw_hi |
          (min_by(.main.temp).main.temp) as $raw_lo |
          ($current.main.temp // empty) as $current_temp |
          {
            day_name: ($rep.local_dt | gmtime | strftime("%a") | ascii_upcase),
            date: ($rep.local_dt | gmtime | strftime("%Y-%m-%d")),
            high_f: (
              if .[0].local_day == $today and ($current_temp | type) == "number"
              then ([$raw_hi, $current_temp] | max)
              else $raw_hi
              end
            ),
            low_f: (
              if .[0].local_day == $today and ($current_temp | type) == "number"
              then ([$raw_lo, $current_temp] | min)
              else $raw_lo
              end
            ),
            cloud_percent: ($rep.clouds.all // empty),
            wx_code: (
              def wx_rank($id):
                if $id == null then 999
                elif ($id >= 200 and $id < 300) then 1
                elif ($id == 511) then 2
                elif ($id >= 600 and $id < 700) then 3
                elif (($id >= 500 and $id < 600) or ($id >= 300 and $id < 400)) then 4
                elif ($id >= 700 and $id < 800) then 5
                elif ($id >= 900) then 6
                else 999
                end;
              ([ $all_wx[] | select(wx_rank(.) < 999) ] | sort_by(wx_rank(.), .) | .[0]) //
              (([ $mid[] | (.weather[0].id // empty) ] | group_by(.) | max_by(length)[0]) // ($rep.weather[0].id // empty))
            ),
            icon: (
              ([ $mid[] | (.weather[0].icon // empty | sub("n$";"d")) ]) as $icons |
              if ($icons|length) > 0 then ($icons | group_by(.) | max_by(length)[0]) else ($rep.weather[0].icon // empty | sub("n$";"d")) end
            )
          }
        )
      | .[:6]
    )
  }
  ' > "$FORECAST_JSON"

PROVIDER_TS="$(jq -r '.provider_updated_at // empty' "$CURRENT_JSON" 2>/dev/null || true)"
write_status "ok" "$PROVIDER_TS" ""
