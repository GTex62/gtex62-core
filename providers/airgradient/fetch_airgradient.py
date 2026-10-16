#!/usr/bin/env python3
# providers/airgradient/fetch_airgradient.py
# Core airgradient provider: polls an AirGradient ONE's local HTTP API
# (http://<host>/measures/current, no cloud, no SSH), scales the readings,
# runs the ventilation advisor over them plus the outdoor air/weather caches,
# and writes shared/airgradient/<profile>/status.json.
#
# Design: docs/airgradient-provider-design.md (schema, partial payloads) and
# docs/ventilation-advisor-design.md (rules). The advisor itself lives in
# ventilation_advisor.py (pure, no I/O); this file owns fetching, carry-forward
# of fields the device intermittently omits, persistence and output.
#
# Usage: fetch_airgradient.py <profile> [<air_profile> [<weather_profile> [<aviation_profile>]]]
import csv
import fcntl
import json
import math
import os
import re
import sys
import time
import tomllib
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ventilation_advisor as va  # noqa: E402

HOME = Path(os.path.expanduser("~"))
XDG_CACHE_HOME = Path(os.getenv("XDG_CACHE_HOME") or (HOME / ".cache"))
CONFIG_ROOT = Path(os.getenv("GTEX62_CONFIG_DIR") or os.getenv("GTEX62_CONKY_CONFIG_DIR") or (HOME / ".config" / "gtex62-core"))
CACHE_ROOT = Path(os.getenv("GTEX62_CACHE_DIR") or os.getenv("GTEX62_CONKY_CACHE_DIR") or (XDG_CACHE_HOME / "gtex62-core"))
SHARED_ASSETS = Path(os.getenv("GTEX62_SHARED_ASSETS") or os.getenv("GTEX62_SHARED_ASSETS_DIR")
                     or (HOME / ".config" / "conky" / "gtex62-shared-assets"))

PROFILE_ID = sys.argv[1] if len(sys.argv) > 1 else "indoor"
AIR_PROFILE = sys.argv[2] if len(sys.argv) > 2 else "home"
WEATHER_PROFILE = sys.argv[3] if len(sys.argv) > 3 else "home"
AVIATION_PROFILE = sys.argv[4] if len(sys.argv) > 4 else "home"

PROFILE_TOML = CONFIG_ROOT / "profiles" / "airgradient" / f"{PROFILE_ID}.toml"
OUT_DIR = CACHE_ROOT / "shared" / "airgradient" / PROFILE_ID
STATUS_JSON = OUT_DIR / "status.json"
FETCH_LOG = OUT_DIR / "fetch.log"
TMP_DIR = CACHE_ROOT / "tmp"
# Engine-private state and the lock: runtime/, not shared/ (suites never read these, and they are
# disposable: the advisor restarts from NEUTRAL without them).
STATE_DIR = CACHE_ROOT / "runtime" / "airgradient" / PROFILE_ID
STATE_JSON = STATE_DIR / "advisor_state.json"
LOCK_FILE = STATE_DIR / "lock"
# The logs (verdict_log.txt, inputs-*.csv) are NOT disposable (the outdoor record in them exists nowhere
# else), so they live in the data root, or wherever [advisor] log_dir says. Set in main().
LOG_DIR = STATE_DIR


def data_root() -> Path:
    """Persistent data root: $GTEX62_DATA_DIR, else core.toml [paths] data_root, else ~/.local/share/gtex62-core."""
    env = os.getenv("GTEX62_DATA_DIR") or os.getenv("GTEX62_CONKY_DATA_DIR")
    if env:
        return Path(env).expanduser()
    configured = (load_toml(CONFIG_ROOT / "core.toml").get("paths") or {}).get("data_root")
    return Path(str(configured or HOME / ".local" / "share" / "gtex62-core")).expanduser()


def resolve_log_dir(advisor_cfg: dict) -> Path:
    configured = advisor_cfg.get("log_dir")
    if configured:
        return Path(str(configured)).expanduser()
    return data_root() / "airgradient" / PROFILE_ID / "logs"

DEFAULT_TTL_SEC = 30
DEFAULT_TIMEOUT_SEC = 5
DEFAULT_CARRY_MAX_AGE_SEC = 600
DEFAULT_AIR_MAX_AGE_SEC = 7200
DEFAULT_WX_MAX_AGE_SEC = 1800
DEFAULT_STORM_LOOKAHEAD_MIN = 180
DEFAULT_LOG_KEEP_DAYS = 365
DEFAULT_GAP_LOG_SEC = 300
STATE_VERSION = 1

# A response missing any of these is a failed fetch. Everything else the device may omit.
REQUIRED_NUMERIC = ("rco2", "tvocIndex", "noxIndex", "pm01", "pm10")
# Public field name -> (device field, converter). The device intermittently drops all of the
# compensated fields together (firmware 3.7.0); these are carried forward, never replaced by raw.
CARRIED = (
    ("pm25_ugm3", "pm02Compensated", lambda v: round(v, 2)),
    ("temp_f", "atmpCompensated", lambda v: round(v * 9.0 / 5.0 + 32.0, 1)),
    ("humidity_pct", "rhumCompensated", lambda v: round(v, 2)),
    ("pm03_per_dl", "pm003Count", lambda v: int(round(v))),
)


class DeviceError(Exception):
    """The device could not be read: unreachable, bad HTTP status, not JSON, or missing required fields."""


# -----------------------------------------------------------------------
# Generic helpers (same shape as fetch_modem.py)
# -----------------------------------------------------------------------

def load_toml(path: Path) -> dict:
    try:
        with open(path, "rb") as f:
            return tomllib.load(f)
    except Exception:
        return {}


def iso(t):
    if t is None:
        return None
    return datetime.fromtimestamp(t, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(s):
    try:
        return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
    except Exception:
        return None


def atomic_write(path: Path, content: str):
    path.parent.mkdir(parents=True, exist_ok=True)
    TMP_DIR.mkdir(parents=True, exist_ok=True)
    tmp = TMP_DIR / (f"airgradient_{PROFILE_ID}_{path.name}.tmp.{os.getpid()}")
    tmp.write_text(content, encoding="utf-8")
    tmp.replace(path)


def read_json(path: Path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def log(msg: str):
    """One line to fetch.log, trimmed so a dead device cannot grow it without bound."""
    try:
        OUT_DIR.mkdir(parents=True, exist_ok=True)
        if FETCH_LOG.exists() and FETCH_LOG.stat().st_size > 100_000:
            FETCH_LOG.write_text(FETCH_LOG.read_text(encoding="utf-8")[-50_000:], encoding="utf-8")
        with open(FETCH_LOG, "a", encoding="utf-8") as f:
            f.write(f"{iso(time.time())} {msg}\n")
    except OSError:
        pass


def label_from(profile: dict) -> str:
    return str(profile.get("label") or "").strip().upper()[:8]


# -----------------------------------------------------------------------
# Device fetch, scaling, carry-forward
# -----------------------------------------------------------------------

def fetch_device(host: str, timeout: float) -> dict:
    url = f"http://{host}/measures/current"
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            if resp.status != 200:
                raise DeviceError(f"HTTP {resp.status}")
            payload = json.loads(resp.read().decode("utf-8"))
    except DeviceError:
        raise
    except Exception as exc:
        raise DeviceError(f"{type(exc).__name__}: {exc}") from exc
    if not isinstance(payload, dict):
        raise DeviceError("response is not a JSON object")
    missing = [k for k in REQUIRED_NUMERIC if va.num(payload.get(k)) is None]
    if not isinstance(payload.get("serialno"), str):
        missing.append("serialno")
    if missing:
        raise DeviceError("missing required fields: " + ", ".join(missing))
    return payload


def build_reading(payload: dict, carry: dict, now: float, max_age: float):
    """Scale a good response. Returns (reading, carried, carry). `carry` maps public field name ->
    [time, value] of the last value actually reported by the device."""
    carry = dict(carry or {})
    carried, vals = [], {}
    for name, key, conv in CARRIED:
        raw = va.num(payload.get(key))
        if raw is not None:
            vals[name] = conv(raw)
            carry[name] = [now, vals[name]]
            continue
        prev = carry.get(name)
        if prev and 0 <= now - prev[0] <= max_age:
            vals[name] = prev[1]
            carried.append({"field": name, "age_sec": int(now - prev[0])})
        else:
            vals[name] = None
    dew = va.dewpoint_f(vals["temp_f"], vals["humidity_pct"])
    reading = {
        "co2_ppm": int(math.floor(payload["rco2"])),
        "voc_index": int(math.floor(payload["tvocIndex"])),
        "nox_index": int(math.floor(payload["noxIndex"])),
        "pm": {
            "pm03_per_dl": vals["pm03_per_dl"],
            "pm1_ugm3": round(float(payload["pm01"]), 2),
            "pm25_ugm3": vals["pm25_ugm3"],
            "pm10_ugm3": round(float(payload["pm10"]), 2),
        },
        "temp_f": vals["temp_f"],
        "humidity_pct": vals["humidity_pct"],
        "dew_point_f": None if dew is None else round(dew, 1),
        "wifi_rssi": None if va.num(payload.get("wifi")) is None else int(payload["wifi"]),
    }
    return reading, carried, carry


# -----------------------------------------------------------------------
# Outdoor inputs for the advisor (read-only; other domains own these files)
# -----------------------------------------------------------------------

def gather_outdoor(now: float, air_max_age: float, wx_max_age: float):
    """Returns (advisor `out` dict, flags for status.json). Missing or stale inputs only switch off
    the rules that need them."""
    out, flags = {}, {"pm_source": None, "air_fresh": False, "wx_fresh": False}
    air = read_json(CACHE_ROOT / "shared" / "air" / AIR_PROFILE / "current.json")
    if isinstance(air, dict):
        gen = parse_iso(air.get("generated_at"))
        # provider_updated_at is AirNow's hourly observation time and lags; generated_at says the provider is alive.
        flags["air_fresh"] = gen is not None and -60 <= now - gen <= air_max_age
        sel = air.get("selected") or {}
        anw = air.get("airnow") or {}
        owm = (air.get("openweather") or {}).get("components") or {}
        out.update(aqi=anw.get("aqi"), pm25=sel.get("pm2_5"), pm10=sel.get("pm10"),
                   owm_pm25=owm.get("pm2_5"), owm_pm10=owm.get("pm10"))
        if va.num((anw.get("values") or {}).get("pm2_5")) is not None:
            flags["pm_source"] = "airnow"
        elif va.num(sel.get("pm2_5")) is not None:
            flags["pm_source"] = "owm"
    wx = read_json(CACHE_ROOT / "shared" / "weather" / WEATHER_PROFILE / "current.json")
    if isinstance(wx, dict):
        upd = parse_iso(wx.get("provider_updated_at"))
        flags["wx_fresh"] = upd is not None and -60 <= now - upd <= wx_max_age
        out.update(temp_f=wx.get("temp_f"), rh=wx.get("humidity_pct"))
    out.update(air_fresh=flags["air_fresh"], wx_fresh=flags["wx_fresh"], pm_source=flags["pm_source"])
    return out, flags


_METAR_WIND = re.compile(r"^(VRB|\d{3})(\d{2,3})(?:G(\d{2,3}))?(KT|MPS)$")
_METAR_TIME = re.compile(r"^(\d{2})(\d{2})(\d{2})Z$")


def parse_metar_wind(raw, now: float):
    """Wind and observation time from a raw METAR line, or {} if there is none. Speeds are knots.
    `00000KT` is calm (direction None); `VRB05KT` has no direction either. Handles KT and MPS."""
    out = {}
    if not isinstance(raw, str) or not raw.strip():
        return out
    for tok in raw.strip().splitlines()[0].split():
        m = _METAR_TIME.match(tok)
        if m and "metar_obs" not in out:
            day, hh, mm = int(m.group(1)), int(m.group(2)), int(m.group(3))
            n = datetime.fromtimestamp(now, timezone.utc)
            for back in (0, 1):                         # this month, else the previous one (a report from just before a month turn)
                y, mo = n.year, n.month - back
                if mo == 0:
                    y, mo = y - 1, 12
                try:
                    cand = datetime(y, mo, day, hh, mm, tzinfo=timezone.utc).timestamp()
                except ValueError:
                    continue
                if cand <= now + 6 * 3600:
                    out["metar_obs"] = iso(cand)
                    break
            continue
        m = _METAR_WIND.match(tok)
        if m:
            scale = 1.0 if m.group(4) == "KT" else 1.943844
            speed = int(m.group(2)) * scale
            gust = int(m.group(3)) * scale if m.group(3) else None
            out["wind_dir"] = None if (m.group(1) == "VRB" or speed == 0) else int(m.group(1))
            out["wind_kt"] = round(speed, 1)
            out["wind_gust_kt"] = None if gust is None else round(gust, 1)
            out["wind_variable"] = int(m.group(1) == "VRB")
            break
    return out


def gather_wind(now: float) -> dict:
    """Outdoor wind for the input log only (no advisor rule uses it): the METAR from the aviation cache is the
    primary (an observation, with direction and gusts); OpenWeather's speed from the weather cache is a second
    column for comparison."""
    av = read_json(CACHE_ROOT / "shared" / "aviation" / AVIATION_PROFILE / "current.json")
    wind = parse_metar_wind(av.get("metar_raw") if isinstance(av, dict) else None, now)
    wx = read_json(CACHE_ROOT / "shared" / "weather" / WEATHER_PROFILE / "current.json")
    mph = va.num(wx.get("wind_mph")) if isinstance(wx, dict) else None
    wind["wind_mph_owm"] = mph
    return wind


# -----------------------------------------------------------------------
# Weather hazards for the advisor: thunder and rain now (METAR, OpenWeather) and expected (TAF)
# -----------------------------------------------------------------------

_WX_TOKEN = re.compile(r"^(?:[-+]|VC)?(?:MI|BC|PR|DR|BL|SH|TS|FZ)*(?:DZ|RA|SN|SG|IC|PL|GR|GS|UP)*$")


def wx_token_flags(tok: str):
    """(thunder, rain) for one METAR/TAF present-weather token. Thunder is any TS (VCTS included: a storm
    within 5 to 10 miles of the airport, which is about the distance to the house). Rain is RA, DZ or SH
    (showers). Snow, mist and the like count as neither."""
    if not tok or not _WX_TOKEN.match(tok):
        return False, False
    return "TS" in tok, ("RA" in tok or "DZ" in tok or "SH" in tok)


def parse_metar_weather(raw, now: float):
    """Present weather in a raw METAR: {'ts': bool, 'rain': bool, 'obs': epoch or None}. Empty if no METAR."""
    if not isinstance(raw, str) or not raw.strip():
        return {}
    toks = raw.strip().splitlines()[0].split()
    ts = rain = False
    for tok in toks[2:]:
        if tok == "RMK":
            break
        t, r = wx_token_flags(tok)
        ts, rain = ts or t, rain or r
    obs = None
    meta = parse_metar_wind(raw, now)
    if meta.get("metar_obs"):
        obs = parse_iso(meta["metar_obs"])
    return {"ts": ts, "rain": rain, "obs": obs}


_TAF_DDHH = re.compile(r"^(\d{2})(\d{2})/(\d{2})(\d{2})$")
_TAF_FM = re.compile(r"^FM(\d{2})(\d{2})(\d{2})$")
_TAF_ISSUE = re.compile(r"^(\d{2})(\d{2})(\d{2})Z$")


def _resolve_day_hour(day: int, hour: int, minute: int, ref: float):
    """The UTC epoch of day-of-month/hour/minute nearest to `ref` (a TAF carries no month)."""
    n = datetime.fromtimestamp(ref, timezone.utc)
    best = None
    for dm in (-1, 0, 1):
        y, mo = n.year, n.month + dm
        if mo == 0:
            y, mo = y - 1, 12
        elif mo == 13:
            y, mo = y + 1, 1
        try:
            base = datetime(y, mo, day, 0, 0, tzinfo=timezone.utc).timestamp() + hour * 3600 + minute * 60
        except ValueError:
            continue
        if best is None or abs(base - ref) < abs(best - ref):
            best = base
    return best


def _taf_wind(toks):
    """Wind direction from a group's tokens: degrees, None for variable or calm, and a flag for 'none given'."""
    for tok in toks:
        w = _METAR_WIND.match(tok)
        if w:
            return (None if (w.group(1) == "VRB" or int(w.group(2)) == 0) else int(w.group(1))), True
    return None, False


def parse_taf(raw, now: float):
    """Forecast periods from a raw TAF: a list of {start, end, ts, rain, wind_deg} (epoch seconds; wind_deg None
    for variable or calm). FM groups replace the prevailing conditions from their time; BECMG, TEMPO and PROBnn
    groups are taken as possible within their own window (the cautious reading). A group without a wind
    takes the prevailing wind. [] if unparseable."""
    if not isinstance(raw, str) or not raw.strip():
        return []
    toks = raw.split()
    issue = None
    k = 0
    while k < len(toks) and not _TAF_DDHH.match(toks[k]):
        m = _TAF_ISSUE.match(toks[k])
        if m and issue is None:
            issue = _resolve_day_hour(int(m.group(1)), int(m.group(2)), int(m.group(3)), now)
        k += 1
    if k >= len(toks) or issue is None:
        return []
    m = _TAF_DDHH.match(toks[k])
    start = _resolve_day_hour(int(m.group(1)), int(m.group(2)), 0, issue)
    end = _resolve_day_hour(int(m.group(3)), int(m.group(4)), 0, start)
    if start is None or end is None:
        return []
    groups = [{"kind": "prevailing", "start": start, "end": end, "toks": []}]
    k += 1
    while k < len(toks):
        tok = toks[k]
        mfm = _TAF_FM.match(tok)
        if mfm:
            t0 = _resolve_day_hour(int(mfm.group(1)), int(mfm.group(2)), int(mfm.group(3)), issue)
            groups.append({"kind": "prevailing", "start": t0, "end": end, "toks": []})
            k += 1
            continue
        if tok in ("BECMG", "TEMPO") or re.match(r"^PROB\d\d$", tok):
            j = k + 1
            if tok.startswith("PROB") and j < len(toks) and toks[j] == "TEMPO":
                j += 1
            mv = _TAF_DDHH.match(toks[j]) if j < len(toks) else None
            if mv:
                a = _resolve_day_hour(int(mv.group(1)), int(mv.group(2)), 0, issue)
                b = _resolve_day_hour(int(mv.group(3)), int(mv.group(4)), 0, a or issue)
                if a is None or b is None:
                    return []
                groups.append({"kind": "sibling", "start": a, "end": b, "toks": []})
                k = j + 1
                continue
        groups[-1]["toks"].append(tok)
        k += 1
    prev = [g for g in groups if g["kind"] == "prevailing"]
    for n, g in enumerate(prev):                       # a prevailing group ends where the next one starts
        g["end"] = prev[n + 1]["start"] if n + 1 < len(prev) else end
    periods = []
    for g in groups:
        deg, given = _taf_wind(g["toks"])
        if not given:
            cover = [p for p in prev if p["start"] <= g["start"] < p["end"]]
            deg = cover[-1].get("wind_deg") if cover else None
        g["wind_deg"] = deg
        ts = rain = False
        for tok in g["toks"]:
            t, r = wx_token_flags(tok)
            ts, rain = ts or t, rain or r
        periods.append({"start": g["start"], "end": g["end"], "ts": ts, "rain": rain, "wind_deg": deg})
    return periods


def taf_outlook(raw, now: float, lookahead_s: float):
    """What the TAF expects within the look-ahead: {'ts_min', 'rain_min', 'rain_wind_deg'} (minutes from now,
    0 = under way), each None when nothing is expected. {} when the TAF is missing, unparseable or already over."""
    periods = parse_taf(raw, now)
    if not periods or max(p["end"] for p in periods) <= now:
        return {}
    horizon = now + lookahead_s
    ts_min = rain_min = rain_wind = None
    for per in sorted(periods, key=lambda x: x["start"]):
        if per["end"] <= now or per["start"] >= horizon:
            continue
        mins = max(0.0, (per["start"] - now) / 60.0)
        if per["ts"] and (ts_min is None or mins < ts_min):
            ts_min = mins
        if per["rain"] and (rain_min is None or mins < rain_min):
            rain_min, rain_wind = mins, per["wind_deg"]
    return {"ts_min": ts_min, "rain_min": rain_min, "rain_wind_deg": rain_wind}


def weather_hazard(now: float, lookahead_s: float, wx_fresh: bool, aviation_max_age: float = 7200) -> dict:
    """Advisor inputs for thunder and rain, and the wind that decides whether rain would blow in:
    now = METAR present weather (a report under 90 minutes old) or OpenWeather's condition code (fresh);
    expected = the TAF within the look-ahead. OpenWeather's wind direction is used when fresh, else the METAR's.
    Keys are present only when there is something to report (the advisor treats absent as none)."""
    out = {}
    wx = read_json(CACHE_ROOT / "shared" / "weather" / WEATHER_PROFILE / "current.json")
    av = read_json(CACHE_ROOT / "shared" / "aviation" / AVIATION_PROFILE / "current.json")
    code = va.num(wx.get("wx_code")) if isinstance(wx, dict) and wx_fresh else None
    ts_now = rain_now = False
    if code is not None:
        ts_now = 200 <= code < 300
        rain_now = 300 <= code < 400 or 500 <= code < 600
    metar_raw = av.get("metar_raw") if isinstance(av, dict) else None
    mw = parse_metar_weather(metar_raw, now)
    if mw.get("obs") is not None and -300 <= now - mw["obs"] <= 5400:
        ts_now, rain_now = ts_now or mw["ts"], rain_now or mw["rain"]
    wind_deg = va.num(wx.get("wind_deg")) if isinstance(wx, dict) and wx_fresh else None
    if wind_deg is None:
        wind_deg = parse_metar_wind(metar_raw, now).get("wind_dir")
    out["wind_deg"] = wind_deg
    gen = parse_iso(av.get("generated_at")) if isinstance(av, dict) else None
    soon = {}
    if gen is not None and -60 <= now - gen <= aviation_max_age:
        soon = taf_outlook(av.get("taf_raw"), now, lookahead_s)
    ts_min = 0.0 if ts_now else soon.get("ts_min")
    rain_min = 0.0 if rain_now else soon.get("rain_min")
    if ts_min is not None:
        out["ts_min"] = ts_min
    if rain_min is not None:
        out["rain_min"] = rain_min
        if not rain_now and soon.get("rain_min") is not None:
            out["rain_wind_deg"] = soon.get("rain_wind_deg")
    return out


def read_pollen(csv_path: Path):
    """Seasonal pollen index for today's local day of year, or None if the file or row is missing."""
    try:
        doy = datetime.now().timetuple().tm_yday
        with open(csv_path, encoding="utf-8") as f:
            for row in csv.reader(f):
                if row and row[0].strip().isdigit() and int(row[0]) == doy and len(row) >= 5:
                    return {"tree": float(row[1]), "grass": float(row[2]),
                            "weed": float(row[3]), "mold": float(row[4]), "source": "seasonal-curve"}
    except (OSError, ValueError):
        pass
    return None


# -----------------------------------------------------------------------
# Advisor configuration and persistence
# -----------------------------------------------------------------------

def advisor_cfg(profile: dict) -> dict:
    adv = profile.get("advisor", {}) or {}
    cfg = {}
    for k, v in (adv.get("thresholds", {}) or {}).items():
        if k in va.DEFAULTS and isinstance(v, (int, float)) and not isinstance(v, bool):
            cfg[k] = v
    for k in ("window_facing_deg", "wind_side_deg"):
        v = adv.get(k)
        if isinstance(v, (int, float)) and not isinstance(v, bool) and 0 <= v <= 360:
            cfg[k] = float(v)
    pol = adv.get("pollen", {}) or {}
    if isinstance(pol.get("threshold"), (int, float)):
        cfg["pollen_threshold"] = pol["threshold"]
    if isinstance(pol.get("categories"), list):
        cfg["pollen_categories"] = tuple(str(c) for c in pol["categories"])
    return cfg


def load_state() -> dict:
    st = read_json(STATE_JSON)
    if isinstance(st, dict) and st.get("v") == STATE_VERSION and isinstance(st.get("advisor"), dict):
        return st
    if STATE_JSON.exists():
        log("advisor_state.json unreadable or from another version; starting from NEUTRAL")
    return {"v": STATE_VERSION, "advisor": None, "carry": {}, "log": {}, "first_t": None}


# -----------------------------------------------------------------------
# Output
# -----------------------------------------------------------------------

def vent_block(adv: "va.Advisor", now: float, flags: dict, shadow: bool) -> dict:
    al = adv.alert(now)
    show = al["visible"] and not shadow
    return {
        "verdict": adv.verdict,
        "severity": adv.severity,
        "class": adv.cls,
        "reason": adv.reason,
        "since": iso(adv.since),
        "alert_visible": show,
        "alert_text": al["text"] if show else "",
        "alert_expires_at": iso(al["expires_at"]) if show else None,
        "annotations": list(adv.notes),
        "outdoor": {"pm_source": flags.get("pm_source"), "air_fresh": bool(flags.get("air_fresh")),
                    "wx_fresh": bool(flags.get("wx_fresh"))},
        "shadow": shadow,
    }


def envelope(state: str, label: str, note: str, now: float, **kw) -> dict:
    """Full shape on every path (nulls when unknown) so consumers can jq the same paths."""
    doc = {
        "state": state, "profile": PROFILE_ID, "collector": "airgradient", "label": label,
        "generated_at": None, "attempted_at": iso(now), "note": note,
        "device": {"host": None, "serialno": None, "model": None, "firmware": None},
        "carried_fields": [],
        "co2_ppm": None, "voc_index": None, "nox_index": None,
        "pm": {"pm03_per_dl": None, "pm1_ugm3": None, "pm25_ugm3": None, "pm10_ugm3": None},
        "temp_f": None, "humidity_pct": None, "dew_point_f": None, "wifi_rssi": None,
        "ventilation": None,
    }
    doc.update(kw)
    return doc


def write_status(doc: dict):
    atomic_write(STATUS_JSON, json.dumps(doc, separators=(",", ":")) + "\n")


def log_verdict(now: float, event: str, adv: "va.Advisor", flags: dict):
    line = "\t".join([iso(now), event, adv.verdict, adv.cls, adv.severity, adv.reason,
                      f"pm_source={flags.get('pm_source')} air_fresh={bool(flags.get('air_fresh'))} "
                      f"wx_fresh={bool(flags.get('wx_fresh'))}"])
    try:
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        with open(LOG_DIR / "verdict_log.txt", "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass


def fmt_dur(sec: float) -> str:
    sec = int(sec)
    d, rem = divmod(sec, 86400)
    h, rem = divmod(rem, 3600)
    m = rem // 60
    return " ".join(p for p in (f"{d}d" if d else "", f"{h}h" if h or d else "", f"{m}m") if p)


def log_gap(now: float, kind: str, start: float, why: str):
    """Mark a hole in the record in the same log as the verdicts, so a later analysis never mistakes it
    for a calm stretch: kind "offline" = the provider itself was not running (the machine was off, or the
    suite was closed); "unreachable" = it ran but could not read the device."""
    line = "\t".join([iso(now), "gap", "", "", "",
                      f"{kind} from {iso(start)} to {iso(now)} ({fmt_dur(now - start)}): {why}",
                      f"kind={kind} gap_sec={int(now - start)}"])
    try:
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        with open(LOG_DIR / "verdict_log.txt", "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass


INPUT_COLUMNS = ["epoch", "utc", "co2_ppm", "pm25_ugm3", "pm10_ugm3", "pm1_ugm3", "pm03_per_dl", "voc_index",
                 "nox_index", "temp_f", "humidity_pct", "dew_point_f", "complete",
                 "out_aqi", "out_pm25", "out_pm10", "out_owm_pm25", "out_owm_pm10", "pm_source", "air_fresh",
                 "out_temp_f", "out_rh", "wx_fresh", "pollen_tree", "pollen_grass", "pollen_weed", "pollen_mold",
                 "verdict", "class", "severity",
                 "out_wind_kt", "out_wind_gust_kt", "out_wind_dir", "out_wind_variable", "metar_obs", "out_wind_mph_owm",
                 "out_rain_min", "out_ts_min", "out_wind_deg"]


def ensure_header(path: Path):
    """Today's file may have been started by an older version with fewer columns. Rewrite it once under the
    current header (old rows padded with blanks) so appended rows line up; readers should use column names."""
    try:
        with open(path, newline="", encoding="utf-8") as f:
            first = next(csv.reader(f), None)
    except OSError:
        return
    if first is None or first == INPUT_COLUMNS:
        return
    with open(path, newline="", encoding="utf-8") as f:
        old_rows = list(csv.DictReader(f))
    tmp = path.with_name(path.name + ".tmp")
    with open(tmp, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(INPUT_COLUMNS)
        for r in old_rows:
            w.writerow([r.get(c, "") or "" for c in INPUT_COLUMNS])
    tmp.replace(path)


def log_inputs(now: float, reading: dict, carried: list, out: dict, flags: dict, pollen, adv, keep_days: int, wind=None):
    """One row per minute: every input the advisor saw, so a later replay can include outdoor data."""
    pm = reading["pm"]
    pol = pollen or {}
    row = [int(now), iso(now), reading["co2_ppm"], pm["pm25_ugm3"], pm["pm10_ugm3"], pm["pm1_ugm3"],
           pm["pm03_per_dl"], reading["voc_index"], reading["nox_index"], reading["temp_f"],
           reading["humidity_pct"], reading["dew_point_f"], int(not carried),
           out.get("aqi"), out.get("pm25"), out.get("pm10"), out.get("owm_pm25"), out.get("owm_pm10"),
           flags.get("pm_source"), int(bool(flags.get("air_fresh"))), out.get("temp_f"), out.get("rh"),
           int(bool(flags.get("wx_fresh"))), pol.get("tree"), pol.get("grass"), pol.get("weed"), pol.get("mold"),
           adv.verdict, adv.cls, adv.severity]
    wd = wind or {}
    row += [wd.get("wind_kt"), wd.get("wind_gust_kt"), wd.get("wind_dir"), wd.get("wind_variable"), wd.get("metar_obs"),
            wd.get("wind_mph_owm"), out.get("rain_min"), out.get("ts_min"), out.get("wind_deg")]
    path = LOG_DIR / f"inputs-{datetime.fromtimestamp(now).strftime('%Y%m%d')}.csv"
    try:
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        new = not path.exists()
        if not new:
            ensure_header(path)
        with open(path, "a", encoding="utf-8", newline="") as f:
            w = csv.writer(f)
            if new:
                w.writerow(INPUT_COLUMNS)
            w.writerow(["" if v is None else v for v in row])
        if new:
            cutoff = now - keep_days * 86400
            for old in LOG_DIR.glob("inputs-*.csv"):
                try:
                    if old.stat().st_mtime < cutoff:
                        old.unlink()
                except OSError:
                    pass
    except OSError:
        pass


# -----------------------------------------------------------------------
# main
# -----------------------------------------------------------------------

def main():
    global LOG_DIR
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    now = time.time()

    profile = load_toml(PROFILE_TOML)
    label = label_from(profile)
    if not profile:
        write_status(envelope("error", label, "missing profile toml", now))
        return 0
    if not profile.get("enabled", True):
        write_status(envelope("disabled", label, "profile disabled", now))
        return 0
    dev = profile.get("device", {}) or {}
    host = str(dev.get("host") or "").strip()
    if not host:
        write_status(envelope("error", label, "device host not configured ([device].host in profile toml)", now))
        return 0
    ttl = float(profile.get("cache_ttl_sec") or DEFAULT_TTL_SEC)
    timeout = float(dev.get("timeout_sec") or DEFAULT_TIMEOUT_SEC)
    carry_max_age = float(dev.get("carry_max_age_sec") or DEFAULT_CARRY_MAX_AGE_SEC)
    adv_cfg_toml = profile.get("advisor", {}) or {}
    LOG_DIR = resolve_log_dir(adv_cfg_toml)
    advisor_on = bool(adv_cfg_toml.get("enabled", True))
    shadow = bool(adv_cfg_toml.get("shadow", True))
    keep_days = int(adv_cfg_toml.get("log_keep_days") or DEFAULT_LOG_KEEP_DAYS)
    gap_log_sec = float(adv_cfg_toml.get("gap_log_sec") or DEFAULT_GAP_LOG_SEC)
    do_log_inputs = bool(adv_cfg_toml.get("log_inputs", True))
    outdoor_cfg = adv_cfg_toml.get("outdoor", {}) or {}
    pol_cfg = adv_cfg_toml.get("pollen", {}) or {}

    # One writer at a time (the launcher's run_locked already serializes per domain; this also covers
    # a second launcher or a manual run), then re-check freshness once the lock is held.
    lock = open(LOCK_FILE, "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return 0
    if STATUS_JSON.exists() and time.time() - STATUS_JSON.stat().st_mtime < ttl * 0.8:
        return 0   # comfortably fresh; same 80%-of-TTL margin as the other providers
    now = time.time()

    state = load_state()
    # Gap markers. last_run_t moves on every run, so a hole in it means the provider was not running at
    # all; last_ok_t moves only on a good reading, so a hole there with last_run_t current means the device
    # was down while the provider was up. One marker per hole, written by the first run after it.
    offline_gap = False
    last_run = state.get("last_run_t")
    if isinstance(last_run, (int, float)) and now - last_run > gap_log_sec:
        offline_gap = True
        log_gap(now, "offline", last_run, "the provider was not running (machine off or suite closed)")
    state["last_run_t"] = now
    prev = read_json(STATUS_JSON)
    prev = prev if isinstance(prev, dict) and prev.get("collector") == "airgradient" else None
    cfg = advisor_cfg(profile)
    adv = va.Advisor.from_state(state["advisor"], cfg) if state.get("advisor") else va.Advisor(cfg)

    try:
        payload = fetch_device(host, timeout)
    except DeviceError as exc:
        log(f"fetch failed: {exc}")
        # Hold: the advisor is not stepped, the last readings and verdict stay, generated_at does not move.
        doc = dict(prev) if prev else envelope("degraded", label, "", now)
        doc.update(state="degraded", label=label, attempted_at=iso(now), note=f"device unreachable: {exc}")
        doc["device"] = dict(doc.get("device") or {}, host=host)
        if advisor_on and state.get("advisor"):
            flags = (doc.get("ventilation") or {}).get("outdoor") or {}
            doc["ventilation"] = vent_block(adv, now, flags, shadow)
        write_status(doc)
        atomic_write(STATE_JSON, json.dumps(state, separators=(",", ":")) + "\n")   # keeps last_run_t current
        return 0

    last_ok = state.get("last_ok_t")
    if not offline_gap and isinstance(last_ok, (int, float)) and now - last_ok > gap_log_sec:
        log_gap(now, "unreachable", last_ok, "the provider was running but could not read the device")
    state["last_ok_t"] = now

    reading, carried, carry = build_reading(payload, state.get("carry"), now, carry_max_age)
    # state "partial": compensated fields (PM2.5, temperature, humidity) have had no value for longer
    # than the carry window, so the advisor is silently skipping the rules that need them. Not
    # reported until the provider has itself been running for a full carry window: right after
    # enabling there is nothing to carry yet, and a dropped response is normal.
    if state.get("first_t") is None:
        state["first_t"] = now
    unavailable = [name for name, val in (("pm25_ugm3", reading["pm"]["pm25_ugm3"]),
                                          ("temp_f", reading["temp_f"]),
                                          ("humidity_pct", reading["humidity_pct"])) if val is None]
    partial = bool(unavailable) and now - state["first_t"] >= carry_max_age
    out, flags = gather_outdoor(now, float(outdoor_cfg.get("air_max_age_sec") or DEFAULT_AIR_MAX_AGE_SEC),
                                float(outdoor_cfg.get("wx_max_age_sec") or DEFAULT_WX_MAX_AGE_SEC))
    if advisor_on:
        out.update(weather_hazard(now, float(adv_cfg_toml.get("storm_lookahead_min") or DEFAULT_STORM_LOOKAHEAD_MIN) * 60,
                                  flags["wx_fresh"]))
    pollen = None
    if advisor_on and pol_cfg.get("enabled", True):
        csv_path = Path(str(pol_cfg.get("csv") or "")) if pol_cfg.get("csv") else \
            SHARED_ASSETS / "data" / "pollen" / "pollen_mem_v2.csv"
        pollen = read_pollen(csv_path)

    vent = None
    if advisor_on:
        ind = {"co2": reading["co2_ppm"], "pm25": reading["pm"]["pm25_ugm3"], "voc": reading["voc_index"],
               "temp_f": reading["temp_f"], "rh": reading["humidity_pct"]}
        event = adv.step(int(now), ind, out, pollen)
        if event:
            log_verdict(now, event, adv, flags)
        vent = vent_block(adv, now, flags, shadow)
        lg = state.get("log") or {}
        if do_log_inputs and lg.get("last_minute") != int(now // 60):
            log_inputs(now, reading, carried, out, flags, pollen, adv, keep_days, gather_wind(now))
            lg["last_minute"] = int(now // 60)
        state["log"] = lg
        state["advisor"] = adv.to_state()
    state["carry"] = carry
    atomic_write(STATE_JSON, json.dumps(state, separators=(",", ":")) + "\n")

    doc = envelope("partial" if partial else "ok", label,
                   ("fields unavailable: " + ", ".join(unavailable)) if partial else "", now,
                   generated_at=iso(now), carried_fields=carried,
                   device={"host": host, "serialno": payload.get("serialno"), "model": payload.get("model"),
                           "firmware": payload.get("firmware")},
                   ventilation=vent, **reading)
    write_status(doc)
    return 0


if __name__ == "__main__":
    sys.exit(main())
