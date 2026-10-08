#!/usr/bin/env python3
"""Regression tests for providers/air/fetch_air.sh's AirNow handling.

Run directly (this repo has no test runner):

    python3 tests/air/test_fetch_air.py

The real script runs against a temporary config/cache tree with freshly written raw files, so it
skips every network call and only does its merge step; nothing real is read or written. Each case
below traces back to something found on live data (2026-10-07 and 2026-10-08).
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

CORE = Path(__file__).resolve().parent.parent.parent
SCRIPT = CORE / "providers" / "air" / "fetch_air.sh"
LAT, LON = 35.111649, -89.755973
FAILURES = []


def check(label, condition, detail=""):
    print(f"[{'PASS' if condition else 'FAIL'}] {label}" + (f" - {detail}" if detail and not condition else ""))
    if not condition:
        FAILURES.append(label)


def hour_floor(t):
    return t - t % 3600


def obs_row(param, aqi, hour_ts, key="nowcastAQI"):
    """AirNow observation row for the UTC hour `hour_ts` (the script reads localTimeZone UTC as +0)."""
    d = time.gmtime(hour_ts)
    return {"parameterName": param, key: aqi, "dateObserved": time.strftime("%Y-%m-%d", d),
            "hourObserved": time.strftime("%H:00", d), "localTimeZone": "UTC", "reportingAreaName": "Memphis"}


def data_row(param, value, raw, hour_ts, lat, lon, unit="UG/M3"):
    return {"Latitude": lat, "Longitude": lon, "UTC": time.strftime("%Y-%m-%dT%H:%M", time.gmtime(hour_ts)),
            "Parameter": param, "Unit": unit, "Value": value, "RawConcentration": raw}


def run(obs=(), data=(), max_age=None, owm_pm25=13.2):
    d = Path(tempfile.mkdtemp(prefix="airtest_"))
    cfg, cache = d / "config", d / "cache"
    out = cache / "shared" / "air" / "home"
    (cfg / "profiles" / "air").mkdir(parents=True)
    out.mkdir(parents=True)
    extra = f"max_age_sec = {max_age}\n" if max_age is not None else ""
    (cfg / "profiles" / "air" / "home.toml").write_text(
        f'profile_id = "home"\nenabled = true\n[location]\nlat = {LAT}\nlon = {LON}\ntimezone = "UTC"\n'
        f'[cache]\nttl_sec = 900\n[openweather]\nenabled = true\napi_key = "x"\n'
        f'[airnow]\nenabled = true\napi_key = "x"\ndistance_miles = 25\nwindow_hours = 6\n{extra}')
    now = int(time.time())
    (out / "raw_openweather.json").write_text(json.dumps({"coord": {"lat": LAT, "lon": LON}, "list": [
        {"dt": now, "main": {"aqi": 2}, "components": {"pm2_5": owm_pm25, "pm10": 14.0, "o3": 50.0, "no2": 7.0,
                                                       "so2": 1.0, "co": 200.0, "nh3": 2.0}}]}))
    (out / "raw_airnow_data.json").write_text(json.dumps(list(data)))
    (out / "raw_airnow_observation.json").write_text(json.dumps(list(obs)))
    env = dict(os.environ, GTEX62_CONFIG_DIR=str(cfg), GTEX62_CACHE_DIR=str(cache),
               GTEX62_CONKY_CONFIG_DIR=str(cfg), GTEX62_CONKY_CACHE_DIR=str(cache))
    r = subprocess.run(["bash", str(SCRIPT), "home"], env=env, capture_output=True, text=True, timeout=60)
    cur = json.loads((out / "current.json").read_text()) if (out / "current.json").exists() else {}
    status = json.loads((out / "status.json").read_text()) if (out / "status.json").exists() else {}
    shutil.rmtree(d, ignore_errors=True)
    if r.returncode != 0:
        print(r.stderr[-300:])
    return cur, status


H = hour_floor(int(time.time()))
NEAR = (35.151588, -89.85022)      # about 6 miles from the site
FAR = (34.820633, -89.987782)      # about 24 miles

# ---------------------------------------------------------------------------
# Overall AQI: the highest pollutant sub-index among the newest rows
# ---------------------------------------------------------------------------
cur, st = run(obs=[obs_row("PM2.5", 63, H), obs_row("OZONE", 15, H)])
check("PM2.5 63 listed first, ozone 15 last: AQI is 63 (it used to take the last row, 15)", cur["airnow"]["aqi"] == 63, str(cur["airnow"]["aqi"]))
cur, _ = run(obs=[obs_row("OZONE", 15, H), obs_row("PM2.5", 63, H)])
check("same rows in the other order: still 63", cur["airnow"]["aqi"] == 63, str(cur["airnow"]["aqi"]))
cur, _ = run(obs=[obs_row("PM2.5", 63, H), obs_row("OZONE", 120, H)])
check("ozone worse than PM2.5: AQI is 120, so the hazard rule's AQI input can see it", cur["airnow"]["aqi"] == 120, str(cur["airnow"]["aqi"]))
cur, _ = run(obs=[obs_row("PM2.5", 90, H - 3600), obs_row("PM2.5", 40, H), obs_row("OZONE", 15, H)])
check("only the newest hour counts: an older, higher reading is ignored", cur["airnow"]["aqi"] == 40, str(cur["airnow"]["aqi"]))
check("aqi_ts is the newest observation hour", cur["airnow"]["aqi_ts"] == H, str(cur["airnow"]["aqi_ts"]))
cur, _ = run(obs=[obs_row("PM2.5", -999, H), obs_row("OZONE", 15, H)])
check("AirNow's -999 missing marker is ignored: AQI 15", cur["airnow"]["aqi"] == 15, str(cur["airnow"]["aqi"]))
cur, _ = run(obs=[obs_row("PM2.5", 55, H, key="AQI"), obs_row("OZONE", 15, H)])
check("the AQI key works as well as nowcastAQI", cur["airnow"]["aqi"] == 55, str(cur["airnow"]["aqi"]))
cur, _ = run(obs=[])
check("no observation rows: AQI null, no crash", cur["airnow"]["aqi"] is None, str(cur["airnow"]["aqi"]))

# ---------------------------------------------------------------------------
# Concentrations: -999 raw marker, nearest monitor, age ceiling
# ---------------------------------------------------------------------------
cur, _ = run(data=[data_row("PM2.5", 9.7, -999.0, H, *FAR), data_row("PM2.5", 6.7, -999.0, H, *NEAR)])
check("raw concentration -999 falls back to Value", cur["airnow"]["values"].get("pm2_5") == 6.7, str(cur["airnow"]["values"]))
check("...and the nearest monitor wins over a farther one reporting the same hour",
      cur["selected"]["pm2_5"] == 6.7, str(cur["selected"]))
cur, _ = run(data=[data_row("PM2.5", 12.0, 12.9, H - 3600, *NEAR), data_row("PM2.5", 5.0, 5.1, H, *FAR)], max_age=7200)
check("a nearer monitor with an older reading beats a farther one with a newer one (within max_age)",
      cur["airnow"]["values"].get("pm2_5") == 12.9, str(cur["airnow"]["values"]))
cur, _ = run(data=[data_row("PM2.5", 8.0, 8.1, H - 3600, *NEAR), data_row("PM2.5", 9.0, 9.2, H, *NEAR)])
check("per monitor the freshest reading is used", cur["airnow"]["values"].get("pm2_5") == 9.2, str(cur["airnow"]["values"]))
cur, _ = run(data=[data_row("PM2.5", 8.0, 8.1, int(time.time()) - 3 * 3600, *NEAR)])
check("older than the default max_age (3600 s): ignored, selected falls back to OpenWeather",
      "pm2_5" not in cur["airnow"]["values"] and cur["selected"]["pm2_5"] == 13.2, str(cur["airnow"]["values"]))
cur, _ = run(data=[data_row("PM2.5", 8.0, 8.1, int(time.time()) - 5400, *NEAR)], max_age=7200)
check("max_age_sec = 7200 keeps a 90-minute-old reading", cur["airnow"]["values"].get("pm2_5") == 8.1, str(cur["airnow"]["values"]))
cur, _ = run(data=[data_row("OZONE", 56.0, 67.0, H, *NEAR, unit="PPB")])
check("ppb gases are converted to ug/m3 (ozone 67 ppb)", abs(cur["airnow"]["values"].get("o3", 0) - 67.0 * 1.96) < 0.01, str(cur["airnow"]["values"]))
cur, st = run(obs=[obs_row("PM2.5", 63, H)], data=[data_row("PM2.5", 15.7, 17.4, H, *NEAR)])
check("state ok, and the panel inputs line up: AQI 63 beside PM2.5 17.4", st.get("state") == "ok" and cur["airnow"]["aqi"] == 63 and cur["selected"]["pm2_5"] == 17.4, f"{st} {cur['airnow']['aqi']} {cur['selected']['pm2_5']}")

print()
if FAILURES:
    print(f"{len(FAILURES)} FAILED: " + "; ".join(FAILURES))
    sys.exit(1)
print("all air-provider tests passed")
