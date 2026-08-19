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

# Interval-based CPU sampling: overall CPU% (printed to stdout) plus the
# top-N process tables written to processes.json. Percentages are jiffies
# deltas against the previous provider run (state kept in tmp), normalized
# to total capacity across all cores — the same convention as Conky's
# ${top cpu}. A first run with no usable state takes a short two-point
# sample instead of reporting since-boot averages.
sample_cpu_and_processes() {
  python3 - "$CPU_STATE_FILE" "$PROCESSES_JSON" <<'PY'
import json, os, sys, time

state_path, out_path = sys.argv[1], sys.argv[2]
TOP_N = 10
page = os.sysconf("SC_PAGE_SIZE")

def read_totals():
    with open("/proc/stat") as f:
        vals = [int(x) for x in f.readline().split()[1:]]
    idle = vals[3] + (vals[4] if len(vals) > 4 else 0)
    return sum(vals), idle

def read_procs():
    procs = {}
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open("/proc/%s/stat" % pid) as f:
                raw = f.read()
            comm = raw[raw.index("(") + 1:raw.rindex(")")]
            fields = raw[raw.rindex(")") + 2:].split()
            jiff = int(fields[11]) + int(fields[12])  # utime + stime
            with open("/proc/%s/statm" % pid) as f:
                rss = int(f.read().split()[1]) * page
            procs[pid] = {"comm": comm, "jiff": jiff, "rss": rss}
        except (OSError, ValueError, IndexError):
            continue
    return procs

try:
    with open(state_path) as f:
        prev = json.load(f)
except (OSError, ValueError):
    prev = None

total, idle = read_totals()
procs = read_procs()

if not prev or prev.get("total", 0) >= total:
    time.sleep(0.3)
    prev = {"total": total, "idle": idle,
            "pids": {pid: p["jiff"] for pid, p in procs.items()}}
    total, idle = read_totals()
    procs = read_procs()

d_total = total - prev.get("total", 0)
d_idle = idle - prev.get("idle", 0)
cpu_pct = 0.0
if d_total > 0:
    cpu_pct = max(0.0, min(100.0, 100.0 * (d_total - d_idle) / d_total))

prev_pids = prev.get("pids", {})
top_cpu = []
for pid, p in procs.items():
    d = p["jiff"] - prev_pids.get(pid, p["jiff"])  # unseen pid: 0 this interval
    if d_total > 0 and d >= 0:
        top_cpu.append({"name": p["comm"],
                        "cpu_percent": round(100.0 * d / d_total, 2)})
top_cpu.sort(key=lambda r: r["cpu_percent"], reverse=True)

top_mem = sorted(
    ({"name": p["comm"], "rss_bytes": p["rss"]} for p in procs.values()),
    key=lambda r: r["rss_bytes"], reverse=True)

payload = {
    "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "top_cpu": top_cpu[:TOP_N],
    "top_mem": top_mem[:TOP_N],
}
with open(out_path + ".tmp", "w") as f:
    json.dump(payload, f, indent=2)
    f.write("\n")
os.replace(out_path + ".tmp", out_path)

with open(state_path + ".tmp", "w") as f:
    json.dump({"total": total, "idle": idle,
               "pids": {pid: p["jiff"] for pid, p in procs.items()}}, f)
os.replace(state_path + ".tmp", state_path)

print("%.2f" % cpu_pct)
PY
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

# One nvidia-smi call for the full GPU snapshot:
# name, driver, util%, vram used/total (MiB), temp (C), power draw (W)
read_gpu_info() {
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=name,driver_version,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw \
      --format=csv,noheader,nounits 2>/dev/null | head -n1 || true
  fi
}

# Echo $1 if it is a plain number, else $2 (nvidia-smi may emit "[N/A]").
num_or() {
  local v
  v="$(printf '%s' "$1" | tr -d '[:space:]')"
  case "$v" in
    ''|*[!0-9.]*) printf '%s\n' "$2" ;;
    *)            printf '%s\n' "$v" ;;
  esac
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

HOSTNAME_VALUE="$(uname -n 2>/dev/null | normalize_spaces || true)"
USER_VALUE="$(id -un 2>/dev/null | normalize_spaces || true)"
KERNEL_RELEASE_FULL="$(uname -r 2>/dev/null || true)"

GPU_LINE="$(read_gpu_info || true)"
GPU_NAME=""
GPU_DRIVER=""
GPU_UTIL=0
GPU_MEM_USED=0
GPU_MEM_TOTAL=0
GPU_TEMP=0
GPU_POWER=0
if [[ -n "$GPU_LINE" ]]; then
  IFS=',' read -r GF_NAME GF_DRIVER GF_UTIL GF_MEM_USED GF_MEM_TOTAL GF_TEMP GF_POWER <<< "$GPU_LINE"
  GPU_NAME="$(printf '%s' "${GF_NAME:-}" | normalize_spaces)"
  GPU_DRIVER="$(printf '%s' "${GF_DRIVER:-}" | normalize_spaces)"
  GPU_UTIL="$(num_or "${GF_UTIL:-}" 0)"
  GPU_MEM_USED="$(num_or "${GF_MEM_USED:-}" 0)"
  GPU_MEM_TOTAL="$(num_or "${GF_MEM_TOTAL:-}" 0)"
  GPU_TEMP="$(num_or "${GF_TEMP:-}" 0)"
  GPU_POWER="$(num_or "${GF_POWER:-}" 0)"
fi

MEM_TOTAL_KIB="$(read_meminfo_field_kib MemTotal || true)"
MEM_AVAIL_KIB="$(read_meminfo_field_kib MemAvailable || true)"
MEM_TOTAL_BYTES=0
MEM_USED_BYTES=0
MEM_PCT=0
if [[ -n "${MEM_TOTAL_KIB:-}" && "${MEM_TOTAL_KIB:-0}" -gt 0 ]]; then
  MEM_TOTAL_BYTES=$(( MEM_TOTAL_KIB * 1024 ))
  MEM_USED_BYTES=$(( (MEM_TOTAL_KIB - ${MEM_AVAIL_KIB:-0}) * 1024 ))
  MEM_PCT="$(read_ram_usage_percent || true)"
  MEM_PCT="${MEM_PCT:-0}"
fi

CPU_TEMP="$(read_cpu_temp_celsius || true)"
CPU_TEMP="$(num_or "${CPU_TEMP:-}" 0)"

BOARD_NAME="$(cat /sys/class/dmi/id/board_name 2>/dev/null | normalize_spaces || true)"
BIOS_VERSION="$(cat /sys/class/dmi/id/bios_version 2>/dev/null | normalize_spaces || true)"

write_storage_json

CPU_STATE_FILE="$TMP_DIR/system_${PROFILE_ID}_cpu.state"
CPU_USAGE="$(sample_cpu_and_processes || true)"
CPU_USAGE="$(num_or "${CPU_USAGE:-}" 0)"

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
  --arg hostname "$HOSTNAME_VALUE" \
  --arg user_name "$USER_VALUE" \
  --arg kernel_release_full "$KERNEL_RELEASE_FULL" \
  --argjson uptime_seconds "${UPTIME_SECONDS:-0}" \
  --argjson cpu_usage "$CPU_USAGE" \
  --argjson cpu_temp "$CPU_TEMP" \
  --argjson mem_used "$MEM_USED_BYTES" \
  --argjson mem_total "$MEM_TOTAL_BYTES" \
  --argjson mem_pct "$MEM_PCT" \
  --argjson gpu_util "$GPU_UTIL" \
  --argjson gpu_temp "$GPU_TEMP" \
  --argjson gpu_power "$GPU_POWER" \
  --argjson gpu_mem_used "$GPU_MEM_USED" \
  --argjson gpu_mem_total "$GPU_MEM_TOTAL" \
  '{
    generated_at:$generated_at,
    profile:$profile,
    hostname:$hostname,
    user:$user_name,
    os:{
      name:$os_name,
      codename:$os_codename,
      version_id:$os_version_id
    },
    kernel:{
      release:$kernel_release,
      release_full:$kernel_release_full
    },
    uptime_seconds:$uptime_seconds,
    uptime_display:$uptime_display,
    cpu:{
      model:$cpu_model,
      usage_percent:$cpu_usage,
      temperature_c:$cpu_temp
    },
    memory:{
      used_bytes:$mem_used,
      total_bytes:$mem_total,
      usage_percent:$mem_pct
    },
    gpu:{
      model:$gpu_name,
      driver_version:$gpu_driver,
      usage_percent:$gpu_util,
      temperature_c:$gpu_temp,
      power_w:$gpu_power,
      memory:{
        used_mb:$gpu_mem_used,
        total_mb:$gpu_mem_total
      }
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
