# AirGradient Engine Integration

Bringing AirGradient ONE indoor air quality data into the core engine as a new provider,
for display in OSA's ENV panel (and potentially other suites) alongside the existing
outdoor/OWM-sourced ENV data, plus an engine-side ventilation advisor that turns the
readings into an "open windows / close windows" verdict.

Revision 3 (2026-10-07). Status: **design only, not implemented.** Companion document:
`ventilation-advisor-design.md` (rules, thresholds, reference code and the acceptance test).
This revision renames the example profile from `cave` to `indoor` (a display `label` key carries
a personal room name), records that firmware 3.7.0 intermittently omits fields and how the
provider copes, makes the two documents agree on one schema, fixes where state and logs live,
adds the shadow-week input log and the wiring checklist, and applies the decisions from the
design review (visible alerts only for need-based advice, hazards and indoor humidity; AirNow-first
outdoor PM; pollen as a soft drawback). Revision 2 added the advisor, the 7-channel indoor view,
the rotation and alert behavior, and the field-level decisions from a week of real data
(2026-10-01 to 10-07).

---

## Purpose

The AirGradient ONE (indoor air quality monitor: CO2, VOC index, NOx index, PM0.3/1/2.5/10,
temperature, humidity) is on the IoT VLAN with a static reservation and integrated locally
into Home Assistant. This document captures the plan to bring the same data into the Conky
engine/suite ecosystem, following the same collector/engine/display separation established
during the SitRep migration, and to add a ventilation verdict computed in the engine.

---

## Core Principle

> **The engine gathers knowledge. OSA reports status.**

Same principle as SitRep. OSA's ENV panel should not know how to fetch or parse AirGradient
data, and it should not decide whether to open a window. It asks the engine for current
readings and a ready-to-display verdict. All HTTP polling, field selection, scaling,
classification, hysteresis and alert text live in the engine's `airgradient` provider. OSA
only draws what the engine hands it.

---

## Data Source

Unlike the SSH-based providers (pfSense, Zyxel APs), AirGradient exposes a local HTTP API
directly on the device: no SSH session, no gate/backoff state machine required. Confirmed
live against the deployed unit:

```bash
curl -s http://192.168.20.19/measures/current | jq .
```

```json
{
  "pm01": 2.17,
  "pm02": 2.5,
  "pm10": 2.5,
  "pm02Compensated": 2.2,
  "atmp": 25.9,
  "atmpCompensated": 25.9,
  "rhum": 56.35,
  "rhumCompensated": 56.35,
  "rco2": 695.67,
  "tvocIndex": 100.92,
  "tvocRaw": 31028.42,
  "noxIndex": 1,
  "noxRaw": 17701.75,
  "boot": 8,
  "bootCount": 8,
  "wifi": -67,
  "ledMode": "co2",
  "serialno": "3cdc75bcc200",
  "firmware": "3.6.2",
  "model": "I-9PSL"
}
```

Device: I-9PSL, serial `3cdc75bcc200`, firmware `3.7.0` (updated from 3.6.2; the sample above is
from 3.6.2, see the 3.7.0 fields below), static IP `192.168.20.19` (IoT
VLAN; the address lives in the profile TOML, not in code). VOC/NOx index learning offset is set
to 120 hours on-device (adjustable locally via the AirGradient integration's Configuration
entities in Home Assistant; not required for the engine fetch, since the device applies the
learning window before exposing the index values via the API).

**Firmware 3.7.0 adds particle fields** (confirmed live 2026-10-07):

```json
{ "pm003Count": 1119.5, "pm005Count": 300.17, "pm01Count": 28.83, "pm02Count": 2,
  "pm50Count": 0, "pm10Count": 0,
  "pm01Standard": 5.17, "pm02Standard": 6.67, "pm10Standard": 6.67,
  "pm02Compensated": 4.34 }
```

- **PM0.3 is `pm003Count`** (particles/dL), the value Home Assistant shows as PM0.3. The other
  count fields are not used.
- **Which PM2.5 Home Assistant reports: the compensated one** (`pm02Compensated`), by two
  checks. In the same reading, `pm02Compensated` 4.34 equals the standard EPA humidity
  correction applied to raw `pm02` 6.67 at 56.9% RH (0.524 x 6.67 - 0.0862 x 56.9 + 5.75).
  And in the week of HA history, PM2.5 is lower than PM1 in 4,094 of 9,840 minutes (42%),
  which cannot happen for raw values from the same sensor but does when PM2.5 is corrected
  and PM1 is not. Confirmed live on 2026-10-07: HA PM2.5 3.91
  against `pm02Compensated` 3.90 (raw `pm02` 5.83), read seconds apart.
- **Consequence:** PM1 and PM10 are uncorrected, so PM2.5 can read below PM1, and PM10 can
  read below PM2.5. Display them as reported; do not enforce ordering.
- **Units:** `atmp` is Celsius whatever the device's display unit is set to (the device config has
  `temperatureUnit: "f"`, and `atmp` still read 23.97 against a room at about 75 F). Convert in the
  engine.

### Partial payloads (observed, firmware 3.7.0)

Polling the unit 40 times at 1.5 s intervals on 2026-10-07, 9 responses (22%) were complete JSON
(HTTP 200, normal latency, 0.15 s on average) but **omitted five fields together**: `atmp`,
`atmpCompensated`, `rhum`, `rhumCompensated` and `pm02Compensated`. CO2, VOC, NOx, raw PM and the
particle counts were always present. Home Assistant hides this by holding the last value. The
provider must as well, because the two obvious alternatives are both wrong: treating the response
as a failed fetch would put the provider in `degraded` a fifth of the time, and falling back to raw
`pm02` would read about 1.5 times high (6.67 against 4.25 in one sample) against thresholds tuned
on the compensated value.

Rules:

- **Required fields**: `rco2`, `tvocIndex`, `noxIndex`, `pm01`, `pm10`, `serialno`. A response
  missing any of them, or not valid JSON, or not HTTP 200, is a failed fetch (`degraded`).
- **Carried fields**: `pm02Compensated`, `atmpCompensated`, `rhumCompensated` (and `pm003Count`).
  When absent, the last good value is reused for up to `carry_max_age_sec` (default 600) and the
  field is listed in `carried_fields` with its age. Past that age the field is null.
- **Never fall back to raw** `pm02`, `atmp` or `rhum`. A compensated field that has never been
  seen is null.
- **Derived values** (`temp_f`, `dew_point_f`) are computed only from carried-or-fresh inputs that
  are within the maximum age; otherwise null.
- A response is *complete* when no carried field was needed. The shadow log records the fraction of
  complete responses so the behaviour can be re-checked after firmware updates.

---

## Architecture

```text
AirGradient ONE local API (host from profile TOML, port 80, /measures/current)
                    │
              engine poll (curl or urllib, no SSH)
                    │
        ┌───────────┴────────────┐
   readings + scaling      ventilation advisor ◄── shared/air/<air_profile>/current.json
        │                        │              ◄── shared/weather/<weather_profile>/current.json
        │                        │              ◄── pollen_mem_v2.csv (optional)
        │                        └── runtime/airgradient/{profile}/advisor_state.json (private)
        └───────────┬────────────┘
              atomic JSON write
                    │
        shared/airgradient/{profile}/status.json
                    │
                 OSA ENV panel (display only)
```

Provider is written in Python (the advisor needs persistent state, time arithmetic and atomic JSON;
`fetch_modem.py` is the precedent), launched through the usual `fetch_airgradient.sh` wrapper so the
launcher treats it like every other domain.

No SSH gate equivalent is implemented for this provider; see Known Constraints.

**Profile name.** The example profile is `indoor` (`examples/runtime/profiles/airgradient/
indoor.toml.example`), following the generic names the other providers ship (`home`, `local`,
`default`, `main_router`) and leaving `outdoor` available for a second unit. Room names belong in
the optional `label` key, not in the profile name. Home Assistant entity names need not match
anything in the engine.

### Profile TOML (sketch)

```toml
profile_id = "indoor"
enabled = true
# Short text shown after INDOOR in the ENV panel header and on the SRC line.
# Uppercase, 8 characters at most; leave empty for plain "INDOOR".
# label = "CAVE"

[device]
# Address of the AirGradient ONE on your network (local API; no cloud involved).
host = ""
timeout_sec = 5
carry_max_age_sec = 600

[cache]
cache_ttl_sec = 30        # 30 to 60; the launcher's refresh loop honors it

[advisor]
enabled = true
shadow = true             # compute and log, but never show an alert in any suite
# Thresholds: every number in ventilation-advisor-design.md is a key here
# (co2_enter, co2_leave, co2_severe, voc_need, pm_enter, pm_leave, rh_enter, rh_floor, ...).

[advisor.pollen]
enabled = true
# csv = ""                # default: $GTEX62_SHARED_ASSETS/data/pollen/pollen_mem_v2.csv
threshold = 80
categories = ["tree", "grass"]

[advisor.outdoor]
# air and weather profiles are taken from the launching suite's bindings;
# set these only to override.
# air_profile = ""
# weather_profile = ""
```

---

## status.json Schema

`shared/airgradient/{profile}/status.json`, written by `fetch_airgradient.sh` (Python behind it).
Field names ending in a unit carry that unit. This is the single schema; the advisor document
refers here.

```json
{
  "state": "ok",
  "profile": "indoor",
  "collector": "airgradient",
  "label": "CAVE",
  "generated_at": "2026-10-07T14:23:00Z",
  "attempted_at": "2026-10-07T14:23:01Z",
  "device": {
    "host": "192.168.20.19",
    "serialno": "3cdc75bcc200",
    "model": "I-9PSL",
    "firmware": "3.7.0"
  },
  "carried_fields": [],
  "co2_ppm": 695,
  "voc_index": 100,
  "nox_index": 1,
  "pm": {
    "pm03_per_dl": 664,
    "pm1_ugm3": 2.17,
    "pm25_ugm3": 2.2,
    "pm10_ugm3": 2.5
  },
  "temp_f": 78.6,
  "humidity_pct": 56.35,
  "dew_point_f": 62.5,
  "wifi_rssi": -67,
  "ventilation": {
    "verdict": "NEUTRAL",
    "severity": "normal",
    "class": "none",
    "reason": "Fine either way",
    "since": "2026-10-07T13:02:00Z",
    "alert_visible": false,
    "alert_text": "",
    "alert_expires_at": null,
    "annotations": [],
    "outdoor": { "pm_source": "airnow", "air_fresh": true, "wx_fresh": true },
    "shadow": false
  }
}
```

`carried_fields` has entries such as `{"field": "temp_f", "age_sec": 31}` when the device omitted a
field and the previous value was reused.

### state field values

| Value | Meaning |
| --- | --- |
| `"ok"` | HTTP fetch succeeded and all required fields were present (carried fields allowed, listed in `carried_fields`) |
| `"degraded"` | Fetch failed/timed out or lacked required fields; fields hold last-known-good values |
| `"disabled"` | Profile has `enabled = false` in TOML |

Matches the pfSense provider's three-value convention, so SitRep/OSA can reuse the same
staleness-indicator display logic across providers without special-casing AirGradient.

### Timestamps

- `generated_at` is the time of the last **successful** reading. It is not advanced by a degraded
  run, so a dead device cannot look fresh.
- `attempted_at` is the time of the last run, successful or not.
- OSA shows `AG STALE` instead of any advice when `generated_at` is older than 3 minutes,
  regardless of `state`.
- The cache file's mtime changes on every run, so the doctor provider's age-based STALE check will
  not notice an unreachable device; the doctor row for this domain must also read `state` (see the
  wiring checklist).

### ventilation fields

| Field | Meaning |
| --- | --- |
| `verdict` | `OPEN`, `BRIEF` (open briefly), `CLOSE` or `NEUTRAL` |
| `severity` | `severe` when CO2 >= 1500 or VOC >= 250, else `normal` (independent of the verdict) |
| `class` | `need`, `hazard`, `humidity`, `advisory` or `none`; only the first three plus the `CLOSE` hazard/humidity classes can show an alert |
| `reason` | Human-readable reason, same text as in the advisor doc |
| `since` | When the current verdict began (after the dwell filter) |
| `alert_visible` | True while the alert should be on screen (see Alert visibility); always false in shadow mode |
| `alert_text` | Pre-built string, 29 characters or fewer, e.g. `OPEN WIN // CO2 1150 PPM`; empty when not visible |
| `alert_expires_at` | When the 60-minute display cap ends this alert, or null |
| `annotations` | Informational notes that never trigger an alert, e.g. `VOC index 180 (relative, informational)`, `pollen: mold 91, weed 65` |
| `outdoor` | `pm_source` (`airnow`, `owm` or null), `air_fresh`, `wx_fresh` (see the advisor document) |
| `shadow` | True while `advisor.shadow` is set |

OSA never recomputes any of this; it prints `alert_text` when `alert_visible` is true.

---

## Field Notes

**PM2.5 uses the compensated value**, matching Home Assistant (see Data Source). `pm02Compensated` (humidity-corrected) is used for `pm25_ugm3`
rather than the raw `pm02` field. This is a deliberate choice, not obvious from the field
name alone, so keep a note next to the fetch script itself so it isn't silently reversed.
The advisor thresholds (PM2.5 9 ug/m3 trigger, 6 release) were tuned against Home Assistant's
values, so the engine must feed it the same variant HA shows.

**Temperature and humidity use the compensated fields** (`atmpCompensated`,
`rhumCompensated`), matching the HA entities.

**CO2, VOC and NOx are floored to whole numbers** at fetch time, matching the integer style
used elsewhere in OSA's tables (SYS, NET) rather than carrying decimal precision the display
doesn't use.

**Temperature is converted to Fahrenheit** at fetch time (device reports Celsius natively).
Conversion belongs in the engine, not in OSA's Lua, consistent with "the engine gathers
knowledge".

**Dew point is computed in the engine** (Magnus formula, from temperature and humidity),
with the same constants used in the advisor doc. Dew point, not relative humidity, is what
compares indoors to outdoors, because the AC cools and dehumidifies the room and RH moves
with it.

**VOC and NOx are relative indices.** The device normalizes them against a baseline it
learns over about 120 hours, so an absolute VOC level drifts and is a poor alert trigger on
its own. Over the first week of data, VOC sat at 150 or above for 41% of the time. The
advisor therefore treats VOC 150 to 249 as an annotation only and 250 or above as a trigger
(see the advisor doc).

**Polling vs. the history data.** Home Assistant's one-minute history is smoother than a
direct 30 to 60 second poll of the device (raw PM in particular moves second to second). The
replay validates the logic, not the noise; the shadow week is what checks the filters against
the engine's own samples.

---

## Ventilation Advisor (engine-side)

Computes a verdict from indoor readings plus outdoor data, with hysteresis, a dwell time
and a short sustain filter. Full rules, thresholds, reference code and the acceptance test are in
`ventilation-advisor-design.md`; this section records only how it fits the provider.

- **Verdicts:** `OPEN`, `BRIEF`, `CLOSE`, `NEUTRAL`.
- **Inputs:** indoor CO2, PM2.5, VOC, humidity, temperature, dew point from this provider; outdoor
  from the existing ENV providers: `shared/air/<air_profile>/current.json` (`airnow.aqi`,
  `airnow.values.pm2_5`/`pm10`, falling back to `selected.pm2_5`/`pm10`) and
  `shared/weather/<weather_profile>/current.json` (`temp_f`, `humidity_pct`). Outdoor PM from
  AirNow stations drives every PM rule; the hazard rule also trips on OpenWeather's modelled PM
  (either source), so an older station reading cannot mask a current spike.
  Each outdoor input has its own freshness flag, and a stale one switches off only the rules that
  need it.
- **Time-based, not sample-based.** The sustain filter is the minimum over the last 180 seconds,
  the dwell is 600 seconds, and the 30-minute dew point lookback is interpolated at exactly
  `t - 1800 s`. Do not copy "3 samples" literally; the exact definitions are in the advisor
  document because the acceptance test is sensitive to them.
- **State between polls.** History, latch flags, the current verdict and the alert clock persist in
  `runtime/airgradient/{profile}/advisor_state.json` (engine-private, not under `shared/`, matching
  the alerts provider's `runtime/alerts/` state), written atomically. If the file is missing or
  corrupt the advisor starts as `NEUTRAL`. All times are epoch seconds; a local-time datetime would
  break at the DST change on 2026-11-01.
- **One writer.** Refresh loops are started per launching suite, so two suites running the domain
  means two writers. A run takes an exclusive `flock` on the state file's lock, re-checks the cache
  age after acquiring it and exits if the cache is fresh, and the advisor ignores any reading not
  newer than the last one it processed.
- **Never advise on bad data.** If the fetch is `degraded`, the advisor is not stepped: the verdict
  is held and OSA shows `AG STALE` once the reading is 3 minutes old. After an outage longer than
  10 minutes the history windows are cleared rather than bridged.
- **Indoor humidity with outdoor data.** Humid indoors and outdoor air clearly drier (dew point 2 F
  or more lower) is `OPEN` (the morning-shower case); humid indoors and outdoor air not drier, or
  unknown, is `CLOSE`. On 2026-10-07 showers between 06:00 and 09:00 produced both humidity
  episodes (bathroom door faces the sensor, bathroom exhaust fan inoperable), which look the same as
  humid outdoor air to an indoor-only replay.
- **No input logging.** Window position (4 windows, 1 to 90 degrees), ceiling fan speed
  (3 speeds), wind direction and bathroom fan state are deliberately not tracked. The
  advisor responds to measured outcomes (CO2/VOC decay, humidity, PM), not to settings.

### Validation

A week of Home Assistant history (2026-10-01 00:00 to 10-07 19:59, 9,840 one-minute samples)
is the replay fixture: `tests/airgradient/fixtures/week_1min.csv`, with the expected published
verdict changes in `tests/airgradient/fixtures/expected_verdict_changes.csv` (the original
workbook is `AirGradient_week_2026-10-01_to_10-07.xlsx`, sheets `Data_1min` and `Advisor_Replay`).
A replay through the reference `Advisor` class (indoor-only, 600-second dwell, 180-second sustain)
produces 18 verdict changes (469 minutes `OPEN`, 294 `CLOSE`, 9,077 `NEUTRAL`). The engine's
implementation must reproduce those transitions in time, verdict and reason text when fed the same
data at one-minute intervals; that replay is the acceptance test, together with the synthetic cases
listed in the advisor document. If the engine polls every 30 to 60 seconds it uses the same time
windows and the replay still steps one minute at a time.

---

## Display (OSA ENV panel)

### Indoor view

The POLLUTION table (7 rows) switches to an indoor table with the same 7 rows, same
column layout, same (V) column. Pollen and the AQI bars do not change.

| Row | Label | Shown value |
| --- | --- | --- |
| 1 | CARBON DIOXIDE | ppm divided by 10, label `(PPM X10)` |
| 2 | PARTICULATE MATTER 2.5 | ug/m3 |
| 3 | PARTICULATE MATTER 10 | ug/m3 |
| 4 | PARTICULATE MATTER 1 | ug/m3 |
| 5 | PARTICULATE MATTER 0.3 | particles/dL divided by 10, label `(X10/DL)` |
| 6 | VOC INDEX | index, 0 to 500 |
| 7 | NOX INDEX | index, 0 to 500 |

Header reads `INDOOR // <LABEL> (V)` in place of `POLLUTION (V)`, or `INDOOR (V)` when the profile has
no `label`. The SRC line reads `SRC // AG <LABEL>` (or `SRC // AG`) during the indoor phase. A null
value (for instance PM0.3 on firmware older than 3.7.0, or a carried field past its maximum age)
shows as dashes in its row.

**Fixed scaling, never switching.** The (V) column is three digits wide. CO2 and PM0.3
routinely exceed 999 (CO2 1,150 ppm; PM0.3 1,856 to 3,389 particles/dL during vacuuming).
Clamping at 999 would show a wrong number, and switching format by magnitude would be
confusing, so those two rows are always shown at a fixed divide-by-10 scale with the scale
stated in the label: 482 ppm shows `048`, 1,150 ppm shows `115`; 500 particles/dL shows
`050`, 3,389 shows `339`. Three digits cover up to 9,990, well beyond anything this sensor
reports here. CO2 accuracy is about plus or minus 50 ppm, so the lost last digit carries no
information. The alert line shows the true unscaled value with its unit.

Temperature and humidity do not fit the table and are not shown in it (the advisor uses
them). Widening the (V) column to four characters during the indoor phase was considered
and set aside because it changes panel alignment.

### Rotation

- Outdoor view and indoor view alternate on the clock (time modulo cycle), so no stored
  state is needed.
- Default: 15 seconds outdoor, 15 seconds indoor.
- While an alert is visible: 10 seconds outdoor, 20 seconds indoor.
- If the AirGradient provider is `disabled`, or `degraded` and stale, the panel stays on the
  outdoor view.

### Alert line

The alert replaces `NOMINAL` on the `DATA //` line and is independent of the rotation (it
shows in both views). There are about 37 characters in the line, so the alert text after
the `DATA //` prefix is limited to 29 characters. Built by the engine into `alert_text`; the complete table,
including which conditions have no text, is in the advisor document. Examples:

| Verdict | Example text |
| --- | --- |
| `OPEN` | `OPEN WIN // CO2 1150 PPM`, `OPEN WIN // VOC 263`, `OPEN WIN // HUMID, DRIER OUT` |
| `BRIEF` | `BRIEF OPEN // CO2 1700 PPM` |
| `CLOSE` (hazard) | `CLOSE WIN // OUTDOOR AIR` |
| `CLOSE` (indoor humidity) | `CLOSE WIN // HUMID INSIDE` |
| stale | `AG STALE` (built by OSA from `generated_at`, not by the engine) |

`NOMINAL` returns when no alert is visible. Conditions that only compute an advisory `CLOSE` (outdoor
too hot, cold or humid, or dusty by AirNow, with good indoor air) have no text and never show.

Humidity alerts name the dew point condition in words and carry no temperature or humidity
numbers: the dew point is what the advisor compares, and the words say which side is wetter
(`HUMID INSIDE`, `DRIER OUT`). Numbers appear only where they fit and mean
something on their own (CO2 ppm, VOC index). All texts stay within 29 characters.

### Alert visibility

Tied to the condition, not a timer, with a cap:

- An alert stays visible while its verdict holds, and clears when the verdict returns to
  `NEUTRAL` (the advisor's hysteresis and 10-minute dwell prevent flapping).
- Each alert is capped at 60 minutes. After that `alert_visible` goes false and the line
  returns to `NOMINAL` unless the verdict changes or severity escalates from `normal` to `severe`,
  which starts a new 60 minutes. Reason: the longest VOC episode in the week ran 4.5 hours, and a
  banner that long becomes wallpaper.
- Conky takes no input, so there is no acknowledge control; the cap is the substitute.

---

## Design Decisions Carried Over from SitRep

- **Cache TTL before fetch.** Same as the pfSense provider's cache-fresh check. Polling
  every 30 to 60 seconds is plenty (matches Home Assistant's own local-polling cadence for
  this integration); there is no reason to hit the device on every Conky/SitRep refresh.
- **Atomic write via `os.replace()`.** Same pattern as `fetch_pfsense.sh`; avoids a partial
  JSON read mid-write. Applies to `advisor_state.json` too.
- **Raw values plus classification.** Raw readings stay in the file; the classified verdict
  sits beside them in `ventilation`, the same way `PIA: HEALTHY` is a classified verdict
  alongside the raw `connectionstate` field in the VPN provider.

---

## Wiring Checklist

Core (`gtex62-core`):

1. `providers/airgradient/fetch_airgradient.sh` (wrapper) and the Python module behind it; the
   advisor as its own importable module so tests can load it without the HTTP code.
2. `examples/runtime/profiles/airgradient/indoor.toml.example`, then re-run
   `bin/gtex62-core-bootstrap-runtime` (the Bootstrap Gap: a missing profile TOML falls back to a
   60-second TTL).
3. Launcher (`bin/gtex62-core-launch`): parse the `airgradient` profile and its TOML path, TTL,
   stamp and pid file, add the cache dir to the `mkdir` list, add `initial_refresh` and
   `refresh_loop` entries, and pass the suite's air and weather profiles as arguments (the
   `alerts` entry is the pattern for cross-domain reads).
4. **Dual-gated like vpn**: `core.toml` `[providers] airgradient` (default false) plus the suite
   listing `airgradient` in its `[domains]`, so installs without the device never start it. Update
   the dual-gated list in the `core.toml.example` comment and in `README.md` § Provider Toggles.
5. Suite binding templates: `airgradient = "indoor"` under `[profiles]` and the domain in the
   `[domains]` list of `examples/runtime/suites/osa.toml.example`.
6. Doctor: deferred until the provider and OSA are running. Then add a row for the new domain (the
   table is alphabetical and counts domains, so 21 becomes 22) and update `doctor-design.md` and
   `doctor-missing-conditions.md`; the row must read `state` as well as cache age, since a degraded
   run rewrites the file.
7. Docs: `architecture.md` (directory list, cache list, TTL table), `README.md` domain count and
   the "designed but not built" note, `docs/README.md` index, and a `CHANGELOG.md` entry.
8. Tests under `tests/airgradient/`: the fixtures are already there; add the replay test, the
   synthetic table, the persistence round-trip, partial-payload and gap cases.

OSA (`gtex62-osa`, separate repo and commit): `lua/suite/` reader for the new cache, the indoor
table and header in `lua/ui/frame.lua`, the clock-based rotation, the alert on the `DATA //` line
(currently `NOMINAL`, `PARTIAL`, `STALE`, `FAULT` in `env.lua`'s `data_status()`), and the
`AG STALE` check.

---

## Rollout

1. **Shadow mode** (`advisor.shadow = true`). Provider and advisor run live and write
   `status.json`; OSA shows no alert. Two files are kept under
   `runtime/airgradient/{profile}/` (not the cache: they cannot be regenerated):
   - `verdict_log.txt`: one line per verdict change or escalation, with time, verdict, class,
     reason and the outdoor flags;
   - `inputs.csv`: one line per minute with every input the advisor saw (indoor readings, outdoor
     AQI, PM2.5 and PM10 with `pm_source`, outdoor temperature and humidity, pollen values, the
     verdict, and whether the device response was complete), rotated daily and kept 60 days
     (about 13 MB). This is what lets the next replay include outdoor data, which the first week
     lacked.

   Run about a week, spanning the DST change on 2026-11-01, and compare the log to what you would
   have wanted. This is where tuning happens: the VOC 250 line, the humidity thresholds, and the
   outdoor-data rules, which the historical week could not exercise.
2. **Show it.** Set `shadow = false`; enable the indoor view, rotation and alert line in OSA.
3. **Optional notification** on verdict changes only.

Optionally record "opened" or "ignored" when you act on an alert; it is the cheapest way to
judge whether the advice is useful.

---

## Known Constraints

**Single-device assumption.** The schema above assumes one AirGradient per profile. If a
second unit is added (e.g. an outdoor Open Air model), `profile` (e.g. `"outdoor"` vs.
`"indoor"`) is the axis to split on, consistent with how `main_router` scopes the pfSense
provider today. A second unit would also make the advisor's outdoor input measured instead
of borrowed.

**No SSH gate equivalent.** Unlike the SSH-based providers, there is currently no
trip/backoff state machine for extended device unreachability (VLAN issue, power loss, AP
reboot). For a single low-frequency HTTP poll this is likely unnecessary complexity, but
it is noted here as a conscious "not needed yet" rather than an oversight. A failed fetch costs
at most the timeout once per TTL.

**VOC/NOx learning offset is device-side, not engine-side.** The 120-hour learning window
is configured directly on the device and applied before the API returns
`tvocIndex`/`noxIndex`. The engine has no visibility into or control over it. If the
offset is changed later, no provider-side change is required, though the advisor's VOC
thresholds may need re-tuning.

**Only one room.** The sensor sits on a Metro shelf about 4 to 5 ft up and 4 to 5 ft from the
back wall, in a room with four south-facing windows and no other windows. Readings near the
sensor (vacuuming, showers from the bathroom door across from it) can exceed the room
average, so short spikes are filtered rather than treated as room conditions.

**Outdoor air is borrowed.** Outdoor PM comes from AirNow monitoring stations within the air
profile's search radius (hourly, with publication lag) or, failing that, from OpenWeather's model,
and may lag either way. No outdoor temperature or humidity was logged for the validation week, so
the outdoor comfort-band and dew-point rules are untested on real data.

**AirNow overlay.** Until 2026-10-07 the air provider's `airnow.values` was usually empty: AirNow's
newest one to two hours of rows carry `RawConcentration = -999.0` (missing) and `fetch_air.sh` took it
instead of the populated `Value`, so the freshest hour was dropped and the rest failed the 3600 s
`max_age_sec`. Fixed the same day (sentinel treated as missing; example profile sets
`max_age_sec = 7200`); details in `env-provider-status.md` and `CHANGELOG.md`. Profiles installed
before then need `max_age_sec = 7200` added. Residual limits: readings are hourly and can be up to
2 hours old, and the provider keeps the first-listed station per pollutant rather than the nearest.

---

## Open Items

- Air provider: pick the nearest station (or average) per pollutant instead of the first listed
  (see Known Constraints).
- Re-check thresholds after a few weeks of shadow mode, and in a different season, using
  `inputs.csv` for a replay that includes the outdoor rules.
- Explain or accept the two long VOC episodes (2026-10-01 evening, peak 475; 2026-10-04
  evening, peak 310). If they match a real activity the trigger is right; if not, the 250
  line may need to rise, or VOC may need a release threshold near 200.
- Re-evaluate the humidity thresholds after the bathroom exhaust fan is repaired; the
  morning-shower episodes should shrink.
- Whether the doctor row should show the advisor verdict, or only provider health.
- Lua-side panel implementation (indoor table, rotation, alert line).
