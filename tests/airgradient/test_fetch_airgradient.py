#!/usr/bin/env python3
"""Tests for providers/airgradient/fetch_airgradient.py against a fake AirGradient device.

Run directly (this repo has no test runner):

    python3 tests/airgradient/test_fetch_airgradient.py

Everything happens in a temporary config/cache tree; the real runtime config and caches are never
touched and no real device is contacted. The provider is loaded in-process once per scenario with
`time.time` replaced, because the advisor's windows and dwell are time-based.
"""
import csv
import http.server
import importlib.util
import json
import os
import shutil
import socket
import sys
import tempfile
import threading
import time
import types
from pathlib import Path

CORE = Path(__file__).resolve().parent.parent.parent
SCRIPT = CORE / "providers" / "airgradient" / "fetch_airgradient.py"
FAILURES = []


def check(label, condition, detail=""):
    print(f"[{'PASS' if condition else 'FAIL'}] {label}" + (f" - {detail}" if detail and not condition else ""))
    if not condition:
        FAILURES.append(label)


# ---------------------------------------------------------------------------
# Fake device: serves whatever PAYLOAD / MODE say
# ---------------------------------------------------------------------------
FULL = {
    "pm01": 2.17, "pm02": 6.67, "pm10": 2.5, "pm02Compensated": 2.2,
    "pm003Count": 664.4, "pm005Count": 200.0, "pm01Count": 28.0, "pm02Count": 2, "pm50Count": 0, "pm10Count": 0,
    "pm01Standard": 5.1, "pm02Standard": 6.6, "pm10Standard": 6.6,
    "atmp": 25.9, "atmpCompensated": 25.9, "rhum": 56.35, "rhumCompensated": 56.35,
    "rco2": 695.67, "tvocIndex": 100.92, "tvocRaw": 31028.42, "noxIndex": 1.4, "noxRaw": 17701.75,
    "boot": 0, "bootCount": 0, "wifi": -67, "ledMode": "co2", "serialno": "3cdc75bcc200",
    "firmware": "3.7.0", "model": "I-9PSL",
}
OMIT = ("atmp", "atmpCompensated", "rhum", "rhumCompensated", "pm02Compensated")
STATE = {"payload": dict(FULL), "mode": "ok"}


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if STATE["mode"] == "500":
            self.send_response(500); self.end_headers(); return
        if STATE["mode"] == "garbage":
            self.send_response(200); self.end_headers(); self.wfile.write(b"<html>not json</html>"); return
        body = json.dumps(STATE["payload"]).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
HOST = f"127.0.0.1:{server.server_address[1]}"


def set_payload(**changes):
    p = dict(FULL)
    for k, v in changes.items():
        if v is None:
            p.pop(k, None)
        else:
            p[k] = v
    STATE["payload"], STATE["mode"] = p, "ok"


def free_port_host():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); port = s.getsockname()[1]; s.close()
    return f"127.0.0.1:{port}"


# ---------------------------------------------------------------------------
# Scenario scaffolding
# ---------------------------------------------------------------------------
BASE_T = (int(time.time()) + 10_000) // 60 * 60     # in the future so a real status.json mtime is never "fresh"


class Scenario:
    def __init__(self, toml_extra="", host=None, ttl=0, advisor_extra="shadow = true", profile_toml=True,
                 label="", air=None, wx=None, pollen_csv=None, enabled=True, advisor_enabled=True, data_env=True, aviation=None):
        self.dir = Path(tempfile.mkdtemp(prefix="agtest_"))
        self.cfg, self.cache = self.dir / "config", self.dir / "cache"
        (self.cfg / "profiles" / "airgradient").mkdir(parents=True)
        (self.cache / "shared").mkdir(parents=True)
        self.t = BASE_T
        self.data_env = data_env
        if profile_toml:
            lab = f'label = "{label}"\n' if label else ""
            pol = ""
            if pollen_csv:
                pol = f'[advisor.pollen]\nenabled = true\ncsv = "{pollen_csv}"\nthreshold = 80\ncategories = ["tree", "grass"]\n'
            (self.cfg / "profiles" / "airgradient" / "indoor.toml").write_text(
                f'profile_id = "indoor"\nenabled = {str(enabled).lower()}\n{lab}cache_ttl_sec = {ttl}\n\n'
                f'[device]\nhost = "{host if host is not None else HOST}"\ntimeout_sec = 2\n\n'
                f'[advisor]\nenabled = {str(advisor_enabled).lower()}\n{advisor_extra}\nlog_inputs = true\n\n{pol}{toml_extra}\n',
                encoding="utf-8")
        self.set_outdoor(air, wx)
        if aviation is not None:
            d = self.cache / "shared" / "aviation" / "home"; d.mkdir(parents=True, exist_ok=True)
            (d / "current.json").write_text(json.dumps({"metar_raw": aviation}))

    def set_outdoor(self, air=None, wx=None):
        iso = lambda t: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))
        if air is not None:
            d = self.cache / "shared" / "air" / "home"; d.mkdir(parents=True, exist_ok=True)
            doc = {"generated_at": iso(self.t), "airnow": {"aqi": air.get("aqi"), "values": air.get("values", {})},
                   "openweather": {"components": {"pm2_5": air.get("owm_pm25"), "pm10": air.get("owm_pm10")}},
                   "selected": {"pm2_5": air.get("pm25"), "pm10": air.get("pm10")}}
            (d / "current.json").write_text(json.dumps(doc))
        if wx is not None:
            d = self.cache / "shared" / "weather" / "home"; d.mkdir(parents=True, exist_ok=True)
            (d / "current.json").write_text(json.dumps({"provider_updated_at": iso(self.t), **wx}))

    def load(self):
        os.environ["GTEX62_CONFIG_DIR"], os.environ["GTEX62_CACHE_DIR"] = str(self.cfg), str(self.cache)
        os.environ["GTEX62_SHARED_ASSETS"] = str(self.dir / "assets")   # never read this machine's pollen file
        if self.data_env:
            os.environ["GTEX62_DATA_DIR"] = str(self.dir / "data")       # never write to the real data root
        else:
            os.environ.pop("GTEX62_DATA_DIR", None)
        sys.argv = ["fetch_airgradient.py", "indoor", "home", "home"]
        spec = importlib.util.spec_from_file_location("fetch_airgradient_t", SCRIPT)
        mod = importlib.util.module_from_spec(spec)
        sys.path.insert(0, str(SCRIPT.parent))
        spec.loader.exec_module(mod)
        mod.time = types.SimpleNamespace(time=lambda: self.t, sleep=time.sleep)
        return mod

    def run(self, advance=0):
        self.t += advance
        mod = self.load()
        rc = mod.main()
        return rc

    def status(self):
        return json.loads((self.cache / "shared" / "airgradient" / "indoor" / "status.json").read_text())

    @property
    def log_dir(self):
        return self.dir / "data" / "airgradient" / "indoor" / "logs"

    @property
    def state_dir(self):
        return self.cache / "runtime" / "airgradient" / "indoor"

    def done(self):
        shutil.rmtree(self.dir, ignore_errors=True)


iso = lambda t: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))

# ---------------------------------------------------------------------------
# 1. A complete response: scaling, envelope, shadow mode
# ---------------------------------------------------------------------------
set_payload()
sc = Scenario(label="cave")
check("run returns 0", sc.run() == 0)
s = sc.status()
check("state ok, complete response lists no carried fields", s["state"] == "ok" and s["carried_fields"] == [])
check("label is upper-cased", s["label"] == "CAVE")
check("CO2/VOC/NOx floored", (s["co2_ppm"], s["voc_index"], s["nox_index"]) == (695, 100, 1), str((s["co2_ppm"], s["voc_index"], s["nox_index"])))
check("PM2.5 is the compensated value, never raw pm02", s["pm"]["pm25_ugm3"] == 2.2, str(s["pm"]))
check("PM0.3 is pm003Count rounded", s["pm"]["pm03_per_dl"] == 664)
check("temperature converted to F, humidity kept", (s["temp_f"], s["humidity_pct"]) == (78.6, 56.35))
check("dew point computed (Magnus)", abs(s["dew_point_f"] - 61.8) < 0.1, str(s["dew_point_f"]))
check("device block filled", s["device"] == {"host": HOST, "serialno": "3cdc75bcc200", "model": "I-9PSL", "firmware": "3.7.0"})
check("generated_at and attempted_at set", s["generated_at"] == iso(sc.t) == s["attempted_at"])
v = s["ventilation"]
check("ventilation block present and NEUTRAL", v["verdict"] == "NEUTRAL" and v["class"] == "none" and v["shadow"] is True)
check("no outdoor caches: all outdoor flags false", v["outdoor"] == {"pm_source": None, "air_fresh": False, "wx_fresh": False}, str(v["outdoor"]))
check("state is engine-private under runtime/; the input log is in the data root; neither is in shared/",
      (sc.state_dir / "advisor_state.json").exists() and any(sc.log_dir.glob("inputs-*.csv"))
      and not list(sc.state_dir.glob("inputs-*.csv")) and not (sc.state_dir / "verdict_log.txt").exists())
check("advisor state never lands in the shared cache",
      not list((sc.cache / "shared" / "airgradient" / "indoor").glob("advisor_state*")))
rows = list(csv.DictReader(open(next(sc.log_dir.glob("inputs-*.csv")))))
check("input log has a header and one row", len(rows) == 1 and rows[0]["co2_ppm"] == "695" and rows[0]["complete"] == "1")
sc.run(advance=10)
check("two runs in the same minute still log one input row",
      len(list(csv.DictReader(open(next(sc.log_dir.glob("inputs-*.csv")))))) == 1)

# ---------------------------------------------------------------------------
# 2. Partial responses (firmware 3.7.0 drops five fields together)
# ---------------------------------------------------------------------------
set_payload(**{k: None for k in OMIT})
sc.run(advance=60)
s = sc.status()
check("partial response is still state ok", s["state"] == "ok")
check("compensated fields carried forward, not replaced by raw",
      (s["pm"]["pm25_ugm3"], s["temp_f"], s["humidity_pct"]) == (2.2, 78.6, 56.35), str(s["pm"]))
check("carried_fields lists them with their age",
      sorted(c["field"] for c in s["carried_fields"]) == ["humidity_pct", "pm25_ugm3", "temp_f"]
      and all(c["age_sec"] == 60 for c in s["carried_fields"]), str(s["carried_fields"]))
check("dew point still derived from carried inputs", s["dew_point_f"] is not None)
check("generated_at advances on a partial response", s["generated_at"] == iso(sc.t))
rows = list(csv.DictReader(open(next(sc.log_dir.glob("inputs-*.csv")))))
check("input log marks the response incomplete", rows[-1]["complete"] == "0")

sc.run(advance=700)        # beyond carry_max_age_sec (600)
s = sc.status()
check("carried fields expire after carry_max_age_sec: null, never raw",
      (s["pm"]["pm25_ugm3"], s["temp_f"], s["humidity_pct"], s["dew_point_f"]) == (None, None, None, None), str(s))
check("expired fields are not listed as carried", s["carried_fields"] == [])
check("...and the provider reports state partial, naming the fields", s["state"] == "partial" and s["note"] == "fields unavailable: pm25_ugm3, temp_f, humidity_pct", f"{s['state']} {s['note']!r}")
check("partial still publishes readings and a verdict", s["co2_ppm"] == 695 and s["ventilation"] is not None)
check("required fields and PM1/PM10 still reported", s["co2_ppm"] == 695 and s["pm"]["pm10_ugm3"] == 2.5)
set_payload()
sc.run(advance=30)
check("full response restores everything", sc.status()["pm"]["pm25_ugm3"] == 2.2 and sc.status()["carried_fields"] == [])
check("...and state returns to ok", sc.status()["state"] == "ok" and sc.status()["note"] == "")
sc.done()

sc = Scenario()
set_payload(**{k: None for k in OMIT})
sc.run()
s = sc.status()
check("partial response with nothing to carry: ok, nulls, no crash",
      s["state"] == "ok" and s["pm"]["pm25_ugm3"] is None and s["temp_f"] is None and s["dew_point_f"] is None)
check("verdict computed from what is available", s["ventilation"]["verdict"] == "NEUTRAL")
check("startup grace: unavailable fields right after enabling are not yet partial", s["state"] == "ok" and s["note"] == "")
sc.done()

# ---------------------------------------------------------------------------
# 3. Failures: degraded, hold
# ---------------------------------------------------------------------------
set_payload()
sc = Scenario()
sc.run()
good = sc.status()
STATE["mode"] = "500"
sc.run(advance=30)
s = sc.status()
check("HTTP 500: degraded", s["state"] == "degraded", s["note"])
check("degraded keeps last readings and does not move generated_at",
      s["co2_ppm"] == good["co2_ppm"] and s["generated_at"] == good["generated_at"] and s["attempted_at"] == iso(sc.t))
check("degraded keeps the verdict block", s["ventilation"]["verdict"] == good["ventilation"]["verdict"])
STATE["mode"] = "garbage"
sc.run(advance=30)
check("non-JSON response: degraded", sc.status()["state"] == "degraded")
set_payload(rco2=None)
sc.run(advance=30)
check("missing required field: degraded and the note names it", sc.status()["state"] == "degraded" and "rco2" in sc.status()["note"])
set_payload(serialno=None)
sc.run(advance=30)
check("missing serialno: degraded", sc.status()["state"] == "degraded")
set_payload()
sc.run(advance=30)
check("recovery: ok again with a fresh generated_at", sc.status()["state"] == "ok" and sc.status()["generated_at"] == iso(sc.t))
sc.done()

sc = Scenario(host=free_port_host())
sc.run()
s = sc.status()
check("unreachable device on the very first run: degraded stub, null readings, no crash",
      s["state"] == "degraded" and s["co2_ppm"] is None and s["generated_at"] is None and s["ventilation"] is None, str(s["state"]))
sc.done()

# ---------------------------------------------------------------------------
# 4. Configuration states
# ---------------------------------------------------------------------------
set_payload()
sc = Scenario(profile_toml=False)
sc.run()
check("missing profile TOML: error", sc.status()["state"] == "error")
sc.done()
sc = Scenario(host="")
sc.run()
check("no device host: error with a pointer to the key", sc.status()["state"] == "error" and "host" in sc.status()["note"])
sc.done()
sc = Scenario(enabled=False)
sc.run()
check("enabled = false: disabled, device never contacted", sc.status()["state"] == "disabled")
sc.done()
sc = Scenario(ttl=30)
sc.run()
first = sc.status()["generated_at"]
os.utime(sc.cache / "shared" / "airgradient" / "indoor" / "status.json", (time.time(), time.time()))
sc.t = int(time.time())
sc.run()
check("fresh cache (under 80% of the TTL) is not refetched", sc.status()["generated_at"] == first)
sc.done()

# ---------------------------------------------------------------------------
# 5. Advisor through the provider: shadow vs live, outdoor inputs, pollen, thresholds
# ---------------------------------------------------------------------------
def drive(sc, steps, **payload):
    set_payload(**payload)
    for _ in range(steps):
        sc.run(advance=60)
    return sc.status()


clean_air = dict(aqi=40, pm25=3.0, pm10=5.0, owm_pm25=9.0, owm_pm10=10.0, values={"pm2_5": 3.0})
clean_wx = dict(temp_f=76.0, humidity_pct=50)   # inside the 55-85 F band, not 5 F cooler than the 78.6 F room

sc = Scenario(advisor_extra="shadow = true", air=clean_air, wx=clean_wx)
s = drive(sc, 4, rco2=1200)
v = s["ventilation"]
check("shadow: the advisor computes OPEN", v["verdict"] == "OPEN" and v["class"] == "need", v["reason"])
check("shadow: no alert is ever shown", v["alert_visible"] is False and v["alert_text"] == "" and v["shadow"] is True)
check("outdoor flags populated from the air and weather caches",
      v["outdoor"] == {"pm_source": "airnow", "air_fresh": True, "wx_fresh": True}, str(v["outdoor"]))
log = (sc.log_dir / "verdict_log.txt").read_text().splitlines()
check("verdict change is logged with its reason and outdoor flags",
      len(log) == 1 and "\tchange\tOPEN\tneed\t" in log[0] and "pm_source=airnow" in log[0], str(log))
sc.done()

sc = Scenario(advisor_extra="shadow = false", air=clean_air, wx=clean_wx)
s = drive(sc, 4, rco2=1200)
v = s["ventilation"]
check("live: alert visible with the engine-built text", v["alert_visible"] is True and v["alert_text"] == "OPEN WIN // CO2 1200 PPM", str(v))
check("live: alert expires 60 minutes after the change", v["alert_expires_at"] == iso(BASE_T + 120 + 3600), str(v["alert_expires_at"]))
STATE["mode"] = "500"
sc.run(advance=60)
v2 = sc.status()["ventilation"]
check("device failure holds the verdict and the alert", sc.status()["state"] == "degraded" and v2["verdict"] == "OPEN" and v2["alert_visible"] is True)
sc.run(advance=3600)
check("the 60-minute cap keeps running while degraded", sc.status()["ventilation"]["alert_visible"] is False)
sc.done()

sc = Scenario(advisor_extra="shadow = false", air=dict(clean_air, aqi=150, values={}), wx=clean_wx)
s = drive(sc, 3, rco2=1200)
check("outdoor AQI 150: CLOSE hazard, text built by the engine",
      s["ventilation"]["verdict"] == "CLOSE" and s["ventilation"]["alert_text"] == "CLOSE WIN // OUTDOOR AIR", str(s["ventilation"]))
sc.done()

sc = Scenario(advisor_extra="shadow = false", air=dict(clean_air, pm25=8.0, owm_pm25=45.0, values={"pm2_5": 8.0}), wx=clean_wx)
s = drive(sc, 3)
check("hazard trips on OpenWeather PM even when the AirNow value is calm", s["ventilation"]["verdict"] == "CLOSE" and s["ventilation"]["class"] == "hazard")
sc.done()

sc = Scenario(advisor_extra="shadow = false", air=clean_air, wx=clean_wx)
sc.t += 0
# stale air cache (generated 3 hours before the run) must switch the outdoor rules off
sc.set_outdoor(air=dict(aqi=300, pm25=3.0, pm10=5.0, owm_pm25=9.0, owm_pm10=10.0, values={}))
d = sc.cache / "shared" / "air" / "home" / "current.json"
doc = json.loads(d.read_text()); doc["generated_at"] = iso(sc.t - 3 * 3600); d.write_text(json.dumps(doc))
s = drive(sc, 3, rco2=500)
check("stale air cache: hazard rule skipped and air_fresh false",
      s["ventilation"]["verdict"] == "NEUTRAL" and s["ventilation"]["outdoor"]["air_fresh"] is False, str(s["ventilation"]))
sc.done()

pol_csv = Path(tempfile.mkdtemp(prefix="agpollen_")) / "pollen.csv"
pol_csv.write_text("doy,tree,grass,weed,mold\n" + "".join(f"{d},85,10,65,91\n" for d in range(1, 367)))
sc = Scenario(advisor_extra="shadow = false", air=clean_air, wx=clean_wx, pollen_csv=str(pol_csv))
s = drive(sc, 4, rco2=1200)
v = s["ventilation"]
check("high tree pollen turns OPEN into BRIEF", v["verdict"] == "BRIEF" and v["alert_text"] == "BRIEF OPEN // CO2 1200 PPM", str(v["verdict"]))
check("pollen annotation published", any(a.startswith("pollen:") for a in v["annotations"]), str(v["annotations"]))
sc.done()
shutil.rmtree(pol_csv.parent, ignore_errors=True)

sc = Scenario(advisor_extra="shadow = false", toml_extra="[advisor.thresholds]\nco2_enter = 900\n", air=clean_air, wx=clean_wx)
s = drive(sc, 4, rco2=950)
check("a threshold overridden in the profile TOML takes effect", s["ventilation"]["verdict"] == "OPEN")
sc.done()

# ---------------------------------------------------------------------------
# 6. State robustness
# ---------------------------------------------------------------------------
sc = Scenario(advisor_extra="shadow = false", air=clean_air, wx=clean_wx)
drive(sc, 4, rco2=1200)
(sc.state_dir / "advisor_state.json").write_text("{not json")
set_payload()
sc.run(advance=60)
s = sc.status()
check("corrupt advisor_state.json: starts from NEUTRAL and carries on", s["state"] == "ok" and s["ventilation"]["verdict"] == "NEUTRAL", str(s["ventilation"]))
check("corrupt state is logged", "advisor_state.json" in (sc.cache / "shared" / "airgradient" / "indoor" / "fetch.log").read_text())
check("a good state file is rewritten", json.loads((sc.state_dir / "advisor_state.json").read_text())["v"] == 1)
sc.done()

sc = Scenario(advisor_enabled=False, air=clean_air, wx=clean_wx)
sc.run()
s = sc.status()
check("advisor disabled: readings still published, ventilation null", s["state"] == "ok" and s["ventilation"] is None and s["co2_ppm"] == 695)
sc.done()

# ---------------------------------------------------------------------------
# 7. Gap markers in the shadow log
# ---------------------------------------------------------------------------
def gap_lines(sc):
    f = sc.log_dir / "verdict_log.txt"
    return [l.split("\t") for l in f.read_text().splitlines() if "\tgap\t" in l] if f.exists() else []


set_payload()
sc = Scenario(air=clean_air, wx=clean_wx)
sc.run()
sc.run(advance=60)
check("steady polling writes no gap marker", gap_lines(sc) == [])
t_before = sc.t
sc.run(advance=8 * 3600)
g = gap_lines(sc)
check("first run after an 8-hour shutdown writes one 'offline' marker", len(g) == 1 and g[0][6].startswith("kind=offline"), str(g))
check("...naming when it started, when it ended and how long (8h 0m)",
      iso(t_before) in g[0][5] and iso(sc.t) in g[0][5] and "(8h 0m)" in g[0][5] and g[0][6] == "kind=offline gap_sec=28800", g[0][5] if g else "")
sc.run(advance=60)
check("...and only one: the next run adds nothing", len(gap_lines(sc)) == 1)
sc.run(advance=200)
check("a short blip (200 s between runs) is not a gap", len(gap_lines(sc)) == 1)

# device down for ten minutes while the provider keeps running: 'unreachable', not 'offline'
STATE["mode"] = "500"
for _ in range(10):
    sc.run(advance=60)
down_start = sc.t - 9 * 60
set_payload()
sc.run(advance=60)
g = gap_lines(sc)
check("device down 10 minutes then back: one 'unreachable' marker (and not 'offline')",
      len(g) == 2 and g[1][6].startswith("kind=unreachable"), str(g[1:] ))
check("...which says the provider was running", "could not read the device" in g[1][5], g[1][5] if len(g) > 1 else "")
STATE["mode"] = "500"
for _ in range(2):
    sc.run(advance=60)
set_payload()
sc.run(advance=60)
check("a two-minute device blip is not marked", len(gap_lines(sc)) == 2)
sc.done()

sc = Scenario(air=clean_air, wx=clean_wx)
sc.run()
STATE["mode"] = "500"
sc.run(advance=60)
set_payload()
sc.run(advance=10 * 3600)
g = gap_lines(sc)
check("shutdown during which the device was already down: one marker, 'offline'", len(g) == 1 and g[0][6].startswith("kind=offline"), str(g))
sc.done()

# ---------------------------------------------------------------------------
# 8. Where the logs live
# ---------------------------------------------------------------------------
set_payload()
shared = Path(tempfile.mkdtemp(prefix="agshared_"))
(shared / "indoor_1min.csv").write_text("utc_time\n2026-10-01 00:00\n")
(shared / "manifest.json").write_text("{}")
(shared / "inputs-20200101.csv").write_text("epoch\n1\n")
os.utime(shared / "inputs-20200101.csv", (1_577_836_800, 1_577_836_800))
sc = Scenario(advisor_extra=f'shadow = true\nlog_dir = "{shared}"', air=clean_air, wx=clean_wx)
drive(sc, 4, rco2=1200)
check("[advisor] log_dir is honored: input log and verdict log go there", any(shared.glob("inputs-2*.csv")) and (shared / "verdict_log.txt").exists(),
      str(sorted(p.name for p in shared.iterdir())))
check("...and not into the default data-root folder or the runtime folder",
      not sc.log_dir.exists() and not list(sc.state_dir.glob("inputs-*.csv")))
check("pruning old input logs removes only inputs-*.csv: the export's files that share the folder are untouched",
      not (shared / "inputs-20200101.csv").exists() and (shared / "indoor_1min.csv").read_text() == "utc_time\n2026-10-01 00:00\n"
      and (shared / "manifest.json").read_text() == "{}")
check("the advisor state and lock stay in the engine-private runtime folder",
      (sc.state_dir / "advisor_state.json").exists() and not (shared / "advisor_state.json").exists())
sc.done()
shutil.rmtree(shared, ignore_errors=True)

sc = Scenario(data_env=False, air=clean_air, wx=clean_wx)
(sc.cfg / "core.toml").write_text(f'[paths]\ndata_root = "{sc.dir / "coredata"}"\n')
sc.run(); sc.run(advance=60)
check("without GTEX62_DATA_DIR, core.toml [paths] data_root decides: logs in <data_root>/airgradient/<profile>/logs",
      any((sc.dir / "coredata" / "airgradient" / "indoor" / "logs").glob("inputs-*.csv")),
      str(sorted(str(p.relative_to(sc.dir)) for p in sc.dir.rglob("inputs-*.csv"))))
sc.done()

real_home_logs = Path.home() / ".local" / "share" / "gtex62-core" / "airgradient" / "indoor" / "logs"
check("none of these tests wrote into the real data root", not real_home_logs.exists())

# ---------------------------------------------------------------------------
# 9. Outdoor wind for the input log (METAR primary, OpenWeather second column)
# ---------------------------------------------------------------------------
set_payload()
sc = Scenario()
mod = sc.load()
NOW = 1_791_480_000                                   # 2026-10-08 16:00:00Z
pw = lambda raw, now=NOW: mod.parse_metar_wind(raw, now)
w = pw("METAR KMEM 081654Z 05004KT 10SM CLR 29/10 A3006 RMK AO2 SLP175 T02890100 $")
check("METAR wind: from 050 at 4 kt, no gust, observation time parsed",
      (w["wind_dir"], w["wind_kt"], w["wind_gust_kt"], w["wind_variable"]) == (50, 4.0, None, 0) and w["metar_obs"] == "2026-10-08T16:54:00Z", str(w))
w = pw("METAR KMEM 081654Z AUTO 27015G25KT 10SM CLR 29/10 A3006")
check("gusts parsed (270 at 15 gusting 25), AUTO reports handled", (w["wind_dir"], w["wind_kt"], w["wind_gust_kt"]) == (270, 15.0, 25.0), str(w))
w = pw("SPECI KMEM 081654Z 00000KT 10SM CLR 29/10 A3006")
check("calm (00000KT): speed 0 and no direction", (w["wind_kt"], w["wind_dir"]) == (0.0, None), str(w))
w = pw("METAR KMEM 081654Z VRB03KT 10SM CLR 29/10 A3006")
check("variable wind (VRB03KT): speed kept, no direction, flagged", (w["wind_kt"], w["wind_dir"], w["wind_variable"]) == (3.0, None, 1), str(w))
w = pw("METAR XXXX 081654Z 05008MPS CAVOK 20/10 Q1015")
check("metres per second are converted to knots", abs(w["wind_kt"] - 15.6) < 0.1, str(w))
w = pw("METAR KMEM 081654Z 10SM CLR 29/10 A3006")
check("a report with no wind group: no wind, observation time still set", "wind_kt" not in w and w["metar_obs"] == "2026-10-08T16:54:00Z", str(w))
check("empty, missing and non-string input give nothing and never raise", pw("") == {} and pw(None) == {} and pw(123) == {} and pw("garbage text")  == {})
w = mod.parse_metar_wind("METAR KMEM 302355Z 05004KT 10SM CLR", 1_790_899_200 + 60)   # now = 2026-10-01 00:01Z
check("a report from the last minutes of the previous month is dated to that month", w["metar_obs"] == "2026-09-30T23:55:00Z", str(w))
sc.done()

# the log columns, and the header migration of a file started by an older version
set_payload()
raw = lambda sc_: "METAR KMEM %s 05004KT 10SM CLR 29/10 A3006" % time.strftime("%d%H%MZ", time.gmtime(sc_.t - 600))
sc = Scenario(air=clean_air, wx=dict(clean_wx, wind_mph=4.61))
sc.set_outdoor(wx=dict(clean_wx, wind_mph=4.61))
dav = sc.cache / "shared" / "aviation" / "home"; dav.mkdir(parents=True, exist_ok=True)
(dav / "current.json").write_text(json.dumps({"metar_raw": raw(sc)}))
sc.run(); sc.run(advance=60)
r = list(csv.DictReader(open(next(sc.log_dir.glob("inputs-*.csv")))))[-1]
check("input log rows carry METAR wind and OpenWeather speed",
      r["out_wind_kt"] == "4.0" and r["out_wind_dir"] == "50" and r["out_wind_gust_kt"] == "" and r["out_wind_mph_owm"] == "4.61" and r["metar_obs"].endswith("Z"), str({k: r[k] for k in r if "wind" in k or k == "metar_obs"}))
sc.done()

sc = Scenario(air=clean_air, wx=clean_wx)
sc.log_dir.mkdir(parents=True, exist_ok=True)
day = time.strftime("%Y%m%d", time.localtime(sc.t + 60))
oldcols = ["epoch", "utc", "co2_ppm", "verdict"]
with open(sc.log_dir / f"inputs-{day}.csv", "w", newline="") as fh:
    w_ = csv.writer(fh); w_.writerow(oldcols); w_.writerow([1, "2026-10-08T00:00:00Z", 500, "NEUTRAL"])
sc.run(advance=60)
rows_m = list(csv.DictReader(open(sc.log_dir / f"inputs-{day}.csv")))
check("a file started under an older header is rewritten once under the current one: old row kept and padded, new row aligned",
      len(rows_m) == 2 and rows_m[0]["co2_ppm"] == "500" and rows_m[0]["out_wind_kt"] == "" and rows_m[1]["co2_ppm"] != "" and list(rows_m[0])[-1] == "out_wind_mph_owm", str(list(rows_m[0])[-3:]))
sc.run(advance=60)
check("later rows keep appending under the migrated header", len(list(csv.DictReader(open(sc.log_dir / f"inputs-{day}.csv")))) in (2, 3))
sc.done()

# no aviation cache at all: the log still works, wind columns blank
sc = Scenario(air=clean_air, wx=clean_wx)
sc.run(); sc.run(advance=60)
r = list(csv.DictReader(open(next(sc.log_dir.glob("inputs-*.csv")))))[-1]
check("without an aviation cache the wind columns are blank and nothing breaks", r["out_wind_kt"] == "" and r["metar_obs"] == "" and r["co2_ppm"] != "")
sc.done()

# Concurrency: a second writer while the lock is held backs off
sc = Scenario()
import fcntl
sc.state_dir.mkdir(parents=True, exist_ok=True)
holder = open(sc.state_dir / "lock", "w"); fcntl.flock(holder, fcntl.LOCK_EX)
sc.run()
check("a run while another holds the lock exits without writing",
      not (sc.cache / "shared" / "airgradient" / "indoor" / "status.json").exists() or sc.status()["generated_at"] is None)
fcntl.flock(holder, fcntl.LOCK_UN); holder.close()
sc.run(advance=1)
check("and works normally once the lock is free", sc.status()["state"] == "ok")
sc.done()

server.shutdown()
print()
if FAILURES:
    print(f"{len(FAILURES)} FAILED: " + "; ".join(FAILURES))
    sys.exit(1)
print("all provider tests passed")
