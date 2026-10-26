#!/usr/bin/env python3
# providers/air/fetch_air_extras.py
# Optional extras for the air domain, written beside current.json as extras.json:
#
#   forecast  AirNow's current forecast for the reporting area (today's forecast AQI per pollutant, the category,
#             the "action day" flag and the forecaster's discussion)
#   nws       the National Weather Service's active alerts for the site that bear on air quality (Air Quality Alert,
#             Dense Smoke Advisory, Air Stagnation Advisory, the dust products)
#
# Both are opt-in in the air profile and neither can make the air provider fail: fetch_air.sh runs this after its own
# work and ignores its exit status. Usage: fetch_air_extras.py <profile>
#
#   [airnow]  forecast = true               needs airnow enabled and its API key, as the provider already has
#   [nws]     alerts = true                 keyless; api.weather.gov wants a User-Agent that identifies the client
#             user_agent = "..."            default: gtex62-core's public repository URL
#
# Each source keeps its last good result when a fetch fails, marked with `fetched_at`, so consumers decide how old is
# too old. Test hooks: GTEX62_AIRNOW_BASE and GTEX62_NWS_BASE replace the service URLs.
import json
import os
import sys
import tempfile
import tomllib
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

HOME = Path(os.path.expanduser("~"))
CONFIG_ROOT = Path(os.getenv("GTEX62_CONFIG_DIR") or os.getenv("GTEX62_CONKY_CONFIG_DIR") or (HOME / ".config" / "gtex62-core"))
CACHE_ROOT = Path(os.getenv("GTEX62_CACHE_DIR") or os.getenv("GTEX62_CONKY_CACHE_DIR") or (HOME / ".cache" / "gtex62-core"))
AIRNOW_BASE = os.getenv("GTEX62_AIRNOW_BASE") or "https://www.airnowapi.org"
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


def main(argv):
    profile_id = argv[1] if len(argv) > 1 else "home"
    prof = load_toml(CONFIG_ROOT / "profiles" / "air" / f"{profile_id}.toml")
    site = load_toml(CONFIG_ROOT / "site.toml")
    out_dir = CACHE_ROOT / "shared" / "air" / profile_id
    out_path = out_dir / "extras.json"
    want_forecast = bool((prof.get("airnow") or {}).get("forecast")) and (prof.get("airnow") or {}).get("enabled", True) is not False
    want_nws = bool((prof.get("nws") or {}).get("alerts"))
    if not (want_forecast or want_nws):
        try:
            out_path.unlink()
        except OSError:
            pass
        return 0
    loc = {**((site.get("location") or {}).get("home") or {}), **(prof.get("location") or {})}
    try:
        lat, lon = float(loc["lat"]), float(loc["lon"])
    except (KeyError, TypeError, ValueError):
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
