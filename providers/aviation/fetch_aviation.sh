#!/usr/bin/env bash
set -euo pipefail

PROFILE_ID="${1:-home}"
CONFIG_ROOT="${GTEX62_CONKY_CONFIG_DIR:-$HOME/.config/gtex62-conky}"
CACHE_ROOT="${GTEX62_CONKY_CACHE_DIR:-$HOME/.cache/gtex62-conky}"
PROFILE_TOML="$CONFIG_ROOT/profiles/aviation/${PROFILE_ID}.toml"
OUT_DIR="$CACHE_ROOT/shared/aviation/${PROFILE_ID}"
CURRENT_JSON="$OUT_DIR/current.json"
STATUS_JSON="$OUT_DIR/status.json"
LOG_FILE="$OUT_DIR/fetch.log"
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

parse_section_value() {
  local path="$1"
  local section="$2"
  local key="$3"
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
    --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg note "$note" \
    '{state:$state, profile:$profile, generated_at:$generated_at, note:$note}' > "$STATUS_JSON"
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

METAR_STATION="$(parse_section_value "$PROFILE_TOML" stations metar || true)"
TAF_STATION="$(parse_section_value "$PROFILE_TOML" stations taf || true)"
METAR_TTL="$(parse_section_value "$PROFILE_TOML" cache metar_ttl_sec || true)"
TAF_TTL="$(parse_section_value "$PROFILE_TOML" cache taf_ttl_sec || true)"
METAR_STATION="${METAR_STATION:-KMEM}"
TAF_STATION="${TAF_STATION:-$METAR_STATION}"
METAR_TTL="${METAR_TTL:-600}"
TAF_TTL="${TAF_TTL:-600}"

RAW_METAR="$OUT_DIR/metar_raw.txt"
RAW_TAF="$OUT_DIR/taf_raw.txt"
TMP_METAR="$TMP_DIR/aviation_${PROFILE_ID}_metar.tmp"
TMP_TAF="$TMP_DIR/aviation_${PROFILE_ID}_taf.tmp"

is_fresh() {
  local path="$1"
  local ttl="$2"
  [[ -f "$path" ]] || return 1
  local mtime
  mtime="$(stat -c %Y "$path" 2>/dev/null || echo 0)"
  [[ $(( $(date +%s) - mtime )) -lt $ttl ]]
}

fetch_metar() {
  local station="$1"
  local out="$2"
  curl -fsS "https://tgftp.nws.noaa.gov/data/observations/metar/decoded/${station}.TXT" -o "$out" 2>>"$LOG_FILE"
}

fetch_taf() {
  local station="$1"
  local out="$2"
  curl -fsS "https://aviationweather.gov/api/data/taf?ids=${station}&hours=0&sep=true" -o "$out" 2>>"$LOG_FILE"
}

if ! is_fresh "$RAW_METAR" "$METAR_TTL"; then
  if fetch_metar "$METAR_STATION" "$TMP_METAR" && [[ -s "$TMP_METAR" ]]; then
    mv -f "$TMP_METAR" "$RAW_METAR"
  else
    rm -f "$TMP_METAR"
  fi
fi

if ! is_fresh "$RAW_TAF" "$TAF_TTL"; then
  if fetch_taf "$TAF_STATION" "$TMP_TAF" && [[ -s "$TMP_TAF" ]]; then
    mv -f "$TMP_TAF" "$RAW_TAF"
  else
    rm -f "$TMP_TAF"
  fi
fi

METAR_TEXT="$(cat "$RAW_METAR" 2>/dev/null || true)"
TAF_TEXT="$(cat "$RAW_TAF" 2>/dev/null || true)"
if [[ -z "$METAR_TEXT" && -z "$TAF_TEXT" ]]; then
  write_status "error" "aviation fetch failed; no cache"
  exit 0
fi

jq -n \
  --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg metar_station "$METAR_STATION" \
  --arg taf_station "$TAF_STATION" \
  --rawfile metar "$RAW_METAR" \
  --rawfile taf "$RAW_TAF" \
  '{generated_at:$generated_at, stations:{metar:$metar_station, taf:$taf_station}, metar_raw:$metar, taf_raw:$taf}' > "$CURRENT_JSON"

write_status "ok" ""
