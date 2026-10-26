#!/usr/bin/env python3
"""Tests for providers/airgradient/notices.py (PM and VOC spike notices for the display's DATA line).

Run directly: python3 tests/airgradient/test_notices.py. Pure functions, no I/O. The scenarios are shaped like real
events from the author's logs (a smoke puff on 2026-10-24, a sharp VOC spike on 2026-10-20, a cooking VOC rise, a slow
VOC rise from a day of outdoor cleaning).
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "providers" / "airgradient"))
import trend as tr  # noqa: E402
import notices as nt  # noqa: E402

FAILURES = []


def check(label, condition, detail=""):
    print(f"[{'PASS' if condition else 'FAIL'}] {label}" + (f" - {detail}" if detail and not condition else ""))
    if not condition:
        FAILURES.append(label)


T0 = 1_792_000_200          # a multiple of 600
BASE = {"co2_ppm": 450, "voc_index": 60, "nox_index": 1, "pm1_ugm3": 4.0, "pm25_ugm3": 5.0, "pm10_ugm3": 6.0, "pm03_per_dl": 1000}


def drive(profile, start, end, step=30, cfg=None, trend=None, nstate=None):
    """Feed readings and evaluate after each. profile(t) -> metric dict. Returns (notices at the end, trend, nstate, log)
    where log is a list of (t, [texts])."""
    trend = trend if trend is not None else {}
    nstate = nstate if nstate is not None else {}
    log = []
    t = start
    notices = []
    while t <= end:
        trend = tr.update(trend, t, profile(t))
        notices, nstate = nt.evaluate(trend, nstate, t, cfg)
        log.append((t, [n["text"] for n in notices]))
        t += step
    return notices, trend, nstate, log


# ---- a calm hour: nothing
n, trend, ns, log = drive(lambda t: BASE, T0, T0 + 3600)
check("a calm hour gives no notices", all(not x for _, x in log))

# ---- a smoke puff: PM2.5 5 -> 99 in two minutes, back to normal within 40 minutes (10-24)
def puff(t):
    d = dict(BASE)
    k = t - (T0 + 3600)
    if k >= 0:
        d["pm25_ugm3"] = 99.0 * (0.5 ** (max(0, k - 120) / 420.0)) if k >= 120 else 5.0 + 94.0 * k / 120.0
        d["pm25_ugm3"] = max(d["pm25_ugm3"], 5.0)
    return d
n, trend, ns, log = drive(puff, T0, T0 + 3600 + 3600)
first = next((t for t, x in log if x), None)
check("a smoke puff: a PM SPIKE notice appears within two minutes of the jump", first is not None and first - (T0 + 3600) <= 150, str(first and first - (T0 + 3600)))
check("...with the measured value in the text, no guess at the cause", any(x and x[0].startswith("PM SPIKE // 2.5: ") and len(x[0]) <= 29 for _, x in log) and not any("SMOKE" in "".join(x) for _, x in log))
last = max((t for t, x in log if x), default=None)
check("...which clears once PM2.5 is back under 1.5 times its baseline (well inside an hour here)", last is not None and last - (T0 + 3600) < 2400 and not log[-1][1], str(last and last - (T0 + 3600)))

# ---- cooking: PM2.5 5.4 -> 8.7: under the thresholds, no PM notice
def cook(t):
    d = dict(BASE); k = t - (T0 + 3600)
    d["pm25_ugm3"] = 5.4 + (3.3 * min(max(k, 0), 1800) / 1800)
    return d
n, trend, ns, log = drive(cook, T0, T0 + 3600 + 1800)
check("cooking, PM2.5 5.4 to 8.7: no PM notice", all(not x for _, x in log))

# ---- a sharp VOC spike: 34 -> 485 in 8 minutes (10-20)
def vocspike(t):
    d = dict(BASE); d["voc_index"] = 34
    k = t - (T0 + 3600)
    if k >= 0:
        d["voc_index"] = min(485, 34 + 451 * k / 480.0) * (0.5 ** (max(0, k - 480) / 1500.0))
        d["voc_index"] = max(d["voc_index"], 34)
    return d
n, trend, ns, log = drive(vocspike, T0, T0 + 3600 + 7200)
first = next((t for t, x in log if x), None)
check("a sharp VOC spike: a VOC SPIKE notice within about three minutes of the start", first is not None and first - (T0 + 3600) <= 300, str(first and first - (T0 + 3600)))
check("...text 'VOC SPIKE // <value>'", any(x and x[0].startswith("VOC SPIKE // ") for _, x in log))
check("...and it is over within the 60 minute cap", log[-1][1] == [] and max(t for t, x in log if x) - first <= 3660)

# ---- a slow VOC rise (the day of the outdoor cleaning): 53 -> 267 over three hours never makes a notice
def slowvoc(t):
    d = dict(BASE); k = t - (T0 + 3600)
    d["voc_index"] = 53 + 214 * min(max(k, 0), 10800) / 10800.0
    return d
n, trend, ns, log = drive(slowvoc, T0, T0 + 3600 + 10800)
check("a slow VOC climb (214 over three hours) is not a spike", all(not x for _, x in log))

# ---- no baseline yet (a fresh start) means no notice, whatever the value
n, trend, ns, log = drive(lambda t: dict(BASE, pm25_ugm3=80.0, voc_index=400), T0, T0 + 900)
check("with no baseline history yet nothing fires, however high the readings are", all(not x for _, x in log))

# ---- the cap, and the frozen baseline: a long event cannot raise its own bar
def long_event(t):
    d = dict(BASE)
    if t >= T0 + 3600:
        d["pm25_ugm3"] = 40.0
    return d
n, trend, ns, log = drive(long_event, T0, T0 + 3600 + 7200)
shown = [t for t, x in log if x]
check("a PM level that stays high shows for the 60 minute cap and then stops", shown and shown[-1] - shown[0] <= 3660 and not log[-1][1], str((shown[0] - T0, shown[-1] - T0) if shown else None))

# ---- disabled by default, custom thresholds
check("enabled defaults to False (the provider only evaluates when the profile turns it on)", nt.DEFAULTS["enabled"] is False)
n, trend, ns, log = drive(puff, T0, T0 + 3600 + 600, cfg={"pm_ratio": 100.0})
check("a higher pm_ratio keeps the same puff quiet", all(not x for _, x in log))

# ---- junk never raises
check("junk trend state and notice state never raise", nt.evaluate(None, "x", T0) == ([], {}) or nt.evaluate(None, "x", T0)[0] == [])

# ---- outdoor facts: NWS products and the AirNow action day
f = nt.outdoor_facts({"nws_alerts": [{"event": "Air Quality Alert", "effective": "2026-10-26T09:00:00-05:00", "expires": "2026-10-27T06:00:00-05:00"},
                                     {"event": "Blowing Dust Advisory"}],
                      "aq_forecast": {"aqi": 112, "pollutant": "PM2.5", "action_day": True}}, "2026-10-26T15:00:00Z")
check("an NWS product becomes 'NWS <EVENT>' with its own times; one without times gets now and no expiry",
      [x["text"] for x in f][:2] == ["NWS AIR QUALITY ALERT", "NWS BLOWING DUST ADVISORY"] and f[0]["since"] == "2026-10-26T09:00:00-05:00"
      and f[0]["expires_at"] == "2026-10-27T06:00:00-05:00" and f[1]["since"] == "2026-10-26T15:00:00Z" and f[1]["expires_at"] is None, str(f))
check("an action day becomes 'AQI ACTION DAY: PM2.5 112'; every text fits 29 characters",
      f[2]["text"] == "AQI ACTION DAY: PM2.5 112" and all(len(x["text"]) <= 29 for x in f))
check("no action day and no alerts: no facts, and junk input never raises",
      nt.outdoor_facts({"aq_forecast": {"aqi": 64, "action_day": False}}, "t") == [] and nt.outdoor_facts(None, "t") == [] and nt.outdoor_facts({"nws_alerts": [None, 5, {"event": 3}]}, "t") == [])

print()
if FAILURES:
    print(f"{len(FAILURES)} FAILED: " + "; ".join(FAILURES))
    sys.exit(1)
print("all notices tests passed")
