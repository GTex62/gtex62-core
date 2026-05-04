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

REAL_UV=""
REAL_RAD=""
if [[ -n "$LAT" && -n "$LON" ]]; then
  OM_UV_TMP="$TMP_DIR/solar_${PROFILE_ID}_om_uv.json"
  OM_UV_URL="https://api.open-meteo.com/v1/forecast?latitude=${LAT}&longitude=${LON}&current=uv_index,shortwave_radiation&timezone=auto&forecast_days=1"
  if curl -fsS --max-time 8 "$OM_UV_URL" > "$OM_UV_TMP" 2>>"$LOG_FILE"; then
    REAL_UV="$(jq -r '.current.uv_index // empty' "$OM_UV_TMP" 2>/dev/null || true)"
    REAL_RAD="$(jq -r '.current.shortwave_radiation // empty' "$OM_UV_TMP" 2>/dev/null || true)"
  fi
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
  --arg real_uv "$REAL_UV" \
  --arg real_rad "$REAL_RAD" \
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
  (($ts | strftime("%j")) | tonumber) as $doy |
  (23.45 * ((2 * 3.141592653589793 * ($doy - 81) / 365) | sin)) as $decl_deg |
  (($lat | tonumber) - $decl_deg | if . < 0 then -. else . end | clamp(0; 89)) as $zenith_noon_deg |
  ($zenith_noon_deg * 3.141592653589793 / 180 | cos) as $cos_zenith_noon |
  (11 * $cos_zenith_noon * $cos_zenith_noon) as $uv_noon_max |
  (if ($real_uv | length) > 0 then ($real_uv | tonumber) else null end) as $om_uv |
  (if ($real_rad | length) > 0 then ($real_rad | tonumber) else null end) as $om_rad |
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
      UV: (if $om_uv then ($om_uv | round2) else (($uv_noon_max * $sun_factor * $cloud_factor) | round2) end),
      VI: ((100 * $visible_factor) | round2),
      IR: ((100 * $ir_factor) | round2),
      CL: ($clouds | round2),
      RAD: (if $om_rad then ($om_rad | round2) else ((1000 * $visible_factor) | round2) end)
    },
    norm: {
      UV: (if $om_uv then (($om_uv / 11) | clamp(0; 1) | round2) else ($visible_factor | round2) end),
      VI: ($visible_factor | round2),
      IR: ($ir_factor | round2),
      CL: (($clouds / 100) | round2),
      RAD: (if $om_rad then (($om_rad / 1000) | clamp(0; 1) | round2) else ($visible_factor | round2) end)
    },
    meta: {
      source_weather_profile: $weather_profile,
      timestamp: $ts,
      sunrise: $sunrise,
      sunset: $sunset,
      clouds: $clouds,
      temp_f: $temp,
      temp_c: $temp_c,
      uv_source: (if $om_uv then "open-meteo" else "synthetic" end)
    }
  }
  ' > "$CURRENT_JSON"; then
  echo "$(date -Is) solar derive failed for profile ${PROFILE_ID}" >> "$LOG_FILE"
  write_status "error" "" "solar derive failed"
  exit 0
fi

PROVIDER_TS="$(jq -r '.provider_updated_at // empty' "$CURRENT_JSON" 2>/dev/null || true)"
write_status "ok" "$PROVIDER_TS" ""
