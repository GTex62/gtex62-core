#!/usr/bin/env python3
"""Tests for providers/air/air_trend.py (the outdoor one-hour and 24-hour change). Pure functions, no I/O.
Run directly: python3 tests/air/test_air_trend.py
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "providers" / "air"))
import air_trend as at  # noqa: E402

FAILURES = []


def check(label, condition, detail=""):
    print(f"[{'PASS' if condition else 'FAIL'}] {label}" + (f" - {detail}" if detail and not condition else ""))
    if not condition:
        FAILURES.append(label)


T0 = 1_792_000_000
BASE = {"pm2_5": 10.0, "o3": 60.0, "pm10": 12.0, "no2": 5.0, "so2": 2.0, "co": 200.0, "nh3": 1.0}


def run(fn, start, end, step=900, st=None):
    st = st if st is not None else {}
    t = start
    while t <= end:
        st = at.update(st, t, fn(t))
        t += step
    return st


st = run(lambda t: BASE, T0, T0 + 1800)
c = at.compute(st, T0 + 1800)
check("under an hour of data: every one-hour and 24-hour change is None", all(v["h1_pct"] is None and v["h24_pct"] is None for v in c.values()), str(c["pm2_5"]))
st = run(lambda t: BASE, T0, T0 + 3600 + 900)
c = at.compute(st, T0 + 3600 + 900)
check("steady for over an hour: 0% over the hour, 24-hour still None", all(v["h1_pct"] == 0 and v["h24_pct"] is None for v in c.values()), str(c))

st = run(lambda t: dict(BASE, pm2_5=8.0 if t < T0 + 3600 else 12.0, o3=60.0 if t < T0 + 3600 else 61.0), T0, T0 + 3600 + 900)
c = at.compute(st, T0 + 3600 + 900)
check("PM2.5 8 an hour ago and 12 now: +50%", c["pm2_5"]["h1_pct"] == 50, str(c["pm2_5"]))
check("ozone 60 to 61 is under its floor of 3: 0%", c["o3"]["h1_pct"] == 0)

st = run(lambda t: dict(BASE, pm2_5=10.0 if t < T0 + 86400 else 5.0), T0, T0 + 86400 + 4500)
c = at.compute(st, T0 + 86400 + 4500)
check("24 hours: PM2.5 10 yesterday at this time, 5 now: -50%, and the one-hour change is 0%", c["pm2_5"]["h24_pct"] == -50 and c["pm2_5"]["h1_pct"] == 0, str(c["pm2_5"]))

st = run(lambda t: BASE, T0, T0 + 1200)
st = run(lambda t: BASE, T0 + 3600 + 3000, T0 + 3600 + 3900, st=st)
c = at.compute(st, T0 + 3600 + 3900)
check("no sample in the window an hour ago (the provider was off): None, never a guess", c["pm2_5"]["h1_pct"] is None, str(c["pm2_5"]))

st = run(lambda t: dict(BASE, nh3=0.0 if t < T0 + 3600 else 3.0), T0, T0 + 3600 + 900)
check("a zero baseline with a real change cannot be a percent: None", at.compute(st, T0 + 3600 + 900)["nh3"]["h1_pct"] is None)
st = run(lambda t: dict(BASE, co=100.0 if t < T0 + 3600 else 100000.0), T0, T0 + 3600 + 900)
check("a huge rise is capped at +999%", at.compute(st, T0 + 3600 + 900)["co"]["h1_pct"] == 999)
st = run(lambda t: dict(BASE, so2=None), T0, T0 + 3600 + 900)
c = at.compute(st, T0 + 3600 + 900)
check("a metric that is never reported stays None and never raises", c["so2"] == {"h1_pct": None, "h24_pct": None} and c["pm2_5"]["h1_pct"] == 0)
st = run(lambda t: BASE, T0, T0 + 50 * 3600, step=1800)
check("samples older than 27 hours are dropped (state stays small)", max(len(v) for v in st["samples"].values()) <= 27 * 2 + 2, str(max(len(v) for v in st["samples"].values())))
check("junk state and values never raise", at.compute(None, T0) is not None and at.update("x", T0, {"pm2_5": "abc"}) is not None)

# ---- the seven-day HI and LO
st = at.update({}, T0, dict(BASE, pm2_5=12.0))
st = at.update(st, T0 + 900, dict(BASE, pm2_5=30.5))
st = at.update(st, T0 + 1800, dict(BASE, pm2_5=2.25))
ex, span = at.extremes(st, T0 + 1900)
check("HI and LO are the highest and lowest readings, not medians", ex["pm2_5"] == {"hi": 30.5, "lo": 2.25}, str(ex["pm2_5"]))
check("a metric never seen is None and a young history is an hour or two", at.extremes({}, T0)[0]["o3"] == {"hi": None, "lo": None} and span in (1, 2) and at.extremes({}, T0)[1] == 0)
st = at.update(st, T0 + 8 * 86400, dict(BASE, pm2_5=9.0))
ex, span = at.extremes(st, T0 + 8 * 86400 + 60)
check("eight days later the old extremes have rolled out of the window and out of the state", ex["pm2_5"] == {"hi": 9.0, "lo": 9.0} and sum(len(b) for b in st["ext"].values()) <= 7, str(ex["pm2_5"]))
grid = [(T0 - 3 * 86400 + 3600 * k, dict(BASE, pm2_5=40.0 if k == 5 else 3.0)) for k in range(0, 60)]
st = at.backfill_extremes({}, grid, T0)
st = at.backfill_extremes(st, grid, T0)
ex, span = at.extremes(st, T0)
check("a backfilled hourly grid gives the week's HI and LO, a repeat is harmless", ex["pm2_5"] == {"hi": 40.0, "lo": 3.0}, str(ex["pm2_5"]))
check("coverage counts the distinct hours with data (60 hourly points in 60 distinct hours)", at.coverage_hours(st, T0) == 60, str(at.coverage_hours(st, T0)))
check("rows older than seven days or junk are ignored and never raise",
      at.coverage_hours(at.backfill_extremes({}, [(T0 - 9 * 86400, BASE), (1, None), ("x", {}), (T0, {"pm2_5": "abc"})], T0), T0) == 0 and at.extremes("x", T0)[1] == 0)

print()
if FAILURES:
    print(f"{len(FAILURES)} FAILED: " + "; ".join(FAILURES))
    sys.exit(1)
print("all air-trend tests passed")
