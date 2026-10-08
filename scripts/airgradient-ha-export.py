#!/usr/bin/env python3
"""Archive Home Assistant's history for the AirGradient indoor sensors.

Home Assistant keeps raw sensor history for only 10 days (`recorder: purge_keep_days: 10`) and keeps
running while this machine is off, so it holds the nights the engine's own shadow log cannot. This tool
copies what HA has into plain CSV files in the engine's persistent data root, merging with anything
already archived so that a re-run after HA has purged old rows never loses them.

It reads HA's recorder database READ-ONLY, through a private copy: the database file and its write-ahead
log are copied to a temporary directory first, so nothing on the HA side is opened, locked or modified.
Nothing in the live provider or display depends on this tool; it is for analysis and replay.

    python3 scripts/airgradient-ha-export.py [--ha-db PATH] [--out DIR] [--profile indoor]

Writes, under <data_root>/airgradient/<profile>/ha_export/ (data_root from core.toml, default
~/.local/share/gtex62-core):

    indoor_1min.csv        the nine AirGradient sensors resampled to one row per minute, plus dew point,
                           and the cave thermostat's setpoint and whether the AC was cooling
    outdoor_weather.csv    HA's own outdoor weather entity (temperature, humidity, dew point, ...), as recorded
    thermostat.csv         thermostat state changes
    statistics_hourly.csv  HA's long-term hourly statistics (kept indefinitely) for the nine sensors
    manifest.json          what was exported, from where, coverage and units

Resampling: each minute holds the value as of its START (the last reading strictly before it), the same
convention as tests/airgradient/fixtures/week_1min.csv, so a replay built from this export lines up with the
validated fixture. Home Assistant writes a row only when a value CHANGES, so a reading is held until the next
change (NOx can hold one value for 10 hours), so a sensor is held until its next change and goes blank on an
"unavailable"/"unknown" state. Whole minutes are blank when none of the fast sensors (CO2 and the particle
channels, which record every minute or two) has recorded anything for --max-silence-sec (default 15 minutes):
Home Assistant, the recorder or the device was down, and holding a value would invent a steady room.
"""
import argparse
import bisect
import csv
import json
import os
import shutil
import sqlite3
import sys
import tempfile
import time
import tomllib
from datetime import datetime, timezone
from pathlib import Path

try:
    from zoneinfo import ZoneInfo
except ImportError:  # pragma: no cover
    ZoneInfo = None

HOME = Path.home()
CORE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(CORE / "providers" / "airgradient"))
import ventilation_advisor as va  # noqa: E402  (dew point, so it matches what the engine computes)

DEFAULT_MAX_SILENCE_SEC = 900
FAST_SENSORS = ("co2_ppm", "pm25_ugm3", "pm10_ugm3", "pm1_ugm3", "pm03_per_dl")
# CSV column -> HA entity suffix after the prefix
SENSORS = [("co2_ppm", "carbon_dioxide"), ("pm03_per_dl", "pm0_3"), ("pm1_ugm3", "pm1"), ("pm25_ugm3", "pm2_5"),
           ("pm10_ugm3", "pm10"), ("voc_index", "voc_index"), ("temp_f", "temperature"),
           ("humidity_pct", "humidity"), ("nox_index", "nox_index")]
WEATHER_ATTRS = ("temperature", "humidity", "dew_point", "pressure", "wind_speed", "wind_bearing", "visibility")
TOOL = "airgradient-ha-export 1"


def load_toml(path):
    try:
        with open(path, "rb") as f:
            return tomllib.load(f)
    except Exception:
        return {}


def default_out(profile):
    cfg_root = Path(os.getenv("GTEX62_CONFIG_DIR") or os.getenv("GTEX62_CONKY_CONFIG_DIR") or HOME / ".config" / "gtex62-core")
    data_root = (load_toml(cfg_root / "core.toml").get("paths") or {}).get("data_root") or str(HOME / ".local" / "share" / "gtex62-core")
    return Path(data_root).expanduser() / "airgradient" / profile / "ha_export", cfg_root


def default_tz(cfg_root):
    name = ((load_toml(cfg_root / "site.toml").get("location") or {}).get("home") or {}).get("timezone")
    if name and ZoneInfo:
        try:
            return ZoneInfo(name), name
        except Exception:
            pass
    return datetime.now().astimezone().tzinfo, "system local"


def iso(ts):
    return datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def snapshot(db: Path, tmp: Path):
    """Copy the database and its WAL/SHM into `tmp` so it can be read without touching HA's files."""
    last_err = None
    for _ in range(3):
        try:
            dest = tmp / db.name
            shutil.copy2(db, dest)
            for suffix in ("-wal", "-shm"):
                src = Path(str(db) + suffix)
                if src.exists():
                    shutil.copy2(src, Path(str(dest) + suffix))
            con = sqlite3.connect(str(dest))
            con.execute("pragma query_only = on")
            con.execute("select count(*) from states_meta").fetchone()   # fails now if the copy is inconsistent
            return con, "snapshot"
        except sqlite3.DatabaseError as exc:   # copied mid-write: try again
            last_err = exc
            time.sleep(1)
    # Last resort: read the original in place, immutable (ignores the WAL, so the newest minutes may be missing)
    con = sqlite3.connect(f"file:{db}?mode=ro&immutable=1", uri=True)
    return con, f"immutable (snapshot failed: {last_err})"


def metadata_id(con, entity_id):
    r = con.execute("select metadata_id from states_meta where entity_id = ?", (entity_id,)).fetchone()
    return r[0] if r else None


def numeric_states(con, mid):
    """(ts, value) per recorded change; value is None for unknown/unavailable, which blanks the hold."""
    rows = []
    for ts, s in con.execute("select last_updated_ts, state from states where metadata_id = ? and last_updated_ts is not null "
                             "order by last_updated_ts", (mid,)):
        try:
            rows.append((ts, float(s)))
        except (TypeError, ValueError):
            rows.append((ts, None))
    return rows


def unit_of(con, mid):
    r = con.execute("select a.shared_attrs from states s join state_attributes a on a.attributes_id = s.attributes_id "
                    "where s.metadata_id = ? order by s.last_updated_ts desc limit 1", (mid,)).fetchone()
    try:
        return json.loads(r[0]).get("unit_of_measurement") if r and r[0] else None
    except ValueError:
        return None


def attr_states(con, mid):
    out = []
    for ts, st, raw in con.execute("select s.last_updated_ts, s.state, a.shared_attrs from states s "
                                   "left join state_attributes a on a.attributes_id = s.attributes_id "
                                   "where s.metadata_id = ? and s.last_updated_ts is not null order by s.last_updated_ts", (mid,)):
        try:
            attrs = json.loads(raw) if raw else {}
        except ValueError:
            attrs = {}
        out.append((ts, st, attrs))
    return out


def merge_csv(path: Path, header, new_rows, key_cols):
    """Write header + rows, merged into what `path` already holds (see the per-cell rule below)."""
    existing = {}
    if path.exists():
        with open(path, newline="", encoding="utf-8") as f:
            for row in csv.DictReader(f):
                existing[tuple(row[k] for k in key_cols)] = [row.get(h, "") for h in header]
    for row in new_rows:
        key = tuple(str(row[header.index(k)]) for k in key_cols)
        new = ["" if v is None else v for v in row]
        old = existing.get(key)
        # per cell: a new value wins, but a blank never erases a value already archived
        existing[key] = new if old is None else [n if n != "" else o for n, o in zip(new, old)]
    ordered = sorted(existing.items(), key=lambda kv: kv[0])
    tmp = path.with_suffix(path.suffix + ".tmp")
    with open(tmp, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(header)
        for _, row in ordered:
            w.writerow(row)
    tmp.replace(path)
    return [r for _, r in ordered]


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--ha-db", type=Path, default=HOME / ".local" / "ha-config" / "home-assistant_v2.db")
    ap.add_argument("--profile", default="indoor")
    ap.add_argument("--out", type=Path, default=None)
    ap.add_argument("--prefix", default="sensor.cave_airgradient_cave_", help="entity id prefix of the AirGradient sensors")
    ap.add_argument("--thermostat", default="climate.thermostat_cave")
    ap.add_argument("--weather", default="weather.forecast_home")
    ap.add_argument("--max-silence-sec", type=float, default=DEFAULT_MAX_SILENCE_SEC,
                    help="blank a minute when none of the fast sensors has recorded for this long (default 900)")
    ap.add_argument("--tz", default=None, help="IANA time zone for the local_time column (default: site.toml, else system)")
    args = ap.parse_args(argv)

    out_default, cfg_root = default_out(args.profile)
    out = args.out or out_default
    if args.tz and ZoneInfo:
        tz, tzname = ZoneInfo(args.tz), args.tz
    else:
        tz, tzname = default_tz(cfg_root)
    if not args.ha_db.exists():
        print(f"Home Assistant database not found: {args.ha_db} (is the mount up?)", file=sys.stderr)
        return 2
    out.mkdir(parents=True, exist_ok=True)

    tmp = Path(tempfile.mkdtemp(prefix="agha_"))
    try:
        con, how = snapshot(args.ha_db, tmp)
        print(f"read {args.ha_db} via {how}")
        series, units, entities = {}, {}, {}
        for col, suffix in SENSORS:
            eid = args.prefix + suffix
            mid = metadata_id(con, eid)
            if mid is None:
                print(f"  missing entity: {eid}")
                continue
            rows = numeric_states(con, mid)
            unit = unit_of(con, mid)
            if col == "temp_f" and unit and "C" in unit:
                rows = [(t, None if v is None else v * 9.0 / 5.0 + 32.0) for t, v in rows]
                unit = "F (converted from C)"
            series[col] = ([t for t, _ in rows], [v for _, v in rows])
            units[col], entities[col] = unit, eid
        if not series:
            print("no AirGradient entities found; check --prefix", file=sys.stderr)
            return 3

        # thermostat: setpoint + whether the AC was cooling, held until the next change
        tmid = metadata_id(con, args.thermostat)
        thermo = attr_states(con, tmid) if tmid is not None else []
        t_ts = [t for t, _, _ in thermo]

        first = min(s[0][0] for s in series.values() if s[0])
        last = max(s[0][-1] for s in series.values() if s[0])
        start_min, end_min = (int(first // 60) + 1) * 60, int(last // 60) * 60 + 60   # first minute that has a prior reading, last whole minute
        alive_ts = sorted(ts for col in FAST_SENSORS for ts in series.get(col, ([], []))[0])
        header = ["local_time", "utc_time"] + [c for c, _ in SENSORS] + ["dew_point_f", "thermostat_setpoint_f", "ac_cooling"]
        rows = []
        for m in range(start_min, end_min, 60):
            vals = []
            k = bisect.bisect_left(alive_ts, m) - 1
            recording = k >= 0 and m - alive_ts[k] <= args.max_silence_sec
            for col, _ in SENSORS:
                ts, vs = series.get(col, ([], []))
                i = bisect.bisect_left(ts, m) - 1          # last reading strictly before the minute starts
                vals.append(round(vs[i], 2) if recording and i >= 0 and vs[i] is not None else None)
            temp, rh = vals[SENSORS.index(("temp_f", "temperature"))], vals[SENSORS.index(("humidity_pct", "humidity"))]
            dp = va.dewpoint_f(temp, rh)
            j = bisect.bisect_left(t_ts, m) - 1
            sp = cool = None
            if j >= 0:
                a = thermo[j][2]
                sp = a.get("temperature")
                cool = 1 if a.get("hvac_action") == "cooling" else (0 if a.get("hvac_action") else None)
            rows.append([datetime.fromtimestamp(m, tz).strftime("%Y-%m-%d %H:%M"),
                         datetime.fromtimestamp(m, timezone.utc).strftime("%Y-%m-%d %H:%M")] + vals +
                        [None if dp is None else round(dp, 2), sp, cool])
        merged_indoor = merge_csv(out / "indoor_1min.csv", header, rows, ["utc_time"])

        # outdoor weather entity, as recorded
        wmid = metadata_id(con, args.weather)
        wrows = []
        for ts, st, a in (attr_states(con, wmid) if wmid is not None else []):
            wrows.append([iso(ts), datetime.fromtimestamp(ts, tz).strftime("%Y-%m-%d %H:%M:%S"), st] + [a.get(k) for k in WEATHER_ATTRS])
        w_header = ["utc_time", "local_time", "condition"] + list(WEATHER_ATTRS)
        merged_weather = merge_csv(out / "outdoor_weather.csv", w_header, wrows, ["utc_time"])

        trows = [[iso(ts), datetime.fromtimestamp(ts, tz).strftime("%Y-%m-%d %H:%M:%S"), st, a.get("hvac_action"),
                  a.get("temperature"), a.get("current_temperature")] for ts, st, a in thermo]
        merged_thermo = merge_csv(out / "thermostat.csv", ["utc_time", "local_time", "mode", "hvac_action", "setpoint", "current_temperature"],
                                  trows, ["utc_time"])

        srows = []
        for sid, unit, st_ts, mean, mn, mx in con.execute(
                "select m.statistic_id, m.unit_of_measurement, s.start_ts, s.mean, s.min, s.max from statistics s "
                "join statistics_meta m on m.id = s.metadata_id where m.statistic_id like ? order by m.statistic_id, s.start_ts",
                (args.prefix + "%",)):
            srows.append([sid, iso(st_ts), datetime.fromtimestamp(st_ts, tz).strftime("%Y-%m-%d %H:%M"), mean, mn, mx, unit])
        merged_stats = merge_csv(out / "statistics_hourly.csv",
                                 ["statistic_id", "start_utc", "start_local", "mean", "min", "max", "unit"], srows, ["statistic_id", "start_utc"])
        con.close()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    def span(rs, col):
        v = [r[col] for r in rs if r[col] not in ("", None)]
        return {"rows": len(rs), "first": min(v) if v else None, "last": max(v) if v else None}
    manifest = {
        "tool": TOOL, "exported_at": iso(time.time()), "source_db": str(args.ha_db), "read_method": how,
        "timezone": tzname, "files": {
            "indoor_1min.csv": span(merged_indoor, 1), "outdoor_weather.csv": span(merged_weather, 0),
            "thermostat.csv": span(merged_thermo, 0), "statistics_hourly.csv": span(merged_stats, 1)},
        "entities": entities, "units": units,
        "resample": f"value held as of the start of each minute (last reading strictly before it), as in the test fixture; Home Assistant records changes only, so a reading is held until the next change; blank after an unavailable state, and blank for whole minutes when none of the fast sensors recorded in the previous {int(args.max_silence_sec)} s",
        "note": "Merged on every run: rows already archived are kept even after Home Assistant purges them (it keeps raw history "
                "for 10 days). No outdoor PM or AQI exists in Home Assistant; those are only in the engine's own inputs-*.csv log.",
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {out}")
    for name, info in manifest["files"].items():
        print(f"  {name:22s} {info['rows']:6d} rows  {info['first']} -> {info['last']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
