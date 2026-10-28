#!/usr/bin/env python3
# providers/air/fetch_air_extras.py
# Optional extras for the air domain, written beside current.json as extras.json:
#
#   forecast  AirNow's current forecast for the reporting area (today's forecast AQI per pollutant, the category,
#             the "action day" flag and the forecaster's discussion)
#   nws       the National Weather Service's active alerts for the site that bear on air quality (Air Quality Alert,
#             Dense Smoke Advisory, Air Stagnation Advisory, the dust products)
#   trend     the one-hour and 24-hour change of the outdoor readings the ENV panel shows (air_trend.py)
#
# Both are opt-in in the air profile and neither can make the air provider fail: fetch_air.sh runs this after its own
# work and ignores its exit status. Usage: fetch_air_extras.py <profile>
#
#   [airnow]  forecast = true               needs airnow enabled and its API key, as the provider already has
#   [trend]   outdoor = true                one- and 24-hour change of the outdoor readings, from this provider's own history
#   [nws]     alerts = true                 keyless; api.weather.gov wants a User-Agent that identifies the client
#             user_agent = "..."            default: gtex62-core's public repository URL
#
# Each source keeps its last good result when a fetch fails, marked with `fetched_at`, so consumers decide how old is
# too old. Test hooks: GTEX62_AIRNOW_BASE and GTEX62_NWS_BASE replace the service URLs.
import json
import math
import os
import sys
import tempfile
import tomllib
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import air_backfill  # noqa: E402
import air_trend  # noqa: E402

HOME = Path(os.path.expanduser("~"))
CONFIG_ROOT = Path(os.getenv("GTEX62_CONFIG_DIR") or os.getenv("GTEX62_CONKY_CONFIG_DIR") or (HOME / ".config" / "gtex62-core"))
CACHE_ROOT = Path(os.getenv("GTEX62_CACHE_DIR") or os.getenv("GTEX62_CONKY_CACHE_DIR") or (HOME / ".cache" / "gtex62-core"))
AIRNOW_BASE = os.getenv("GTEX62_AIRNOW_BASE") or "https://www.airnowapi.org"
OWM_BASE = os.getenv("GTEX62_OWM_BASE") or "https://api.openweathermap.org"
NWS_BASE = os.getenv("GTEX62_NWS_BASE") or "https://api.weather.gov"
DEFAULT_UA = "gtex62-core (https://github.com/GTex62/gtex62-core)"
TIMEOUT = 10

# Events worth showing: the ones about the air, smoke or dust. Anything else NWS issues is ignored.
AQ_EVENTS = (
    "Air Quality Alert", "Air Stagnation Advisory", "Dense Smoke Advisory",
    "Dust Advisory", "Blowing Dust Advisory", "Blowing Dust Warning", "Dust Storm Warning",
)


def iso(t=None):
    return datetime.fromtimestamp(t if t is not None else datetime.now(timezone.utc).timestamp(), timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_toml(path: Path) -> dict:
    try:
        with open(path, "rb") as f:
            return tomllib.load(f)
    except (OSError, tomllib.TOMLDecodeError):
        return {}


def get_json(url: str, headers=None):
    req = urllib.request.Request(url, headers=headers or {})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        return json.loads(r.read().decode("utf-8", "replace"))


def forecast_rows(raw):
    """AirNow's /aq/forecast/current/ rows reduced to what the display needs, or None if the reply is not a row list."""
    if not isinstance(raw, list):
        return None
    rows = []
    for r in raw:
        if not isinstance(r, dict) or r.get("aqi") is None:
            continue
        try:
            aqi = int(r["aqi"])
        except (TypeError, ValueError):
            continue
        if aqi < 0:
            continue
        rows.append({
            "date_valid": r.get("dateValid"), "date_issue": r.get("dateIssue"), "pollutant": r.get("parameterName"),
            "aqi": aqi, "category": r.get("categoryName"), "category_number": r.get("categoryNumber"),
            "action_day": bool(r.get("actionDay")), "discussion": (r.get("discussion") or "").strip()[:400],
            "agency": r.get("forecastAgency"), "area": r.get("reportingArea"),
        })
    return rows


def nws_alerts(raw):
    """The active alerts of an api.weather.gov reply that concern air quality, or None if the reply is not an alert list."""
    if not isinstance(raw, dict) or not isinstance(raw.get("features"), list):
        return None
    out = []
    for f in raw["features"]:
        p = (f or {}).get("properties") or {}
        if p.get("event") not in AQ_EVENTS or p.get("status") not in (None, "Actual") or p.get("messageType") == "Cancel":
            continue
        out.append({
            "event": p["event"], "severity": p.get("severity"), "headline": (p.get("headline") or "")[:200],
            "effective": p.get("effective"), "expires": p.get("ends") or p.get("expires"),
        })
    return out


def fetch_backfill(prof, site, lat, lon, now_ts):
    """The last 27 hours of the outdoor readings as the air provider would have selected them (air_backfill.series): AirNow's hourly
    rows from aq/data over a longer window than the provider's own, and OpenWeather's history list. Either may be missing; [] when
    neither source answers or there are no coordinates."""
    if lat is None or lon is None:
        return []
    anw_cfg, owm_cfg = prof.get("airnow") or {}, prof.get("openweather") or {}
    creds = site.get("credentials") or {}
    anw_raw, owm_list = None, None
    akey = anw_cfg.get("api_key") or creds.get("airnow_api_key")
    if anw_cfg.get("enabled", True) is not False and akey:
        dist = float(anw_cfg.get("distance_miles", 25))
        dlat = dist / 69.0
        dlon = dist / (69.0 * math.cos(math.radians(lat))) if abs(lat) < 89 else 0.0
        q = urllib.parse.urlencode({
            "startDate": datetime.fromtimestamp(now_ts - 28 * 3600, timezone.utc).strftime("%Y-%m-%dT%H"),
            "endDate": datetime.fromtimestamp(now_ts + 3600, timezone.utc).strftime("%Y-%m-%dT%H"),
            "parameters": "OZONE,PM25,PM10,CO,NO2,SO2", "BBOX": f"{lon - dlon:.4f},{lat - dlat:.4f},{lon + dlon:.4f},{lat + dlat:.4f}",
            "dataType": "C", "format": "application/json", "verbose": 0, "monitorType": 2, "includerawconcentrations": 1, "API_KEY": akey})
        try:
            raw = get_json(f"{AIRNOW_BASE}/aq/data/?{q}")
            anw_raw = raw if isinstance(raw, list) else None
        except (urllib.error.URLError, OSError, ValueError):
            pass
    okey = owm_cfg.get("api_key") or creds.get("openweather_api_key")
    if owm_cfg.get("enabled", True) is not False and okey:
        q = urllib.parse.urlencode({"lat": f"{lat:.4f}", "lon": f"{lon:.4f}", "start": int(now_ts - 28 * 3600), "end": int(now_ts), "appid": okey})
        try:
            raw = get_json(f"{OWM_BASE}/data/2.5/air_pollution/history?{q}")
            owm_list = raw.get("list") if isinstance(raw, dict) else None
        except (urllib.error.URLError, OSError, ValueError):
            pass
    if anw_raw is None and owm_list is None:
        return []
    return air_backfill.series(anw_raw or [], owm_list or [], lat, lon, now_ts, max_age=float(anw_cfg.get("max_age_sec", 3600)))


def main(argv):
    profile_id = argv[1] if len(argv) > 1 else "home"
    prof = load_toml(CONFIG_ROOT / "profiles" / "air" / f"{profile_id}.toml")
    site = load_toml(CONFIG_ROOT / "site.toml")
    out_dir = CACHE_ROOT / "shared" / "air" / profile_id
    out_path = out_dir / "extras.json"
    want_forecast = bool((prof.get("airnow") or {}).get("forecast")) and (prof.get("airnow") or {}).get("enabled", True) is not False
    want_nws = bool((prof.get("nws") or {}).get("alerts"))
    want_trend = bool((prof.get("trend") or {}).get("outdoor"))
    if not (want_forecast or want_nws or want_trend):
        try:
            out_path.unlink()
        except OSError:
            pass
        return 0
    loc = {**((site.get("location") or {}).get("home") or {}), **(prof.get("location") or {})}
    try:
        lat, lon = float(loc["lat"]), float(loc["lon"])
    except (KeyError, TypeError, ValueError):
        lat = lon = None
    if lat is None and (want_forecast or want_nws):
        want_forecast = want_nws = False
        if not want_trend:
            return 0
    try:
        prev = json.loads(out_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        prev = {}
    doc = {"profile": profile_id, "generated_at": iso()}

    if want_forecast:
        key = (prof.get("airnow") or {}).get("api_key") or (site.get("credentials") or {}).get("airnow_api_key")
        dist = (prof.get("airnow") or {}).get("distance_miles", 25)
        old = prev.get("forecast") if isinstance(prev.get("forecast"), dict) else {}
        new = {"ok": False, "fetched_at": old.get("fetched_at"), "rows": old.get("rows", [])}
        if key:
            q = urllib.parse.urlencode({"format": "application/json", "latitude": f"{lat:.4f}", "longitude": f"{lon:.4f}",
                                        "distance": dist, "API_KEY": key})
            try:
                rows = forecast_rows(get_json(f"{AIRNOW_BASE}/aq/forecast/current/?{q}"))
                if rows is not None:
                    new = {"ok": True, "fetched_at": iso(), "rows": rows}
            except (urllib.error.URLError, OSError, ValueError):
                pass
        new["action_day"] = any(r.get("action_day") for r in new["rows"])
        new["max_aqi"] = max((r["aqi"] for r in new["rows"]), default=None)
        doc["forecast"] = new

    if want_nws:
        ua = (prof.get("nws") or {}).get("user_agent") or DEFAULT_UA
        old = prev.get("nws") if isinstance(prev.get("nws"), dict) else {}
        new = {"ok": False, "fetched_at": old.get("fetched_at"), "alerts": old.get("alerts", [])}
        try:
            alerts = nws_alerts(get_json(f"{NWS_BASE}/alerts/active?point={lat:.4f},{lon:.4f}",
                                         {"User-Agent": ua, "Accept": "application/geo+json"}))
            if alerts is not None:
                new = {"ok": True, "fetched_at": iso(), "alerts": alerts}
        except (urllib.error.URLError, OSError, ValueError):
            pass
        doc["nws"] = new

    if want_trend:
        state_path = CACHE_ROOT / "runtime" / "air" / profile_id / "trend_state.json"
        try:
            tstate = json.loads(state_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            tstate = {}
        try:
            cur = json.loads((out_dir / "current.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            cur = {}
        now_ts = datetime.now(timezone.utc).timestamp()
        # A start (or a long gap) leaves the history empty around one hour and 24 hours ago: seed it from the sources' own history, at
        # most once per 6 hours (30 minutes after a failed attempt).
        if not (air_trend.has_sample(tstate, now_ts - 86400, 1800) and air_trend.has_sample(tstate, now_ts - 3600, 1200)):
            last = tstate.get("backfill_at")
            if not isinstance(last, (int, float)) or now_ts - last >= (21600 if tstate.get("backfill_ok") else 1800):
                grid = fetch_backfill(prof, site, lat, lon, now_ts)
                tstate = air_trend.backfill(tstate, grid, now_ts)
                tstate["backfill_at"], tstate["backfill_ok"] = now_ts, bool(grid)
        tstate = air_trend.update(tstate, now_ts, (cur.get("selected") or {}) if isinstance(cur, dict) else {})
        state_path.parent.mkdir(parents=True, exist_ok=True)
        state_path.write_text(json.dumps(tstate, separators=(",", ":")) + "\n", encoding="utf-8")
        doc["trend"] = {"ok": True, "computed_at": iso(now_ts), "values": air_trend.compute(tstate, now_ts)}

    out_dir.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix="extras_", suffix=".tmp", dir=str(out_dir))
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(json.dumps(doc, separators=(",", ":")) + "\n")
    os.replace(tmp, out_path)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception as e:  # never let an optional extra break the caller
        print(f"fetch_air_extras: {type(e).__name__}: {e}", file=sys.stderr)
        sys.exit(0)
