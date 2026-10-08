#!/usr/bin/env python3
"""Acceptance tests for providers/airgradient/ventilation_advisor.py.

Run directly (this repo has no test runner):

    python3 tests/airgradient/test_advisor.py

What is checked, and why it is specified this tightly: docs/ventilation-advisor-design.md,
"Acceptance test". The week of replay data exercises only the VOC and humidity paths and one PM
burst, and its transitions move by a minute if the sustain window, the dwell or the dew point
lookback is defined slightly differently, so the replay compares time, verdict and reason text.
The synthetic cases carry the rest of the rules.
"""
import calendar
import csv
import importlib.util
import json
import re
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
CORE = HERE.parent.parent
FIX = HERE / "fixtures"
MODULE = CORE / "providers" / "airgradient" / "ventilation_advisor.py"
DESIGN = CORE / "docs" / "ventilation-advisor-design.md"

spec = importlib.util.spec_from_file_location("ventilation_advisor", MODULE)
va = importlib.util.module_from_spec(spec)
sys.modules["ventilation_advisor"] = va
spec.loader.exec_module(va)

FAILURES = []


def check(label, condition, detail=""):
    print(f"[{'PASS' if condition else 'FAIL'}] {label}" + (f" - {detail}" if detail and not condition else ""))
    if not condition:
        FAILURES.append(label)


# -----------------------------------------------------------------------
# The module is the design document's reference implementation, verbatim
# -----------------------------------------------------------------------
doc_code = re.findall(r"```python\n(.*?)```", DESIGN.read_text(encoding="utf-8"), re.S)[0]
mod_text = MODULE.read_text(encoding="utf-8")
mod_code = mod_text.split("# " + "-" * 75 + "\n", 1)[1]
check("module body equals the reference code in the design doc", mod_code.strip() == doc_code.strip())

# -----------------------------------------------------------------------
# Replay: week_1min.csv against expected_verdict_changes.csv
# -----------------------------------------------------------------------
rows = list(csv.DictReader(open(FIX / "week_1min.csv", encoding="utf-8")))
expected = [(r["local_time_cdt"], r["verdict"], r["reason"])
            for r in csv.DictReader(open(FIX / "expected_verdict_changes.csv", encoding="utf-8"))][1:]


def fl(x):
    return float(x) if x != "" else None


def epoch(s):
    return calendar.timegm(time.strptime(s, "%Y-%m-%d %H:%M"))


def indoor(r):
    return dict(co2=fl(r["co2_ppm"]), pm25=fl(r["pm25_ugm3"]), voc=fl(r["voc_index"]),
                temp_f=fl(r["temp_f"]), rh=fl(r["humidity_pct"]))


def replay(hold_30s=False, persist=False, drop=()):
    adv, changes, minutes = va.Advisor(), [], {}
    label = {}
    seq = []
    for r in rows:
        t = epoch(r["utc_time"])
        label[t] = r["local_time_cdt"]
        seq.append((t, r))
        if hold_30s:
            seq.append((t + 30, r))
    for t, r in seq:
        if t in drop:
            continue
        if persist:
            adv = va.Advisor.from_state(json.loads(json.dumps(adv.to_state())))
        if adv.step(t, indoor(r)) == "change":
            changes.append((label[t - t % 60], adv.verdict, adv.reason))
        minutes[adv.verdict] = minutes.get(adv.verdict, 0) + (0.5 if hold_30s else 1)
    return changes, minutes, adv


changes, minutes, _ = replay()
check("replay: 18 published changes", len(changes) == 18 == len(expected), f"got {len(changes)}")
check("replay: time, verdict and reason text match expected_verdict_changes.csv", changes == expected,
      "; ".join(f"{a} != {b}" for a, b in zip(changes, expected) if a != b)[:300])
check("replay: minutes OPEN/CLOSE/NEUTRAL = 469/294/9077",
      (minutes.get("OPEN"), minutes.get("CLOSE"), minutes.get("NEUTRAL")) == (469, 294, 9077), str(minutes))
check("replay with state written to JSON and read back before every step is identical",
      replay(persist=True)[0] == expected)
check("replay with every reading repeated at +30 s gives the same changes", replay(hold_30s=True)[0] == expected)
outage = {epoch("2026-10-05 01:30") + 60 * k for k in range(20)}   # 20:30-20:49 CDT, inside the 10-04 VOC onset
c_out = replay(drop=outage)[0]
skip = {i for i, e in enumerate(expected) if "2026-10-04 20:3" <= e[0] <= "2026-10-04 21:2"}   # onset waits for the window to refill
check("a 20-minute outage resets the windows without inventing or losing changes",
      [c[1] for c in c_out] == [e[1] for e in expected], f"{len(c_out)} changes")
check("a 20-minute outage changes no transition except the one it interrupted",
      [c for i, c in enumerate(c_out) if i not in skip] == [e for i, e in enumerate(expected) if i not in skip]
      and all(c_out[i][0] > expected[i][0] for i in skip))

# Alert cap on the 281-minute VOC episode of 2026-10-01
adv = va.Advisor()
visible, open_min, text = 0, 0, ""
for r in rows[:1700]:
    t = epoch(r["utc_time"])
    adv.step(t, indoor(r))
    if adv.verdict == "OPEN":
        al = adv.alert(t)
        open_min += 1
        visible += al["visible"]
        text = text or al["text"]
check("alert is visible for the first 60 minutes of a long episode only",
      (open_min, visible) == (281, 60), f"open {open_min} visible {visible}")
check("VOC alert text", text == "OPEN WIN // VOC 338", text)

# Duplicate and backwards timestamps are ignored
adv = va.Advisor()
adv.step(1000, dict(co2=500, pm25=2, voc=50, temp_f=74, rh=50))
check("duplicate timestamp is ignored", adv.step(1000, dict(co2=2000, pm25=2, voc=50, temp_f=74, rh=50)) is None)
check("timestamp going backwards is ignored", adv.step(900, dict(co2=2000, pm25=2, voc=50, temp_f=74, rh=50)) is None)

# Escalation: same verdict, severity normal -> severe restarts the alert clock
adv = va.Advisor()
ev = []
for i in range(0, 8):
    ev.append(adv.step(10_000 + 60 * i, dict(co2=1100 if i < 4 else 1600, pm25=2, voc=50, temp_f=74, rh=50)))
check("OPEN at CO2 1100, then escalate when CO2 reaches 1600", "change" in ev and "escalate" in ev, str(ev))

# -----------------------------------------------------------------------
# Synthetic cases through advise()
# -----------------------------------------------------------------------
BASE = dict(co2=500, voc=50, pm25=2, temp_f=74, rh=50, dp_rise_30=0)


def clean(**k):
    d = dict(air_fresh=True, wx_fresh=True, aqi=40, pm25=3, pm10=5, pm_source="airnow", temp_f=70, rh=50)
    d.update(k)
    return d


def case(label, ind, out, verdict, alert=None, cls=None, latched=frozenset(), pollen=None):
    r = va.advise({**BASE, **ind}, out, latched, pollen)
    ok = (r["verdict"] == verdict and (alert is None or r["alert_text"] == alert)
          and (cls is None or r["cls"] == cls) and len(r["alert_text"]) <= 29)
    check(label, ok, f"{r['verdict']} | {r['alert_text']!r} | {r['cls']} | {r['reason']}")


case("CO2 1250, clean outdoor: OPEN", dict(co2=1250), clean(), "OPEN", "OPEN WIN // CO2 1250 PPM")
case("CO2 1250, AQI 154: CLOSE hazard", dict(co2=1250), clean(aqi=154), "CLOSE", "CLOSE WIN // OUTDOOR AIR", "hazard")
case("CO2 1250, 90 F / 70% outside: BRIEF", dict(co2=1250), clean(temp_f=90, rh=70), "BRIEF", "BRIEF OPEN // CO2 1250 PPM")
case("CO2 1700, 90 F / 70% outside: OPEN", dict(co2=1700), clean(temp_f=90, rh=70), "OPEN")
case("RH 64, drier outside: OPEN", dict(rh=64), clean(temp_f=60, rh=40), "OPEN", "OPEN WIN // HUMID, DRIER OUT")
case("dusty outside (AirNow), clean inside: advisory CLOSE", {}, clean(pm25=14), "CLOSE", "", "advisory")
case("RH 73 alone, no outdoor data: CLOSE humidity", dict(rh=73), None, "CLOSE", "CLOSE WIN // HUMID INSIDE", "humidity")
case("RH 73 and CO2 1700: BRIEF", dict(rh=73, co2=1700), None, "BRIEF", "BRIEF OPEN // CO2 1700 PPM")
case("RH 67, dew point up 5: CLOSE", dict(rh=67, dp_rise_30=5), None, "CLOSE")
case("RH 65, dew point up 5: NEUTRAL", dict(rh=65, dp_rise_30=5), None, "NEUTRAL")
case("VOC 180: NEUTRAL with annotation", dict(voc=180), None, "NEUTRAL")
case("VOC 270: OPEN", dict(voc=270), None, "OPEN", "OPEN WIN // VOC 270")
case("outdoor 95 F, good indoor air: advisory CLOSE", {}, clean(temp_f=95, rh=40), "CLOSE", "", "advisory")
case("outdoor 40 F, good indoor air: advisory CLOSE", {}, clean(temp_f=40, rh=60), "CLOSE", "", "advisory")
case("OpenWeather-only PM2.5 13, AQI 43: soft rules off, NEUTRAL", dict(pm25=3.5),
     clean(pm25=13.3, pm_source="owm", aqi=43), "NEUTRAL")
case("OpenWeather-only PM2.5 40: hazard", {}, clean(pm25=40, pm_source="owm"), "CLOSE", "CLOSE WIN // OUTDOOR AIR", "hazard")
case("stale air data: hazard rule skipped", {}, clean(air_fresh=False, aqi=300), "NEUTRAL")
case("stale weather: temperature rules skipped", dict(co2=1100), clean(wx_fresh=False, temp_f=95), "OPEN")
case("indoor humid, outdoor drier: OPEN", dict(rh=73), clean(temp_f=66, rh=55), "OPEN", "OPEN WIN // HUMID, DRIER OUT")
case("indoor humid, outdoor wetter: CLOSE humidity", dict(rh=73), clean(temp_f=78, rh=80), "CLOSE", None, "humidity")
case("indoor humid, drier outside but 95 F: BRIEF", dict(rh=73), clean(temp_f=95, rh=15), "BRIEF", "BRIEF OPEN // DRIER OUT")
POL = dict(tree=85, grass=10, weed=65, mold=91)
case("need plus high tree pollen: BRIEF", dict(co2=1100), clean(), "BRIEF", "BRIEF OPEN // CO2 1100 PPM", pollen=POL)
case("need plus high weed and mold only: OPEN", dict(co2=1100), clean(), "OPEN", pollen=dict(tree=10, grass=10, weed=95, mold=95))
case("severe need beats pollen: OPEN", dict(co2=1600), clean(), "OPEN", pollen=dict(tree=95))
case("pollen alone does not alert: NEUTRAL", {}, clean(), "NEUTRAL", pollen=dict(tree=95, grass=90))
case("hazard beats need and pollen: CLOSE", dict(co2=1600), clean(aqi=120), "CLOSE", cls="hazard", pollen=dict(tree=99))
case("hazard trips on OpenWeather even when AirNow is calm", {}, clean(pm25=8, owm_pm25=40), "CLOSE", cls="hazard")
case("hazard trips on AirNow even when OpenWeather is calm", {}, clean(pm25=40, owm_pm25=8), "CLOSE", cls="hazard")
case("hazard trips on OpenWeather PM10", {}, clean(pm10=20, owm_pm10=160), "CLOSE", cls="hazard")
case("soft PM rules use AirNow, not OpenWeather", dict(pm25=3), clean(pm25=8, owm_pm25=13), "NEUTRAL")
case("stale air data ignores an OpenWeather spike too", {}, clean(air_fresh=False, owm_pm25=90), "NEUTRAL")
case("outdoor PM2.5 null", {}, clean(pm25=None), "NEUTRAL")
case("outdoor PM10 null", {}, clean(pm10=None), "NEUTRAL")
case("outdoor RH 0", {}, clean(rh=0), "NEUTRAL")
case("outdoor RH a string", {}, clean(rh="x"), "NEUTRAL")
case("indoor readings unavailable (window not warm)", dict(co2=None, voc=None, pm25=None), clean(), "NEUTRAL")
case("indoor RH unavailable", dict(rh=None), clean(), "NEUTRAL")
case("CO2 900 unlatched: NEUTRAL", dict(co2=900), clean(), "NEUTRAL")
case("CO2 900 latched: OPEN", dict(co2=900), clean(), "OPEN", latched=frozenset({"co2"}))
case("PM2.5 7 latched: OPEN", dict(pm25=7), clean(), "OPEN", latched=frozenset({"pm"}))
for ind, out in ((dict(co2=99999), clean()), (dict(co2=1200, rh=73), clean(temp_f=66, rh=55)), (dict(pm25=123.4), clean(pm_source="owm"))):
    r = va.advise({**BASE, **ind}, out)
    check(f"alert text fits 29 characters: {r['alert_text']!r}", len(r["alert_text"]) <= 29)

print()
if FAILURES:
    print(f"{len(FAILURES)} FAILED: " + "; ".join(FAILURES))
    sys.exit(1)
print("all advisor tests passed")
