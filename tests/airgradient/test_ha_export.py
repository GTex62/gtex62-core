#!/usr/bin/env python3
"""Tests for scripts/airgradient-ha-export.py against synthetic Home Assistant databases.

Run directly (this repo has no test runner):

    python3 tests/airgradient/test_ha_export.py

The synthetic database has the handful of Home Assistant recorder tables the tool reads. Nothing real
is opened: the tool is pointed at temporary files with --ha-db and --out.
"""
import csv
import hashlib
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
from pathlib import Path

CORE = Path(__file__).resolve().parent.parent.parent
SCRIPT = CORE / "scripts" / "airgradient-ha-export.py"
sys.path.insert(0, str(CORE / "providers" / "airgradient"))
import ventilation_advisor as va  # noqa: E402

FAILURES = []


def check(label, condition, detail=""):
    print(f"[{'PASS' if condition else 'FAIL'}] {label}" + (f" - {detail}" if detail and not condition else ""))
    if not condition:
        FAILURES.append(label)


T0 = 1_791_000_000 - 1_791_000_000 % 60    # a whole minute, 2026-10-03 UTC


def make_db(path, minutes=range(20), co2_gap=range(5, 15), temp_unit="°C", drop_before=None, silent=(), t0=None):
    T0 = t0 if t0 is not None else globals()['T0']
    con = sqlite3.connect(path)
    con.executescript("""
        create table states_meta (metadata_id integer primary key, entity_id text);
        create table state_attributes (attributes_id integer primary key, shared_attrs text);
        create table states (state_id integer primary key, metadata_id integer, state text, last_updated_ts real, attributes_id integer);
        create table statistics_meta (id integer primary key, statistic_id text, unit_of_measurement text);
        create table statistics (id integer primary key, metadata_id integer, start_ts real, mean real, min real, max real);
    """)
    ents = {"sensor.t_carbon_dioxide": 1, "sensor.t_pm0_3": 2, "sensor.t_pm1": 3, "sensor.t_pm2_5": 4, "sensor.t_pm10": 5,
            "sensor.t_voc_index": 6, "sensor.t_temperature": 7, "sensor.t_humidity": 8, "sensor.t_nox_index": 9,
            "climate.t": 10, "weather.t": 11}
    for e, i in ents.items():
        con.execute("insert into states_meta values (?,?)", (i, e))
    aid = [0]

    def attrs(d):
        aid[0] += 1
        con.execute("insert into state_attributes values (?,?)", (aid[0], json.dumps(d)))
        return aid[0]

    def state(mid, ts, s, a=None):
        if drop_before is not None and ts < drop_before:
            return
        con.execute("insert into states (metadata_id,state,last_updated_ts,attributes_id) values (?,?,?,?)",
                    (mid, s, ts, attrs(a) if a is not None else None))
    for m in minutes:
        if m in silent:
            continue
        ts = T0 + m * 60 + 20
        if m not in co2_gap:
            state(1, ts, str(500 + m))
        state(2, ts, "1000"); state(3, ts, "4.0"); state(4, ts, "3.0"); state(5, ts, "6.0"); state(6, ts, "50")
        state(7, ts, "24.0", {"unit_of_measurement": temp_unit}); state(8, ts, "50"); state(9, ts, "2")
    state(7, T0 + 30, "24.0", {"unit_of_measurement": temp_unit})
    state(10, T0, "cool", {"hvac_action": "idle", "temperature": 76, "current_temperature": 75, "fan_mode": "Circulation", "fan_state": "Idle / off"})
    state(10, T0 + 2 * 60 + 5, "cool", {"hvac_action": "idle", "temperature": 76, "current_temperature": 75, "fan_mode": "Circulation", "fan_state": "Running / running low"})
    state(10, T0 + 3 * 60 + 5, "cool", {"hvac_action": "cooling", "temperature": 76, "current_temperature": 76, "fan_mode": "Circulation", "fan_state": "Running / running low"})
    state(11, T0 + 10, "sunny", {"temperature": 70, "humidity": 60, "dew_point": 55, "pressure": 30.0})
    state(11, T0 + 600, "cloudy", {"temperature": 69, "humidity": 62, "dew_point": 55.5, "pressure": 30.0})
    con.execute("insert into statistics_meta values (1,'sensor.t_carbon_dioxide','ppm')")
    con.execute("insert into statistics_meta values (2,'sensor.other_thing','x')")
    con.execute("insert into statistics (metadata_id,start_ts,mean,min,max) values (1,?,510,500,520)", (T0 - 3600,))
    con.execute("insert into statistics (metadata_id,start_ts,mean,min,max) values (2,?,1,1,1)", (T0 - 3600,))
    con.commit(); con.close()


def run(db, out, *extra):
    r = subprocess.run([sys.executable, str(SCRIPT), "--ha-db", str(db), "--out", str(out), "--prefix", "sensor.t_",
                        "--thermostat", "climate.t", "--weather", "weather.t", "--tz", "America/Chicago", *extra],
                       capture_output=True, text=True, timeout=120)
    return r


def rows(path):
    return list(csv.DictReader(open(path, newline="", encoding="utf-8")))


d = Path(tempfile.mkdtemp(prefix="agha_test_"))
db, out = d / "ha.db", d / "out"
make_db(db)
sha_before, mtime_before = hashlib.sha256(db.read_bytes()).hexdigest(), db.stat().st_mtime
r = run(db, out)
check("export runs and reports what it wrote", r.returncode == 0 and "indoor_1min.csv" in r.stdout, r.stdout[-200:] + r.stderr[-200:])
check("the source database is untouched (bytes and mtime)", hashlib.sha256(db.read_bytes()).hexdigest() == sha_before and db.stat().st_mtime == mtime_before)
check("read through a private snapshot copy", json.loads((out / "manifest.json").read_text())["read_method"] == "snapshot")

ind = rows(out / "indoor_1min.csv")
check("one row per whole minute, starting at the first minute that has a prior reading",
      len(ind) == 19 and ind[0]["utc_time"] == time.strftime("%Y-%m-%d %H:%M", time.gmtime(T0 + 60)), f"{len(ind)} rows, first {ind[0]['utc_time']}")
check("local_time uses the given zone (CDT = UTC-5 in October)",
      ind[0]["local_time"] == time.strftime("%Y-%m-%d %H:%M", time.gmtime(T0 + 60 - 5 * 3600)), ind[0]["local_time"])
check("each minute holds the value as of its START: the reading before it, not one inside it",
      ind[0]["co2_ppm"] == "500.0" and ind[2]["co2_ppm"] == "502.0" and ind[3]["co2_ppm"] == "503.0", f"{ind[0]['co2_ppm']} {ind[2]['co2_ppm']} {ind[3]['co2_ppm']}")
check("Home Assistant records changes only, so a steady reading is held through a long silence (no 300 s cutoff)",
      ind[8]["co2_ppm"] == "504.0" and ind[12]["co2_ppm"] == "504.0", f"{ind[8]['co2_ppm']} {ind[12]['co2_ppm']}")
check("temperature converted from C to F (24 C = 75.2 F)", ind[3]["temp_f"] == "75.2", ind[3]["temp_f"])
check("dew point matches the engine's own Magnus calculation",
      abs(float(ind[3]["dew_point_f"]) - va.dewpoint_f(75.2, 50.0)) < 0.01, ind[3]["dew_point_f"])
check("thermostat setpoint carried, AC idle then cooling from the change",
      ind[2]["thermostat_setpoint_f"] == "76" and ind[2]["ac_cooling"] == "0" and ind[4]["ac_cooling"] == "1", f"{ind[2]['ac_cooling']} {ind[4]['ac_cooling']}")
check("PM, VOC, NOx, humidity columns present", ind[1]["pm25_ugm3"] == "3.0" and ind[1]["voc_index"] == "50.0" and ind[1]["humidity_pct"] == "50.0" and ind[1]["nox_index"] == "2.0")

wx = rows(out / "outdoor_weather.csv")
check("outdoor weather rows with their attributes", len(wx) == 2 and wx[0]["condition"] == "sunny" and wx[1]["temperature"] == "69" and wx[1]["dew_point"] == "55.5", str(wx))
th = rows(out / "thermostat.csv")
check("thermostat changes recorded, with fan mode and state", len(th) == 3 and th[2]["hvac_action"] == "cooling"
      and th[0]["fan_mode"] == "Circulation" and th[0]["fan_state"] == "Idle / off" and th[1]["fan_state"] == "Running / running low", str(th))
check("indoor rows carry whether the fan was running, as of each minute start",
      ind[0]["ac_fan_running"] == "0" and ind[2]["ac_fan_running"] == "1" and ind[3]["ac_fan_running"] == "1", f"{ind[0]['ac_fan_running']} {ind[2]['ac_fan_running']} {ind[3]['ac_fan_running']}")
st = rows(out / "statistics_hourly.csv")
check("hourly statistics only for the AirGradient sensors", len(st) == 1 and st[0]["statistic_id"] == "sensor.t_carbon_dioxide" and st[0]["max"] == "520.0" and st[0]["unit"] == "ppm", str(st))
mf = json.loads((out / "manifest.json").read_text())
check("manifest records coverage, entities and the resampling rule",
      mf["files"]["indoor_1min.csv"]["rows"] == 19 and "sensor.t_carbon_dioxide" in mf["entities"].values() and "start of each minute" in mf["resample"] and "changes only" in mf["resample"], str(mf["files"]["indoor_1min.csv"]))

# an archive written before the fan columns existed is upgraded in place: old rows blank, new rows filled
old_out = d / "oldheader"
run(db, old_out)
legacy = rows(old_out / "indoor_1min.csv")
cols_old = [c for c in legacy[0] if c != "ac_fan_running"]
with open(old_out / "indoor_1min.csv", "w", newline="", encoding="utf-8") as fh:
    w = csv.writer(fh); w.writerow(cols_old); w.writerows([[r[c] for c in cols_old] for r in legacy[:10]])    # only the first 10 minutes, old header
with open(old_out / "thermostat.csv", "w", newline="", encoding="utf-8") as fh:
    w = csv.writer(fh); w.writerow(["utc_time", "local_time", "mode", "hvac_action", "setpoint", "current_temperature"])
run(db, old_out)
up = rows(old_out / "indoor_1min.csv")
check("an indoor_1min.csv with the old header is upgraded in place and refilled from Home Assistant", "ac_fan_running" in up[0] and len(up) == 19 and up[0]["ac_fan_running"] == "0" and up[3]["ac_fan_running"] == "1", str(list(up[0])[-3:]))
check("a thermostat.csv with the old header gains the fan columns", "fan_state" in rows(old_out / "thermostat.csv")[0] and rows(old_out / "thermostat.csv")[1]["fan_state"] == "Running / running low")
# whole-recorder silence: no sensor records for 10 minutes. Default allows 15, so held; --max-silence-sec 300 blanks
db_sil = d / "ha_sil.db"
make_db(db_sil, minutes=range(30), co2_gap=(), silent=range(10, 21))
run(db_sil, d / "out_sil_default")
run(db_sil, d / "out_sil_short", "--max-silence-sec", "300")
sd, ss = rows(d / "out_sil_default" / "indoor_1min.csv"), rows(d / "out_sil_short" / "indoor_1min.csv")
check("a recorder silence shorter than --max-silence-sec (default 900) is held", sd[15]["co2_ppm"] == "509.0" and sd[15]["pm25_ugm3"] == "3.0", f"{sd[15]['co2_ppm']!r}")
check("--max-silence-sec 300 blanks every sensor for the minutes after 5 minutes of total silence, and not before",
      ss[10]["co2_ppm"] == "509.0" and ss[16]["co2_ppm"] == "" and ss[16]["pm25_ugm3"] == "" and ss[16]["dew_point_f"] == "" and ss[22]["co2_ppm"] == "522.0",
      f"{ss[10]['co2_ppm']!r} {ss[16]['co2_ppm']!r} {ss[22]['co2_ppm']!r}")
db_un = d / "ha_un.db"
make_db(db_un)
c = sqlite3.connect(db_un)
c.execute("insert into states (metadata_id,state,last_updated_ts) values (1,'unavailable',?)", (T0 + 7 * 60 + 5,))
c.commit(); c.close()
run(db_un, d / "out_un")
un = rows(d / "out_un" / "indoor_1min.csv")
check("an 'unavailable' state blanks the hold from that moment (the minute starting after it), and a later reading restores it",
      un[6]["co2_ppm"] == "504.0" and un[8]["co2_ppm"] == "" and un[18]["co2_ppm"] == "518.0", f"{un[6]['co2_ppm']!r} {un[8]['co2_ppm']!r} {un[18]['co2_ppm']!r}")

# idempotent
before = (out / "indoor_1min.csv").read_bytes()
run(db, out)
check("re-running with the same database changes nothing", (out / "indoor_1min.csv").read_bytes() == before)

# purge scenario: Home Assistant has dropped the early rows, and has newer ones
db2 = d / "ha2.db"
make_db(db2, minutes=range(20, 30), co2_gap=(), drop_before=None)
import sqlite3 as _s
c = _s.connect(db2); c.execute("update states set last_updated_ts = last_updated_ts"); c.commit(); c.close()
run(db2, out)
merged = rows(out / "indoor_1min.csv")
utcs = [r["utc_time"] for r in merged]
check("after Home Assistant purges old rows, a later export keeps the archived ones and adds the new",
      utcs == sorted(utcs) and merged[0]["utc_time"] == ind[0]["utc_time"] and len(merged) > 19 and merged[-1]["utc_time"] > ind[-1]["utc_time"],
      f"{len(merged)} rows, {merged[0]['utc_time']} -> {merged[-1]['utc_time']}")
check("no duplicate minutes after merging", len(utcs) == len(set(utcs)))
check("archived rows keep their values", merged[2]["co2_ppm"] == "502.0")
check("a blank in a later export never erases an archived value (per-cell merge)", merged[0]["co2_ppm"] == "500.0" and merged[2]["co2_ppm"] == "502.0" and merged[3]["temp_f"] == "75.2")

# errors
r = run(d / "nope.db", out)
check("missing database: clear message and exit 2", r.returncode == 2 and "not found" in r.stderr, r.stderr[-120:])
r = subprocess.run([sys.executable, str(SCRIPT), "--ha-db", str(db), "--out", str(d / "o2"), "--prefix", "sensor.none_"], capture_output=True, text=True)
check("no matching AirGradient entities: exit 3", r.returncode == 3 and "check --prefix" in r.stderr, r.stderr[-120:])
db3 = d / "ha3.db"; make_db(db3, temp_unit="°F")
run(db3, d / "o3")
check("a temperature already in F is not converted again", rows(d / "o3" / "indoor_1min.csv")[3]["temp_f"] == "24.0")

# ---------------------------------------------------------------------------
# Rolling window and archive
# ---------------------------------------------------------------------------
import calendar, gzip
def epoch_of(s):
    return calendar.timegm(time.strptime(s, "%Y-%m-%d %H:%M"))


def gz_rows(path):
    with gzip.open(path, "rt", newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


TODAY = "2026-10-08"                      # keep 3 months -> cutoff 2026-07-08
old_db, new_db, edge_db = d / "old.db", d / "new.db", d / "edge.db"
make_db(old_db, t0=epoch_of("2026-01-15 03:00"))
make_db(new_db, t0=epoch_of("2026-10-03 04:00"))
make_db(edge_db, t0=epoch_of("2026-07-08 00:00"))
rw = d / "rolling"
r = run(old_db, rw, "--keep-months", "3", "--today", TODAY)
check("rows older than the window are archived, not kept live", r.returncode == 0 and len(rows(rw / "indoor_1min.csv")) == 0, r.stderr[-200:])
arc = rw / "archive" / "indoor_1min-2026-01.csv.gz"
check("...into one gzip per file per month", arc.exists() and len(gz_rows(arc)) == 19, str(sorted(p.name for p in (rw / "archive").glob("*"))))
check("...for every exported file (weather, thermostat, statistics too)",
      all((rw / "archive" / n).exists() for n in ("outdoor_weather-2026-01.csv.gz", "thermostat-2026-01.csv.gz")) and any((rw / "archive").glob("statistics_hourly-*.csv.gz")),
      str(sorted(p.name for p in (rw / "archive").glob("*"))))
check("archived rows keep their values and the header", gz_rows(arc)[2]["co2_ppm"] == "502.0" and "utc_time" in gz_rows(arc)[0])
mf = json.loads((rw / "manifest.json").read_text())
check("manifest records the window, the cutoff and what was moved",
      mf["retention"]["keep_months"] == 3 and mf["retention"]["cutoff"] == "2026-07-08" and mf["retention"]["moved_this_run"].get("indoor_1min-2026-01.csv.gz") == 19
      and mf["retention"]["archive_files"].get("indoor_1min-2026-01.csv.gz") == 19, str(mf["retention"]))
arc_bytes = arc.read_bytes()
run(old_db, rw, "--keep-months", "3", "--today", TODAY)
check("re-exporting the same old data is idempotent (archive unchanged, live still empty)", arc.read_bytes() == arc_bytes and len(rows(rw / "indoor_1min.csv")) == 0)
run(new_db, rw, "--keep-months", "3", "--today", TODAY)
check("recent rows stay live while the January archive is left alone", len(rows(rw / "indoor_1min.csv")) == 19 and arc.read_bytes() == arc_bytes)
# the window rolls forward: a later 'today' moves the October rows into an October archive, nothing lost
run(new_db, rw, "--keep-months", "3", "--today", "2027-02-01")
check("as the window rolls forward the newly expired rows are archived by month and live shrinks accordingly",
      (rw / "archive" / "indoor_1min-2026-10.csv.gz").exists() and len(rows(rw / "indoor_1min.csv")) == 0 and len(gz_rows(rw / "archive" / "indoor_1min-2026-10.csv.gz")) == 19)
check("an archive file is never deleted by later runs", arc.exists() and arc.read_bytes() == arc_bytes)
# merging into an existing month file
make_db(d / "jan2.db", t0=epoch_of("2026-01-15 03:30"), minutes=range(5))
run(d / "jan2.db", rw, "--keep-months", "3", "--today", "2027-02-01")
check("rows for an already-archived month merge into its file (no duplicates, nothing lost)",
      len(gz_rows(arc)) == 19 + 4 and len({r["utc_time"] for r in gz_rows(arc)}) == 23, str(len(gz_rows(arc))))
# a monthly archive written before the fan column existed merges with new-header rows without loss
oa = d / "oldarc"
(oa / "archive").mkdir(parents=True)
old_cols = ["local_time", "utc_time", "co2_ppm", "pm03_per_dl", "pm1_ugm3", "pm25_ugm3", "pm10_ugm3", "voc_index", "temp_f",
            "humidity_pct", "nox_index", "dew_point_f", "thermostat_setpoint_f", "ac_cooling"]
with gzip.open(oa / "archive" / "indoor_1min-2026-01.csv.gz", "wt", newline="", encoding="utf-8") as fh:
    w = csv.writer(fh)
    w.writerow(old_cols)
    w.writerow(["2026-01-14 20:50", "2026-01-15 02:50", "480", "900", "4", "3", "6", "40", "70", "50", "1", "50", "76", "0"])
    w.writerow(["2026-01-14 20:51", "2026-01-15 02:51", "481", "901", "4", "3", "6", "40", "70", "50", "1", "50", "76", "0"])
run(old_db, oa, "--keep-months", "3", "--today", TODAY)
merged_old = gz_rows(oa / "archive" / "indoor_1min-2026-01.csv.gz")
check("an old-header archive file merges with new rows: nothing lost, new column present, old rows blank in it",
      len(merged_old) == 19 + 2 and "ac_fan_running" in merged_old[0] and merged_old[0]["co2_ppm"] == "480" and merged_old[0]["ac_fan_running"] == "")

# boundary: a row dated exactly on the cutoff stays live, the day before is archived
rb = d / "boundary"
run(edge_db, rb, "--keep-months", "3", "--today", TODAY)
live_b = rows(rb / "indoor_1min.csv")
check("a row dated on the cutoff day stays live", len(live_b) == 19 and live_b[0]["utc_time"].startswith("2026-07-08"), str(len(live_b)))
rb2 = d / "boundary2"
make_db(d / "edge2.db", t0=epoch_of("2026-07-07 23:40"))
run(d / "edge2.db", rb2, "--keep-months", "3", "--today", TODAY)
check("rows from the day before the cutoff are archived",
      (rb2 / "archive" / "indoor_1min-2026-07.csv.gz").exists() and all(r["utc_time"][:10] >= "2026-07-08" for r in rows(rb2 / "indoor_1min.csv")),
      str(sorted(p.name for p in (rb2 / "archive").glob("*"))))
rk = d / "keepall"
run(old_db, rk, "--keep-months", "0", "--today", TODAY)
check("--keep-months 0 keeps everything live and writes no archive", len(rows(rk / "indoor_1min.csv")) == 19 and not (rk / "archive").exists())
import importlib.util
from datetime import date
spec = importlib.util.spec_from_file_location("hx", SCRIPT)
hx = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hx)
check("month arithmetic: 31 May minus 3 months clamps to 28 Feb; across a year boundary; zero stays put",
      hx.months_back(date(2026, 5, 31), 3) == date(2026, 2, 28) and hx.months_back(date(2026, 1, 15), 3) == date(2025, 10, 15)
      and hx.months_back(date(2026, 3, 31), 1) == date(2026, 2, 28) and hx.months_back(date(2026, 10, 8), 12) == date(2025, 10, 8)
      and hx.months_back(date(2024, 3, 31), 1) == date(2024, 2, 29), "")

# ---------------------------------------------------------------------------
# Settings from the airgradient profile
# ---------------------------------------------------------------------------
cfgdir = d / "cfg"
(cfgdir / "profiles" / "airgradient").mkdir(parents=True)
prof = cfgdir / "profiles" / "airgradient" / "indoor.toml"
rc = d / "fromcfg"
prof.write_text(f'[ha_export]\nha_db = "{db}"\nprefix = "sensor.t_"\nthermostat = "climate.t"\nweather = "weather.t"\n'
                f'keep_months = 2\ntz = "America/Chicago"\nout = "{rc}"\n')
env = dict(os.environ, GTEX62_CONFIG_DIR=str(cfgdir), GTEX62_CONKY_CONFIG_DIR=str(cfgdir))
r = subprocess.run([sys.executable, str(SCRIPT), "--today", TODAY], env=env, capture_output=True, text=True, timeout=120)
mf = json.loads((rc / "manifest.json").read_text()) if (rc / "manifest.json").exists() else {}
check("no flags needed: db, entities, window and output all come from [ha_export] in the profile",
      r.returncode == 0 and mf.get("retention", {}).get("keep_months") == 2 and mf["retention"]["cutoff"] == "2026-08-08" and "sensor.t_carbon_dioxide" in mf["entities"].values(),
      r.stdout[-200:] + r.stderr[-200:])
r = subprocess.run([sys.executable, str(SCRIPT), "--today", TODAY, "--keep-months", "6"], env=env, capture_output=True, text=True, timeout=120)
check("a command-line flag overrides the profile", json.loads((rc / "manifest.json").read_text())["retention"]["keep_months"] == 6)
prof.write_text(f'[ha_export]\nha_db = "{db}"\nout = "{d / "noprefix"}"\n')
r = subprocess.run([sys.executable, str(SCRIPT)], env=env, capture_output=True, text=True, timeout=60)
check("no prefix anywhere: a clear message and exit 2", r.returncode == 2 and "prefix" in r.stderr, r.stderr[-150:])
prof.write_text('[ha_export]\nenabled = false\n')
r = subprocess.run([sys.executable, str(SCRIPT)], env=env, capture_output=True, text=True, timeout=60)
check("[ha_export] enabled = false: exits 0 without touching anything", r.returncode == 0 and "disabled" in r.stdout)
prof.write_text(f'[ha_export]\nha_db = "{db}"\nprefix = "sensor.t_"\nout = "{d / "nothermo"}"\n')
r = subprocess.run([sys.executable, str(SCRIPT), "--today", TODAY], env=env, capture_output=True, text=True, timeout=120)
check("thermostat and weather are optional: without them those files are simply not written",
      r.returncode == 0 and (d / "nothermo" / "indoor_1min.csv").exists() and not (d / "nothermo" / "thermostat.csv").exists()
      and not (d / "nothermo" / "outdoor_weather.csv").exists() and rows(d / "nothermo" / "indoor_1min.csv")[2]["thermostat_setpoint_f"] == "", r.stderr[-200:])

shutil.rmtree(d, ignore_errors=True)
print()
if FAILURES:
    print(f"{len(FAILURES)} FAILED: " + "; ".join(FAILURES))
    sys.exit(1)
print("all HA-export tests passed")
