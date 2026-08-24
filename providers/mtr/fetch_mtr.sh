#!/usr/bin/env bash
# providers/mtr/fetch_mtr.sh
# Core MTR-trigger provider (Pi5). Own SSH target, own gate dir
# (runtime/mtr), own domain — standalone single-target provider, same
# shape as fetch_vpn.sh/fetch_pihole.sh, not part of the pfsense family.
#
# Does NOT run mtr itself. It starts (and only ever starts — no auto-kill,
# see design/sitrep-design-notes.md § Alert banner / outage detection,
# "MTR auto-trigger") the pre-existing, untouched
# `~/mtr_overnight_log.sh` on Pi5 once the gateway-offline duration
# (fetch_alerts.sh's SEVERE trigger) has actually crossed threshold, and
# writes shared/mtr/{profile}/mtr_state.json so pf.lua's wan_mtr_line()
# has a real, non-inferred "is it running" signal to read.
#
# Trigger condition is read from banner.json, not re-derived: banner.json
# only ever carries a queue entry with id "gateway-offline" once
# fetch_alerts.sh's own duration check has already crossed
# [alerts].gateway_offline_duration_sec — so this script doesn't need its
# own copy of that threshold. Reuse, not re-derivation.
#
# "Is it running" is answered from our own last-written state, not a
# pgrep-every-poll check (no per-poll SSH cost — matches the standing
# design decision, see sitrep-design-notes.md). SSH is only used to (a)
# start the script the first time the trigger fires, (b) confirm — on a
# later poll, never blocking the start — that the start actually took,
# and (c) periodically re-confirm (every reconfirm_interval_sec, default
# 30min) even after confirmation, so a process that died on Pi5 for an
# unrelated reason (crash, reboot, manual kill) doesn't leave the display
# reporting RUNNING forever. That periodic re-check is what also makes
# this correct across a Titan restart: mtr_state.json lives under the
# normal persistent cache root (survives reboot), but its "confirmed"
# belief is never trusted blindly past the reconfirm interval — the
# first poll after any restart that's more than reconfirm_interval_sec
# since the last real check re-verifies via pgrep rather than assuming.
# This is a correctness check, not the rejected "auto-stop on gateway
# recovery" — it only ever corrects the display to match reality, it
# does not add a new way for this script to kill the process.
set -euo pipefail

MTR_PROFILE_ID="${1:-pi5}"
ALERTS_PROFILE_ID="${2:-main_router}"
CONFIG_ROOT="${GTEX62_CONFIG_DIR:-${GTEX62_CONKY_CONFIG_DIR:-$HOME/.config/gtex62-core}}"
CACHE_ROOT="${GTEX62_CACHE_DIR:-${GTEX62_CONKY_CACHE_DIR:-$HOME/.cache/gtex62-core}}"
PROFILE_TOML="$CONFIG_ROOT/profiles/mtr/${MTR_PROFILE_ID}.toml"
BANNER_JSON="$CACHE_ROOT/shared/alerts/${ALERTS_PROFILE_ID}/banner.json"
OUT_DIR="$CACHE_ROOT/shared/mtr/${MTR_PROFILE_ID}"
MTR_JSON="$OUT_DIR/mtr_state.json"
TMP_DIR="$CACHE_ROOT/tmp"
GATE_DIR="$CACHE_ROOT/runtime/mtr"
GATE_SCRIPT="$(dirname "$0")/../pfsense/pf-ssh-gate.sh"
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
        reason)  reason="${value:-}"   ;;
        until)   until="${value:-0}"   ;;
      esac
    done < "$file"
  fi
  if [[ "$tripped" == "1" && "$now" -lt "$until" ]]; then
    left=$((until - now))
    printf 'TRIPPED|left=%s|reason=%s\n' "$left" "${reason:-MTR_SSH_FAIL}"
  else
    printf 'OK\n'
  fi
}

# -------------------------------------------------------------------------
# Prior state (our own last-written belief — never re-derived from a live
# pgrep unless the confirm step below decides to check).
# -------------------------------------------------------------------------

PREV_RUNNING="false"
PREV_CONFIRMED="false"
PREV_STARTED_AT=""
PREV_STARTED_EPOCH=""
PREV_LAST_CONFIRMED_EPOCH=""
if [[ -f "$MTR_JSON" ]]; then
  PREV_RUNNING="$(jq -r '.running // false' "$MTR_JSON" 2>/dev/null || echo false)"
  PREV_CONFIRMED="$(jq -r '.confirmed // false' "$MTR_JSON" 2>/dev/null || echo false)"
  PREV_STARTED_AT="$(jq -r '.started_at // empty' "$MTR_JSON" 2>/dev/null || true)"
  PREV_STARTED_EPOCH="$(jq -r '.started_at_epoch // empty' "$MTR_JSON" 2>/dev/null || true)"
  PREV_LAST_CONFIRMED_EPOCH="$(jq -r '.last_confirmed_at_epoch // empty' "$MTR_JSON" 2>/dev/null || true)"
fi

write_status() {
  local state="$1"
  local note="$2"
  local ssh_target="$3"
  local gate="$4"
  local trigger_active="$5"
  local trigger_since="$6"
  local trigger_duration="$7"
  local running="$8"
  local confirmed="$9"
  local started_at="${10}"
  local started_epoch="${11}"
  local last_confirmed_epoch="${12}"
  local tripped="false"
  local left="0"
  local reason=""
  if [[ "$gate" == TRIPPED* ]]; then
    tripped="true"
    left="$(printf '%s' "$gate" | awk -F'[=|]' '{for(i=1;i<=NF;i++) if($i=="left") {print $(i+1); exit}}')"
    reason="$(printf '%s' "$gate" | awk -F'[=|]' '{for(i=1;i<=NF;i++) if($i=="reason") {print $(i+1); exit}}')"
  fi
  jq -n \
    --arg state          "$state" \
    --arg profile        "$MTR_PROFILE_ID" \
    --arg collector      "mtr" \
    --arg generated_at   "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg note           "$note" \
    --arg ssh_target     "$ssh_target" \
    --arg gate_status    "$gate" \
    --arg reason         "$reason" \
    --argjson tripped    "$tripped" \
    --argjson left       "${left:-0}" \
    --argjson trigger_active "$trigger_active" \
    --arg trigger_since  "$trigger_since" \
    --argjson trigger_duration "${trigger_duration:-null}" \
    --argjson running    "$running" \
    --argjson confirmed  "$confirmed" \
    --arg started_at     "$started_at" \
    --argjson started_epoch "${started_epoch:-null}" \
    --argjson last_confirmed_epoch "${last_confirmed_epoch:-null}" \
    '{
      state:$state,
      profile:$profile,
      collector:$collector,
      generated_at:$generated_at,
      note:$note,
      ssh_target:$ssh_target,
      ssh_gate:{status:$gate_status, tripped:$tripped, left_seconds:$left, reason:$reason},
      trigger:{active:$trigger_active, since:(if $trigger_since=="" then null else $trigger_since end), duration_seconds:$trigger_duration},
      running:$running,
      confirmed:$confirmed,
      started_at:(if $started_at=="" then null else $started_at end),
      started_at_epoch:$started_epoch,
      last_confirmed_at_epoch:$last_confirmed_epoch
    }' > "$MTR_JSON"
}

# -------------------------------------------------------------------------
# Pre-flight checks
# -------------------------------------------------------------------------

ENABLED="$(parse_root_value "$PROFILE_TOML" enabled || true)"
SSH_TARGET="$(parse_root_value "$PROFILE_TOML" ssh_target || true)"
REMOTE_PATH="$(parse_section_value "$PROFILE_TOML" script remote_path || true)"
REMOTE_PATH="${REMOTE_PATH:-~/mtr_overnight_log.sh}"

if [[ ! -f "$PROFILE_TOML" || "${ENABLED:-true}" != "true" ]]; then
  write_status "disabled" "profile disabled" "${SSH_TARGET:-}" "$(gate_status)" \
    false "" null "$PREV_RUNNING" "$PREV_CONFIRMED" "$PREV_STARTED_AT" "${PREV_STARTED_EPOCH:-null}" "${PREV_LAST_CONFIRMED_EPOCH:-null}"
  exit 0
fi

if [[ -z "$SSH_TARGET" ]]; then
  write_status "error" "no ssh_target configured" "" "$(gate_status)" \
    false "" null "$PREV_RUNNING" "$PREV_CONFIRMED" "$PREV_STARTED_AT" "${PREV_STARTED_EPOCH:-null}" "${PREV_LAST_CONFIRMED_EPOCH:-null}"
  exit 0
fi

# -------------------------------------------------------------------------
# Cache TTL — cheap local recompute either way, but no need to re-check
# more often than the profile's own cadence.
# -------------------------------------------------------------------------

CACHE_TTL="$(parse_root_value "$PROFILE_TOML" cache_ttl_sec || true)"
CACHE_TTL="${CACHE_TTL:-15}"

# How often a confirmed "running" belief gets re-verified via a live
# pgrep, even though nothing else would trigger a check. Generous by
# design — this exists to catch an unexpected exit (crash, reboot,
# manual kill) and to make a post-restart first poll trustworthy, not to
# approximate real-time liveness.
RECONFIRM_INTERVAL_SEC="$(parse_root_value "$PROFILE_TOML" reconfirm_interval_sec || true)"
RECONFIRM_INTERVAL_SEC="${RECONFIRM_INTERVAL_SEC:-1800}"

# Outer safety bound — deliberately distinct from the rejected
# "auto-stop on gateway recovery" idea (confirmed with user, Aug 24,
# 2026): this is a disk/resource backstop against an unbounded run
# (mtr_overnight_log.sh appends a snapshot every 60s forever, no cap of
# its own), not a reaction to the outage ending. Generous by design —
# not meant to bound a normal overnight window.
MAX_RUNTIME_HOURS="$(parse_root_value "$PROFILE_TOML" max_runtime_hours || true)"
MAX_RUNTIME_HOURS="${MAX_RUNTIME_HOURS:-72}"

if [[ -f "$MTR_JSON" ]]; then
  now_ts="$(date +%s)"
  file_ts="$(stat -c %Y "$MTR_JSON" 2>/dev/null || echo 0)"
  age=$(( now_ts - file_ts ))
  if [[ "$age" -lt "$CACHE_TTL" ]]; then
    exit 0
  fi
fi

# -------------------------------------------------------------------------
# Gate check (own state dir — never shares runtime/pihole or
# runtime/pfsense ssh_state)
# -------------------------------------------------------------------------

GATE="$(gate_status)"
if [[ "$GATE" == TRIPPED* ]]; then
  write_status "degraded" "ssh gate tripped" "$SSH_TARGET" "$GATE" \
    false "" null "$PREV_RUNNING" "$PREV_CONFIRMED" "$PREV_STARTED_AT" "${PREV_STARTED_EPOCH:-null}" "${PREV_LAST_CONFIRMED_EPOCH:-null}"
  exit 0
fi

# -------------------------------------------------------------------------
# Read the trigger condition from banner.json — reused, not re-derived.
# banner.json's queue only ever carries an entry with id "gateway-offline"
# once fetch_alerts.sh's own gateway_offline_duration_sec threshold has
# already been crossed, so its mere presence here IS the SEVERE trigger.
# -------------------------------------------------------------------------

TRIGGER_ACTIVE="false"
TRIGGER_SINCE=""
TRIGGER_DURATION="null"
if [[ -f "$BANNER_JSON" ]]; then
  row="$(jq -r '(.queue[]? | select(.id == "gateway-offline") | [.since, .duration_seconds] | @tsv)' "$BANNER_JSON" 2>/dev/null || true)"
  if [[ -n "$row" ]]; then
    TRIGGER_ACTIVE="true"
    TRIGGER_SINCE="$(printf '%s' "$row" | cut -f1)"
    TRIGGER_DURATION="$(printf '%s' "$row" | cut -f2)"
  fi
fi

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5 -o ConnectionAttempts=1 \
          -o ServerAliveInterval=5 -o ServerAliveCountMax=1 -o LogLevel=ERROR)

RUNNING="$PREV_RUNNING"
CONFIRMED="$PREV_CONFIRMED"
STARTED_AT="$PREV_STARTED_AT"
STARTED_EPOCH="${PREV_STARTED_EPOCH:-null}"
LAST_CONFIRMED_EPOCH="${PREV_LAST_CONFIRMED_EPOCH:-null}"
NOTE=""

# Needs a live pgrep check if: never confirmed yet since the last start,
# OR it's been >= reconfirm_interval_sec (or never) since the last real
# check. The second arm is what makes a stale "confirmed" belief
# self-correcting — including on the first poll after a Titan restart,
# since mtr_state.json's last_confirmed_at_epoch predates the downtime
# and will already be older than the interval.
NEED_CONFIRM="false"
if [[ "$PREV_RUNNING" == "true" ]]; then
  if [[ "$PREV_CONFIRMED" != "true" ]]; then
    NEED_CONFIRM="true"
  else
    now_epoch="$(date +%s)"
    last_epoch="${PREV_LAST_CONFIRMED_EPOCH:-0}"
    [[ "$last_epoch" =~ ^[0-9]+$ ]] || last_epoch=0
    if (( now_epoch - last_epoch >= RECONFIRM_INTERVAL_SEC )); then
      NEED_CONFIRM="true"
    fi
  fi
fi

if [[ "$NEED_CONFIRM" == "true" ]]; then
  # ---------------------------------------------------------------------
  # Confirm/re-confirm step — never blocks a start (a start either
  # already happened on a prior poll, or happens below this block on
  # this same poll if still not running). rc 255 is ssh's own
  # connection-failure code (trip the gate); rc 0 means pgrep found it;
  # rc 1 means we reached Pi5 fine but the process isn't there (start
  # never took, it already ended, or it died unexpectedly since the last
  # confirm) — reset to not-running so the next poll can retry while the
  # trigger holds.
  # ---------------------------------------------------------------------
  _ssh_rc=0
  ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "pgrep -f mtr_overnight_log.sh >/dev/null 2>&1" || _ssh_rc=$?
  if [[ $_ssh_rc -eq 0 ]]; then
    CONFIRMED="true"
    LAST_CONFIRMED_EPOCH="$(date +%s)"
    NOTE="confirmed running"
  elif [[ $_ssh_rc -eq 255 ]]; then
    GATE_STATE_DIR="$GATE_DIR" "$GATE_SCRIPT" trip MTR_SSH_FAIL
    GATE="$(gate_status)"
    write_status "degraded" "ssh failed during confirm" "$SSH_TARGET" "$GATE" \
      "$TRIGGER_ACTIVE" "$TRIGGER_SINCE" "$TRIGGER_DURATION" \
      "$RUNNING" "$CONFIRMED" "$STARTED_AT" "$STARTED_EPOCH" "$LAST_CONFIRMED_EPOCH"
    exit 0
  else
    RUNNING="false"
    CONFIRMED="false"
    STARTED_AT=""
    STARTED_EPOCH="null"
    LAST_CONFIRMED_EPOCH="null"
    NOTE="not running (process not found on reconfirm) — will restart if trigger still active"
  fi
fi

# ---------------------------------------------------------------------
# Outer safety cap — disk/resource backstop only, confirmed with user
# (Aug 24, 2026) as distinct from the rejected auto-stop-on-recovery
# idea: this fires purely on elapsed wall-clock runtime, regardless of
# whether the gateway is still offline. If the trigger condition is
# still active on this same poll, the "start" block right below this one
# will pick it right back up under a fresh timestamped log (that's an
# ordinary consequence of "stop, then re-evaluate the trigger" — not a
# special-cased rotation feature) — so hitting the cap bounds any one
# log file's growth without ending diagnostic coverage of an outage
# that's still ongoing three-plus days in.
# ---------------------------------------------------------------------
if [[ "$RUNNING" == "true" && "$CONFIRMED" == "true" && "$STARTED_EPOCH" =~ ^[0-9]+$ ]]; then
  now_epoch="$(date +%s)"
  max_runtime_sec=$(( MAX_RUNTIME_HOURS * 3600 ))
  if (( now_epoch - STARTED_EPOCH >= max_runtime_sec )); then
    _ssh_rc=0
    ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "pkill -f mtr_overnight_log.sh" || _ssh_rc=$?
    if [[ $_ssh_rc -eq 255 ]]; then
      GATE_STATE_DIR="$GATE_DIR" "$GATE_SCRIPT" trip MTR_SSH_FAIL
      GATE="$(gate_status)"
      write_status "degraded" "ssh failed during outer-cap stop" "$SSH_TARGET" "$GATE" \
        "$TRIGGER_ACTIVE" "$TRIGGER_SINCE" "$TRIGGER_DURATION" \
        "$RUNNING" "$CONFIRMED" "$STARTED_AT" "$STARTED_EPOCH" "$LAST_CONFIRMED_EPOCH"
      exit 0
    fi
    # rc 0 (found and killed) or rc 1 (pkill found nothing — already gone)
    # both mean it's not running now; either way, stop tracking it.
    RUNNING="false"
    CONFIRMED="false"
    STARTED_AT=""
    STARTED_EPOCH="null"
    LAST_CONFIRMED_EPOCH="null"
    NOTE="stopped: outer safety cap reached (${MAX_RUNTIME_HOURS}h)"
  fi
fi

if [[ "$RUNNING" != "true" && "$TRIGGER_ACTIVE" == "true" ]]; then
  # ---------------------------------------------------------------------
  # Start. Detached nohup, exactly the manual command this script wires
  # into — mtr_overnight_log.sh itself is never touched.
  # ---------------------------------------------------------------------
  # shellcheck disable=SC2029  # $REMOTE_PATH is meant to expand here, on
  # Titan, from this profile's own config (default ~/mtr_overnight_log.sh)
  # — not on the remote shell — before the resulting literal command
  # string is sent over ssh.
  _ssh_rc=0
  ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "nohup $REMOTE_PATH >/dev/null 2>&1 &" || _ssh_rc=$?
  if [[ $_ssh_rc -eq 0 ]]; then
    GATE_STATE_DIR="$GATE_DIR" "$GATE_SCRIPT" reset
    RUNNING="true"
    CONFIRMED="false"
    STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    STARTED_EPOCH="$(date +%s)"
    LAST_CONFIRMED_EPOCH="null"
    NOTE="start issued, awaiting confirm"
  elif [[ $_ssh_rc -eq 255 ]]; then
    GATE_STATE_DIR="$GATE_DIR" "$GATE_SCRIPT" trip MTR_SSH_FAIL
    GATE="$(gate_status)"
    write_status "degraded" "ssh failed during start" "$SSH_TARGET" "$GATE" \
      "$TRIGGER_ACTIVE" "$TRIGGER_SINCE" "$TRIGGER_DURATION" \
      "$RUNNING" "$CONFIRMED" "$STARTED_AT" "$STARTED_EPOCH" "$LAST_CONFIRMED_EPOCH"
    exit 0
  else
    NOTE="start command returned $_ssh_rc (unexpected) — not marking running"
  fi
fi

GATE_STATE_DIR="$GATE_DIR" "$GATE_SCRIPT" reset
GATE="$(gate_status)"
write_status "ok" "$NOTE" "$SSH_TARGET" "$GATE" \
  "$TRIGGER_ACTIVE" "$TRIGGER_SINCE" "$TRIGGER_DURATION" \
  "$RUNNING" "$CONFIRMED" "$STARTED_AT" "$STARTED_EPOCH" "$LAST_CONFIRMED_EPOCH"
