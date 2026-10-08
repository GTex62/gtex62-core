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
# Usage: fetch_airgradient.py <profile> [<air_profile> [<weather_profile>]]
import csv
import fcntl
import json
import math
import os
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

PROFILE_TOML = CONFIG_ROOT / "profiles" / "airgradient" / f"{PROFILE_ID}.toml"
OUT_DIR = CACHE_ROOT / "shared" / "airgradient" / PROFILE_ID
STATUS_JSON = OUT_DIR / "status.json"
FETCH_LOG = OUT_DIR / "fetch.log"
TMP_DIR = CACHE_ROOT / "tmp"
# Engine-private state and the shadow-week logs: runtime/, not shared/ (suites never read these,
# and the input log cannot be regenerated, so it does not belong in a deletable cache).
STATE_DIR = CACHE_ROOT / "runtime" / "airgradient" / PROFILE_ID
STATE_JSON = STATE_DIR / "advisor_state.json"
LOCK_FILE = STATE_DIR / "lock"
VERDICT_LOG = STATE_DIR / "verdict_log.txt"

DEFAULT_TTL_SEC = 30
DEFAULT_TIMEOUT_SEC = 5
DEFAULT_CARRY_MAX_AGE_SEC = 600
DEFAULT_AIR_MAX_AGE_SEC = 7200
DEFAULT_WX_MAX_AGE_SEC = 1800
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
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        with open(VERDICT_LOG, "a", encoding="utf-8") as f:
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
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        with open(VERDICT_LOG, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass


INPUT_COLUMNS = ["epoch", "utc", "co2_ppm", "pm25_ugm3", "pm10_ugm3", "pm1_ugm3", "pm03_per_dl", "voc_index",
                 "nox_index", "temp_f", "humidity_pct", "dew_point_f", "complete",
                 "out_aqi", "out_pm25", "out_pm10", "out_owm_pm25", "out_owm_pm10", "pm_source", "air_fresh",
                 "out_temp_f", "out_rh", "wx_fresh", "pollen_tree", "pollen_grass", "pollen_weed", "pollen_mold",
                 "verdict", "class", "severity"]


def log_inputs(now: float, reading: dict, carried: list, out: dict, flags: dict, pollen, adv, keep_days: int):
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
    path = STATE_DIR / f"inputs-{datetime.fromtimestamp(now).strftime('%Y%m%d')}.csv"
    try:
        new = not path.exists()
        with open(path, "a", encoding="utf-8", newline="") as f:
            w = csv.writer(f)
            if new:
                w.writerow(INPUT_COLUMNS)
            w.writerow(["" if v is None else v for v in row])
        if new:
            cutoff = now - keep_days * 86400
            for old in STATE_DIR.glob("inputs-*.csv"):
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
            log_inputs(now, reading, carried, out, flags, pollen, adv, keep_days)
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
