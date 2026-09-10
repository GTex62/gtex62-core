#!/usr/bin/env bash
# providers/alerts/fetch_alerts.sh
# Core alert-banner watcher. Not an SSH provider — no gate, no remote target.
# Reads other providers' already-written cache files (status.json, pihole.json,
# ap_status.json, ap_clients.json under shared/pfsense/{profile}/, vpn.json
# under shared/vpn/{vpn_profile}/, status.json under shared/modem/{modem_profile}/),
# applies threshold/duration logic from
# core.toml's [alerts] section, and writes one
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
# VPN_PROFILE_ID: cross-domain read only, same as MTR_PROFILE_ID above —
# shared/vpn/{vpn_profile}/vpn.json, written by providers/vpn/fetch_vpn.sh.
# Default "local" matches fetch_vpn.sh's and the launcher's own default.
VPN_PROFILE_ID="${3:-local}"
# MODEM_PROFILE_ID: cross-domain read only, same shape as MTR_PROFILE_ID/
# VPN_PROFILE_ID above — shared/modem/{modem_profile}/status.json, written by
# providers/modem/fetch_modem.py. Default "local" matches fetch_modem.py's
# own profile default and pf.lua's suite_profile("modem", "local") fallback.
MODEM_PROFILE_ID="${4:-local}"
CONFIG_ROOT="${GTEX62_CONFIG_DIR:-${GTEX62_CONKY_CONFIG_DIR:-$HOME/.config/gtex62-core}}"
CACHE_ROOT="${GTEX62_CACHE_DIR:-${GTEX62_CONKY_CACHE_DIR:-$HOME/.cache/gtex62-core}}"
CORE_TOML="$CONFIG_ROOT/core.toml"
PF_DIR="$CACHE_ROOT/shared/pfsense/${PROFILE_ID}"
STATUS_JSON="$PF_DIR/status.json"
PIHOLE_JSON="$PF_DIR/pihole.json"
AP_STATUS_JSON="$PF_DIR/ap_status.json"
AP_CLIENTS_JSON="$PF_DIR/ap_clients.json"
MTR_JSON="$CACHE_ROOT/shared/mtr/${MTR_PROFILE_ID}/mtr_state.json"
VPN_JSON="$CACHE_ROOT/shared/vpn/${VPN_PROFILE_ID}/vpn.json"
# fetch_modem.py's status.json — distinct file from pfsense's own
# status.json above (same basename, different provider dir).
MODEM_STATUS_JSON="$CACHE_ROOT/shared/modem/${MODEM_PROFILE_ID}/status.json"
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

ADV_KILLSWITCH_DURATION_SEC="$(parse_section_value "$CORE_TOML" alerts advanced_killswitch_duration_sec || true)"
ADV_KILLSWITCH_DURATION_SEC="${ADV_KILLSWITCH_DURATION_SEC:-10}"

# comcast-degraded (CAUTION) — OR of a T3 burst and a sustained gateway
# loss-% reading. See the evaluation block below for the full reasoning;
# these are its config knobs, same naming shape as the duration keys above.
#
# Replaced 2026-09-10 (see roadmap's Sept 8-10 session logs): the T3 side
# used to be a flat `recent_t3_timeouts >= comcast_degraded_t3_threshold`
# (default 5) — but that field is a whole collapsed row's *lifetime*
# count, not "how many just happened," so once it first crossed 5 it
# tended to stay crossed for as long as the same condition kept
# recurring at all, however mildly (observed live: a trickle averaging
# ~2.5/hr stayed continuously breached for 40+ hours). It couldn't tell
# a real burst from a long-running mild trickle — both looked like flat
# "CAUTION, big number." `comcast_degraded_t3_burst_count`/
# `..._window_min` instead gate on a genuine recent delta: how many NEW
# occurrences landed within roughly the last `..._window_min` minutes,
# normalized to a rate so an irregular polling gap doesn't distort it
# (see the evaluation block for exactly why it's a rate, not a raw
# per-poll delta). Defaults (5 within 5min = 60/hr) picked from the same
# real-episode reference the old flat threshold used ("9, then 12,
# climbing" during confirmed live bursts, docs/network-providers-
# roadmap.md's Aug 31/Sept 6-7 session logs) — a genuinely tunable pair,
# expected to need adjusting after a week of watching real data.
COMCAST_DEGRADED_T3_BURST_COUNT="$(parse_section_value "$CORE_TOML" alerts comcast_degraded_t3_burst_count || true)"
COMCAST_DEGRADED_T3_BURST_COUNT="${COMCAST_DEGRADED_T3_BURST_COUNT:-5}"

COMCAST_DEGRADED_T3_BURST_WINDOW_MIN="$(parse_section_value "$CORE_TOML" alerts comcast_degraded_t3_burst_window_min || true)"
COMCAST_DEGRADED_T3_BURST_WINDOW_MIN="${COMCAST_DEGRADED_T3_BURST_WINDOW_MIN:-5}"

COMCAST_DEGRADED_LOSS_PCT_THRESHOLD="$(parse_section_value "$CORE_TOML" alerts comcast_degraded_loss_pct_threshold || true)"
COMCAST_DEGRADED_LOSS_PCT_THRESHOLD="${COMCAST_DEGRADED_LOSS_PCT_THRESHOLD:-25}"

COMCAST_DEGRADED_LOSS_DURATION_SEC="$(parse_section_value "$CORE_TOML" alerts comcast_degraded_loss_duration_sec || true)"
COMCAST_DEGRADED_LOSS_DURATION_SEC="${COMCAST_DEGRADED_LOSS_DURATION_SEC:-300}"

# How stale modem/status.json can get before the T3 sub-condition is forced
# to expire rather than keep re-asserting a frozen recent_t3_timeouts value
# forever. Added 2026-09-09 (see roadmap's Sept 8/9 session log): load_json()
# only checks the file's own `state` field, never its age — if fetch_modem.py
# stopped running entirely (crash, dead loop, expired credential) rather than
# writing a fresh "degraded"/"error" state, the file just sits there saying
# "ok" with whatever it last saw. 900s (15min, 3x the modem provider's own
# 300s cache_ttl_sec) is generous enough to ride out a couple of missed
# polls without false-expiring on ordinary jitter, tight enough to catch a
# genuinely dead provider well before it can pin the banner for hours.
COMCAST_DEGRADED_T3_STALE_SEC="$(parse_section_value "$CORE_TOML" alerts comcast_degraded_t3_stale_sec || true)"
COMCAST_DEGRADED_T3_STALE_SEC="${COMCAST_DEGRADED_T3_STALE_SEC:-900}"

# -------------------------------------------------------------------------
# Evaluate + write. Pure computation over already-cached JSON — no SSH, no
# gate, no cache-TTL skip (cheap local reads; every invocation recomputes).
# -------------------------------------------------------------------------

python3 - \
  "$STATUS_JSON" "$PIHOLE_JSON" "$AP_STATUS_JSON" "$AP_CLIENTS_JSON" "$MTR_JSON" "$VPN_JSON" \
  "$MODEM_STATUS_JSON" \
  "$STATE_JSON" "$BANNER_JSON" "$ALERT_LOG" \
  "$PROFILE_ID" "$GATEWAY_OFFLINE_DURATION_SEC" "$PIHOLE_INACTIVE_DURATION_SEC" \
  "$ADV_KILLSWITCH_DURATION_SEC" "$COMCAST_DEGRADED_T3_BURST_COUNT" \
  "$COMCAST_DEGRADED_T3_BURST_WINDOW_MIN" \
  "$COMCAST_DEGRADED_LOSS_PCT_THRESHOLD" "$COMCAST_DEGRADED_LOSS_DURATION_SEC" \
  "$COMCAST_DEGRADED_T3_STALE_SEC" <<'PY'
import json, os, sys, time
from datetime import datetime, timezone

(status_path, pihole_path, ap_status_path, ap_clients_path, mtr_path, vpn_path,
 modem_status_path,
 state_path, banner_path, log_path,
 profile_id, gateway_dur_s, pihole_dur_s, adv_ks_dur_s,
 t3_burst_count, t3_burst_window_min, loss_pct_threshold, loss_dur_s, t3_stale_s) = sys.argv[1:20]

gateway_dur_s = int(gateway_dur_s)
pihole_dur_s  = int(pihole_dur_s)
adv_ks_dur_s  = int(adv_ks_dur_s)
t3_burst_count      = int(t3_burst_count)
t3_burst_window_min = float(t3_burst_window_min)
# The count/window pair above is what a human tunes; the actual comparison
# is a rate (events/hour) so an irregular real polling gap doesn't distort
# it — see the evaluation block below for why a raw per-poll delta can't
# work at this cadence.
t3_burst_rate_per_hour = t3_burst_count / (t3_burst_window_min / 60.0)
loss_pct_threshold  = float(loss_pct_threshold)
loss_dur_s          = int(loss_dur_s)
t3_stale_s          = int(t3_stale_s)
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
state.setdefault("adv_ks_blocking_since", None)
state.setdefault("adv_ks_blocking_alerted", False)
state.setdefault("comcast_loss_since", None)
state.setdefault("comcast_t3_burst_active", False)
# Baseline for delta/rate burst detection — the reading (count, epoch,
# lineage anchor) from the last poll that had a genuinely nonzero T3
# total. None until the first such poll ever happens. Deliberately NOT
# reset to (0, now, None) on a poll that reads 0 — see the evaluation
# block for why a real false-positive burst alert (2026-09-10) came from
# doing exactly that.
state.setdefault("t3_last_seen_count", None)
state.setdefault("t3_last_seen_at", None)
state.setdefault("t3_last_seen_since_epoch", None)
state.setdefault("comcast_degraded_since", None)
state.setdefault("comcast_degraded_alerted", False)

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
# Comcast Degraded (CAUTION) — distinct from gateway-offline (SEVERE) above:
# this catches partial WAN degradation that may or may not go on to become
# a full outage. The two conditions are evaluated completely independently
# and can both be active at once — a degraded episode escalating into
# gateway-offline doesn't clear this one, and this one clearing doesn't
# imply gateway-offline has too.
#
# OR of two independent sub-conditions — either firing is enough to raise
# the parent, and whichever one(s) actually fired get their own INFO child
# so a person can see which symptom(s) triggered it:
#
#   - T3 burst: NOT modem/status.json's recent_t3_timeouts crossing a flat
#     threshold anymore (that was the design through 2026-09-09; see
#     docs/network-providers-roadmap.md's Sept 8-10 session logs for the
#     full investigation this replaces). recent_t3_timeouts is a whole
#     collapsed row's *lifetime* docsDevEvCounts, riding along for as
#     long as that row's LastTime stays inside fetch_modem.py's own
#     window — so a flat `>= 5` check couldn't distinguish a genuine
#     active burst from a long-running mild trickle that just never goes
#     a full clean hour. Observed live: a trickle averaging ~2.5/hr kept
#     this flat-breached continuously for 40+ hours, even though it
#     wasn't perceptibly affecting anything — the number the threshold
#     was checking never meant "how much just happened."
#
#     Burst instead tracks a genuine recent delta: `t3_last_seen_count`/
#     `t3_last_seen_at`/`t3_last_seen_since_epoch` (state.json) remember
#     the reading from the last poll that had a genuinely *nonzero* T3
#     total; each poll, `delta = max(0, current - last_seen)` and `rate =
#     delta / hours_since(last_seen_at)` — a rate, not a raw per-poll
#     delta, because polling isn't perfectly metronomic (a missed poll, a
#     slow provider, a manual re-run all stretch or compress the real
#     gap) and a flat delta would misread a long gap as a burst or a
#     short one as calm. Burst fires when `rate >= t3_burst_rate_per_hour`
#     (from comcast_degraded_t3_burst_count / ..._window_min above).
#     Important floor to know when tuning those: at a normal ~5min poll
#     cadence, even one single isolated trickle hit computes to `1 /
#     (5/60) = 12/hr` purely from measurement granularity — the threshold
#     has to sit clearly above that "one lone event" floor or every
#     trickle occurrence reads as a burst. The default (5 in 5min =
#     60/hr) does; anything picked well under ~15/hr likely won't.
#
#     `t3_last_seen_since_epoch` (added 2026-09-10, fetch_modem.py's
#     recent_t3_since_epoch — see its compute_recent_t3() docstring) is
#     the delta math's guard against a real false-positive burst alert
#     that fired live that day: `recent_t3_timeouts` is a whole collapsed
#     row's lifetime count, and when the SAME still-recurring row goes
#     fully quiet (LastTime ages past the window, total genuinely reads
#     0) and then recurs even once, it reports its *entire* history again
#     — not "+1". A naive delta against a baseline that had been reset to
#     0 during that quiet gap misread the whole reappearing total (108,
#     in the real case) as "108 fresh events in one poll interval," an
#     alarming but false burst. The fix: a poll that reads 0 does NOT
#     touch the baseline at all (see below) — it's left exactly as it was
#     the last time the total was genuinely nonzero — and a poll that
#     reads nonzero only trusts the delta as a real rate signal when the
#     lineage anchor (`since_epoch`) matches what's on file, i.e. it's
#     provably the same row reappearing, not a coincidence of timing. If
#     the anchor doesn't match (or there's no prior baseline at all), this
#     poll just (re)establishes the baseline for next time — never treated
#     as "everything's new," same conservative default as the cold-start
#     case below.
#
#     Two more deliberately conservative edge cases, on top of the
#     same-lineage check above: no prior baseline at all (state freshly
#     initialized, or right after a restart with a cleared cache) -> *no
#     burst*, never "everything's new," same "don't derive a breach from
#     incomplete history" principle as everywhere else in this file; and
#     a same-lineage count that's *lower* than the last baseline (should
#     not happen in practice — a row's Counts only grows — but guarded
#     anyway) -> delta floors at 0 rather than going negative. All three
#     bias toward under-, never over-, calling a burst.
#
#     The baseline only advances on a poll with genuinely fresh, nonzero
#     modem data (`ok_modem and not modem_stale and t3_count > 0`) — same
#     fresh-evidence gate as everything else here, extended to also skip
#     zero readings for the reason above — so neither a stale/absent-data
#     gap nor an ordinary quiet reading silently poisons the next real
#     delta; the next nonzero poll's rate is computed against whatever the
#     last genuinely nonzero reading for this same lineage was, however
#     long ago that was, which the rate math already handles correctly
#     regardless of gap length.
#
#     comcast_t3_burst_active is persisted (not recomputed as a bare local
#     each poll) so a transient modem-provider hiccup can't force a false
#     CLEAR the instant its cache goes degraded — same principle as
#     load_json()'s state=="ok" gate. That protection only covers a
#     same-poll ok_modem=False, though — it says nothing about a
#     status.json that's simply gone stale while still saying "ok"
#     (fetch_modem.py stopped running rather than reporting a clean
#     error). Added 2026-09-09: if the file's mtime is older than
#     comcast_degraded_t3_stale_sec (default 900s/15min, 3x the modem
#     provider's own poll cadence), the T3 sub-condition is force-expired
#     instead of re-asserting whatever it last saw, poll after poll,
#     forever.
#
#     Two INFORMATIONAL children when active, not one — the burst itself
#     (what just happened, fast: "T3: +8 IN 10MIN", reviving the exact
#     pre-2026-09-08 "T3: <n> IN <window>M" phrasing, just finally
#     attached to a genuine short-window delta instead of the lifetime
#     total it used to be misapplied to) and the running total for
#     context (modem/status.json's recent_t3_elapsed, "T3: 91 TOTAL FOR
#     36:12" — elapsed rather than a wall-clock anchor so it stays
#     meaningful past 24h without needing a date printed). Both children
#     only appear while a burst is active — a pure trickle (nonzero total,
#     not currently bursting) doesn't raise this alert at all anymore;
#     that context lives solely on the WAN panel's always-visible
#     `T3 X N TOTAL` line (gtex62-sitrep's pf.lua) instead.
#   - Gateway loss: pfsense/status.json's gateway.loss_pct (dpinger's own
#     rolling 60s average, not a single ping — see the gateway.online
#     boolean condition above) >= comcast_degraded_loss_pct_threshold
#     (default 25%, matching the design notes' original ">=25% loss"
#     target now that real loss-% data exists — c7c3f37, 2026-08-23),
#     sustained for >= comcast_degraded_loss_duration_sec (default 300s/
#     5min — deliberately much shorter than gateway-offline's 900s/15min:
#     this condition is meant as an earlier warning, not a duplicate of the
#     full-outage condition on a longer fuse). Same duration-sustain shape
#     as gateway_offline_since/gateway_dur_s above, tracked separately as
#     comcast_loss_since since the threshold/duration differ.
# -------------------------------------------------------------------------

# `ok`/`status` here are the exact pfsense status.json already loaded above
# for the gateway-offline condition — not re-read.
loss_pct = status.get("gateway", {}).get("loss_pct") if ok else None
if ok and isinstance(loss_pct, (int, float)):
    if loss_pct >= loss_pct_threshold:
        if state["comcast_loss_since"] is None:
            state["comcast_loss_since"] = now_epoch
    else:
        state["comcast_loss_since"] = None

loss_breached = False
if state["comcast_loss_since"] is not None:
    loss_duration = now_epoch - state["comcast_loss_since"]
    if loss_duration >= loss_dur_s:
        loss_breached = True

ok_modem, modem = load_json(modem_status_path)
modem_stale = True
try:
    modem_stale = (now_epoch - os.path.getmtime(modem_status_path)) > t3_stale_s
except OSError:
    pass  # missing file -> treat as stale, same as ok_modem's own "no fresh evidence" default

SAME_LINEAGE_TOLERANCE_SEC = 5  # since_epoch equality check slack -- see comment above

t3_count = t3_elapsed = None
t3_burst_delta = t3_burst_interval_min = None  # only set when a burst is actually firing
if ok_modem and not modem_stale:
    t3_count = modem.get("recent_t3_timeouts")
    t3_elapsed = modem.get("recent_t3_elapsed")
    t3_since_epoch = modem.get("recent_t3_since_epoch")

    burst_now = False
    if isinstance(t3_count, (int, float)) and t3_count > 0:
        last_seen_count = state.get("t3_last_seen_count")
        last_seen_at = state.get("t3_last_seen_at")
        last_seen_since_epoch = state.get("t3_last_seen_since_epoch")

        same_lineage = (
            isinstance(last_seen_count, (int, float))
            and isinstance(last_seen_at, (int, float))
            and isinstance(last_seen_since_epoch, (int, float))
            and isinstance(t3_since_epoch, (int, float))
            and abs(t3_since_epoch - last_seen_since_epoch) <= SAME_LINEAGE_TOLERANCE_SEC
        )
        if same_lineage:
            delta = max(0, t3_count - last_seen_count)
            interval_sec = max(1, now_epoch - last_seen_at)  # guard div-by-zero on a same-second re-run
            rate_per_hour = delta / (interval_sec / 3600.0)
            if delta > 0 and rate_per_hour >= t3_burst_rate_per_hour:
                burst_now = True
                t3_burst_delta = delta
                t3_burst_interval_min = max(1, interval_sec // 60)
        # else: no prior baseline yet, or the anchor changed (a genuinely
        # new/different lineage) -> this poll just (re)establishes the
        # baseline below, never treated as "everything's new."

        state["t3_last_seen_count"] = t3_count
        state["t3_last_seen_at"] = now_epoch
        state["t3_last_seen_since_epoch"] = t3_since_epoch
    # else: t3_count is 0 (or missing) -- deliberately leave t3_last_seen_*
    # untouched. See the comment block above: a quiet reading doesn't mean
    # the lineage is gone, and overwriting the baseline with 0 here is
    # exactly what caused the 2026-09-10 false-positive burst.

    state["comcast_t3_burst_active"] = burst_now
elif ok_modem and modem_stale:
    # File says "ok" but hasn't been refreshed in t3_stale_s -- the provider
    # itself has likely stopped running, not just had one bad poll. Force-
    # expire rather than let a stale burst flag re-assert BREACH
    # indefinitely; deliberately do NOT touch t3_last_seen_* here, so the
    # next genuinely fresh poll computes its delta/rate against the last
    # real reading, however long ago that was.
    state["comcast_t3_burst_active"] = False
t3_burst = state["comcast_t3_burst_active"]

degraded_active = t3_burst or loss_breached

if degraded_active:
    if state["comcast_degraded_since"] is None:
        state["comcast_degraded_since"] = now_epoch
else:
    if state["comcast_degraded_alerted"]:
        log("CLEAR", "CAUTION", "comcast-degraded", "COMCAST DEGRADED")
    state["comcast_degraded_since"] = None
    state["comcast_degraded_alerted"] = False

if state["comcast_degraded_since"] is not None:
    if not state["comcast_degraded_alerted"]:
        log("BREACH", "CAUTION", "comcast-degraded", "COMCAST DEGRADED")
        state["comcast_degraded_alerted"] = True
    comcast_children = []
    # Fresh-data-only children: if the sub-condition's own source is
    # degraded/absent this particular poll, its child is simply omitted
    # this round (matching the fresh-evidence gate used everywhere else)
    # rather than rendering a number that isn't actually current.
    if ok_modem and t3_burst:
        comcast_children.append({
            "id": "comcast-degraded-t3-burst",
            "severity": "INFORMATIONAL",
            "message": f"T3: +{t3_burst_delta} IN {t3_burst_interval_min}MIN",
            "since": iso(state["comcast_degraded_since"]),
        })
        if isinstance(t3_count, (int, float)):
            t3_total_message = f"T3: {int(t3_count)} TOTAL"
            if t3_elapsed:
                t3_total_message += f" FOR {t3_elapsed}"
            comcast_children.append({
                "id": "comcast-degraded-t3-total",
                "severity": "INFORMATIONAL",
                "message": t3_total_message,
                "since": iso(state["comcast_degraded_since"]),
            })
    if ok and loss_breached and isinstance(loss_pct, (int, float)):
        loss_minutes = (now_epoch - state["comcast_loss_since"]) // 60
        comcast_children.append({
            "id": "comcast-degraded-loss",
            "severity": "INFORMATIONAL",
            "message": f"GATEWAY: {loss_pct:.0f}% FOR {loss_minutes}MIN",
            "since": iso(state["comcast_loss_since"]),
        })
    queue.append({
        "id": "comcast-degraded",
        "severity": "CAUTION",
        "message": "COMCAST DEGRADED",
        "since": iso(state["comcast_degraded_since"]),
        "duration_seconds": now_epoch - state["comcast_degraded_since"],
        "children": comcast_children,
    })

# -------------------------------------------------------------------------
# Advanced Kill Switch blocking all traffic. Same symptom as gateway-offline
# (nothing works) but a completely different cause and fix — worth its own
# distinct SEVERE message so it isn't mistaken for a Comcast outage.
# Confirmed with user Aug 28, 2026 (see gtex62-core/docs/network-providers-
# roadmap.md § Killswitch Mode Detection — Advanced vs. Regular): PIA's
# "Advanced Kill Switch" (killswitch_mode == "on") keeps blocking traffic
# even while intentionally disconnected — that's the entire point of the
# mode — so vpn.json's connectionstate != "Connected" while that mode is
# configured means real, ongoing traffic blocking, not just "no VPN".
# Short 10s duration gate (vs. gateway-offline's 15min): this isn't waiting
# out a normal blip, it's surfacing promptly since the person may not
# remember Advanced mode is even on. No children — matches ap-offline's
# simplicity, not gateway-offline's parent+child structure; there's nothing
# more useful to break out here than the single fact.
# -------------------------------------------------------------------------

ok, vpn = load_json(vpn_path)
if ok:
    killswitch_mode = vpn.get("killswitch_mode")
    connectionstate = vpn.get("connectionstate")
    blocking = killswitch_mode == "on" and connectionstate != "Connected"
    if blocking:
        if state["adv_ks_blocking_since"] is None:
            state["adv_ks_blocking_since"] = now_epoch
    else:
        if state["adv_ks_blocking_alerted"]:
            log("CLEAR", "SEVERE", "advanced-killswitch-blocking", "KS BLOCKING TRAFFIC")
        state["adv_ks_blocking_since"] = None
        state["adv_ks_blocking_alerted"] = False

if state["adv_ks_blocking_since"] is not None:
    duration = now_epoch - state["adv_ks_blocking_since"]
    if duration >= adv_ks_dur_s:
        if not state["adv_ks_blocking_alerted"]:
            log("BREACH", "SEVERE", "advanced-killswitch-blocking", "KS BLOCKING TRAFFIC")
            state["adv_ks_blocking_alerted"] = True
        queue.append({
            "id": "advanced-killswitch-blocking",
            "severity": "SEVERE",
            "message": "KS BLOCKING TRAFFIC",
            "since": iso(state["adv_ks_blocking_since"]),
            "duration_seconds": duration,
            "children": [],
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
            # Two children, not one (same split as COMCAST DEGRADED's T3
            # burst/total pair) -- name+label+both IPs on one line ran to
            # ~63 chars, more than double the alert column's ~32-34 char
            # budget, and overflowed past the banner's right edge.
            # .upper() matches the font's own requirement (GTex62 OSA has
            # no lowercase glyphs -- see ap.lua's client-name :upper()) --
            # name/label are display_name/label text pulled from
            # devices.toml, not guaranteed pre-uppercased like every other
            # message in this file, which is hardcoded caps.
            children.append({
                "id": f"msmtch-{m.get('mac', '')}-loc",
                "severity": "INFORMATIONAL",
                "message": f"{m.get('name', m.get('mac', ''))} at {label}".upper(),
                "since": iso(state["msmtch_since"]),
            })
            children.append({
                "id": f"msmtch-{m.get('mac', '')}-ip",
                "severity": "INFORMATIONAL",
                "message": f"{m.get('ip', '')} <- {m.get('documented_ip', '')}".upper(),
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
                # .upper() for the same reason as msmtch's children above --
                # label is devices.toml/ap-source text, not guaranteed
                # pre-uppercased, and the font has no lowercase glyphs.
                "message": f"{ip} at {label}".upper(),
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
# the fixed evaluation order above (gateway, comcast-degraded,
# advanced-killswitch-blocking, pihole, msmtch, unidentified-ip,
# ap-offline(s)). Parent/child grouping is inherent — children travel
# embedded in their parent, never flattened into the top-level sort.
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
