#!/usr/bin/env bash
set -euo pipefail

PROFILE_ID="${1:-main_router}"
CONFIG_ROOT="${GTEX62_CONFIG_DIR:-${GTEX62_CONKY_CONFIG_DIR:-$HOME/.config/gtex62-core}}"
CACHE_ROOT="${GTEX62_CACHE_DIR:-${GTEX62_CONKY_CACHE_DIR:-$HOME/.cache/gtex62-core}}"
PROFILE_TOML="$CONFIG_ROOT/profiles/pfsense/${PROFILE_ID}.toml"
SITE_TOML="$CONFIG_ROOT/site.toml"
OUT_DIR="$CACHE_ROOT/shared/pfsense/${PROFILE_ID}"
STATUS_JSON="$OUT_DIR/status.json"
TMP_DIR="$CACHE_ROOT/tmp"
GATE_DIR="$CACHE_ROOT/runtime/pfsense"
mkdir -p "$OUT_DIR" "$TMP_DIR" "$GATE_DIR"

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

gate_status() {
  local file="$GATE_DIR/ssh_state"
  local tripped=0 reason="" until=0 now left=0
  now="$(date +%s)"
  if [[ -f "$file" ]]; then
    while IFS='=' read -r key value; do
      case "$key" in
        tripped) tripped="${value:-0}" ;;
        reason) reason="${value:-}" ;;
        until) until="${value:-0}" ;;
      esac
    done < "$file"
  fi
  if [[ "$tripped" == "1" && "$now" -lt "$until" ]]; then
    left=$((until - now))
    printf 'TRIPPED|left=%s|reason=%s\n' "$left" "${reason:-PF_SSH_FAIL}"
  else
    printf 'OK\n'
  fi
}

write_status() {
  local state="$1"
  local note="$2"
  local ssh_target="$3"
  local gate="$4"
  local tripped="false"
  local left="0"
  local reason=""
  if [[ "$gate" == TRIPPED* ]]; then
    tripped="true"
    left="$(printf '%s' "$gate" | awk -F'[=|]' '{for (i=1; i<=NF; i++) if ($i=="left") {print $(i+1); exit}}')"
    reason="$(printf '%s' "$gate" | awk -F'[=|]' '{for (i=1; i<=NF; i++) if ($i=="reason") {print $(i+1); exit}}')"
  fi
  jq -n \
    --arg state "$state" \
    --arg profile "$PROFILE_ID" \
    --arg collector "pfsense" \
    --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg note "$note" \
    --arg ssh_target "$ssh_target" \
    --arg gate_status "$gate" \
    --arg reason "$reason" \
    --argjson tripped "$tripped" \
    --argjson left "${left:-0}" \
    '{
      state:$state,
      profile:$profile,
      collector:$collector,
      generated_at:$generated_at,
      note:$note,
      ssh_target:$ssh_target,
      ssh_gate:{status:$gate_status, tripped:$tripped, left_seconds:$left, reason:$reason}
    }' > "$STATUS_JSON"
}

if [[ ! -f "$PROFILE_TOML" ]]; then
  write_status "error" "missing profile toml" "" "$(gate_status)"
  exit 0
fi

ENABLED="$(parse_root_value "$PROFILE_TOML" enabled || true)"
SSH_TARGET="$(parse_root_value "$PROFILE_TOML" ssh_target || true)"
SSH_TARGET="${SSH_TARGET:-$(parse_root_value "$SITE_TOML" ssh_target || true)}"
SSH_TARGET="${SSH_TARGET:-$(parse_section_value "$SITE_TOML" pfsense ssh_target || true)}"
if [[ "${ENABLED:-true}" != "true" ]]; then
  write_status "disabled" "profile disabled" "${SSH_TARGET:-}" "$(gate_status)"
  exit 0
fi

write_status "ok" "" "${SSH_TARGET:-}" "$(gate_status)"
