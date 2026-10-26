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

# Weather hard closes: thunder, and rain with the wind onto the windows (south-facing windows: facing 180)
W = lambda **k: clean(**k)
def advise_w(ind, out, facing=180.0, **cfg):
    return va.advise({**BASE, **ind}, out, frozenset(), None, {"window_facing_deg": facing, **cfg})
r = advise_w(dict(co2=1700), W(ts_min=0.0, wind_deg=20))
check("thunder now beats even a severe need and ignores the wind", r["verdict"] == "CLOSE" and r["cls"] == "hazard" and r["alert_text"] == "CLOSE WIN // STORM", str(r))
r = advise_w(dict(co2=1200), W(ts_min=95.0))
check("thunder expected: hard close with the minutes in the reason", r["verdict"] == "CLOSE" and "expected within 95 min" in r["reason"], str(r))
r = va.advise({**BASE, **dict(co2=1200)}, W(ts_min=0.0))
check("thunder closes with no window direction configured", r["alert_text"] == "CLOSE WIN // STORM")
r = advise_w(dict(co2=450), W(aqi=150, ts_min=0.0))
check("a poor-air hazard still comes first (same CLOSE, its own text)", r["alert_text"] == "CLOSE WIN // OUTDOOR AIR", str(r))
for deg, hard in ((180, True), (270, True), (90, True), (271, False), (89, False), (0, False), (None, True)):
    r = advise_w(dict(co2=1200), W(rain_min=0.0, wind_deg=deg))
    check(f"rain now, wind from {deg}: {'hard CLOSE' if hard else 'only a note'} (90 degrees either side of a south window; unknown counts as toward)",
          (r["alert_text"] == "CLOSE WIN // RAIN") == hard and (hard or (r["verdict"] == "OPEN" and any("raining" in n for n in r["notes"]))), str(r))
r = va.advise({**BASE, **dict(co2=1200)}, W(rain_min=0.0, wind_deg=180))
check("rain with no window direction is a note only", r["verdict"] == "OPEN" and any("raining" in n for n in r["notes"]), str(r))
r = advise_w(dict(co2=1200), W(rain_min=40.0, rain_wind_deg=190, wind_deg=20))
check("rain forecast with the forecast wind toward the windows: BRIEF (the forecast wind decides, not the current one)",
      r["verdict"] == "BRIEF" and "rain" in r["blocks"], str(r))
r = advise_w(dict(co2=1200), W(rain_min=40.0, rain_wind_deg=10, wind_deg=190))
check("rain forecast with the wind from the north: OPEN plus a note", r["verdict"] == "OPEN" and any("rain expected within 40 min" in n for n in r["notes"]), str(r))
r = advise_w(dict(co2=1700), W(rain_min=40.0, rain_wind_deg=190))
check("a severe need still opens despite forecast rain", r["verdict"] == "OPEN", str(r))
r = advise_w(dict(co2=450), W(rain_min=40.0, rain_wind_deg=190))
check("forecast rain with nothing to ventilate: advisory CLOSE, never shown", r["verdict"] == "CLOSE" and r["cls"] == "advisory", str(r))
check("window_facing_deg defaults to none (a fresh install never gets a rain close)", va.DEFAULTS["window_facing_deg"] is None and va.wind_on_windows(180) is None)
check("angle difference wraps around north", va.angle_diff(350, 10) == 20 and va.angle_diff(0, 180) == 180 and va.angle_diff(90, 270) == 180)
# an advisory CLOSE turning into a hazard under the same verdict, and one hazard replacing another, start a new alert
a = va.Advisor({"window_facing_deg": 180.0})
t = 1_792_000_000
for i in range(5):
    a.step(t + 60 * i, dict(co2=450, pm25=2, voc=50, temp_f=75, rh=50), clean(temp_f=92.0))
check("hot outside, nothing to do: advisory CLOSE, no alert", a.verdict == "CLOSE" and a.cls == "advisory" and not a.alert(t + 300)["visible"])
ev = a.step(t + 360, dict(co2=450, pm25=2, voc=50, temp_f=75, rh=50), clean(temp_f=92.0, ts_min=0.0))
check("thunderstorm arrives under the same verdict: the step fires an alert, visible with the storm text",
      ev == "escalate" and a.alert(t + 360)["visible"] and a.alert(t + 360)["text"] == "CLOSE WIN // STORM", str((ev, a.alert(t + 360))))
ev = a.step(t + 420, dict(co2=450, pm25=2, voc=50, temp_f=75, rh=50), clean(temp_f=92.0, ts_min=0.0))
check("the same hazard on the next minute does not re-fire", ev is None)

# NWS air-quality products and AirNow's forecast
r = va.advise({**BASE, **dict(co2=1700)}, clean(nws_events=["Air Quality Alert"]))
check("an NWS Air Quality Alert is a hard CLOSE even with a severe need", r["verdict"] == "CLOSE" and r["cls"] == "hazard" and r["alert_text"] == "CLOSE WIN // NWS AIR QUALITY", str(r))
for ev, txt in (("Dense Smoke Advisory", "CLOSE WIN // NWS DENSE SMOKE"), ("Dust Storm Warning", "CLOSE WIN // NWS DUST STORM"),
                ("Blowing Dust Warning", "CLOSE WIN // NWS BLOWING DUST"), ("Blowing Dust Advisory", "CLOSE WIN // NWS BLOWING DUST"), ("Dust Advisory", "CLOSE WIN // NWS DUST")):
    r = va.advise({**BASE, **dict(co2=1200)}, clean(nws_events=[ev]))
    check(f"{ev}: hard CLOSE, '{txt}'", r["alert_text"] == txt and r["cls"] == "hazard" and len(r["alert_text"]) <= 29, str(r["alert_text"]))
r = va.advise({**BASE, **dict(co2=450)}, clean(nws_events=["Dust Advisory", "Air Quality Alert"]))
check("with several products the most urgent names the alert", r["alert_text"] == "CLOSE WIN // NWS AIR QUALITY")
r = va.advise({**BASE, **dict(co2=1200)}, clean(nws_events=["Air Stagnation Advisory"]))
check("an Air Stagnation Advisory is a note, not a close: OPEN with 'NWS air stagnation advisory' in the reason", r["verdict"] == "OPEN" and "NWS air stagnation advisory" in r["reason"], str(r["reason"]))
r = va.advise({**BASE, **dict(co2=1200)}, clean(nws_events=["Heat Advisory", None, 5]))
check("other products and junk in nws_events are ignored", r["verdict"] == "OPEN" and "NWS" not in r["reason"], str(r["reason"]))
r = va.advise({**BASE, **dict(co2=1200)}, clean(aq_forecast=dict(aqi=112, pollutant="PM2.5", action_day=True)))
check("an AirNow action day forecast is a note with the pollutant and AQI", "AirNow forecast: PM2.5 112 (action day)" in r["reason"] and r["verdict"] == "OPEN", str(r["reason"]))
r = va.advise({**BASE, **dict(co2=1200)}, clean(aq_forecast=dict(aqi=64, pollutant="PM2.5", action_day=False)))
check("a moderate forecast (64, no action day) adds nothing", "AirNow" not in r["reason"])
r = va.advise({**BASE, **dict(co2=1200)}, clean(aq_forecast=dict(aqi=101, pollutant="OZONE", action_day=False)))
check("a forecast AQI of 101 or more is noted even without the action day flag", "AirNow forecast: OZONE 101" in r["reason"] and "action day" not in r["reason"])
r = va.advise({**BASE, **dict(co2=1200)}, clean(aq_forecast=dict(action_day=True)))
check("an action day with no AQI or pollutant still reads sensibly and never raises", "AirNow forecast: AQI (action day)" in r["reason"], str(r["reason"]))
r = va.advise({**BASE, **dict(co2=450)}, clean(aqi=150, nws_events=["Air Quality Alert"]))
check("poor outdoor air (rule 1) still comes first with its own text", r["alert_text"] == "CLOSE WIN // OUTDOOR AIR")

print()
if FAILURES:
    print(f"{len(FAILURES)} FAILED: " + "; ".join(FAILURES))
    sys.exit(1)
print("all advisor tests passed")
