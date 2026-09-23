#!/usr/bin/env bash
# providers/doctor/fetch_doctor.sh
# Core health watcher for gtex62-doctor. Not an SSH provider — no gate, no
# remote target. Reads every other provider's already-written cache files
# and mtimes, core.toml's [providers] flags, each domain's profile TOML, and
# site.toml, then writes one shared status.json that the Doctor suite (or any
# other consumer) renders without re-deriving anything.
#
# Design: docs/doctor-design.md. Per-domain evidence: docs/doctor-missing-
# conditions.md. Long-form remediation lives in gtex62-doctor/docs/doctor-qrh.md;
# this script emits the QRH procedure title (`proc`) plus dynamic `detail`,
# never the remediation prose itself.
#
# Same shape as providers/alerts/fetch_alerts.sh: pure computation over
# already-cached files, no cache-TTL skip, every invocation recomputes.
#
# Usage: fetch_doctor.sh [profile]      (default profile: "local")
#   Output: $CACHE_ROOT/shared/doctor/<profile>/status.json — schema below.
#
# status.json schema (schema_version 1)
# ---------------------------------------------------------------------
# {
#   "state": "ok",                  # this script's own health; always "ok"
#   "profile", "collector":"doctor", "schema_version":1,
#   "generated_at": ISO-8601 Z, "generated_epoch": int,
#   "summary": { "entry_count": N, "header": "NO HEALTH ALERTS" |
#                                            "CHECK ACTIONS (N)" },
#   "domain_order": [ ...alphabetical domain keys... ],
#   "domains": { "<key>": ROW, ... },     # 21 domains
#   "entries": [ ENTRY, ... ],            # actionable conditions only
#   "info":    [ ENTRY, ... ],            # informational, not actionable
#   "runtime": [ {"label","path","exists"} ... ],   # RUNTIME panel
#   "config":  { "timezone":F, "lat":F, "lon":F,    # CONFIG panel
#                "openwx_api":F, "airnow_api":F,
#                "nominal": bool },
#   "config_alerts": [ {"id","text"} ... ],         # config-completeness
#   "media":   { ... }                              # MEDIA detail snapshot
# }
# F = {"state":"set"|"blank","value":masked-or-null}. API keys never carry a
# value; lat/lon are masked after the first decimal digit ("32.1XXXXX").
#
# ROW
#   state         "nominal" | "warn" | "disabled" | "private" | "hybrid" |
#                 "idle" | "armed" | "running" | "optional"
#                 Derived ONLY from ttl_sec vs age_sec (plus the provider's
#                 own non-ok state) — never from ttl_fallback, MISSING or
#                 REFRESH (doctor-design.md, "STATE's inputs").
#   enabled       bool — false for DISABLED rows
#   ttl_sec       int | null       INTENDED ttl (a flagged NET reports 1,
#                                  never the launcher's effective 60)
#   ttl_label     null | "ON DEMAND" | "TRIGGER" | "VARIES" | "WRITE" |
#                 "TIMER"          display hint for domains without one TTL
#   ttl_fallback  true | false | null   null = not evaluated (ALERTS, AP,
#                 MEDIA, CONNECT, GITHUB). true when the profile TOML lacks
#                 the key the launcher parses its TTL from (or, for NET and
#                 ORB only, the file is missing), i.e. the launcher is running
#                 the domain on its bash-default cadence. A domain whose fetch
#                 script checks for its profile reports a missing FILE as its
#                 own error (PROFILE TOML MISSING) — never as ttl_fallback.
#   fast_track    bool — NET/SYSTEM/TIME (1s class); AGE display is blank
#                 for these, NET's only while ttl_fallback is false
#   age_sec       number | null    freshness age (now - cache mtime)
#   age_kind      "duration" | "timestamp" | "date" | "ratio"
#   age_ts        ISO-8601 Z | "YYYY-MM-DD" | null   for timestamp/date kinds
#   age_ratio     "N/14" | null                       GITHUB REFRESH only
#   note          primary NOTE tag | null   ERROR DEGRADED PARTIAL WAITING
#                 STALE MISSING REFRESH OPTIONAL
#   notes         all NOTE tags on the row, priority order
#   highlight     bool — an actionable tag is present (row highlight; also
#                 DCM's takeover trigger)
#   provider_state, provider_note      what the provider itself wrote
#   subcaches     PFSENSE only: [{name, enabled, ttl_sec, age_sec, state}]
#   flags         where the enable state came from (core flag / domains)
# ENTRY  {"domain","tag","proc","detail"}   proc = exact QRH title or null
set -euo pipefail

PROFILE_ID="${1:-local}"
CONFIG_ROOT="${GTEX62_CONFIG_DIR:-${GTEX62_CONKY_CONFIG_DIR:-$HOME/.config/gtex62-core}}"
CACHE_ROOT="${GTEX62_CACHE_DIR:-${GTEX62_CONKY_CACHE_DIR:-$HOME/.cache/gtex62-core}}"
# Doctor reads its own launching suite's [profiles]/[domains]
# (suites/doctor.toml) — it has no view of any other suite's launcher.
SUITE_ID="${GTEX62_SUITE_ID:-doctor}"
OUT_DIR="$CACHE_ROOT/shared/doctor/${PROFILE_ID}"
STATE_DIR="$CACHE_ROOT/runtime/doctor/${PROFILE_ID}"
mkdir -p "$OUT_DIR" "$STATE_DIR" "$CACHE_ROOT/tmp"

python3 - "$CONFIG_ROOT" "$CACHE_ROOT" "$SUITE_ID" "$PROFILE_ID" "$OUT_DIR" "$STATE_DIR" <<'PY'
import json, os, re, sys, time
from datetime import datetime, timezone

try:
    import tomllib
except ImportError:  # pragma: no cover
    tomllib = None

(CONFIG_ROOT, CACHE_ROOT, SUITE_ID, PROFILE_ID, OUT_DIR, STATE_DIR) = sys.argv[1:7]
SHARED = os.path.join(CACHE_ROOT, "shared")
NOW = time.time()
NOW_EPOCH = int(NOW)
HOME = os.path.expanduser("~")

# A row goes WARN only once age exceeds ttl + this slack. A cache's age peaks
# just before its next rewrite at one cadence interval plus the difference in
# fetch runtime between two consecutive runs (SSH and scrape times vary), plus
# whole-second mtime granularity. Measured after the skip-margin fix: AP peaks at
# 120-121s on a 120s TTL, Pi-hole/router at 60s. 5s covers that jitter with room
# for a slow SSH round, and only delays a dead 1s loop's WARN by a few seconds.
STALE_GRACE_SEC = 5
GITHUB_REFRESH_DAYS = 10   # NOTE `REFRESH` line (4-day buffer before the cliff)
GITHUB_WINDOW_DAYS = 14

# ttl_fallback — the launcher parses each domain's TTL key out of its profile
# TOML with awk; a present file lacking the key (or, for domains whose fetch
# script never checks for its profile, a missing file) silently drops the
# refresh_loop to the launcher's bash default. Evaluated for every launcher-
# loop domain that has a profile TOML with a TTL key. A flagged row reports
# the INTENDED ttl_sec (the shipped example's value; the launcher default
# where the example ships none), never the effective fallback.
#
# Not evaluated (ttl_fallback null): ALERTS (no profile ships), AP (TTL lives
# in site.toml [ap]), MEDIA (site.toml), CONNECT (on-demand), GITHUB (systemd
# timer), PFSENSE's router/pfblockerng/ifaces sub-caches (their keys are not
# shipped in the example either). A domain whose fetch script explicitly
# checks for its profile writes state:"error" / "missing profile toml" when
# the FILE is absent — that is a different failure mode (PROC: PROFILE TOML
# MISSING) and does not set ttl_fallback. Only NET and ORB never check.
NO_EXISTENCE_CHECK = {"net", "orb"}
TTL_KEY = {
    "air": "cache.ttl_sec", "astro": "cache.refresh_sec", "calendar": "events.cache_ttl_sec",
    "modem": "cache_ttl_sec", "mtr": "cache_ttl_sec", "net": "cache.ttl_sec",
    "network": "cache.refresh_sec", "orb": "cache.ttl_sec", "pihole": "pihole.cache_ttl_sec",
    "pfsense": "cache_ttl_sec", "solar": "cache.refresh_sec", "system": "cache.refresh_sec",
    "time": "cache.refresh_sec", "vpn": "cache_ttl_sec", "weather": "request.cache_ttl_sec",
    "aviation": "cache.metar_ttl_sec / cache.taf_ttl_sec",
}
# Domains with their own QRH fallback procedure; the rest use the generic one.
FALLBACK_PROC = {"net": "NET FALLBACK TTL", "orb": "ORB FALLBACK TTL", "astro": "ASTRO FALLBACK TTL"}


def ttl_key(pt, exists, key, intended, domain):
    """(ttl_sec, ttl_fallback). ttl_sec is the profile's value, or the
    intended value when the key is absent / the row is on the fallback."""
    absent_key = exists and dig(pt, key) is None
    missing_unchecked = (not exists) and domain in NO_EXISTENCE_CHECK
    fallback = bool(absent_key or missing_unchecked)
    ttl = intended if fallback else as_int(dig(pt, key), intended)
    return ttl, fallback


# ---------------------------------------------------------------- helpers
def lenient_toml(path):
    """Line-oriented reader for profiles tomllib rejects. The launcher parses
    profiles with awk, so a file that is not strict TOML (e.g. the bare
    `America/Chicago = ...` keys in profiles/time) still works there; Doctor
    must read it the same way or it would report a false fallback."""
    out, cur = {}, None
    cur = out
    try:
        lines = open(path, "r", encoding="utf-8").read().splitlines()
    except OSError:
        return out
    for raw in lines:
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        m = re.match(r"^\[\[?\s*([^\]]+?)\s*\]\]?$", line)
        if m:
            cur = out
            for part in m.group(1).split("."):
                cur = cur.setdefault(part.strip().strip('"'), {})
            continue
        m = re.match(r"^([^=]+?)\s*=\s*(.+)$", line)
        if not m:
            continue
        key, val = m.group(1).strip().strip('"'), m.group(2).strip()
        if val[:1] in "\"'" and val[-1:] == val[:1] and len(val) > 1:
            cur[key] = val[1:-1]
        elif val in ("true", "false"):
            cur[key] = (val == "true")
        else:
            try:
                cur[key] = int(val)
            except ValueError:
                try:
                    cur[key] = float(val)
                except ValueError:
                    cur[key] = val
    return out


def load_toml(path):
    """(exists, dict). Falls back to lenient_toml when tomllib rejects a
    present file."""
    if not os.path.isfile(path):
        return False, {}
    if tomllib is None:
        return True, lenient_toml(path)
    try:
        with open(path, "rb") as fh:
            return True, tomllib.load(fh)
    except tomllib.TOMLDecodeError:
        return True, lenient_toml(path)
    except OSError:
        return True, {}


def dig(d, dotted, default=None):
    cur = d
    for part in dotted.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return default
        cur = cur[part]
    return cur


def read_json(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def mtime(path):
    try:
        return os.path.getmtime(path)
    except OSError:
        return None


def iso(epoch):
    if epoch is None:
        return None
    return datetime.fromtimestamp(epoch, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def as_int(v, default):
    try:
        return int(float(v))
    except (TypeError, ValueError):
        return default


def profile_toml(domain_dir, profile):
    return load_toml(os.path.join(CONFIG_ROOT, "profiles", domain_dir, f"{profile}.toml"))


core_ok, CORE = load_toml(os.path.join(CONFIG_ROOT, "core.toml"))
site_ok, SITE = load_toml(os.path.join(CONFIG_ROOT, "site.toml"))
suite_ok, SUITE = load_toml(os.path.join(CONFIG_ROOT, "suites", f"{SUITE_ID}.toml"))

# Launcher-equivalent per-domain profile defaults (gtex62-core-launch).
PROFILE_DEFAULTS = {
    "weather": "home", "air": "home", "solar": "home", "aviation": "home",
    "system": "local", "calendar": "local", "time": "local", "astro": "home",
    "network": "local", "connectivity": "default", "pfsense": "main_router",
    "net": "local", "orb": "home", "vpn": "local", "ap": "main_router",
    "modem": "local", "alerts": "main_router", "mtr": "pi5", "media": "local",
    "github": "default",
}


def prof(name):
    return dig(SUITE, f"profiles.{name}") or PROFILE_DEFAULTS[name]


SUITE_DOMAINS = None
if suite_ok:
    SUITE_DOMAINS = set(dig(SUITE, "domains.required", []) or []) | set(
        dig(SUITE, "domains.optional", []) or [])


def core_flag(dotted):
    v = dig(CORE, f"providers.{dotted}", False)
    return v is True


DUAL_GATED = {"vpn", "ap", "modem", "alerts", "mtr", "pihole"}
FLAG_ONLY = {"media"}

PRIORITY = ["ERROR", "DEGRADED", "PARTIAL", "WAITING", "STALE", "MISSING", "REFRESH", "OPTIONAL"]
INFORMATIONAL_TAGS = {"OPTIONAL"}
PROVIDER_BAD = {"error": "ERROR", "degraded": "DEGRADED", "partial": "PARTIAL", "waiting": "WAITING"}


# ------------------------------------------------------------- row engine
class Row:
    def __init__(self, key):
        self.key = key
        self.enabled = True
        self.forced_state = None      # disabled/private/idle/... set by the domain
        self.ttl_sec = None
        self.ttl_label = None
        self.ttl_fallback = None
        self.fast_track = False
        self.age_sec = None
        self.age_kind = "duration"
        self.age_ts = None
        self.age_ratio = None
        self.provider_state = None
        self.provider_note = None
        self.conds = []               # (tag, proc, detail)
        self.extra = {}
        self.stale = False
        self.present = False

    def cond(self, tag, proc=None, detail=None):
        self.conds.append((tag, proc, detail))

    def freshness(self, path, ttl):
        """Set age/stale/present from one cache file's mtime against ttl."""
        self.ttl_sec = ttl
        m = mtime(path)
        self.present = m is not None
        if m is not None:
            self.age_sec = round(max(0.0, NOW - m), 1)
            if ttl is not None and self.age_sec > ttl + STALE_GRACE_SEC:
                self.stale = True
        return m

    def take_provider(self, doc):
        if isinstance(doc, dict):
            self.provider_state = doc.get("state")
            self.provider_note = doc.get("note") or None

    def to_dict(self):
        tags = []
        for tag, _, _ in self.conds:
            if tag not in tags:
                tags.append(tag)
        tags.sort(key=PRIORITY.index)
        actionable = [t for t in tags if t not in INFORMATIONAL_TAGS]
        highlight = bool(actionable) and self.enabled

        if not self.enabled:
            state = "disabled"
        elif self.forced_state in ("private", "hybrid", "idle", "armed", "running"):
            state = self.forced_state
        else:
            state = "nominal"
        # WARN derives from freshness and the provider's own non-ok state,
        # overriding the informational states below except PRIVATE/DISABLED.
        bad_provider = self.provider_state in PROVIDER_BAD
        if self.enabled and state != "private" and (self.stale or bad_provider):
            state = "warn"

        row = {
            "state": state,
            "enabled": self.enabled,
            "ttl_sec": self.ttl_sec,
            "ttl_label": self.ttl_label,
            "ttl_fallback": self.ttl_fallback,
            "fast_track": self.fast_track,
            "age_sec": self.age_sec,
            "age_kind": self.age_kind,
            "age_ts": self.age_ts,
            "age_ratio": self.age_ratio,
            "note": tags[0] if (tags and self.enabled) else None,
            "notes": tags if self.enabled else [],
            "highlight": highlight,
            "provider_state": self.provider_state,
            "provider_note": self.provider_note,
        }
        row.update(self.extra)
        return row


ROWS = {}
ENTRIES = []
INFO = []
CONFIG_ALERTS = []


def add_generic_provider_conds(row, doc, specific):
    """Provider-reported error/degraded/partial/waiting -> NOTE + proc.
    `specific` is a list of (needle, proc) matched (lowercased substring)
    against the provider's note; unmatched notes keep their tag with no
    proc (the caller reports these). Missing profile is generic."""
    if not isinstance(doc, dict):
        return
    st = doc.get("state")
    if st not in PROVIDER_BAD:
        return
    tag = PROVIDER_BAD[st]
    note = str(doc.get("note") or "")
    low = note.lower()
    matched = False
    if "missing profile toml" in low:
        row.cond(tag, "PROFILE TOML MISSING", note)
        matched = True
    for needle, proc in specific:
        if needle in low:
            row.cond(tag, proc, note)
            matched = True
    if not matched:
        row.cond(tag, "UNRECOGNIZED NOTE", note)


def dual_gate(row, key):
    """Apply the core.toml flag (+ suite [domains]) gate. Returns False when
    the row is administratively DISABLED and needs no further reading."""
    flag = core_flag(key)
    in_domains = None if SUITE_DOMAINS is None else (key in SUITE_DOMAINS)
    row.extra["flags"] = {"core_flag": flag, "in_suite_domains": in_domains}
    if not flag:
        row.enabled = False
        return False
    return True


def not_listed_cause(row, key):
    """Flag on, cache missing/stale, launching suite omits the domain: name
    that as the cause (doctor-design.md, Config-Completeness Alerts)."""
    fl = row.extra.get("flags", {})
    if fl.get("core_flag") and fl.get("in_suite_domains") is False and (row.stale or not row.present):
        text = (f"{key.upper()} is enabled in core.toml but not listed in [domains] of "
                f"suites/{SUITE_ID}.toml — add it, or the launcher never starts it.")
        CONFIG_ALERTS.append({"id": "DOMAIN NOT LISTED", "domain": key, "text": text})
        return text
    return None


def generic_stale(row, key, proc, never_tag="STALE", detail=None):
    """Missing cache or stale-with-provider-ok -> STALE/MISSING NOTE."""
    if not row.enabled:
        return
    if not row.present:
        row.cond(never_tag, proc, detail)
    elif row.stale and row.provider_state not in PROVIDER_BAD and row.ttl_fallback is not True:
        row.cond("STALE", proc, detail)


def finish(row, key):
    if row.ttl_fallback is True and row.enabled and not any(t == "MISSING" for t, _, _ in row.conds):
        row.cond("MISSING", FALLBACK_PROC.get(key, "FALLBACK TTL"), TTL_KEY.get(key))
    cause = not_listed_cause(row, key)
    if cause:
        # Replace the generic "provider isn't running" wording with the
        # named cause; STATE/NOTE stay whatever the cache says.
        row.conds = [(t, "DOMAIN NOT LISTED", cause) if t in ("STALE", "MISSING") else (t, p, d)
                     for (t, p, d) in row.conds]
    ROWS[key] = row


# =================================================================== domains
def status_path(domain_dir, profile, name="status.json"):
    return os.path.join(SHARED, domain_dir, profile, name)


def profile_gated_disabled(row, doc, ptoml):
    """Profile-gated domains: the loop always runs; the fetch script writes
    state:"disabled". Also honor an explicit enabled=false before any run."""
    if isinstance(doc, dict) and doc.get("state") == "disabled":
        row.enabled = False
        return True
    if ptoml is not None and dig(ptoml, "enabled", True) is False:
        row.enabled = False
        return True
    return False


# ---- AIR
def do_air():
    p = prof("air")
    row = Row("air")
    exists, pt = profile_toml("air", p)
    ttl, row.ttl_fallback = ttl_key(pt, exists, "cache.ttl_sec", 900, "air")
    path = status_path("air", p)
    doc = read_json(path)
    row.freshness(path, ttl)
    row.take_provider(doc)
    if profile_gated_disabled(row, doc, pt if exists else None):
        return finish(row, "air")
    add_generic_provider_conds(row, doc, [
        ("missing air profile coordinates", "AIR COORDINATES MISSING"),
        ("missing openweather air api key", "AIR API KEY MISSING"),
        ("air fetch failed; no cache", "AIR NO CACHE"),
        ("no provider timestamp", "AIR NO TIMESTAMP"),
        ("openweather source invalid", "AIR OPENWEATHER DEGRADED"),
        ("airnow source invalid", "AIR AIRNOW DEGRADED"),
    ])
    generic_stale(row, "air", "PROVIDER STALE")
    finish(row, "air")


# ---- ALERTS (dual-gated; no profile TOML ships, no state but "ok")
def do_alerts():
    p = prof("alerts")
    row = Row("alerts")
    _, pt = profile_toml("alerts", p)
    ttl = as_int(dig(pt, "cache_ttl_sec"), 60)
    path = status_path("alerts", p, "banner.json")
    row.freshness(path, ttl)
    row.take_provider(read_json(path))
    if dual_gate(row, "alerts"):
        generic_stale(row, "alerts", "ALERTS NOT RUNNING")
    finish(row, "alerts")


# ---- AP (dual-gated; writes into the pfsense cache dir)
def do_ap():
    p = prof("ap")
    row = Row("ap")
    _, pt = profile_toml("pfsense", p)
    ttl = as_int(dig(pt, "ap.cache_ttl_sec") or dig(SITE, "ap.cache_ttl_sec"), 120)
    path = status_path("pfsense", p, "ap_status.json")
    doc = read_json(path)
    row.freshness(path, ttl)
    row.take_provider(doc)
    if dual_gate(row, "ap"):
        add_generic_provider_conds(row, doc, [
            ("no ap ips configured", "AP NO IPS CONFIGURED"),
            ("password file not found", "AP PASSWORD FILE MISSING"),
            ("ssh gate tripped", "AP SSH GATE"),
            ("ssh failed", "AP SSH GATE"),
        ])
        generic_stale(row, "ap", "PROVIDER STALE")
    finish(row, "ap")


# ---- ASTRO (TTL-fallback flag)
def do_astro():
    p = prof("astro")
    row = Row("astro")
    exists, pt = profile_toml("astro", p)
    ttl, row.ttl_fallback = ttl_key(pt, exists, "cache.refresh_sec", 60, "astro")
    path = status_path("astro", p)
    doc = read_json(path)
    row.freshness(path, ttl)
    row.take_provider(doc)
    if profile_gated_disabled(row, doc, pt if exists else None):
        return finish(row, "astro")
    add_generic_provider_conds(row, doc, [("missing location", "ASTRO LOCATION MISSING")])
    generic_stale(row, "astro", "PROVIDER STALE")
    finish(row, "astro")


# ---- AVIATION
def do_aviation():
    p = prof("aviation")
    row = Row("aviation")
    exists, pt = profile_toml("aviation", p)
    t1, f1 = ttl_key(pt, exists, "cache.metar_ttl_sec", 600, "aviation")
    t2, f2 = ttl_key(pt, exists, "cache.taf_ttl_sec", 600, "aviation")
    ttl, row.ttl_fallback = min(t1, t2), (f1 or f2)
    path = status_path("aviation", p)
    doc = read_json(path)
    row.freshness(path, ttl)
    row.take_provider(doc)
    if profile_gated_disabled(row, doc, pt if exists else None):
        return finish(row, "aviation")
    add_generic_provider_conds(row, doc, [
        ("fetch failed; no cache", "AVIATION NO CACHE"),
        ("fetch failing", "AVIATION DEGRADED"),
    ])
    generic_stale(row, "aviation", "PROVIDER STALE")
    finish(row, "aviation")


# ---- CALENDAR (86400s events TTL; timestamp AGE)
def do_calendar():
    p = prof("calendar")
    row = Row("calendar")
    exists, pt = profile_toml("calendar", p)
    ttl, row.ttl_fallback = ttl_key(pt, exists, "events.cache_ttl_sec", 86400, "calendar")
    path = status_path("calendar", p)
    doc = read_json(path)
    m = row.freshness(path, ttl)
    row.take_provider(doc)
    row.age_kind = "timestamp"
    row.age_ts = iso(m)
    if profile_gated_disabled(row, doc, pt if exists else None):
        return finish(row, "calendar")
    add_generic_provider_conds(row, doc, [])
    generic_stale(row, "calendar", "CALENDAR NEVER RUN", never_tag="MISSING")
    finish(row, "calendar")


# ---- CONNECT (on-demand speedtest; age comes from current.json)
def do_connect():
    p = prof("connectivity")
    row = Row("connect")
    exists, pt = profile_toml("connectivity", p)
    path = status_path("connectivity", p)
    doc = read_json(path)
    cur = read_json(status_path("connectivity", p, "current.json")) or {}
    st = cur.get("speedtest") if isinstance(cur, dict) else None
    st = st if isinstance(st, dict) else {}
    max_days = as_int(st.get("max_age_days"), as_int(dig(pt, "speedtest.max_age_days"), 1))
    ttl = max_days * 86400
    row.freshness(path, None)
    row.ttl_sec = ttl
    row.ttl_label = "ON DEMAND"
    row.age_kind = "timestamp"
    row.take_provider(doc)
    age_s = st.get("age_seconds")
    if isinstance(age_s, (int, float)):
        row.age_sec = round(float(age_s), 1)
        row.age_ts = iso(NOW - age_s)
    if profile_gated_disabled(row, doc, pt if exists else None):
        return finish(row, "connect")
    add_generic_provider_conds(row, doc, [("speedtest failing", "CONNECT SPEEDTEST FAILING")])
    if st.get("state") != "disabled" and isinstance(age_s, (int, float)) and age_s > ttl:
        row.stale = True
        if row.provider_state not in PROVIDER_BAD:
            days = int(age_s // 86400)
            row.cond("STALE", "CONNECT SPEEDTEST STALE", f"{days} days")
    if not row.present:
        row.cond("STALE", "PROVIDER STALE")
    finish(row, "connect")


# ---- GITHUB (systemd timer, outside the launcher; STATE hardcoded PRIVATE)
def do_github():
    p = prof("github")
    row = Row("github")
    row.forced_state = "private"
    row.ttl_label = "TIMER"
    row.age_kind = "date"
    exists, pt = profile_toml("github", p)
    path = status_path("github", p)
    doc = read_json(path)
    cur = read_json(status_path("github", p, "current.json")) or {}
    row.freshness(path, None)
    row.take_provider(doc)
    registry_str = dig(pt, "repos.registry_path") or ""
    registry = os.path.expanduser(registry_str) if registry_str else os.path.join(HOME, ".config/conky/github-traffic-repos.json")
    reg = read_json(registry)
    repos = []
    if isinstance(reg, dict):
        for item in reg.get("repos", []) or []:
            name = item if isinstance(item, str) else (item or {}).get("repo")
            if name:
                repos.append(str(name).strip())
    row.extra["registry_repos"] = len(repos)
    # GITHUB is maintainer-only: raise NOTEs only where the profile exists
    # and is enabled. A fresh install ships enabled=false, so it stays silent
    # instead of highlighting MISSING forever.
    applicable = exists and dig(pt, "enabled", True) is not False and \
        not (isinstance(doc, dict) and doc.get("state") == "disabled")
    newest = []
    for r in repos:
        # repo names contain '/', so dig() by dotted path cannot be used
        days = ((cur.get("repos") or {}).get(r) or {}).get("history_days") if isinstance(cur, dict) else None
        if isinstance(days, dict) and days:
            newest.append(max(days.keys()))
    last_success = min(newest) if newest else None
    row.age_ts = last_success
    if applicable:
        if not row.present:
            row.cond("MISSING", "GITHUB NEVER RUN")
        else:
            st = (doc or {}).get("state")
            note = str((doc or {}).get("note") or "")
            if st == "error":
                if "no repos configured" in note.lower():
                    row.cond("ERROR", "GITHUB REGISTRY EMPTY", note)
                elif "fetch failed" in note.lower():
                    row.cond("ERROR", "GITHUB FETCH FAILING", note.split(":", 1)[-1].strip())
                else:
                    row.cond("ERROR", "UNRECOGNIZED NOTE", note)
            if last_success:
                try:
                    d0 = datetime.strptime(last_success, "%Y-%m-%d").date()
                    behind = (datetime.now(timezone.utc).date() - d0).days
                except ValueError:
                    behind = None
                if behind is not None and behind >= GITHUB_REFRESH_DAYS:
                    row.cond("REFRESH", "GITHUB REFRESH", f"{behind}/{GITHUB_WINDOW_DAYS}")
                    row.age_kind = "ratio"
                    row.age_ratio = f"{behind}/{GITHUB_WINDOW_DAYS}"
    finish(row, "github")


# ---- MEDIA (flag-only; config in site.toml [media.lyrics])
def do_media():
    p = prof("media")
    row = Row("media")
    cfg = dig(SITE, "media.lyrics", {}) or {}
    ttl = as_int(cfg.get("poll_interval_sec"), 5)
    path = status_path("media", p)
    doc = read_json(path)
    row.freshness(path, ttl)
    row.ttl_label = "WRITE"
    row.take_provider(doc)
    row.age_kind = "timestamp"
    hit = mtime(status_path("media", p, "lyrics_last_hit.json"))
    row.age_ts = iso(hit)
    local_dir = os.path.expanduser(str(cfg.get("local_dir") or ""))
    genius_set = bool(str(cfg.get("genius_token") or "").strip())
    reach = doc.get("local_dir_reachable") if isinstance(doc, dict) else None
    state_doc = read_json(status_path("media", p, "lyrics_state.json")) or {}
    count = None
    if dual_gate_flag_only(row, "media"):
        count = lyrics_file_count(local_dir, reach)
        add_generic_provider_conds(row, doc, [])
        # MEDIA remediation entries are provisional (doctor-design.md, Open
        # Questions): local_dir_reachable is read straight from status.json.
        if reach is False:
            row.provider_state = "degraded"   # keeps STATE (WARN) beside the DEGRADED NOTE
            row.cond("DEGRADED", "MEDIA LOCAL DIR UNREACHABLE", "local_dir unreachable")
        if not genius_set:
            row.cond("OPTIONAL", "MEDIA GENIUS NOT CONFIGURED", "Genius API not configured — optional")
        generic_stale(row, "media", "PROVIDER STALE")
    MEDIA_DETAIL.update({
        "lyrics_file_count": count,
        "last_track": state_doc.get("last_track_key") or None,
        "sites_checked": list(cfg.get("providers_noapi") or []) + list(cfg.get("providers_api") or []),
        "genius_configured": genius_set,
        "local_dir_reachable": reach,
    })
    finish(row, "media")


MEDIA_DETAIL = {}


def dual_gate_flag_only(row, key):
    flag = core_flag(key)
    row.extra["flags"] = {"core_flag": flag, "in_suite_domains": None}
    if not flag:
        row.enabled = False
    return flag


def lyrics_file_count(local_dir, reachable):
    """Flat file count of the NAS library, cached 300s so the doctor loop
    never lists the mount every few seconds."""
    if not local_dir or reachable is False:
        return None
    cache = os.path.join(STATE_DIR, "media_count.json")
    c = read_json(cache)
    if isinstance(c, dict) and c.get("dir") == local_dir and NOW - c.get("at", 0) < 300:
        return c.get("count")
    try:
        with os.scandir(local_dir) as it:
            n = sum(1 for e in it if e.is_file())
    except OSError:
        return None
    try:
        tmp = cache + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump({"dir": local_dir, "count": n, "at": NOW}, fh)
        os.replace(tmp, cache)
    except OSError:
        pass
    return n


# ---- MODEM (dual-gated)
def do_modem():
    p = prof("modem")
    row = Row("modem")
    exists, pt = profile_toml("modem", p)
    ttl, row.ttl_fallback = ttl_key(pt, exists, "cache_ttl_sec", 300, "modem")
    path = status_path("modem", p)
    doc = read_json(path)
    row.freshness(path, ttl)
    row.take_provider(doc)
    if dual_gate(row, "modem"):
        if profile_gated_disabled(row, doc, pt if exists else None):
            return finish(row, "modem")
        add_generic_provider_conds(row, doc, [
            ("password not configured", "MODEM PASSWORD NOT SET"),
            ("modem unreachable", "MODEM UNREACHABLE"),
            ("modem auth failed", "MODEM AUTH FAILED"),
            ("header mapping incomplete", "MODEM HEADER MAPPING"),
            ("not found", "MODEM HEADER MAPPING"),
            ("has no rows", "MODEM HEADER MAPPING"),
            ("not registered with comcast", "MODEM CONN DEGRADED"),
            ("no locked upstream channels", "MODEM NO UPSTREAM LOCK"),
        ])
        generic_stale(row, "modem", "PROVIDER STALE")
    finish(row, "modem")


# ---- MTR (dual-gated, trigger-driven; own state word)
def do_mtr():
    p = prof("mtr")
    row = Row("mtr")
    exists, pt = profile_toml("mtr", p)
    ttl, row.ttl_fallback = ttl_key(pt, exists, "cache_ttl_sec", 15, "mtr")
    path = status_path("mtr", p, "mtr_state.json")
    doc = read_json(path)
    row.freshness(path, ttl)
    row.ttl_label = "TRIGGER"
    row.take_provider(doc)
    row.age_kind = "timestamp"
    if dual_gate(row, "mtr"):
        if profile_gated_disabled(row, doc, pt if exists else None) or not exists:
            row.enabled = False
            return finish(row, "mtr")   # missing profile reads as disabled
        add_generic_provider_conds(row, doc, [
            ("no ssh_target configured", "MTR NO SSH TARGET"),
            ("ssh gate tripped", "MTR SSH GATE"),
            ("ssh failed", "MTR SSH GATE"),
        ])
        generic_stale(row, "mtr", "PROVIDER STALE")
        if isinstance(doc, dict):
            # Read SitRep's published values — never recompute "last fired".
            started = doc.get("started_at_epoch") or doc.get("last_confirmed_at_epoch")
            row.age_ts = iso(started) if isinstance(started, (int, float)) else None
            trig = doc.get("trigger") if isinstance(doc.get("trigger"), dict) else {}
            if doc.get("running") is True:
                row.forced_state = "running"
            elif trig.get("active") is True:
                row.forced_state = "armed"
            else:
                row.forced_state = "idle"
    finish(row, "mtr")


# ---- NET (fast-track; TTL-fallback flag)
def do_net():
    p = prof("net")
    row = Row("net")
    row.fast_track = True
    exists, pt = profile_toml("net", p)
    ttl, row.ttl_fallback = ttl_key(pt, exists, "cache.ttl_sec", 1, "net")
    path = status_path("net", p)
    doc = read_json(path)
    row.freshness(path, ttl)
    row.take_provider(doc)
    if profile_gated_disabled(row, doc, pt if exists else None):
        return finish(row, "net")
    add_generic_provider_conds(row, doc, [])
    generic_stale(row, "net", "NET NOT RUNNING")
    finish(row, "net")


# ---- NETWORK
def do_network():
    p = prof("network")
    row = Row("network")
    exists, pt = profile_toml("network", p)
    ttl, row.ttl_fallback = ttl_key(pt, exists, "cache.refresh_sec", 5, "network")
    path = status_path("network", p)
    doc = read_json(path)
    row.freshness(path, ttl)
    row.take_provider(doc)
    if profile_gated_disabled(row, doc, pt if exists else None):
        return finish(row, "network")
    add_generic_provider_conds(row, doc, [("null field", "NETWORK NULL FIELDS")])
    generic_stale(row, "network", "PROVIDER STALE")
    finish(row, "network")


# ---- ORB (no status.json — ephemeris.vars only; TTL-fallback flag)
def do_orb():
    p = prof("orb")
    row = Row("orb")
    exists, pt = profile_toml("orb", p)
    ttl, row.ttl_fallback = ttl_key(pt, exists, "cache.ttl_sec", 60, "orb")
    row.freshness(status_path("orb", p, "ephemeris.vars"), ttl)
    generic_stale(row, "orb", "PROVIDER STALE")
    finish(row, "orb")


# ---- PFSENSE (four flags -> DISABLED / HYBRID / NOMINAL-WARN)
def do_pfsense():
    p = prof("pfsense")
    row = Row("pfsense")
    exists, pt = profile_toml("pfsense", p)
    row.ttl_label = "VARIES"
    row.age_kind = "timestamp"
    _, row.ttl_fallback = ttl_key(pt, exists, "cache_ttl_sec", 5, "pfsense")
    d = os.path.join(SHARED, "pfsense", p)
    specs = [
        ("status", "status.json", as_int(dig(pt, "cache_ttl_sec"), 5)),
        ("router", "router.json", as_int(dig(pt, "router.cache_ttl_sec"), 60)),
        ("pfblockerng", "pfblockerng.json", as_int(dig(pt, "pfblockerng.cache_ttl_sec"), 300)),
        ("ifaces", "ifaces.json", as_int(dig(pt, "ifaces_cache_ttl_sec"), 1)),
    ]
    flags = {n: core_flag(f"pfsense.{n}") for n, _, _ in specs}
    row.extra["flags"] = {"core_flags": flags, "in_suite_domains": None}
    subs = []
    # arp/leases ride on status's fetch: no flag of their own.
    riders = [("arp", "arp.json", as_int(dig(pt, "arp_cache_ttl_sec"), 180)),
              ("leases", "leases.json", as_int(dig(pt, "leases_cache_ttl_sec"), 180))]
    plan = [(n, f, t, flags[n]) for n, f, t in specs] + \
           [(n, f, t, flags["status"]) for n, f, t in riders]
    rider_names = {n for n, _, _ in riders}
    status_ttl = specs[0][2]
    newest = None
    stale_names, bad_names = [], []
    main_doc = None
    for name, fname, ttl, en in plan:
        path = os.path.join(d, fname)
        doc = read_json(path)
        m = mtime(path)
        age = round(max(0.0, NOW - m), 1) if m is not None else None
        sstate = doc.get("state") if isinstance(doc, dict) else None
        sub = {"name": name, "enabled": en, "ttl_sec": ttl, "age_sec": age, "state": sstate}
        subs.append(sub)
        if name == "status":
            main_doc = doc
        if not en:
            continue
        if m is not None and (newest is None or m > newest):
            newest = m
        # arp/leases only refresh inside a status fetch that finds them
        # older than their own TTL, so they can legitimately reach
        # ttl + one status cycle before being rewritten.
        limit = ttl + (status_ttl if name in rider_names else 0) + STALE_GRACE_SEC
        if m is None or age > limit:
            stale_names.append(name)
        elif sstate in PROVIDER_BAD:
            bad_names.append((name, sstate, (doc or {}).get("note")))
    row.extra["subcaches"] = subs
    n_enabled = sum(1 for v in flags.values() if v)
    row.age_ts = iso(newest)
    if n_enabled == 0:
        row.enabled = False
        return finish(row, "pfsense")
    row.present = newest is not None
    if isinstance(main_doc, dict) and flags["status"]:
        row.take_provider(main_doc)
        add_generic_provider_conds(row, main_doc, [
            ("no ssh_target configured", "PFSENSE NO SSH TARGET"),
            ("ssh gate tripped", "PFSENSE SSH GATE"),
            ("ssh failed", "PFSENSE SSH GATE"),
        ])
    if stale_names:
        row.stale = True
        row.cond("STALE", "PFSENSE SUBCACHE STALE", ", ".join(stale_names))
    # An enabled, fresh sub-cache reporting its own non-ok state, independent
    # of the HYBRID rollup. The status sub-cache (and arp/leases, which mirror
    # it) are already covered by the main-doc conditions above.
    status_bad = row.provider_state in PROVIDER_BAD
    for name, sstate, snote in bad_names:
        if name == "status" or (name in rider_names and status_bad):
            continue
        row.provider_state = row.provider_state if status_bad else "degraded"
        row.cond(PROVIDER_BAD[sstate], "PFSENSE SUBCACHE DEGRADED",
                 f"{name}: {snote or sstate}")
    if n_enabled < 4:
        row.forced_state = "hybrid"
        row.extra["hybrid"] = {"enabled": n_enabled, "of": 4}
    finish(row, "pfsense")


# ---- PIHOLE (dual-gated; own script/gate; shares pfsense's cache dir)
def do_pihole():
    p = prof("pfsense")
    row = Row("pihole")
    exists, pt = profile_toml("pfsense", p)
    ttl, row.ttl_fallback = ttl_key(pt, exists, "pihole.cache_ttl_sec", 60, "pihole")
    path = status_path("pfsense", p, "pihole.json")
    doc = read_json(path)
    row.freshness(path, ttl)
    row.take_provider(doc)
    if dual_gate(row, "pihole"):
        add_generic_provider_conds(row, doc, [
            ("no ssh_target configured", "PIHOLE NO SSH TARGET"),
            ("ssh gate tripped", "PIHOLE SSH GATE"),
            ("ssh failed", "PIHOLE SSH GATE"),
        ])
        generic_stale(row, "pihole", "PROVIDER STALE")
    finish(row, "pihole")


# ---- SOLAR
def do_solar():
    p = prof("solar")
    row = Row("solar")
    exists, pt = profile_toml("solar", p)
    ttl, row.ttl_fallback = ttl_key(pt, exists, "cache.refresh_sec", 300, "solar")
    path = status_path("solar", p)
    doc = read_json(path)
    row.freshness(path, ttl)
    row.take_provider(doc)
    if profile_gated_disabled(row, doc, pt if exists else None):
        return finish(row, "solar")
    add_generic_provider_conds(row, doc, [("waiting for weather cache", "SOLAR WAITING")])
    generic_stale(row, "solar", "PROVIDER STALE")
    finish(row, "solar")


def do_fast(key, ttl_default, proc):
    p = prof(key)
    row = Row(key)
    row.fast_track = True
    exists, pt = profile_toml(key, p)
    ttl, row.ttl_fallback = ttl_key(pt, exists, "cache.refresh_sec", ttl_default, key)
    path = status_path(key, p)
    doc = read_json(path)
    row.freshness(path, ttl)
    row.take_provider(doc)
    if profile_gated_disabled(row, doc, pt if exists else None):
        return finish(row, key)
    add_generic_provider_conds(row, doc, [])
    generic_stale(row, key, proc)
    finish(row, key)


# ---- VPN (dual-gated)
def do_vpn():
    p = prof("vpn")
    row = Row("vpn")
    exists, pt = profile_toml("vpn", p)
    ttl, row.ttl_fallback = ttl_key(pt, exists, "cache_ttl_sec", 10, "vpn")
    path = status_path("vpn", p, "vpn.json")
    doc = read_json(path)
    row.freshness(path, ttl)
    row.take_provider(doc)
    if dual_gate(row, "vpn"):
        if profile_gated_disabled(row, doc, pt if exists else None):
            return finish(row, "vpn")
        add_generic_provider_conds(row, doc, [
            ("piactl not found", "VPN PIACTL MISSING"),
            ("sudo wg dump failed", "VPN WG STATS DEGRADED"),
            ("wg not found", "VPN WG STATS DEGRADED"),
            ("tunnel ping failing", "VPN TUNNEL PING DEGRADED"),
        ])
        generic_stale(row, "vpn", "PROVIDER STALE")
    finish(row, "vpn")


# ---- WEATHER
def do_weather():
    p = prof("weather")
    row = Row("weather")
    exists, pt = profile_toml("weather", p)
    ttl, row.ttl_fallback = ttl_key(pt, exists, "request.cache_ttl_sec", 300, "weather")
    path = status_path("weather", p)
    doc = read_json(path)
    row.freshness(path, ttl)
    row.take_provider(doc)
    if profile_gated_disabled(row, doc, pt if exists else None):
        return finish(row, "weather")
    add_generic_provider_conds(row, doc, [
        ("missing weather credentials or coordinates", "WEATHER CONFIG MISSING"),
        ("weather fetch failed; no cache", "WEATHER NO CACHE"),
        ("fetch failing", "WEATHER DEGRADED"),
    ])
    generic_stale(row, "weather", "PROVIDER STALE")
    finish(row, "weather")


for fn in (do_air, do_alerts, do_ap, do_astro, do_aviation, do_calendar, do_connect,
           do_github, do_media, do_modem, do_mtr, do_net, do_network, do_orb,
           do_pfsense, do_pihole, do_solar, lambda: do_fast("system", 1, "SYSTEM NOT RUNNING"),
           lambda: do_fast("time", 1, "TIME NOT RUNNING"), do_vpn, do_weather):
    fn()

# ------------------------------------------------------------ entries / info
for key in sorted(ROWS):
    r = ROWS[key]
    if not r.enabled:
        continue
    for tag, proc, detail in r.conds:
        item = {"domain": key, "tag": tag, "proc": proc, "detail": detail}
        (INFO if tag in INFORMATIONAL_TAGS else ENTRIES).append(item)

# --------------------------------------------------- runtime / config panels
def mask_coord(v):
    """Keep sign, integer part and the first decimal digit: 32.1XXXXX"""
    s = str(v).strip()
    if "." not in s:
        return s
    head, tail = s.split(".", 1)
    return f"{head}.{tail[:1]}{'X' * max(0, len(tail) - 1)}"


def field(value, mask=False, secret=False):
    s = "" if value is None else str(value).strip()
    if not s or s.upper().startswith("YOUR_"):
        return {"state": "blank", "value": None}
    if secret:
        return {"state": "set", "value": None}
    return {"state": "set", "value": mask_coord(s) if mask else s}


_, wx_pt = profile_toml("weather", prof("weather"))
_, air_pt = profile_toml("air", prof("air"))
tz = dig(SITE, "location.home.timezone")
openwx = dig(wx_pt, "credentials.owm_api_key") or dig(SITE, "credentials.openweather_api_key")
airnow = dig(air_pt, "airnow.api_key") or dig(SITE, "credentials.airnow_api_key")
CONFIG = {
    "timezone": field(tz),
    "lat": field(dig(SITE, "location.home.lat"), mask=True),
    "lon": field(dig(SITE, "location.home.lon"), mask=True),
    "openwx_api": field(openwx, secret=True),
    "airnow_api": field(airnow, secret=True),
}
if CONFIG["timezone"]["state"] == "blank":
    # Vestigial almost everywhere it is read; there is no system-TZ fallback.
    CONFIG_ALERTS.append({"id": "TZ NOT SET (UNUSED)", "text": "TZ NOT SET (UNUSED)"})
for name, fld in (("lat", "LAT"), ("lon", "LON")):
    if CONFIG[name]["state"] == "blank":
        CONFIG_ALERTS.append({"id": "CONFIG VALUE UNSET", "text": f"site.toml [location.home] {name} is unset"})
CONFIG["nominal"] = all(v["state"] == "set" for k, v in CONFIG.items() if k in ("lat", "lon", "timezone", "openwx_api"))

media_dir = os.path.expanduser(str(dig(SITE, "media.lyrics.local_dir") or ""))
assets = os.environ.get("GTEX62_SHARED_ASSETS_DIR") or os.environ.get("GTEX62_SHARED_ASSETS") \
    or os.path.join(HOME, ".config/conky/gtex62-shared-assets")


def root(label, path):
    path = os.path.expanduser(path or "")
    return {"label": label, "path": path or None, "exists": bool(path) and os.path.isdir(path)}


RUNTIME = [
    root("CONFIG", dig(CORE, "paths.config_root") or CONFIG_ROOT),
    root("DATA", dig(CORE, "paths.data_root") or os.path.join(HOME, ".local/share/gtex62-core")),
    root("CACHE", dig(CORE, "paths.cache_root") or CACHE_ROOT),
    root("ASSETS", assets),
    root("SUITES", dig(CORE, "paths.suites_root") or os.path.join(HOME, ".config/conky")),
    root("MEDIA", media_dir),
]

# ------------------------------------------------------------------ write
order = sorted(ROWS)
payload = {
    "state": "ok",
    "profile": PROFILE_ID,
    "collector": "doctor",
    "schema_version": 1,
    "generated_at": iso(NOW_EPOCH),
    "generated_epoch": NOW_EPOCH,
    "summary": {
        "entry_count": len(ENTRIES),
        "header": f"CHECK ACTIONS ({len(ENTRIES)})" if ENTRIES else "NO HEALTH ALERTS",
    },
    "domain_order": order,
    "domains": {k: ROWS[k].to_dict() for k in order},
    "entries": ENTRIES,
    "info": INFO,
    "runtime": RUNTIME,
    "config": CONFIG,
    "config_alerts": CONFIG_ALERTS,
    "media": MEDIA_DETAIL,
}

out = os.path.join(OUT_DIR, "status.json")
tmp = out + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, separators=(",", ":"))
os.replace(tmp, out)
PY
