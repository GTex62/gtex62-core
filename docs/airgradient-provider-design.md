# AirGradient Engine Integration

Bringing AirGradient ONE indoor air quality data into the core engine as a new provider,
for display in OSA's ENV panel (and potentially other suites) alongside the existing
outdoor/OWM-sourced ENV data, plus an engine-side ventilation advisor that turns the
readings into an "open windows / close windows" verdict.

Revision 2 (2026-10-07). Status: **design only, not implemented.** Companion document:
`ventilation-advisor-design.md` (rules, thresholds, reference code and the week-long replay).
This revision adds the advisor, the 7-channel indoor view, the rotation and alert behavior,
and the field-level decisions from a week of real data (2026-10-01 to 10-07).

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
VLAN). VOC/NOx index learning offset is set to 120 hours on-device (adjustable locally via
the AirGradient integration's Configuration entities in Home Assistant; not required for
the engine fetch, since the device applies the learning window before exposing the index
values via the API).

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

---

## Architecture

```text
AirGradient ONE local API (192.168.20.19:80/measures/current)
                    │
              engine poll (curl, no SSH)
                    │
        ┌───────────┴────────────┐
   readings + scaling      ventilation advisor  ◄── outdoor data (existing ENV providers)
        │                        │                     advisor_state.json (history, latch)
        └───────────┬────────────┘
              atomic JSON write
                    │
        shared/airgradient/{profile}/status.json
                    │
                 OSA ENV panel (display only)
```

No SSH gate equivalent is implemented for this provider; see Known Constraints.

Profile name for this unit: `cave` (matches the Home Assistant entity names,
`sensor.cave_airgradient_cave_*`).

---

## status.json Schema (Proposed)

`shared/airgradient/{profile}/status.json`, written by `fetch_airgradient.sh` (or its
Python successor). Field names ending in a unit carry that unit.

```json
{
  "state": "ok",
  "profile": "cave",
  "collector": "airgradient",
  "generated_at": "2026-10-07T14:23:00Z",
  "device": {
    "ip": "192.168.20.19",
    "serialno": "3cdc75bcc200",
    "model": "I-9PSL",
    "firmware": "3.7.0"
  },
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
    "reason": "Fine either way",
    "since": "2026-10-07T13:02:00Z",
    "alert_visible": false,
    "alert_text": "",
    "alert_expires_at": null,
    "annotations": [],
    "outdoor": { "used": true, "stale": false }
  }
}
```

### state field values

| Value | Meaning |
| --- | --- |
| `"ok"` | HTTP fetch succeeded, all fields populated |
| `"degraded"` | Fetch failed/timed out; fields hold last-known-good values |
| `"disabled"` | Profile has `enabled = false` in TOML |

Matches the pfSense provider's three-value convention, so SitRep/OSA can reuse the same
staleness-indicator display logic across providers without special-casing AirGradient.

OSA also checks `generated_at`: if the reading is older than 3 minutes, the alert line shows
`AG STALE` instead of any advice (see Display), regardless of `state`.

### ventilation fields

| Field | Meaning |
| --- | --- |
| `verdict` | `OPEN`, `BRIEF` (open briefly), `CLOSE` or `NEUTRAL` |
| `severity` | `normal` or `severe` (severe is what produces `BRIEF`) |
| `reason` | Human-readable reason, same text as in the advisor doc |
| `since` | When the current verdict began (after the dwell filter) |
| `alert_visible` | True while the alert should be on screen (see Alert visibility) |
| `alert_text` | Pre-built string, 29 characters or fewer, e.g. `OPEN WIN // CO2 1150 PPM`; empty when not visible |
| `alert_expires_at` | When the 60-minute display cap ends this alert, or null |
| `annotations` | Informational notes that never trigger an alert, e.g. `VOC 180 (relative)` |
| `outdoor` | Whether outdoor data was used, and whether it was stale |

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

---

## Ventilation Advisor (engine-side)

Computes a verdict from indoor readings plus outdoor data, with hysteresis, a dwell time
and a short sustain filter. Full rules, thresholds and reference code are in
`ventilation-advisor-design.md`; this section records only how it fits the provider.

- **Verdicts:** `OPEN`, `BRIEF`, `CLOSE`, `NEUTRAL`.
- **Inputs:** indoor CO2, PM2.5, VOC, humidity, temperature, dew point from this provider;
  outdoor PM2.5, PM10, AQI, temperature and dew point from the existing ENV providers
  (AirNow/OpenWeather; exact file paths to confirm when implementing). If outdoor data is
  missing or stale the advisor runs indoor-only and flags `outdoor.stale`.
- **Time-based, not sample-based.** The reference code assumes one-minute samples. With a
  30 to 60 second poll the engine must use time windows: the sustain filter is the minimum
  over the last 3 minutes, and the dwell is 10 minutes. Do not copy "3 samples" literally.
- **State between polls.** History, latch flags and the current verdict persist in
  `shared/airgradient/{profile}/advisor_state.json`, written atomically alongside
  `status.json`. If the file is missing or corrupt the advisor starts as `NEUTRAL`.
- **Never advise on bad data.** If the fetch is `degraded` or the reading is stale, the
  verdict is held (not changed) and OSA shows `AG STALE`.
- **Known limitation: indoor moisture sources.** The humidity trip currently always says
  `CLOSE`. On 2026-10-07 showers between 06:00 and 09:00 produced both humidity episodes
  (bathroom door faces the sensor, bathroom exhaust fan inoperable), which look the same as
  humid outdoor air. Once outdoor dew point is available the rule should become: humid
  indoors and outdoor air not drier means `CLOSE`; humid indoors and outdoor air clearly
  drier (dew point 2 F or more lower) means `OPEN`, with the reason worded as indoor
  humidity. This is a planned change and is **not** in the tested reference code.
- **No input logging.** Window position (4 windows, 1 to 90 degrees), ceiling fan speed
  (3 speeds), wind direction and bathroom fan state are deliberately not tracked. The
  advisor responds to measured outcomes (CO2/VOC decay, humidity, PM), not to settings.

### Validation

A week of Home Assistant history (2026-10-01 00:00 to 10-07 19:59, 9,840 one-minute samples)
is in `AirGradient_week_2026-10-01_to_10-07.xlsx`, sheet `Data_1min`. A replay through the
reference `Advisor` class (indoor-only, 10-minute dwell, 3-minute sustain) produced 18
verdict changes (469 minutes `OPEN`, 294 `CLOSE`, 9,077 `NEUTRAL`). The engine's
implementation should reproduce those transitions when fed the same data, and that replay is
the acceptance test. The list is on the `Advisor_Replay` sheet.

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

Header reads `INDOOR // CAVE (V)` in place of `POLLUTION (V)`. The SRC line reads
`SRC // AG CAVE` during the indoor phase.

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
`DATA // ` is limited to 29 characters. Built by the engine into `alert_text`:

| Verdict | Example text |
| --- | --- |
| `OPEN` | `OPEN WIN // CO2 1150 PPM`, `OPEN WIN // VOC 263` |
| `BRIEF` | `BRIEF OPEN // CO2 1700 PPM` |
| `CLOSE` | `CLOSE WIN // OUTDOOR PM`, `CLOSE WIN // HUMID INSIDE`, `CLOSE WIN // HUMID OUTSIDE` |
| `OPEN` (humidity) | `OPEN WIN // HUMID, DRIER OUT` |
| stale | `AG STALE` (built by OSA from `generated_at`, not by the engine) |

`NOMINAL` returns when no alert is visible.

Humidity alerts name the dew point condition in words and carry no temperature or humidity
numbers: the dew point is what the advisor compares, and the words say which side is wetter
(`HUMID INSIDE`, `HUMID OUTSIDE`, `DRIER OUT`). Numbers appear only where they fit and mean
something on their own (CO2 ppm, VOC index). All texts stay within 29 characters.

### Alert visibility

Tied to the condition, not a timer, with a cap:

- An alert stays visible while its verdict holds, and clears when the verdict returns to
  `NEUTRAL` (the advisor's hysteresis and 10-minute dwell prevent flapping).
- Each alert is capped at 60 minutes. After that `alert_visible` goes false and the line
  returns to `NOMINAL` unless the verdict changes or severity escalates to `BRIEF`, which
  starts a new 60 minutes. Reason: the longest VOC episode in the week ran 4.5 hours, and a
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

## Rollout

1. **Shadow mode.** Provider and advisor run live and write `status.json`; the verdict and
   reason are logged but OSA shows no alert. Run about a week and compare the log to what
   you would have wanted. This is where tuning happens: the VOC 250 line, the humidity
   thresholds, and the outdoor-data rules, which the historical week could not exercise.
2. **Show it.** Enable the indoor view, rotation and alert line.
3. **Optional notification** on verdict changes only.

Optionally record "opened" or "ignored" when you act on an alert; it is the cheapest way to
judge whether the advice is useful.

---

## Known Constraints

**Single-device assumption.** The schema above assumes one AirGradient per profile. If a
second unit is added (e.g. an outdoor Open Air model), `profile` (e.g. `"outdoor"` vs.
`"cave"`) is the axis to split on, consistent with how `main_router` scopes the pfSense
provider today. A second unit would also make the advisor's outdoor input measured instead
of borrowed.

**No SSH gate equivalent.** Unlike the SSH-based providers, there is currently no
trip/backoff state machine for extended device unreachability (VLAN issue, power loss, AP
reboot). For a single low-frequency HTTP poll this is likely unnecessary complexity, but
it is noted here as a conscious "not needed yet" rather than an oversight.

**VOC/NOx learning offset is device-side, not engine-side.** The 120-hour learning window
is configured directly on the device and applied before the API returns
`tvocIndex`/`noxIndex`. The engine has no visibility into or control over it. If the
offset is changed later, no provider-side change is required, though the advisor's VOC
thresholds may need re-tuning.

**Only one room.** The sensor sits on a Metro shelf about 4 to 5 ft up and 4 to 5 ft from the
back wall, in a room with four south-facing windows and no other windows. Readings near the
sensor (vacuuming, showers from the bathroom door across from it) can exceed the room
average, so short spikes are filtered rather than treated as room conditions.

**Outdoor air is borrowed.** Outdoor PM comes from AirNow/OpenWeather stations about 5 miles
away, hourly, and may lag. No outdoor temperature or humidity was logged for the validation
week, so the outdoor comfort-band and dew-point rules are untested on real data.

---

## Open Items

- Confirm exact paths for outdoor PM, temperature and dew point in the existing ENV
  providers.
- Implement the indoor-humidity rule change (see Ventilation Advisor) and add it to the
  replay test.
- Re-check thresholds after a few weeks of shadow mode, and in a different season.
- Explain or accept the two long VOC episodes (2026-10-01 evening, peak 475; 2026-10-04
  evening, peak 310). If they match a real activity the trigger is right; if not, the 250
  line may need to rise.
- Re-evaluate the humidity thresholds after the bathroom exhaust fan is repaired; the
  morning-shower episodes should shrink.
- Lua-side panel implementation (indoor table, rotation, alert line).
