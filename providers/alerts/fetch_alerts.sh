#!/usr/bin/env bash
# providers/alerts/fetch_alerts.sh
# Core alert-banner watcher. Not an SSH provider — no gate, no remote target.
# Reads other providers' already-written cache files (status.json, pihole.json,
# ap_status.json, ap_clients.json under shared/pfsense/{profile}/), applies
# threshold/duration logic from core.toml's [alerts] section, and writes one
# shared, severity-sorted, parent/child-grouped alert queue that SitRep (and
# any other consumer) can render without re-deriving anything.
#
# Per the standing "suites just display, core does all the work" principle
# (see gtex62-sitrep/design/sitrep-design-notes.md § Alert banner /
# outage detection): this is a general-purpose watcher framework, not a
# single-condition script. Adding a new condition means adding one more
# evaluation block below plus (if it needs a duration threshold) one more
# tracked timestamp in state.json — the read/sort/write/log plumbing is
# shared.
set -euo pipefail

PROFILE_ID="${1:-main_router}"
# MTR_PROFILE_ID: cross-domain read only (shared/mtr/{mtr_profile}/
# mtr_state.json, written by providers/mtr/fetch_mtr.sh) — mirrors how
# fetch_mtr.sh itself takes an alerts-profile arg to read this script's
# banner.json. Not this script's own profile; just where to find one
# other provider's already-written cache file.
MTR_PROFILE_ID="${2:-pi5}"
CONFIG_ROOT="${GTEX62_CONFIG_DIR:-${GTEX62_CONKY_CONFIG_DIR:-$HOME/.config/gtex62-core}}"
CACHE_ROOT="${GTEX62_CACHE_DIR:-${GTEX62_CONKY_CACHE_DIR:-$HOME/.cache/gtex62-core}}"
CORE_TOML="$CONFIG_ROOT/core.toml"
PF_DIR="$CACHE_ROOT/shared/pfsense/${PROFILE_ID}"
STATUS_JSON="$PF_DIR/status.json"
PIHOLE_JSON="$PF_DIR/pihole.json"
AP_STATUS_JSON="$PF_DIR/ap_status.json"
AP_CLIENTS_JSON="$PF_DIR/ap_clients.json"
MTR_JSON="$CACHE_ROOT/shared/mtr/${MTR_PROFILE_ID}/mtr_state.json"
OUT_DIR="$CACHE_ROOT/shared/alerts/${PROFILE_ID}"
BANNER_JSON="$OUT_DIR/banner.json"
ALERT_LOG="$OUT_DIR/alert_log.txt"
STATE_DIR="$CACHE_ROOT/runtime/alerts/${PROFILE_ID}"
STATE_JSON="$STATE_DIR/state.json"
TMP_DIR="$CACHE_ROOT/tmp"
mkdir -p "$OUT_DIR" "$STATE_DIR" "$TMP_DIR"

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

# -------------------------------------------------------------------------
# [alerts] thresholds — defaults match the proposed values in
# sitrep-design-notes.md § Alert banner, confirmed with user Aug 22, 2026.
# -------------------------------------------------------------------------

GATEWAY_OFFLINE_DURATION_SEC="$(parse_section_value "$CORE_TOML" alerts gateway_offline_duration_sec || true)"
GATEWAY_OFFLINE_DURATION_SEC="${GATEWAY_OFFLINE_DURATION_SEC:-900}"

PIHOLE_INACTIVE_DURATION_SEC="$(parse_section_value "$CORE_TOML" alerts pihole_inactive_duration_sec || true)"
PIHOLE_INACTIVE_DURATION_SEC="${PIHOLE_INACTIVE_DURATION_SEC:-600}"

# -------------------------------------------------------------------------
# Evaluate + write. Pure computation over already-cached JSON — no SSH, no
# gate, no cache-TTL skip (cheap local reads; every invocation recomputes).
# -------------------------------------------------------------------------

python3 - \
  "$STATUS_JSON" "$PIHOLE_JSON" "$AP_STATUS_JSON" "$AP_CLIENTS_JSON" "$MTR_JSON" \
  "$STATE_JSON" "$BANNER_JSON" "$ALERT_LOG" \
  "$PROFILE_ID" "$GATEWAY_OFFLINE_DURATION_SEC" "$PIHOLE_INACTIVE_DURATION_SEC" <<'PY'
import json, os, sys, time
from datetime import datetime, timezone

(status_path, pihole_path, ap_status_path, ap_clients_path, mtr_path,
 state_path, banner_path, log_path,
 profile_id, gateway_dur_s, pihole_dur_s) = sys.argv[1:12]

gateway_dur_s = int(gateway_dur_s)
pihole_dur_s  = int(pihole_dur_s)
now_epoch     = int(time.time())
now_iso       = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

SEVERITY_RANK = {"SEVERE": 0, "CAUTION": 1, "INFORMATIONAL": 2}


def iso(epoch):
    if epoch is None:
        return None
    return datetime.fromtimestamp(epoch, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_json(path):
    """Returns (state_ok, data). state_ok is False for a missing file, bad
    JSON, or an envelope whose own `state` isn't "ok" — the caller treats
    that as "no fresh evidence this round" and carries forward whatever
    state.json already has, rather than mis-deriving a clear/breach from
    data that may not reflect current reality (a tripped SSH gate is not
    the same fact as "the condition it monitors went away")."""
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (FileNotFoundError, json.JSONDecodeError):
        return False, {}
    return data.get("state") == "ok", data


def load_state():
    try:
        with open(state_path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


state = load_state()
state.setdefault("gateway_offline_since", None)
state.setdefault("gateway_alerted", False)
state.setdefault("pihole_inactive_since", None)
state.setdefault("pihole_alerted", False)
state.setdefault("msmtch_since", None)
state.setdefault("msmtch_alerted", False)
state.setdefault("unknown_since", None)
state.setdefault("unknown_alerted", False)
state.setdefault("ap_offline_since", {})   # {label: epoch}
state.setdefault("ap_offline_alerted", {}) # {label: bool}

log_lines = []


def log(action, severity, alert_id, message):
    log_lines.append(f"{now_iso} {action} {severity} {alert_id} {message}")


queue = []

# -------------------------------------------------------------------------
# Gateway offline (proxy for the design notes' proposed >=25% loss / >15min
# condition). status.json today only carries a boolean gateway.online (a
# single ping, no loss % or latency sampling) — real loss-% data is a
# separate, not-yet-built network-health provider (see
# docs/network-providers-roadmap.md). Confirmed with user Aug 22, 2026:
# approximate this session as "gateway.online has been continuously false
# for >= gateway_offline_duration_sec" -> SEVERE.
# -------------------------------------------------------------------------

ok, status = load_json(status_path)
if ok:
    online = status.get("gateway", {}).get("online")
    if online is False:
        if state["gateway_offline_since"] is None:
            state["gateway_offline_since"] = now_epoch
    elif online is True:
        if state["gateway_alerted"]:
            log("CLEAR", "SEVERE", "gateway-offline", "COMCAST OUTAGE DETECTED")
        state["gateway_offline_since"] = None
        state["gateway_alerted"] = False

def mtr_began_child():
    """Second INFO child under gateway-offline: "MTR SCRIPT ON PI5 BEGAN
    <HHMM>UTC", read from providers/mtr/fetch_mtr.sh's own
    mtr_state.json — no SSH, no re-derivation, just the file it already
    wrote. Deliberately does NOT reuse load_json()'s state=="ok" gate:
    that gate means "is this poll's collector healthy", not "is the
    previously-confirmed running fact still valid" — a transient SSH
    hiccup to Pi5 (state flips to "degraded") shouldn't retract an
    already-confirmed BEGAN line. running/confirmed are checked
    directly instead, matching the same "don't claim something that
    isn't verified" standard the state file itself was designed
    around: confirmed=False (start issued, not yet pgrep-verified)
    silently omits this child, same as a missing/unparseable file."""
    try:
        with open(mtr_path, "r", encoding="utf-8") as fh:
            mtr = json.load(fh)
    except (FileNotFoundError, json.JSONDecodeError):
        return None
    if mtr.get("running") is not True or mtr.get("confirmed") is not True:
        return None
    started_epoch = mtr.get("started_at_epoch")
    try:
        started_epoch = int(started_epoch)
    except (TypeError, ValueError):
        return None
    hhmm = datetime.fromtimestamp(started_epoch, tz=timezone.utc).strftime("%H%M")
    return {
        "id": "gateway-offline-mtr",
        "severity": "INFORMATIONAL",
        "message": f"MTR SCRIPT ON PI5 BEGAN {hhmm}UTC",
        "since": iso(started_epoch),
    }


if state["gateway_offline_since"] is not None:
    duration = now_epoch - state["gateway_offline_since"]
    if duration >= gateway_dur_s:
        if not state["gateway_alerted"]:
            log("BREACH", "SEVERE", "gateway-offline", "COMCAST OUTAGE DETECTED")
            state["gateway_alerted"] = True
        minutes = gateway_dur_s // 60
        gateway_children = [{
            "id": "gateway-offline-detail",
            "severity": "INFORMATIONAL",
            "message": f"GATEWAY OFFLINE >={minutes}MIN",
            "since": iso(state["gateway_offline_since"]),
        }]
        mtr_child = mtr_began_child()
        if mtr_child is not None:
            gateway_children.append(mtr_child)
        queue.append({
            "id": "gateway-offline",
            "severity": "SEVERE",
            "message": "COMCAST OUTAGE DETECTED",
            "since": iso(state["gateway_offline_since"]),
            "duration_seconds": duration,
            "children": gateway_children,
        })

# -------------------------------------------------------------------------
# Pi-hole inactive. Duration-threshold, not instantaneous (Pi-hole has been
# observed to blip inactive then self-recover). Severity CAUTION, confirmed
# with user Aug 22, 2026 — degrades ad/tracker blocking, not itself evidence
# the network/WAN is down.
# -------------------------------------------------------------------------

ok, pihole = load_json(pihole_path)
if ok:
    active = pihole.get("active")
    if active is False:
        if state["pihole_inactive_since"] is None:
            state["pihole_inactive_since"] = now_epoch
    elif active is True:
        if state["pihole_alerted"]:
            log("CLEAR", "CAUTION", "pihole-inactive", "PI-HOLE INACTIVE")
        state["pihole_inactive_since"] = None
        state["pihole_alerted"] = False

if state["pihole_inactive_since"] is not None:
    duration = now_epoch - state["pihole_inactive_since"]
    if duration >= pihole_dur_s:
        if not state["pihole_alerted"]:
            log("BREACH", "CAUTION", "pihole-inactive", "PI-HOLE INACTIVE")
            state["pihole_alerted"] = True
        queue.append({
            "id": "pihole-inactive",
            "severity": "CAUTION",
            "message": "PI-HOLE INACTIVE",
            "since": iso(state["pihole_inactive_since"]),
            "duration_seconds": duration,
            "children": [],
        })

# -------------------------------------------------------------------------
# AP client MAC/IP mismatch (MSMTCH). Instantaneous — core-computed
# mismatch_total in ap_clients.json, any count > 0 is CAUTION (no separate
# threshold key; confirmed with user Aug 22, 2026).
# -------------------------------------------------------------------------

ok, ap_clients = load_json(ap_clients_path)
if ok:
    mismatch_total = ap_clients.get("mismatch_total", 0)
    if mismatch_total > 0:
        if state["msmtch_since"] is None:
            state["msmtch_since"] = now_epoch
    else:
        if state["msmtch_alerted"]:
            log("CLEAR", "CAUTION", "msmtch", "MAC/IP MISMATCH")
        state["msmtch_since"] = None
        state["msmtch_alerted"] = False

if state["msmtch_since"] is not None:
    children = []
    total = 0
    for ap in ap_clients.get("aps", []):
        label = ap.get("label", "")
        for m in ap.get("mismatches", []):
            total += 1
            children.append({
                "id": f"msmtch-{m.get('mac', '')}",
                "severity": "INFORMATIONAL",
                "message": (f"{m.get('name', m.get('mac', ''))} at {label}: "
                            f"IP {m.get('ip', '')} (expected {m.get('documented_ip', '')})"),
                "since": iso(state["msmtch_since"]),
            })
    if total > 0:
        if not state["msmtch_alerted"]:
            log("BREACH", "CAUTION", "msmtch", "MAC/IP MISMATCH")
            state["msmtch_alerted"] = True
        queue.append({
            "id": "msmtch",
            "severity": "CAUTION",
            "message": f"MAC/IP MISMATCH ({total})",
            "since": iso(state["msmtch_since"]),
            "duration_seconds": now_epoch - state["msmtch_since"],
            "children": children,
        })

# -------------------------------------------------------------------------
# Unidentified IP. Instantaneous — derived from ap_clients.json's existing
# per-AP unknown[] arrays (no core-side total exists yet for this one, so
# it's summed here rather than requiring a fetch_ap.sh change).
# -------------------------------------------------------------------------

if ok:  # reuses ap_clients envelope state check above
    unknown_total = sum(len(ap.get("unknown", [])) for ap in ap_clients.get("aps", []))
    if unknown_total > 0:
        if state["unknown_since"] is None:
            state["unknown_since"] = now_epoch
    else:
        if state["unknown_alerted"]:
            log("CLEAR", "CAUTION", "unidentified-ip", "UNIDENTIFIED IP ON NETWORK")
        state["unknown_since"] = None
        state["unknown_alerted"] = False

if state["unknown_since"] is not None:
    children = []
    total = 0
    for ap in ap_clients.get("aps", []):
        label = ap.get("label", "")
        for ip in ap.get("unknown", []):
            total += 1
            children.append({
                "id": f"unidentified-ip-{total}",
                "severity": "INFORMATIONAL",
                "message": f"{ip} at {label}",
                "since": iso(state["unknown_since"]),
            })
    if total > 0:
        if not state["unknown_alerted"]:
            log("BREACH", "CAUTION", "unidentified-ip", "UNIDENTIFIED IP ON NETWORK")
            state["unknown_alerted"] = True
        queue.append({
            "id": "unidentified-ip",
            "severity": "CAUTION",
            "message": f"UNIDENTIFIED IP ON NETWORK ({total})",
            "since": iso(state["unknown_since"]),
            "duration_seconds": now_epoch - state["unknown_since"],
            "children": children,
        })

# -------------------------------------------------------------------------
# AP offline. Instantaneous, per-AP — ap_status.json's existing online
# field. Each offline AP is its own top-level SEVERE entry (independent
# conditions, not causally grouped with each other or with gateway-offline).
# -------------------------------------------------------------------------

ok, ap_status = load_json(ap_status_path)
if ok:
    seen_labels = set()
    for ap in ap_status.get("aps", []):
        label = ap.get("label", "")
        seen_labels.add(label)
        online = ap.get("online")
        if online is False:
            if state["ap_offline_since"].get(label) is None:
                state["ap_offline_since"][label] = now_epoch
        elif online is True:
            if state["ap_offline_alerted"].get(label):
                log("CLEAR", "SEVERE", f"ap-offline-{label}", f"AP OFFLINE: {label}")
            state["ap_offline_since"].pop(label, None)
            state["ap_offline_alerted"][label] = False
    # Drop tracked state for any AP label no longer present in ap_status.json
    # (e.g. removed from site.toml) so it can't linger forever.
    for stale in list(state["ap_offline_since"]) :
        if stale not in seen_labels:
            state["ap_offline_since"].pop(stale, None)
            state["ap_offline_alerted"].pop(stale, None)

for label, since_epoch in state["ap_offline_since"].items():
    if not state["ap_offline_alerted"].get(label):
        log("BREACH", "SEVERE", f"ap-offline-{label}", f"AP OFFLINE: {label}")
        state["ap_offline_alerted"][label] = True
    queue.append({
        "id": f"ap-offline-{label}",
        "severity": "SEVERE",
        "message": f"AP OFFLINE: {label}",
        "since": iso(since_epoch),
        "duration_seconds": now_epoch - since_epoch,
        "children": [],
    })

# -------------------------------------------------------------------------
# Sort: severity-ordered (SEVERE, then CAUTION), stable within a tier in
# the fixed evaluation order above (gateway, ap-offline(s), msmtch,
# unidentified-ip, pihole). Parent/child grouping is inherent — children
# travel embedded in their parent, never flattened into the top-level sort.
# -------------------------------------------------------------------------

queue.sort(key=lambda item: SEVERITY_RANK[item["severity"]])

payload = {
    "state": "ok",
    "profile": profile_id,
    "collector": "alerts",
    "generated_at": now_iso,
    "alert_count": len(queue),
    "queue": queue,
}

tmp = banner_path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, separators=(",", ":"))
os.replace(tmp, banner_path)

tmp = state_path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(state, fh, separators=(",", ":"))
os.replace(tmp, state_path)

if log_lines:
    with open(log_path, "a", encoding="utf-8") as fh:
        for line in log_lines:
            fh.write(line + "\n")
PY
