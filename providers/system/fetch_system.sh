#!/usr/bin/env bash
set -euo pipefail

PROFILE_ID="${1:-local}"
CONFIG_ROOT="${GTEX62_CONFIG_DIR:-${GTEX62_CONKY_CONFIG_DIR:-$HOME/.config/gtex62-core}}"
CACHE_ROOT="${GTEX62_CACHE_DIR:-${GTEX62_CONKY_CACHE_DIR:-$HOME/.cache/gtex62-core}}"
PROFILE_TOML="$CONFIG_ROOT/profiles/system/${PROFILE_ID}.toml"
OUT_DIR="$CACHE_ROOT/shared/system/${PROFILE_ID}"
CURRENT_JSON="$OUT_DIR/current.json"
STATUS_JSON="$OUT_DIR/status.json"
PROCESSES_JSON="$OUT_DIR/processes.json"
STORAGE_JSON="$OUT_DIR/storage.json"
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
    --arg collector "system" \
    --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg note "$note" \
    '{state:$state, profile:$profile, collector:$collector, generated_at:$generated_at, note:$note}' > "$STATUS_JSON"
}

if [[ -f "$PROFILE_TOML" ]]; then
  ENABLED="$(parse_root_value "$PROFILE_TOML" enabled || true)"
  if [[ "${ENABLED:-true}" != "true" ]]; then
    write_status "disabled" "profile disabled"
    exit 0
  fi
fi

normalize_spaces() {
  sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

human_uptime() {
  local total="${1:-0}"
  local hours minutes seconds
  hours=$(( total / 3600 ))
  minutes=$(( (total % 3600) / 60 ))
  seconds=$(( total % 60 ))
  printf "%02d:%02d:%02d" "$hours" "$minutes" "$seconds"
}

read_cpu_model() {
  awk -F: '/^model name[[:space:]]*:/ {sub(/^[[:space:]]+/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null || true
}

read_os_field() {
  local key="$1"
  awk -F= -v key="$key" '$1 == key {gsub(/^"|"$/, "", $2); print $2; exit}' /etc/os-release 2>/dev/null || true
}

read_uptime_seconds() {
  awk '{printf "%d\n", $1}' /proc/uptime 2>/dev/null || true
}

read_meminfo_field_kib() {
  local key="$1"
  awk -v key="$key" '$1 == key ":" {print $2; exit}' /proc/meminfo 2>/dev/null || true
}

read_cpu_usage_percent() {
  top -bn1 2>/dev/null | awk -F'id,' '/Cpu\(s\)/ {gsub(/.*,/,"",$1); gsub(/[^0-9.]/,"",$1); if ($1 != "") printf "%.2f\n", 100 - $1; exit}'
}

read_ram_usage_percent() {
  local total available
  total="$(read_meminfo_field_kib MemTotal)"
  available="$(read_meminfo_field_kib MemAvailable)"
  if [[ -n "$total" && -n "$available" && "$total" -gt 0 ]]; then
    awk -v total="$total" -v avail="$available" 'BEGIN { printf "%.2f\n", ((total - avail) / total) * 100 }'
  fi
}

read_cpu_temp_celsius() {
  if command -v sensors >/dev/null 2>&1; then
    local core_avg
    core_avg="$(sensors 2>/dev/null | awk '
      {
        if ($0 ~ /Core [0-9]+:/) {
          line = $0
          sub(/^.*Core [0-9]+:[[:space:]]*\+?/, "", line)
          sub(/[^0-9.].*$/, "", line)
          if (line != "") {
            sum += line + 0
            count += 1
          }
        }
      }
      END {
        if (count > 0) {
          printf "%.2f\n", sum / count
        }
      }
    ')"
    if [[ -n "$core_avg" ]]; then
      printf "%s\n" "$core_avg"
      return
    fi
    sensors 2>/dev/null | awk '
      {
        if ($0 ~ /Package id 0:|Tctl:|Tdie:|CPU Temp:/) {
          line = $0
          sub(/^.*:[[:space:]]*\+?/, "", line)
          sub(/[^0-9.].*$/, "", line)
          if (line != "") {
            print line
            exit
          }
        }
      }
    ' || true
  fi
}

read_gpu_name() {
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1 || true
  fi
}

read_gpu_driver() {
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 || true
  fi
}

storage_row_json() {
  local label="$1"
  local kind="$2"
  local target="$3"
  local size=0 used=0 avail=0 pct=0

  if [[ "$kind" == "swap" ]]; then
    local total_kib free_kib
    total_kib="$(read_meminfo_field_kib SwapTotal)"
    free_kib="$(read_meminfo_field_kib SwapFree)"
    if [[ -n "$total_kib" && "$total_kib" -gt 0 ]]; then
      size=$(( total_kib * 1024 ))
      used=$(( (total_kib - ${free_kib:-0}) * 1024 ))
      avail=$(( (${free_kib:-0}) * 1024 ))
      pct="$(awk -v total="$total_kib" -v free="${free_kib:-0}" 'BEGIN { printf "%.0f", ((total - free) / total) * 100 }')"
    fi
  else
    local df_line
    df_line="$(df -B1 --output=size,used,avail,pcent "$target" 2>/dev/null | awk 'NR==2 {gsub(/%/, "", $4); print $1 "|" $2 "|" $3 "|" $4}')"
    if [[ -n "$df_line" ]]; then
      IFS='|' read -r size used avail pct <<< "$df_line"
    fi
  fi

  jq -n \
    --arg label "$label" \
    --arg kind "$kind" \
    --arg path "$target" \
    --argjson size "$size" \
    --argjson used "$used" \
    --argjson avail "$avail" \
    --argjson pct "$pct" \
    '{
      label:$label,
      kind:$kind,
      mount:$path,
      size_bytes:$size,
      used_bytes:$used,
      avail_bytes:$avail,
      use_percent:$pct
    }'
}

write_storage_json() {
  local tmp="$TMP_DIR/system_${PROFILE_ID}_storage.tmp"
  local wd_black="${WD_BLACK_PATH:-/mnt/WD_Black}"
  local entries=()

  entries+=("$(storage_row_json "/ROOT" "fs" "/")")
  entries+=("$(storage_row_json "/SWAP" "swap" "swap")")
  entries+=("$(storage_row_json "/EFT" "fs" "/boot/efi")")
  entries+=("$(storage_row_json "/NAS" "mount" "/mnt/NAS_Data")")
  entries+=("$(storage_row_json "/WD" "mount" "$wd_black")")

  jq -n \
    --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson filesystems "$(printf '%s\n' "${entries[@]}" | jq -s '.')" \
    '{generated_at:$generated_at, filesystems:$filesystems}' > "$tmp" && mv -f "$tmp" "$STORAGE_JSON"
}

CPU_MODEL="$(read_cpu_model | normalize_spaces || true)"
OS_CODENAME="$(read_os_field VERSION_CODENAME | tr '[:lower:]' '[:upper:]' || true)"
OS_VERSION_ID="$(read_os_field VERSION_ID || true)"
OS_NAME="$(read_os_field PRETTY_NAME | normalize_spaces || true)"
KERNEL_RELEASE="$(uname -r 2>/dev/null | sed 's/-generic$/-G/' || true)"
UPTIME_SECONDS="$(read_uptime_seconds || true)"
UPTIME_DISPLAY=""
if [[ -n "${UPTIME_SECONDS:-}" ]]; then
  UPTIME_DISPLAY="$(human_uptime "$UPTIME_SECONDS")"
fi

GPU_NAME="$(read_gpu_name | normalize_spaces || true)"
GPU_DRIVER="$(read_gpu_driver | normalize_spaces || true)"

BOARD_NAME="$(cat /sys/class/dmi/id/board_name 2>/dev/null | normalize_spaces || true)"
BIOS_VERSION="$(cat /sys/class/dmi/id/bios_version 2>/dev/null | normalize_spaces || true)"

write_storage_json

jq -n \
  --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{generated_at:$generated_at, top_cpu:[]}' > "$PROCESSES_JSON"

TMP_CURRENT="$TMP_DIR/system_${PROFILE_ID}_current.tmp"
jq -n \
  --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg profile "$PROFILE_ID" \
  --arg cpu_model "$CPU_MODEL" \
  --arg os_codename "$OS_CODENAME" \
  --arg os_version_id "$OS_VERSION_ID" \
  --arg os_name "$OS_NAME" \
  --arg kernel_release "$KERNEL_RELEASE" \
  --arg uptime_display "$UPTIME_DISPLAY" \
  --arg board_name "$BOARD_NAME" \
  --arg bios_version "$BIOS_VERSION" \
  --arg gpu_name "$GPU_NAME" \
  --arg gpu_driver "$GPU_DRIVER" \
  --argjson uptime_seconds "${UPTIME_SECONDS:-0}" \
  '{
    generated_at:$generated_at,
    profile:$profile,
    os:{
      name:$os_name,
      codename:$os_codename,
      version_id:$os_version_id
    },
    kernel:{
      release:$kernel_release
    },
    uptime_seconds:$uptime_seconds,
    uptime_display:$uptime_display,
    cpu:{
      model:$cpu_model
    },
    gpu:{
      model:$gpu_name,
      driver_version:$gpu_driver
    },
    motherboard:{
      name:$board_name
    },
    bios:{
      version:$bios_version
    },
    refs:{
      processes:"processes.json",
      storage:"storage.json",
      status:"status.json"
    }
  }' > "$TMP_CURRENT" && mv -f "$TMP_CURRENT" "$CURRENT_JSON"

write_status "ok" ""
