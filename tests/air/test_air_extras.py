#!/usr/bin/env python3
"""Tests for providers/air/fetch_air_extras.py (AirNow forecast and NWS air-quality alerts, written to extras.json).

Run directly: python3 tests/air/test_air_extras.py. The real script runs against a temporary config/cache tree and a fake
AirNow/NWS server on localhost (GTEX62_AIRNOW_BASE / GTEX62_NWS_BASE), so nothing real is read, written or contacted.
"""
import http.server
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

CORE = Path(__file__).resolve().parent.parent.parent
SCRIPT = CORE / "providers" / "air" / "fetch_air_extras.py"
FAILURES = []


def check(label, condition, detail=""):
    print(f"[{'PASS' if condition else 'FAIL'}] {label}" + (f" - {detail}" if detail and not condition else ""))
    if not condition:
        FAILURES.append(label)


STATE = {"forecast": None, "nws": None, "forecast_status": 200, "nws_status": 200, "seen": []}


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        STATE["seen"].append({"path": self.path, "ua": self.headers.get("User-Agent")})
        which = "forecast" if self.path.startswith("/aq/forecast/current/") else "nws"
        status = STATE[which + "_status"]
        body = STATE[which]
        raw = body if isinstance(body, str) else json.dumps(body)
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(raw.encode())


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{server.server_address[1]}"

FORECAST = [
    {"dateIssue": "2026-10-23", "dateValid": "2026-10-26", "reportingArea": "Testville", "reportingAreaCode": "xx001", "stateCode": "XX",
     "parameterName": "PM2.5", "aqi": 112, "forecastAgency": "Test County Health", "categoryNumber": 3, "categoryName": "Unhealthy for Sensitive Groups",
     "actionDay": True, "discussion": "Stagnant air and smoke aloft. "},
    {"dateIssue": "2026-10-23", "dateValid": "2026-10-26", "reportingArea": "Testville", "parameterName": "OZONE", "aqi": 47,
     "forecastAgency": "Test County Health", "categoryNumber": 1, "categoryName": "Good", "actionDay": False, "discussion": ""},
    {"dateValid": "2026-10-26", "parameterName": "PM10", "aqi": -999},
]


def feature(event, status="Actual", msg="Alert", ends=None, expires="2026-10-27T06:00:00-05:00"):
    return {"properties": {"event": event, "status": status, "messageType": msg, "severity": "Moderate", "headline": f"{event} issued",
                           "effective": "2026-10-26T09:00:00-05:00", "expires": expires, "ends": ends}}


def run(profile_extra="", site=True, coords=True, key=True, existing=None, env_extra=None, nows=True, current=None, seed=None, want_state=False):
    d = Path(tempfile.mkdtemp(prefix="airx_"))
    cfg, cache = d / "config", d / "cache"
    (cfg / "profiles" / "air").mkdir(parents=True)
    out = cache / "shared" / "air" / "home"
    out.mkdir(parents=True)
    (cfg / "profiles" / "air" / "home.toml").write_text(
        'profile_id = "home"\nenabled = true\n[location]\n' + ('lat = 40.123456\nlon = -90.654321\n' if coords else '')
        + '[airnow]\nenabled = true\ndistance_miles = 25\n' + ('api_key = "TESTKEY"\n' if key else '') + profile_extra)
    if existing is not None:
        (out / "extras.json").write_text(json.dumps(existing))
    if current is not None:
        (out / "current.json").write_text(json.dumps(current))
    if seed is not None:
        sp = cache / "runtime" / "air" / "home"
        sp.mkdir(parents=True)
        (sp / "trend_state.json").write_text(json.dumps(seed))
    STATE["seen"] = []
    env = dict(os.environ, GTEX62_CONFIG_DIR=str(cfg), GTEX62_CACHE_DIR=str(cache), GTEX62_AIRNOW_BASE=BASE, GTEX62_NWS_BASE=BASE,
               GTEX62_CONKY_CONFIG_DIR=str(cfg), GTEX62_CONKY_CACHE_DIR=str(cache))
    env.update(env_extra or {})
    r = subprocess.run([sys.executable, str(SCRIPT), "home"], env=env, capture_output=True, text=True, timeout=60)
    doc = json.loads((out / "extras.json").read_text()) if (out / "extras.json").exists() else None
    tstate = None
    if (cache / "runtime" / "air" / "home" / "trend_state.json").exists():
        tstate = json.loads((cache / "runtime" / "air" / "home" / "trend_state.json").read_text())
    shutil.rmtree(d, ignore_errors=True)
    if want_state:
        return doc, r, tstate
    return doc, r


# ---- nothing enabled: no file, no network
doc, r = run()
check("neither option on: no extras.json, no request made, exit 0", doc is None and r.returncode == 0 and STATE["seen"] == [])
doc, r = run(existing={"forecast": {"rows": []}})
check("an old extras.json is removed once both options are off", doc is None)

# ---- AirNow forecast
STATE["forecast"] = FORECAST
doc, r = run("forecast = true\n")
f = (doc or {}).get("forecast") or {}
check("forecast on: ok, fetched_at set, junk rows (aqi -999) dropped", f.get("ok") is True and f.get("fetched_at", "").endswith("Z") and len(f.get("rows", [])) == 2, str(f)[:200])
check("forecast rows carry date, pollutant, AQI, category, action day, agency and the trimmed discussion",
      f["rows"][0]["pollutant"] == "PM2.5" and f["rows"][0]["aqi"] == 112 and f["rows"][0]["action_day"] is True
      and f["rows"][0]["category"].startswith("Unhealthy") and f["rows"][0]["agency"] == "Test County Health" and f["rows"][0]["discussion"] == "Stagnant air and smoke aloft.")
check("action_day and max_aqi are summarized", f["action_day"] is True and f["max_aqi"] == 112)
check("the request goes to /aq/forecast/current/ with 4-decimal coordinates, the distance and the key; no NWS call",
      len(STATE["seen"]) == 1 and "latitude=40.1235" in STATE["seen"][0]["path"] and "longitude=-90.6543" in STATE["seen"][0]["path"]
      and "distance=25" in STATE["seen"][0]["path"] and "API_KEY=TESTKEY" in STATE["seen"][0]["path"], str(STATE["seen"]))
check("no nws block when alerts are not enabled", "nws" not in doc)
doc, r = run("forecast = true\n", key=False)
check("forecast on but no AirNow key anywhere: ok false, no request", doc["forecast"]["ok"] is False and doc["forecast"]["rows"] == [] and STATE["seen"] == [])
STATE["forecast"] = "this is not json"
doc, r = run("forecast = true\n", existing={"forecast": {"ok": True, "fetched_at": "2026-10-26T08:00:00Z", "rows": [{"pollutant": "PM2.5", "aqi": 80, "action_day": False}]}})
f = doc["forecast"]
check("a reply that is not JSON keeps the last good rows, marked ok false with the old fetched_at",
      f["ok"] is False and f["fetched_at"] == "2026-10-26T08:00:00Z" and f["rows"][0]["aqi"] == 80, str(f))
STATE["forecast"], STATE["forecast_status"] = FORECAST, 500
doc, r = run("forecast = true\n")
check("an HTTP error is survived: ok false, exit 0", doc["forecast"]["ok"] is False and r.returncode == 0)
STATE["forecast_status"] = 200
STATE["forecast"] = {"WebServiceError": [{"Message": "retired"}]}
doc, r = run("forecast = true\n")
check("AirNow's error object (a dict, not a row list) is not mistaken for data", doc["forecast"]["ok"] is False and doc["forecast"]["rows"] == [])

# ---- NWS alerts
STATE["nws"] = {"features": [
    feature("Air Quality Alert", ends="2026-10-27T00:00:00-05:00"), feature("Heat Advisory"), feature("Air Stagnation Advisory"),
    feature("Dense Smoke Advisory", status="Test"), feature("Dust Storm Warning", msg="Cancel"),
]}
doc, r = run("[nws]\nalerts = true\n")
n = (doc or {}).get("nws") or {}
check("alerts on: ok, only air-quality events kept (Heat Advisory, a Test product and a Cancel are dropped)",
      n.get("ok") is True and [a["event"] for a in n["alerts"]] == ["Air Quality Alert", "Air Stagnation Advisory"], str(n))
check("alert entries: severity, headline, effective, and expiry from `ends` when there is one",
      n["alerts"][0]["expires"] == "2026-10-27T00:00:00-05:00" and n["alerts"][1]["expires"] == "2026-10-27T06:00:00-05:00" and n["alerts"][0]["severity"] == "Moderate")
req = STATE["seen"][0]
check("the NWS request uses the point with 4-decimal coordinates and the default User-Agent that names gtex62-core",
      "point=40.1235,-90.6543" in req["path"] and req["ua"] == "gtex62-core (https://github.com/GTex62/gtex62-core)", str(req))
doc, r = run('[nws]\nalerts = true\nuser_agent = "my-agent (https://example.org)"\n')
check("a configured user_agent is sent instead", STATE["seen"][0]["ua"] == "my-agent (https://example.org)")
STATE["nws"] = {"features": []}
doc, r = run("[nws]\nalerts = true\n", existing={"nws": {"ok": True, "alerts": [{"event": "Air Quality Alert"}]}})
check("an empty alert list is a real answer: ok true, alerts cleared", doc["nws"]["ok"] is True and doc["nws"]["alerts"] == [])
STATE["nws"] = "<html>not json</html>"
doc, r = run("[nws]\nalerts = true\n", existing={"nws": {"ok": True, "fetched_at": "2026-10-26T08:00:00Z", "alerts": [{"event": "Air Quality Alert"}]}})
check("a failed NWS fetch keeps the last alerts with ok false and the old fetched_at (the consumer decides how stale is too stale)",
      doc["nws"]["ok"] is False and doc["nws"]["fetched_at"] == "2026-10-26T08:00:00Z" and doc["nws"]["alerts"][0]["event"] == "Air Quality Alert")
STATE["nws"] = {"detail": "an error object", "status": 301}
doc, r = run("[nws]\nalerts = true\n")
check("an NWS problem object is not mistaken for an empty alert list", doc["nws"]["ok"] is False)

# ---- both, and missing coordinates
STATE["forecast"], STATE["nws"] = FORECAST, {"features": [feature("Dense Smoke Advisory")]}
doc, r = run("forecast = true\n[nws]\nalerts = true\n")
check("both on: one file with both blocks", doc["forecast"]["ok"] and doc["nws"]["ok"] and doc["nws"]["alerts"][0]["event"] == "Dense Smoke Advisory")
doc, r = run("[nws]\nalerts = true\n", coords=False)
check("no coordinates anywhere: nothing written, no request, exit 0", doc is None and STATE["seen"] == [] and r.returncode == 0)
doc, r = run("[nws]\nalerts = true\n", env_extra={"GTEX62_NWS_BASE": "http://127.0.0.1:9"})
check("an unreachable server is survived", doc["nws"]["ok"] is False and r.returncode == 0)

# ---- outdoor trend (own history of the air provider's `selected` readings)
import time as _time
now_ = _time.time()
SEL = {"selected": {"pm2_5": 12.0, "o3": 60.0, "pm10": 14.0, "no2": 4.0, "so2": 1.0, "co": 150.0, "nh3": 0.5, "no": 0.1}}
seed = {"samples": {"pm2_5": [[now_ - 3600, 8.0], [now_ - 3500, 8.0], [now_ - 86400, 6.0]], "o3": [[now_ - 3600, 60.0]]}}
doc, r, ts = run("[trend]\noutdoor = true\n", current=SEL, seed=seed, want_state=True)
t = (doc or {}).get("trend") or {}
check("[trend] outdoor = true alone writes extras.json with a trend block and makes no network request",
      t.get("ok") is True and t.get("computed_at", "").endswith("Z") and STATE["seen"] == [] and "forecast" not in doc and "nws" not in doc, str(doc)[:200])
check("PM2.5 8 an hour ago, 12 now: +50% over the hour; 6 a day ago: +100% over 24 hours", t["values"]["pm2_5"] == {"h1_pct": 50, "h24_pct": 100}, str(t["values"]["pm2_5"]))
check("ozone unchanged: 0% over the hour, None over 24 hours (no sample a day ago); a metric with no history is None",
      t["values"]["o3"] == {"h1_pct": 0, "h24_pct": None} and t["values"]["no2"] == {"h1_pct": None, "h24_pct": None})
check("the history is kept in the provider's runtime state and gains this reading", ts and any(abs(x[0] - now_) < 60 for x in ts["samples"]["pm2_5"]) and len(ts["samples"]["pm2_5"]) == 4, str(ts)[:200])
doc, r = run("[trend]\noutdoor = true\n", coords=False, current=SEL)
check("the trend needs no coordinates", (doc or {}).get("trend", {}).get("ok") is True)
doc, r = run("[trend]\noutdoor = true\n")
check("no current.json yet (a fresh install): a trend block with every value None, no error", doc["trend"]["ok"] is True and all(v == {"h1_pct": None, "h24_pct": None} for v in doc["trend"]["values"].values()) and r.returncode == 0)
STATE["forecast"] = FORECAST
doc, r = run("forecast = true\n[trend]\noutdoor = true\n", current=SEL)
check("with the forecast on as well: one file with both blocks", doc["forecast"]["ok"] and doc["trend"]["ok"])

server.shutdown()
print()
if FAILURES:
    print(f"{len(FAILURES)} FAILED: " + "; ".join(FAILURES))
    sys.exit(1)
print("all air-extras tests passed")
