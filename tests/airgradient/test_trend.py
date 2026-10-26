#!/usr/bin/env python3
"""Tests for providers/airgradient/trend.py (the one-hour and 24-hour change behind the display's trend columns).

Run directly: python3 tests/airgradient/test_trend.py. Pure functions, no I/O.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "providers" / "airgradient"))
import trend as tr  # noqa: E402

FAILURES = []


def check(label, condition, detail=""):
    print(f"[{'PASS' if condition else 'FAIL'}] {label}" + (f" - {detail}" if detail and not condition else ""))
    if not condition:
        FAILURES.append(label)


T0 = 1_792_000_200          # a multiple of 600
ONE = {"co2_ppm": 500, "voc_index": 100, "nox_index": 1, "pm1_ugm3": 4.0, "pm25_ugm3": 5.0, "pm10_ugm3": 6.0, "pm03_per_dl": 1000}


def run(start, end, fn, step=30, st=None):
    """Feed one reading every `step` seconds from start to end; fn(t) gives the metric -> value dict."""
    st = st if st is not None else {}
    t = start
    while t <= end:
        st = tr.update(st, t, fn(t))
        t += step
    return st


# ---- steady values: 0% everywhere once an hour has passed, None before
st = run(T0, T0 + 1800, lambda t: ONE)
c = tr.compute(st, T0 + 1800)
check("before an hour of data: the 1-hour change is None for every metric, the 24-hour change too",
      all(v["h1_pct"] is None and v["h24_pct"] is None for v in c.values()), str(c["co2_ppm"]))
st = run(T0, T0 + 3600 + 900, lambda t: ONE)
c = tr.compute(st, T0 + 3600 + 900)
check("after an hour of steady readings: 0% over the hour, 24-hour still None", all(v["h1_pct"] == 0 and v["h24_pct"] is None for v in c.values()), str(c))

# ---- a real change over the hour: CO2 400 an hour ago, 500 now = +25%
def ramp(t):
    d = dict(ONE)
    d["co2_ppm"] = 400 if t < T0 + 3600 else 500
    d["pm25_ugm3"] = 5.0 if t < T0 + 3600 else 4.0
    d["voc_index"] = 100 if t < T0 + 3600 else 102
    return d
st = run(T0, T0 + 3600 + 900, ramp)
c = tr.compute(st, T0 + 3600 + 900)
check("CO2 400 an hour ago and 500 now: +25%", c["co2_ppm"]["h1_pct"] == 25, str(c["co2_ppm"]))
check("PM2.5 5.0 then 4.0 now: -20%", c["pm25_ugm3"]["h1_pct"] == -20, str(c["pm25_ugm3"]))
check("VOC 100 then 102 is under the floor of 5: 0%, not +2%", c["voc_index"]["h1_pct"] == 0, str(c["voc_index"]))

# ---- 24 hours: yesterday's value is compared when the provider was running then
def day(t):
    d = dict(ONE)
    d["pm03_per_dl"] = 800 if t < T0 + 3600 else 1200
    return d
st = run(T0, T0 + 3600, day, step=60)                                   # yesterday, one hour
st = run(T0 + 86400, T0 + 86400 + 900, lambda t: dict(ONE, pm03_per_dl=1200), step=30, st=st)   # a day later, 15 minutes
c = tr.compute(st, T0 + 86400 + 900)
check("24-hour change against the same time yesterday (800 then, 1200 now): +50%", c["pm03_per_dl"]["h24_pct"] == 50, str(c["pm03_per_dl"]))
check("...while the 1-hour change is None (nothing was recorded an hour ago)", c["pm03_per_dl"]["h1_pct"] is None)

# ---- thin comparison bins are not trusted
st = {}
st = tr.update(st, T0, ONE); st = tr.update(st, T0 + 30, ONE)           # two samples in yesterday's bin
st = run(T0 + 86400 - 600, T0 + 86400 + 900, lambda t: ONE, st=st)
c = tr.compute(st, T0 + 86400 + 900)
check("a comparison bin with fewer than 4 samples is ignored", c["co2_ppm"]["h24_pct"] is None, str(c["co2_ppm"]))

# ---- zero baseline, caps, missing values
st = run(T0, T0 + 3600 + 900, lambda t: dict(ONE, nox_index=0 if t < T0 + 3600 else 3))
c = tr.compute(st, T0 + 3600 + 900)
check("a zero baseline with a real change cannot give a percent: None", c["nox_index"]["h1_pct"] is None, str(c["nox_index"]))
st = run(T0, T0 + 3600 + 900, lambda t: dict(ONE, pm03_per_dl=100 if t < T0 + 3600 else 90000))
c = tr.compute(st, T0 + 3600 + 900)
check("a huge rise is capped at +999%", c["pm03_per_dl"]["h1_pct"] == 999, str(c["pm03_per_dl"]))
st = run(T0, T0 + 3600 + 900, lambda t: dict(ONE, pm25_ugm3=None))
c = tr.compute(st, T0 + 3600 + 900)
check("a metric that is always missing stays None and never raises", c["pm25_ugm3"] == {"h1_pct": None, "h24_pct": None} and c["co2_ppm"]["h1_pct"] == 0)

# ---- noisy single readings do not move the median
import random
random.seed(7)
st = run(T0, T0 + 3600 + 900, lambda t: dict(ONE, pm03_per_dl=1000 + (4000 if random.random() < 0.05 else 0)))
c = tr.compute(st, T0 + 3600 + 900)
check("a few spikes in an otherwise steady series do not change the medians: 0%", c["pm03_per_dl"]["h1_pct"] == 0, str(c["pm03_per_dl"]))

# ---- an outage in between leaves a hole, not a guess
st = run(T0, T0 + 1200, lambda t: ONE)
st = run(T0 + 3600 + 600, T0 + 3600 + 1500, lambda t: ONE, st=st)       # nothing between +1200 and +4200
c = tr.compute(st, T0 + 3600 + 1500)
check("no readings an hour ago (an outage): None", c["co2_ppm"]["h1_pct"] is None, str(c["co2_ppm"]))

# ---- bins older than the retention are dropped; state stays small
st = run(T0, T0 + 50 * 3600, lambda t: ONE, step=300)
n = sum(len(b) for b in st["bins"].values())
check("state keeps about 40 hours of bins, not everything (7 metrics x about 240 bins)", n <= 7 * 242, str(n))
check("garbage state and values never raise", tr.compute(None, T0) is not None and tr.update("x", T0, {"co2_ppm": "abc"}) is not None)

# ---- backfill from past readings
rows = [(T0 + 30 * k, ONE) for k in range(0, 240)]                       # two hours of 30 s readings, an hour ago and more
st = tr.backfill({}, rows, T0 + 50 * 3600)
check("backfill ignores readings from more than 40 hours ago", all(not b for b in st["bins"].values()))
st = tr.backfill({}, rows, T0 + 3 * 3600)
c_now = T0 + 3 * 3600
st = run(c_now, c_now + 900, lambda t: ONE, st=st)
c = tr.compute(st, c_now + 900)
check("backfill gives the one-hour comparison at once (no hour of waiting)", c["co2_ppm"]["h1_pct"] is None or c["co2_ppm"]["h1_pct"] == 0, str(c["co2_ppm"]))
rows2 = [(T0 + 30 * k, dict(ONE, co2_ppm=400)) for k in range(0, 360)]    # T0 .. T0 + 3 h at 400
st = tr.backfill({}, rows2, T0 + 3 * 3600 + 600)
st = run(T0 + 3 * 3600 + 600, T0 + 3 * 3600 + 1500, lambda t: dict(ONE, co2_ppm=500), st=st)
c = tr.compute(st, T0 + 3 * 3600 + 1500)
check("backfilled history: CO2 400 an hour ago and 500 now is +25% straight away", c["co2_ppm"]["h1_pct"] == 25, str(c["co2_ppm"]))
st2 = tr.backfill(st, [(T0 + 30 * k, dict(ONE, co2_ppm=999)) for k in range(0, 120)], T0 + 3 * 3600 + 1500)
check("backfill never overwrites a bin that already exists", tr.compute(st2, T0 + 3 * 3600 + 1500)["co2_ppm"]["h1_pct"] == 25)
check("backfill with junk rows never raises", tr.backfill({}, [(1, None), ("x", {}), (T0, {"co2_ppm": "abc"})], T0 + 3600) is not None)

print()
if FAILURES:
    print(f"{len(FAILURES)} FAILED: " + "; ".join(FAILURES))
    sys.exit(1)
print("all trend tests passed")
