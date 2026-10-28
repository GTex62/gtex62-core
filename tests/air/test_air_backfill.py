#!/usr/bin/env python3
"""Tests for providers/air/air_backfill.py (rebuilding the air provider's `selected` series from AirNow's hourly rows and OpenWeather's
history). Pure functions. Run directly: python3 tests/air/test_air_backfill.py. Every rule here mirrors a rule of fetch_air.sh's jq program.
"""
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "providers" / "air"))
import air_backfill as ab  # noqa: E402

FAILURES = []


def check(label, condition, detail=""):
    print(f"[{'PASS' if condition else 'FAIL'}] {label}" + (f" - {detail}" if detail and not condition else ""))
    if not condition:
        FAILURES.append(label)


LAT, LON = 40.0, -90.0
NEAR, FAR = (40.04, -89.9), (39.7, -90.2)
T = datetime(2026, 10, 28, 12, 0, tzinfo=timezone.utc).timestamp()


def row(param, value, hour, mon=NEAR, raw=None, unit="UG/M3"):
    ts = datetime.fromtimestamp(T + hour * 3600, timezone.utc).strftime("%Y-%m-%dT%H:%M")
    return {"Latitude": mon[0], "Longitude": mon[1], "Parameter": param, "UTC": ts, "Value": value,
            "RawConcentration": value if raw is None else raw, "Unit": unit}


rows = ab.airnow_rows([row("PM2.5", 9.0, 0), row("PM25", 7.0, 0, FAR), row("OZONE", 40.0, 0, unit="PPB"), row("CO", 0.3, 0, unit="PPM"),
                       row("SO2", 3.0, 0, unit="PPB"), row("NO2", 10.0, 0, unit="PPB"), row("PM10", 0.012, 0, unit="MG/M3"),
                       row("PM2.5", 5.0, -1, raw=-999.0), row("BOGUS", 1.0, 0), row("PM2.5", None, 0), row("PM2.5", -4.0, 0, raw=-4.0)], LAT, LON)
by = {(k, round(v, 3)) for k, v, _, _ in rows}
check("unit conversions: ozone 40 ppb = 78.4, CO 0.3 ppm = 343.5, SO2 3 ppb = 7.86, NO2 10 ppb = 18.8, PM10 0.012 mg/m3 = 12",
      ("o3", 78.4) in by and ("co", 343.5) in by and ("so2", 7.86) in by and ("no2", 18.8) in by and ("pm10", 12.0) in by, str(by))
check("a raw concentration of -999 (not yet available) falls back to Value; unknown parameters, null values and negative values are dropped",
      ("pm2_5", 5.0) in by and not any(k == "bogus" for k, _ in by) and sum(1 for k, v in by if k == "pm2_5") == 3, str(by))

now_ = T
a = ab.airnow_at(rows, now_, 3600)
check("two monitors report PM2.5: the nearer one wins (9.0, not the far monitor's 7.0)", a["pm2_5"] == 9.0, str(a))
check("a reading older than max_age is not used: the hour-old -999 row is outside 0..max_age only when max_age is short",
      ab.airnow_at(rows, now_ + 3 * 3600, 3600) == {} and ab.airnow_at(rows, now_ + 3500, 3600).get("pm2_5") == 9.0)
check("readings from after the time asked (age below 0) are ignored", ab.airnow_at(rows, now_ - 7200, 3600) == {})
far_only = ab.airnow_rows([row("PM2.5", 7.0, 0, FAR), row("PM2.5", 4.0, -1, FAR), row("PM2.5", 99.0, 0, (None, None))], LAT, LON)
check("per monitor the freshest reading, and a row with no coordinates ranks last", ab.airnow_at(far_only, now_ + 600, 7200)["pm2_5"] == 7.0)
fresh_far = ab.airnow_rows([row("PM2.5", 6.0, -1, NEAR), row("PM2.5", 8.0, 0, FAR)], LAT, LON)
check("a nearer monitor with an older reading beats a farther one with a newer one, within max_age", ab.airnow_at(fresh_far, now_ + 600, 7200)["pm2_5"] == 6.0)
check("...but not once its reading is too old: then the farther, fresher monitor is used", ab.airnow_at(fresh_far, now_ + 700, 4000)["pm2_5"] == 8.0)

owm = [{"dt": T - 7200, "components": {"pm2_5": 20.0, "nh3": 1.5, "co": 200.0, "no2": 6.0}}, {"dt": T, "components": {"pm2_5": 22.0, "nh3": 1.2, "co": 210.0, "no2": 7.0}}]
check("OpenWeather at a time: the newest entry at or before it", ab.owm_at(owm, T + 100)["pm2_5"] == 22.0 and ab.owm_at(owm, T - 100)["pm2_5"] == 20.0 and ab.owm_at(owm, T - 9000) == {})

sr = ab.series([row("PM2.5", 9.0, -2), row("PM2.5", 12.0, -1), row("PM2.5", 15.0, 0)], owm, LAT, LON, T + 3 * 3600, max_age=3600, hours=4)
at = lambda t: dict(sr)[t]
check("the series covers the grid up to one step before now, every 15 minutes", sr[0][0] == T - 3600 and sr[-1][0] < T + 3 * 3600 and len(sr) > 10, str((len(sr), sr[0][0] - T)))
check("AirNow overlays OpenWeather per pollutant; pollutants AirNow lacks (NH3, CO, NO2) come from OpenWeather",
      at(T + 900)["pm2_5"] == 15.0 and at(T + 900)["nh3"] == 1.2 and at(T + 900)["co"] == 210.0, str(at(T + 900)))
check("when the AirNow reading is too old OpenWeather's value shows through again (hour 2 later: only OpenWeather)",
      "pm2_5" in at(T + 2 * 3600 + 2700) and at(T + 2 * 3600 + 2700)["pm2_5"] == 22.0)
check("no AirNow at all (None) and OpenWeather alone: still a series", len(ab.series([], owm, LAT, LON, T + 3600, hours=2)) > 3)
check("junk inputs give an empty series and never raise", ab.series(None, None, LAT, LON, T) == [] and ab.series("x", {"a": 1}, LAT, LON, T) == [])

print()
if FAILURES:
    print(f"{len(FAILURES)} FAILED: " + "; ".join(FAILURES))
    sys.exit(1)
print("all air-backfill tests passed")
