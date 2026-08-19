# AirGradient Engine Integration

Bringing AirGradient ONE indoor air quality data into the core engine as a new provider,
for display in OSA's ENV panel (and potentially other suites) alongside the existing
outdoor/OWM-sourced ENV data.

---

## Purpose

The AirGradient ONE (indoor air quality monitor: CO2, VOC index, NOx index, PM1/2.5/10,
temperature, humidity) is now on the IoT VLAN with a static reservation and integrated
locally into Home Assistant. This document captures the plan to bring the same data into
the Conky engine/suite ecosystem, following the same collector/engine/display separation
established during the SitRep migration.

---

## Core Principle

> **The engine gathers knowledge. OSA reports status.**

Same principle as SitRep. OSA's ENV panel should not know how to fetch or parse AirGradient
data — it asks the engine for current readings and displays what it receives. All HTTP
polling, field selection, and any future classification (e.g. "is this CO2 level a
concern?") lives in the engine's `airgradient` provider.

---

## Data Source

Unlike the SSH-based providers (pfSense, Zyxel APs), AirGradient exposes a local HTTP API
directly on the device — no SSH session, no gate/backoff state machine required. Confirmed
live against the deployed unit:

```
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

Device: I-9PSL, serial `3cdc75bcc200`, firmware `3.6.2`, static IP `192.168.20.19` (IoT
VLAN). VOC/NOx index learning offset set to 120 hours on-device (adjustable locally via
the AirGradient integration's Configuration entities in Home Assistant; not required for
the engine fetch, since the device applies the learning window before exposing the index
values via the API).

---

## Future Architecture

```
AirGradient ONE local API (192.168.20.19:80/measures/current)
                    │
              engine poll (curl, no SSH)
                    │
              atomic JSON write
                    │
        shared/airgradient/{profile}/status.json
                    │
                 OSA ENV panel (display only)
```

No SSH gate equivalent is implemented for this provider — see Known Constraints.

---

## status.json Schema (Proposed)

`shared/airgradient/{profile}/status.json` — written by `fetch_airgradient.sh`.

```json
{
  "state": "ok",
  "profile": "living_room",
  "collector": "airgradient",
  "generated_at": "2026-07-01T14:23:00Z",
  "device": {
    "ip": "192.168.20.19",
    "serialno": "3cdc75bcc200",
    "model": "I-9PSL",
    "firmware": "3.6.2"
  },
  "co2_ppm": 695,
  "voc_index": 100,
  "nox_index": 1,
  "pm": {
    "pm1_ugm3": 2.17,
    "pm25_ugm3": 2.2,
    "pm10_ugm3": 2.5
  },
  "temp_f": 78.6,
  "humidity_pct": 56.35,
  "wifi_rssi": -67
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

---

## Field Notes

**PM2.5 uses the compensated value.** `pm02Compensated` (humidity-corrected) is used for
`pm25_ugm3` rather than the raw `pm02` field. This is a deliberate choice, not obvious
from the field name alone — worth keeping this note next to the fetch script itself so
it isn't silently reversed later.

**CO2, VOC, and NOx are floored to whole numbers** at fetch time, matching the integer
style used elsewhere in OSA's tables (SYS, NET) rather than carrying decimal precision
the display doesn't use.

**Temperature is converted to Fahrenheit** at fetch time (device reports Celsius natively
via `atmpCompensated`). Conversion belongs in the engine, not in OSA's Lua, consistent
with "the engine gathers knowledge" — OSA should not need to know the source unit.

---

## Design Decisions Carried Over from SitRep

- **Cache TTL before fetch** — same as the pfSense provider's cache-fresh check. Polling
  every 30–60 seconds is plenty (matches Home Assistant's own local-polling cadence for
  this integration); there is no reason to hit the device on every Conky/SitRep refresh
  cycle.
- **Atomic write via `os.replace()`** — same pattern as `fetch_pfsense.sh`, avoids a
  partial-JSON read mid-write.
- **Raw values now, classification later** — CO2/VOC "is this a concern?" thresholds
  belong in a future engine classification layer, not hardcoded in OSA's Lua. A
  `co2_class: "normal"|"elevated"|"poor"` field could be added the same way `PIA: HEALTHY`
  is a classified verdict alongside the raw `connectionstate` field in the VPN provider.

---

## Known Constraints

**Single-device assumption.** The schema above assumes one AirGradient per profile. If a
second unit is added (e.g. an outdoor Open Air model), `profile` (e.g. `"outdoor"` vs.
`"living_room"`) is the axis to split on — consistent with how `main_router` scopes the
pfSense provider today.

**No SSH gate equivalent.** Unlike the SSH-based providers, there is currently no
trip/backoff state machine for extended device unreachability (VLAN issue, power loss, AP
reboot). For a single low-frequency HTTP poll this is likely unnecessary complexity, but
is noted here as a conscious "not needed yet" rather than an oversight, in case this
document is revisited after a second AirGradient device or a different polling pattern is
introduced.

**VOC/NOx learning offset is device-side, not engine-side.** The 120-hour learning window
is configured directly on the device (via Home Assistant's local Configuration entities)
and applied before the API returns `tvocIndex`/`noxIndex`. The engine has no visibility
into or control over this setting — it only reads the resulting index value. If the
learning offset is changed later, no provider-side change is required.

---

## Open Items

- **OSA ENV panel toggle mechanism** — not yet decided (keybind vs. auto-cycle vs. split
  panel showing outdoor/indoor simultaneously). Field mapping between the two data shapes
  (6 outdoor pollutant gases vs. 4 indoor CO2/VOC/NOx/PM metrics) does not line up 1:1;
  current plan is two differently-shaped tables swapped wholesale, same as CLOCK's REL
  mode swaps the column rather than relabeling in place.
- **Lua-side panel implementation** — pending the above decision.
