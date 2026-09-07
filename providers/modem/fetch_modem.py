#!/usr/bin/env python3
# providers/modem/fetch_modem.py
# Core modem provider (Netgear CM1000 cable modem admin UI).
#
# Unlike the pfsense-family and vpn providers, this one talks HTTP — an
# authenticated scrape of the modem's embedded web admin (DocsisStatus.asp,
# EventLog.asp) reached through pfSense's NAT-to-VIP path to 192.168.100.1,
# not SSH and not a local CLI. See docs/network-providers-roadmap.md,
# "Modem-Level Corroboration Provider", for the reconnaissance this auth
# flow and table structure are built from.
#
# Follows the same envelope/atomic-write/TOML-config conventions as
# fetch_pfsense.sh / fetch_vpn.sh / fetch_github_traffic.py, adapted to a
# pure-Python provider (like fetch_github_traffic.py) since the HTML/XML
# parsing here doesn't fit the bash+awk TOML-helper style cleanly.
#
# Health classification (SNR/power/uncorrectable thresholds) is explicitly
# NOT implemented here — see docs/network-providers-roadmap.md, "Health
# Classification": the Aug 18 reference read is one day's data, not yet a
# long enough baseline to trust thresholds against. This script ships raw
# values only.
import json
import os
import re
import sys
import time
import tomllib
from datetime import datetime, timedelta, timezone
from pathlib import Path

import requests
from bs4 import BeautifulSoup

HOME = Path(os.path.expanduser("~"))
XDG_CACHE_HOME = Path(os.getenv("XDG_CACHE_HOME") or (HOME / ".cache"))
CONFIG_ROOT = Path(os.getenv("GTEX62_CONFIG_DIR") or os.getenv("GTEX62_CONKY_CONFIG_DIR") or (HOME / ".config" / "gtex62-core"))
CACHE_ROOT = Path(os.getenv("GTEX62_CACHE_DIR") or os.getenv("GTEX62_CONKY_CACHE_DIR") or (XDG_CACHE_HOME / "gtex62-core"))
PROFILE_ID = sys.argv[1] if len(sys.argv) > 1 else "local"
PROFILE_TOML = CONFIG_ROOT / "profiles" / "modem" / f"{PROFILE_ID}.toml"
OUT_DIR = CACHE_ROOT / "shared" / "modem" / PROFILE_ID
TMP_DIR = CACHE_ROOT / "tmp"
STATUS_JSON = OUT_DIR / "status.json"

DEFAULT_BASE_URL = "http://192.168.100.1"
DEFAULT_USERNAME = "admin"
DEFAULT_TIMEOUT_SEC = 8
DEFAULT_WINDOW_MINUTES = 60
DEFAULT_CLOCK_OFFSET_SEC = 0  # see compute_recent_t3()'s docstring — real correction lives in profile TOML
DEFAULT_CACHE_TTL_SEC = 300

# -----------------------------------------------------------------------
# Generic helpers (same shape as fetch_github_traffic.py)
# -----------------------------------------------------------------------


def load_toml(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        with open(path, "rb") as f:
            return tomllib.load(f)
    except Exception:
        return {}


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def atomic_write(path: Path, content: str):
    path.parent.mkdir(parents=True, exist_ok=True)
    TMP_DIR.mkdir(parents=True, exist_ok=True)
    tmp = TMP_DIR / (path.name + f".tmp.{os.getpid()}")
    tmp.write_text(content, encoding="utf-8")
    tmp.replace(path)


def write_status(state: str, note: str, modem_ip=None, window_minutes=None):
    """Always emits the full envelope shape (empty/null fields on failure)
    so consumers can jq the same paths regardless of state — same principle
    as fetch_ap.sh's write_stub emitting aps:[] rather than omitting keys."""
    atomic_write(STATUS_JSON, json.dumps({
        "state": state,
        "profile": PROFILE_ID,
        "collector": "modem",
        "generated_at": now_iso(),
        "note": note,
        "modem_ip": modem_ip,
        "upstream_channels": [],
        "downstream_ofdm_channels": [],
        "connectivity_state": None,
        "boot_state": None,
        "recent_t3_timeouts": None,
        "event_log_window_minutes": window_minutes,
    }, separators=(",", ":")) + "\n")


# -----------------------------------------------------------------------
# Auth flow — see docs/network-providers-roadmap.md, "Auth flow, confirmed
# via HAR capture". Confirmed live (this session) end-to-end against the
# real modem, both with a deliberately bad password (clean login-failure
# path, no crash) and with real credentials (full login -> authenticated
# fetch -> logout, see the roadmap's Session Log for the live cross-check):
# webToken is an unquoted numeric hidden-input value (`value=1786514987`,
# no quotes) — regex below tolerates both quoted and unquoted forms.
# requests.Session() does merge the two malformed Set-Cookie headers
# transparently, as the doc hoped but hadn't yet confirmed.
# -----------------------------------------------------------------------

WEBTOKEN_RE = re.compile(r'name="webToken"\s+value=["\']?(\d+)')
REDIRECT_STUB_MARKER = "function redirectPage()"


class ModemUnreachableError(Exception):
    """Network-level failure — host down, connection refused, timeout."""


class ModemAuthError(Exception):
    """Reached the modem, but login/session did not succeed."""


def login(session: requests.Session, base_url: str, username: str, password: str, timeout: float):
    try:
        resp = session.get(f"{base_url}/GenieLogin.asp", timeout=timeout)
        resp.raise_for_status()
    except requests.RequestException as exc:
        raise ModemUnreachableError(f"GET GenieLogin.asp failed: {exc}") from exc

    m = WEBTOKEN_RE.search(resp.text)
    if not m:
        raise ModemAuthError("webToken not found on GenieLogin.asp (page structure changed?)")
    web_token = m.group(1)

    try:
        # allow_redirects=True so the session follows POST -> 302 ->
        # GET /GenieIndex.asp in one call, picking up SessionID along the
        # way per the documented one-step-later cookie behavior.
        resp = session.post(
            f"{base_url}/goform/GenieLogin",
            data={
                "loginUsername": username,
                "loginPassword": password,
                "login": "1",
                "webToken": web_token,
            },
            timeout=timeout,
        )
        resp.raise_for_status()
    except requests.RequestException as exc:
        raise ModemUnreachableError(f"POST goform/GenieLogin failed: {exc}") from exc

    if not any(c.name == "SessionID" for c in session.cookies):
        raise ModemAuthError("no SessionID cookie after login (bad credentials, or page/cookie behavior changed)")


def is_auth_redirect(html: str) -> bool:
    """Confirmed live (this session, unauthenticated GET of both
    DocsisStatus.asp and EventLog.asp): an unauthenticated/expired-session
    request to a protected page returns HTTP 200 with a JS stub
    (`window.top.location = "/GenieLogin.asp"`), not a 401/redirect at the
    HTTP layer. Status-code checks alone would miss this."""
    return REDIRECT_STUB_MARKER in html


def get_authenticated(session, base_url, path, timeout, username, password, _retried=False):
    try:
        resp = session.get(f"{base_url}{path}", timeout=timeout)
        resp.raise_for_status()
    except requests.RequestException as exc:
        raise ModemUnreachableError(f"GET {path} failed: {exc}") from exc

    if is_auth_redirect(resp.text):
        if _retried:
            raise ModemAuthError(f"session not authenticated after re-login (GET {path})")
        login(session, base_url, username, password, timeout)
        return get_authenticated(session, base_url, path, timeout, username, password, _retried=True)

    return resp.text


def logout(session: requests.Session, base_url: str, timeout: float):
    try:
        session.get(f"{base_url}/Logout.asp", timeout=timeout)
    except requests.RequestException:
        pass  # best-effort; CM1000 sessions expire on their own anyway


# -----------------------------------------------------------------------
# DocsisStatus.asp parsing — table ids per docs/network-providers-roadmap.md.
# Only usTable (-> upstream_channels) and d31dsTable (-> downstream_ofdm_
# channels) are parsed, matching the fields actually in the target schema;
# dsTable, d31usTable and startup_procedure_table are documented, stable
# targets for a future extension but out of scope for this session's schema.
#
# Columns are matched by header keyword rather than fixed position (more
# resilient to column reordering); confirmed live (this session) against
# the real page that this correctly maps every field the schema needs and
# correctly ignores the several columns it doesn't (Modulation, Active
# Subcarrier Range, Unerrored/Correctable Codewords) — see
# network-providers-roadmap.md session log for the live cross-check step.
# -----------------------------------------------------------------------

NUM_RE = re.compile(r"-?\d+(?:\.\d+)?")


def extract_number(text):
    if not text:
        return None
    m = NUM_RE.search(text.replace(",", ""))
    return float(m.group(0)) if m else None


def extract_int(text):
    v = extract_number(text)
    return int(v) if v is not None else None


# (header keyword, output field) — order matters, first match wins per cell.
US_COLUMN_MAP = [
    ("lock", "locked"),
    ("channel id", "id"),
    ("frequency", "freq_hz"),
    ("power", "power_dbmv"),
]
US_REQUIRED = {"locked", "id", "freq_hz", "power_dbmv"}

DS_OFDM_COLUMN_MAP = [
    ("channel id", "id"),
    ("frequency", "freq_hz"),
    ("power", "power_dbmv"),
    ("snr", "snr_db"),
    ("uncorrectable", "uncorrectables"),
]
DS_OFDM_REQUIRED = {"id", "freq_hz", "power_dbmv", "snr_db", "uncorrectables"}


def parse_channel_table(soup, table_id, column_map, required_fields):
    table = soup.find(id=table_id)
    if table is None:
        return [], f"table #{table_id} not found"

    trs = table.find_all("tr")
    if not trs:
        return [], f"table #{table_id} has no rows"

    header_cells = trs[0].find_all(["th", "td"])
    header_texts = [c.get_text(strip=True).lower() for c in header_cells]

    col_fields = {}
    for idx, text in enumerate(header_texts):
        for keyword, field in column_map:
            if keyword in text:
                col_fields[idx] = field
                break

    found_fields = set(col_fields.values())
    missing = required_fields - found_fields
    if missing:
        return [], f"table #{table_id} header mapping incomplete (missing {sorted(missing)}; headers seen: {header_texts})"

    rows = []
    for tr in trs[1:]:
        cells = tr.find_all(["td", "th"])
        if not cells:
            continue
        rec = {}
        for idx, cell in enumerate(cells):
            field = col_fields.get(idx)
            if field is None:
                continue
            text = cell.get_text(strip=True)
            if field == "locked":
                low = text.lower()
                rec[field] = ("locked" in low) and ("not" not in low)
            elif field in ("id", "freq_hz", "uncorrectables"):
                rec[field] = extract_int(text)
            elif field in ("power_dbmv", "snr_db"):
                rec[field] = extract_number(text)
        if rec.get("id") is not None:
            rows.append(rec)

    return rows, None


# Row label (first cell, case-insensitive substring match) -> output field.
# `startup_procedure_table` is a fixed 3-column table (Procedure | Status |
# Comment, confirmed live against the real modem this session) with several
# rows besides these two (Acquire Downstream Channel, Configuration File,
# Security, IP Provisioning Mode) that aren't part of this schema — matched
# by label rather than position/count so unrelated rows are ignored rather
# than misread.
STARTUP_ROW_MAP = {
    "connectivity state": "connectivity_state",
    "boot state": "boot_state",
}


def parse_startup_procedure(soup):
    table = soup.find(id="startup_procedure_table")
    if table is None:
        return {}, "table #startup_procedure_table not found"

    result = {}
    for tr in table.find_all("tr"):
        cells = tr.find_all("td")
        if len(cells) < 3:
            continue
        label = cells[0].get_text(strip=True).lower()
        field = STARTUP_ROW_MAP.get(label)
        if field is None:
            continue
        result[field] = {
            "status": cells[1].get_text(strip=True),
            "comment": cells[2].get_text(strip=True),
        }

    missing = set(STARTUP_ROW_MAP.values()) - set(result.keys())
    note = f"startup_procedure_table missing row(s): {sorted(missing)}" if missing else None
    return result, note


def parse_docsis_status(html: str):
    soup = BeautifulSoup(html, "lxml")
    upstream, us_note = parse_channel_table(soup, "usTable", US_COLUMN_MAP, US_REQUIRED)
    downstream_ofdm, ds_note = parse_channel_table(soup, "d31dsTable", DS_OFDM_COLUMN_MAP, DS_OFDM_REQUIRED)
    startup, startup_note = parse_startup_procedure(soup)

    # #Current_systemtime / #SystemUpTime are NOT used as a "now" reference.
    # Confirmed live (this session) that Current_systemtime is populated by
    # leftover placeholder JS (InitTagValue() in DocsisStatus.asp's own
    # source returns a hardcoded dummy string ending in a literal
    # "Mon Jun 11 15:30:50 2012") — dead code on this firmware, not live
    # data, despite the doc's original assumption it could be read for
    # freshness confirmation. compute_recent_t3() uses local host time
    # instead (see its comment) — empirically consistent with the real
    # docsDevEvLastTime values observed, which read as local wall-clock
    # timestamps with no timezone marker.
    notes = [n for n in (us_note, ds_note, startup_note) if n]
    return {
        "upstream_channels": upstream,
        "downstream_ofdm_channels": downstream_ofdm,
        "connectivity_state": startup.get("connectivity_state"),
        "boot_state": startup.get("boot_state"),
        "notes": notes,
    }


# -----------------------------------------------------------------------
# EventLog.asp parsing — regex-extracted XML string, per
# docs/network-providers-roadmap.md. Root element name and field names are
# documented (RFC 4639 DOCSIS Device Event MIB); the per-row wrapper tag
# name is not, so rows are found generically (any element carrying a
# docsDevEvId/docsDevEvIndex child), not by a hardcoded tag like <tr>.
# -----------------------------------------------------------------------

XML_STRING_RE = re.compile(r"InitTagValue\(\)\s*{\s*var xmlFormat = '(.+?)';", re.DOTALL)

EVENT_FIELDS = (
    "docsDevEvIndex", "docsDevEvFirstTime", "docsDevEvLastTime",
    "docsDevEvCounts", "docsDevEvLevel", "docsDevEvId", "docsDevEvText",
)

# DOCSIS Device Event MIB IDs for T3 (ranging-response) timeouts. Confirmed
# live (2026-08-31, real modem capture, two back-to-back sync-loss episodes):
# 82000200 ("No Ranging Response received - T3 time-out") is the primary/
# common variant, present in every confirmed real occurrence that day;
# 82000500 ("Started Unicast Maintenance Ranging - No Response received -
# T3 time-out") is a secondary variant seen once and since aged off the log.
# Matched by ID first (authoritative, locale-independent), with a
# "t3 time-out" text-substring fallback so an undiscovered future ID variant
# doesn't silently repeat this same undercount.
#
# NOTE: an earlier text-pattern-only version of this match also included
# "no ranging response received" and "ucd invalid or channel unusable" as
# standalone substrings (no "T3" qualifier required). Both those texts DO
# still match today via the substring fallback below where they co-occur
# with "T3 time-out" in the same string — that part was never actually
# broken (confirmed live against 82000200's real text). But
# "ucd invalid or channel unusable" alone is docsDevEvId 85000200, a
# *different*, non-T3 DOCSIS event confirmed to occur adjacent to real T3
# bursts in live data — keeping it as a bare pattern over-counted unrelated
# events into recent_t3_timeouts, so it's dropped here rather than kept.
T3_EVENT_IDS = {"82000200", "82000500"}
T3_TEXT_PATTERNS = ("t3 time-out", "t3 timeout")


def _unescape_js_string(s: str) -> str:
    return (
        s.replace("\\'", "'")
         .replace('\\"', '"')
         .replace("\\n", "\n")
         .replace("\\r", "")
         .replace("\\/", "/")
    )


def parse_event_log(html: str):
    m = XML_STRING_RE.search(html)
    if not m:
        return [], "EventLog.asp: xmlFormat string not found (page structure changed?)"

    xml_str = _unescape_js_string(m.group(1))

    try:
        import xml.etree.ElementTree as ET
        root = ET.fromstring(xml_str)
    except Exception as exc:
        return [], f"EventLog.asp: XML parse failed: {exc}"

    events = []
    for el in root.iter():
        if el is root:
            continue
        if el.findtext("docsDevEvIndex") is None and el.findtext("docsDevEvId") is None:
            continue
        events.append({f: el.findtext(f) for f in EVENT_FIELDS})

    return events, None


def matches_t3(event) -> bool:
    if (event.get("docsDevEvId") or "").strip() in T3_EVENT_IDS:
        return True
    text = (event.get("docsDevEvText") or "").lower()
    return any(p in text for p in T3_TEXT_PATTERNS)


# Candidate formats for docsDevEvFirstTime/docsDevEvLastTime. Confirmed
# live (this session, real authenticated EventLog.asp) that the actual
# format is "YYYY-MM-DD, HH:MM:SS" — a comma-space between date and time,
# which none of the originally-guessed formats matched, so every row
# silently failed to parse on the first live run. That format is listed
# first; the others are kept as fallbacks in case firmware/locale varies
# it, not because they've been seen.
TIME_FORMATS = (
    "%Y-%m-%d, %H:%M:%S",
    "%m/%d/%Y %H:%M:%S",
    "%Y-%m-%d %H:%M:%S",
    "%m-%d-%Y %H:%M:%S",
)


def parse_event_time(text, ref_date):
    if not text:
        return None
    text = text.strip()
    for fmt in TIME_FORMATS:
        try:
            return datetime.strptime(text, fmt)
        except ValueError:
            continue
    # Time-only fallback (e.g. "08:22:07") — anchor to ref_date.
    try:
        t = datetime.strptime(text, "%H:%M:%S").time()
        return datetime.combine(ref_date, t)
    except ValueError:
        return None


def compute_recent_t3(events, window_minutes, now_dt, clock_offset_sec=0):
    """Sums docsDevEvCounts across T3-pattern-matching rows whose
    docsDevEvLastTime falls within the trailing window — NOT a row count
    (see roadmap: repeated identical events collapse into one row with a
    repeat counter; counting rows undercounts by roughly 10x).

    `now_dt` should be local host time (naive) — docsDevEvLastTime carries
    no timezone marker and was confirmed live to read as local wall-clock,
    not UTC; the modem's own #Current_systemtime field is not a usable
    substitute (confirmed dead placeholder JS on this firmware — see
    parse_docsis_status()).

    `clock_offset_sec`: added to every parsed modem timestamp before
    comparing it to `now_dt`. Default 0 (no correction) — the Aug 31, 2026
    session confirmed the modem's timestamps read as host-local wall clock
    with no meaningful skew *at that time*. Investigating a real-world
    zero-count report on 2026-09-07 found this had stopped being true: a
    live, actively-flapping burst (new rows landing seconds apart in
    modem-time, ruling out "it's just been quiet") was consistently
    dated ~63-67 minutes behind the host across three independent
    measurements — a stuck-on-Standard-Time modem clock while the host
    correctly observes CDT is the leading theory (see the roadmap doc's
    Sept 7 session log), not measurement noise: a genuinely fresh event
    should show a gap of seconds, not consistently close to an hour. The
    old 300s tolerance below was sized for ordinary NTP-class skew and was
    never going to cover an hour-scale offset — it wasn't wrong, just
    answering a much smaller problem than the one that showed up. This
    parameter is 0 by default (unaffected callers/tests are unchanged);
    the real deployment sets `[eventlog].clock_offset_sec` in its profile
    TOML — see fetch_modem.py's main() and the profile TOML template."""
    total = 0
    unparsed = 0
    nearest_excluded_age_min = None  # closest-to-window T3 match that missed, for the note below
    for ev in events:
        if not matches_t3(ev):
            continue
        counts = extract_int(ev.get("docsDevEvCounts") or "") or 0
        last_dt = parse_event_time(ev.get("docsDevEvLastTime"), now_dt.date())
        if last_dt is None:
            # LastTime missing/unparseable — confirmed live (2026-08-31) as
            # the modem's own "Time Not Established" placeholder on a row
            # that otherwise had a valid FirstTime and a large repeat count,
            # i.e. a still-updating/in-progress row, not corrupt data. Fall
            # back to FirstTime rather than dropping the row: FirstTime is
            # always <= the real LastTime, so if FirstTime alone lands
            # inside the window the row is *at least* that recent and
            # belongs in the count; a genuinely stale leftover row's
            # FirstTime would fall outside the window too, so this fallback
            # can only recover a true positive, never manufacture a false
            # one. Without this, an in-progress T3 burst — the one case
            # where the count matters most — was silently zeroed.
            last_dt = parse_event_time(ev.get("docsDevEvFirstTime"), now_dt.date())
        if last_dt is None:
            unparsed += 1
            continue
        if clock_offset_sec:
            last_dt += timedelta(seconds=clock_offset_sec)
        age_sec = (now_dt - last_dt).total_seconds()
        # small negative tolerance for modem/host clock skew at the edge
        # (ordinary NTP-class jitter, seconds not minutes — clock_offset_sec
        # above is the correction for the modem's own gross offset)
        if -300 <= age_sec <= window_minutes * 60:
            total += counts
        else:
            age_min = age_sec / 60
            if nearest_excluded_age_min is None or age_min < nearest_excluded_age_min:
                nearest_excluded_age_min = age_min

    # Added 2026-09-07, investigating a reported real-world case (see
    # docs/network-providers-roadmap.md's Sept 6/7 session log) of
    # recent_t3_timeouts reading 0 during a corroborated Comcast episode.
    # The window math itself checked out against live data — but a 0
    # caused by "no T3 events at all" and a 0 caused by "T3 events exist,
    # just all just outside the window" were previously indistinguishable
    # after the fact, which is exactly what made that report unprovable
    # once the modem's own finite log buffer rolled the rows off. This
    # note closes that gap going forward without changing the count
    # itself — it only ever fires when total is 0 but a real T3 match
    # existed in the fetched log, so it costs nothing on a genuinely quiet
    # night.
    notes = []
    if total == 0 and nearest_excluded_age_min is not None:
        notes.append(
            f"0 T3 timeouts in the {window_minutes}m window, but a matching "
            f"event row exists {nearest_excluded_age_min:.1f}min old (outside "
            f"the window) — not a parsing failure, just outside the trailing "
            f"window at fetch time"
        )
    if unparsed:
        notes.append(f"{unparsed} matching event row(s) had unparseable First/Last "
                      f"timestamps and were excluded from the {window_minutes}m window count")
    note = "; ".join(notes) or None
    return total, note


# -----------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    TMP_DIR.mkdir(parents=True, exist_ok=True)

    profile = load_toml(PROFILE_TOML)
    if not profile:
        write_status("error", "missing profile toml")
        return 0

    if not profile.get("enabled", True):
        write_status("disabled", "profile disabled")
        return 0

    conn = profile.get("connection", {}) or {}
    creds = profile.get("credentials", {}) or {}
    evlog_cfg = profile.get("eventlog", {}) or {}

    base_url = str(conn.get("base_url") or DEFAULT_BASE_URL).rstrip("/")
    username = str(conn.get("username") or DEFAULT_USERNAME)
    timeout = float(conn.get("timeout_sec") or DEFAULT_TIMEOUT_SEC)
    password = str(creds.get("password") or "")
    window_minutes = int(evlog_cfg.get("window_minutes") or DEFAULT_WINDOW_MINUTES)
    clock_offset_sec = int(evlog_cfg.get("clock_offset_sec") or DEFAULT_CLOCK_OFFSET_SEC)
    cache_ttl = int(profile.get("cache_ttl_sec") or DEFAULT_CACHE_TTL_SEC)

    modem_ip = base_url.split("//", 1)[-1].split("/", 1)[0].split(":", 1)[0]

    if STATUS_JSON.exists():
        age = time.time() - STATUS_JSON.stat().st_mtime
        if age < cache_ttl:
            return 0

    if not password or password.strip().upper() == "CHANGE_ME":
        write_status("error",
                     "modem password not configured ([credentials].password in profile toml)",
                     modem_ip, window_minutes)
        return 0

    # Non-fatal permissions check — the profile toml holds a plaintext
    # password; warn (don't block) if it's group/world-readable.
    perm_warning = None
    try:
        mode = PROFILE_TOML.stat().st_mode
        if mode & 0o077:
            perm_warning = f"{PROFILE_TOML} is readable beyond owner; recommend chmod 600"
    except OSError:
        pass

    session = requests.Session()
    try:
        login(session, base_url, username, password, timeout)
        docsis_html = get_authenticated(session, base_url, "/DocsisStatus.asp", timeout, username, password)
        eventlog_html = get_authenticated(session, base_url, "/EventLog.asp", timeout, username, password)
    except ModemUnreachableError as exc:
        write_status("degraded", f"modem unreachable: {exc}", modem_ip, window_minutes)
        return 0
    except ModemAuthError as exc:
        write_status("degraded", f"modem auth failed: {exc}", modem_ip, window_minutes)
        return 0
    except Exception as exc:  # defensive catch-all — never hard-crash the poll cycle
        write_status("error", f"unexpected error: {exc}", modem_ip, window_minutes)
        return 0
    finally:
        logout(session, base_url, timeout)

    docsis = parse_docsis_status(docsis_html)
    # Local host time, naive — matches the timezone convention observed in
    # real docsDevEvLastTime values (no tz marker, reads as local wall
    # clock). See compute_recent_t3()'s docstring and parse_docsis_status()
    # for why the modem's own #Current_systemtime isn't used here instead.
    now_dt = datetime.now()

    events, evlog_note = parse_event_log(eventlog_html)
    recent_t3, window_note = compute_recent_t3(events, window_minutes, now_dt, clock_offset_sec)

    notes = list(docsis.get("notes") or [])
    if evlog_note:
        notes.append(evlog_note)
    if window_note:
        notes.append(window_note)
    if perm_warning:
        notes.append(perm_warning)

    payload = {
        "state": "ok",
        "profile": PROFILE_ID,
        "collector": "modem",
        "generated_at": now_iso(),
        "note": "; ".join(notes),
        "modem_ip": modem_ip,
        "upstream_channels": docsis["upstream_channels"],
        "downstream_ofdm_channels": docsis["downstream_ofdm_channels"],
        "connectivity_state": docsis["connectivity_state"],
        "boot_state": docsis["boot_state"],
        "recent_t3_timeouts": recent_t3,
        "event_log_window_minutes": window_minutes,
    }
    atomic_write(STATUS_JSON, json.dumps(payload, separators=(",", ":")) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
