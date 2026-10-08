#!/usr/bin/env python3
"""Tests for the AIRGRADIENT row of providers/doctor/fetch_doctor.sh.

Run directly (this repo has no test runner):

    python3 tests/airgradient/test_doctor_row.py

The real doctor script runs against a temporary config/cache tree (it takes its roots straight from
GTEX62_CONFIG_DIR / GTEX62_CACHE_DIR), so nothing real is read or written. Every case writes the
status.json the airgradient provider would have written and checks the row Doctor derives from it.
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
SCRIPT = CORE / "providers" / "doctor" / "fetch_doctor.sh"
FAILURES = []


def check(label, condition, detail=""):
    print(f"[{'PASS' if condition else 'FAIL'}] {label}" + (f" - {detail}" if detail and not condition else ""))
    if not condition:
        FAILURES.append(label)


def iso(t):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))


def ag_status(state="ok", note="", temp_f=74.8, humidity=58.3, pm25=4.9, gen_age=5):
    return {"state": state, "profile": "indoor", "collector": "airgradient", "label": "CAVE",
            "generated_at": iso(time.time() - gen_age), "attempted_at": iso(time.time()), "note": note,
            "co2_ppm": 500, "temp_f": temp_f, "humidity_pct": humidity,
            "pm": {"pm25_ugm3": pm25}, "ventilation": {"verdict": "NEUTRAL", "shadow": True}}


def run(flag=True, listed=True, status=None, profile_enabled=True, profile=True, age=0, host_key=True):
    """Build a scratch tree, run Doctor once, return the airgradient row, the entries and domain_order."""
    d = Path(tempfile.mkdtemp(prefix="agdoc_"))
    cfg, cache = d / "config", d / "cache"
    (cfg / "suites").mkdir(parents=True)
    (cfg / "profiles" / "airgradient").mkdir(parents=True)
    (cache / "shared").mkdir(parents=True)
    (cfg / "core.toml").write_text(f"[providers]\nairgradient = {str(flag).lower()}\n")
    domains = '"air", "airgradient"' if listed else '"air"'
    (cfg / "suites" / "doctor.toml").write_text(
        f'suite_id = "doctor"\n[profiles]\nairgradient = "indoor"\n[domains]\nrequired = [{domains}]\noptional = []\n')
    if profile:
        (cfg / "profiles" / "airgradient" / "indoor.toml").write_text(
            f'profile_id = "indoor"\nenabled = {str(profile_enabled).lower()}\ncache_ttl_sec = 30\n')
    if status is not None:
        p = cache / "shared" / "airgradient" / "indoor"
        p.mkdir(parents=True)
        (p / "status.json").write_text(json.dumps(status))
        if age:
            os.utime(p / "status.json", (time.time() - age, time.time() - age))
    env = dict(os.environ, GTEX62_CONFIG_DIR=str(cfg), GTEX62_CACHE_DIR=str(cache), GTEX62_SUITE_ID="doctor",
               GTEX62_CONKY_CONFIG_DIR=str(cfg), GTEX62_CONKY_CACHE_DIR=str(cache))
    r = subprocess.run(["bash", str(SCRIPT), "local"], env=env, capture_output=True, text=True, timeout=60)
    out = json.loads((cache / "shared" / "doctor" / "local" / "status.json").read_text()) if r.returncode == 0 else {}
    shutil.rmtree(d, ignore_errors=True)
    if r.returncode != 0:
        print(r.stderr[-400:])
    row = (out.get("domains") or {}).get("airgradient") or {}
    entries = [e for e in (out.get("entries") or []) if e.get("domain") == "airgradient"]
    return row, entries, out.get("domain_order") or [], out.get("config_alerts") or []


row, entries, order, _ = run(flag=False, status=ag_status())
check("flag off (the shipped default): row DISABLED, no entries", row.get("state") == "disabled" and row.get("enabled") is False and not entries, str(row.get("state")))
check("row exists and sorts between AIR and ALERTS", "airgradient" in order and order.index("air") < order.index("airgradient") < order.index("alerts"), str(order))
check("flag off: the flags block records it", row.get("flags") == {"core_flag": False, "in_suite_domains": True}, str(row.get("flags")))

row, entries, _, _ = run(status=ag_status())
check("healthy: nominal, no notes, no entries", row.get("state") == "nominal" and row.get("note") is None and not entries, f"{row.get('state')} {row.get('notes')} {entries}")
check("healthy: TTL 30, AGE a small duration, not fast-track", row.get("ttl_sec") == 30 and isinstance(row.get("age_sec"), float) and row.get("fast_track") is False, str((row.get("ttl_sec"), row.get("age_sec"), row.get("fast_track"))))
check("healthy: gauge-eligible (duration against a 30 s TTL)", row.get("age_kind") == "duration" and row.get("enabled") is True)

row, entries, _, _ = run(status=ag_status("degraded", "device unreachable: URLError: timed out"))
check("degraded (device unreachable): WARN even though the file is fresh", row.get("state") == "warn" and row.get("age_sec", 99) < 10, str(row))
check("degraded: DEGRADED note, UNREACHABLE procedure with the provider's note",
      row.get("note") == "DEGRADED" and entries and entries[0]["proc"] == "AIRGRADIENT UNREACHABLE" and "timed out" in (entries[0]["detail"] or ""), str(entries))
row, entries, _, _ = run(status=ag_status("degraded", "device unreachable: missing required fields: rco2"))
check("degraded (bad response) uses the same procedure", entries and entries[0]["proc"] == "AIRGRADIENT UNREACHABLE", str(entries))

row, entries, _, _ = run(status=ag_status("error", "device host not configured ([device].host in profile toml)"))
check("error (no host): ERROR note, HOST NOT SET procedure", row.get("note") == "ERROR" and entries and entries[0]["proc"] == "AIRGRADIENT HOST NOT SET", str(entries))
row, entries, _, _ = run(status=ag_status("error", "missing profile toml"))
check("error (no profile): the generic PROFILE TOML MISSING procedure", entries and entries[0]["proc"] == "PROFILE TOML MISSING", str(entries))

row, entries, _, _ = run(status=ag_status("partial", "fields unavailable: temp_f, humidity_pct"))
check("partial (compensated fields gone past the carry window): WARN, PARTIAL note, FIELDS MISSING procedure with the fields",
      row.get("state") == "warn" and row.get("note") == "PARTIAL" and entries
      and entries[0]["proc"] == "AIRGRADIENT FIELDS MISSING" and "temp_f, humidity_pct" in (entries[0]["detail"] or ""), str(entries))
row, entries, _, _ = run(status=ag_status(temp_f=None, humidity=None))
check("Doctor does not read nested fields: state ok with null readings raises nothing (the provider owns that call)",
      row.get("state") == "nominal" and not entries, str(entries))

row, entries, _, _ = run(status=ag_status(), age=120)
check("loop dead (file old, state ok): STALE, AIRGRADIENT NOT RUNNING (not the generic API-key text)", row.get("state") == "warn" and entries and entries[0]["tag"] == "STALE" and entries[0]["proc"] == "AIRGRADIENT NOT RUNNING", str(entries))
row, entries, _, _ = run(status=None)
check("flag on, nothing ever written: STALE / AIRGRADIENT NOT RUNNING", entries and entries[0]["tag"] == "STALE" and entries[0]["proc"] == "AIRGRADIENT NOT RUNNING", str(entries))
row, entries, _, alerts = run(listed=False, status=None)
check("flag on but the suite does not list the domain: DOMAIN NOT LISTED", entries and entries[0]["proc"] == "DOMAIN NOT LISTED" and any(a.get("domain") == "airgradient" for a in alerts), str(entries))

row, entries, _, _ = run(status=ag_status("disabled", "profile disabled"))
check("provider says disabled: row DISABLED", row.get("state") == "disabled" and row.get("enabled") is False and not entries)
row, entries, _, _ = run(status=None, profile_enabled=False)
check("profile enabled = false before any run: row DISABLED", row.get("state") == "disabled" and not entries)

print()
if FAILURES:
    print(f"{len(FAILURES)} FAILED: " + "; ".join(FAILURES))
    sys.exit(1)
print("all doctor-row tests passed")
