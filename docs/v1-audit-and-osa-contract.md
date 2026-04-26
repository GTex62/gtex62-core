# Conky Engine V1 Audit And OSA Contract

## Purpose

This document captures the discussion and audit results for the next-generation engine-driven Conky architecture.

It is intended as a planning reference for:

- engine v1 scope
- `gtex62-osa` as the first native engine suite
- future native rebuilds of legacy suites

Legacy suites remain unchanged for now:

- `gtex62-clean-suite`
- `gtex62-lcars`
- `gtex62-tech-hud`
- `gtex62-tri-hud`

The first native engine suite will be:

- `gtex62-osa`

---

## Core Rule

Engine defines how things work.

Suite defines how things look and where they go.

More specifically:

- Engine owns fetch, normalization, fallback/arbitration, cache layout, path resolution, runtime, launcher behavior, and shared diagnostics.
- Suite owns layout, palette, widget composition, panel shaping, compact view models, and art direction.

The engine should be an operating substrate, not a UI framework.

---

## Legacy Audit Summary

### Overall Result

After auditing `gtex62-lcars`, `gtex62-tri-hud`, `gtex62-tech-hud`, and `gtex62-clean-suite`, the engine v1 scope is stable.

The audits showed that the same core data domains recur across suites, but the current cache names, config placement, and suite-local fetch/display coupling need to be reorganized.

### What The Audits Confirmed

The following domains are clearly shared enough to belong in engine v1:

- `system`
- `time`
- `calendar`
- `astro`
- `weather`
- `aviation`
- `air`
- `solar`
- `network`
- `connectivity`
- `pfsense`
- basic `doctor`

The following domains are real, but should be deferred until after engine v1 and `gtex62-osa`:

- `ap`
- `pollen`
- `music`
- `lyrics`

The following are suite-specific and should remain outside the engine:

- `notes`
- chassis geometry
- widget composition
- panel-ready display shims
- art direction
- theme-specific abbreviations and glyph choices

---

## Per-Suite Conclusions

### `gtex62-lcars`

Strongest proof of:

- `system`
- `weather`
- `air`
- `network`
- `connectivity`
- `pfsense`
- `aviation`
- `solar`

Important lesson:

- LCARS already has engine-like domain coverage, but cache naming and provider behavior are still suite-shaped.

### `gtex62-tri-hud`

Strongest proof of:

- `calendar`
- `astro`
- `doctor`
- optional `ap`
- optional `pollen`

Important lesson:

- Tri-HUD strongly validates `calendar` and `astro` as first-class engine domains rather than widget-local tricks.

### `gtex62-tech-hud`

Strongest proof of:

- multi-widget launch flexibility
- shared diagnostics value
- future `music` and `lyrics` domains

Important lesson:

- The engine must support single-conf, dual-conf, and multi-widget suites without enforcing one layout model.

### `gtex62-clean-suite`

Strongest proof of:

- early shared `weather`
- early shared `aviation`
- early shared `network`
- early shared `pfsense`
- early `astro`/weather-arc logic

Important lesson:

- Clean Suite contains many of the ancestral shared domains, but in a first-generation, widget-local form. It is evidence for engine domains, not a template for engine structure.

---

## Engine V1 Domain List

### 1. `system`

Normalized machine and OS snapshot.

Includes:

- hostname
- OS / kernel
- uptime
- CPU model / usage / temps
- RAM usage
- GPU usage / VRAM / temp / power when available
- disks / filesystems
- motherboard / BIOS where available

### 2. `time`

Shared clock and timezone data.

Includes:

- local current time
- UTC
- named timezones / offsets
- timezone labels

### 3. `calendar`

Shared date/event/seasonal timing data.

Includes:

- current date window
- event cache
- seasonal boundaries
- DST start/end

Presentation such as rings, linear strips, marquees, and event stacks remains suite-specific.

### 4. `astro`

Shared astronomical state for suites.

Includes:

- sun
- moon
- planets
- rise/set values
- position/angle state
- visible-horizon or line/ring-friendly state
- terminator-supporting data when needed

Rendering of globes, rings, lines, or tactical tables remains suite-specific.

### 5. `weather`

Shared weather provider and normalized outputs.

Includes:

- current conditions
- daily forecast
- hourly forecast if needed
- location metadata
- provider status

### 6. `aviation`

Shared aviation weather and text/raw cache.

Includes:

- METAR
- TAF
- advisories when enabled
- normalized station data for station-model consumers

### 7. `air`

Shared multi-source air-quality domain.

Baseline:

- OpenWeather

Overlay/fallback enhancement:

- AirNow

Selection rule:

- OWM provides baseline completeness
- AirNow overlays fresher or better pollutant values where valid
- OWM remains fallback when AirNow is missing, stale, partial, or rate-limited

### 8. `solar`

Shared derived solar/radiation-like values where you want those exposed independently from core weather.

This may later be folded partly into `weather` or `astro`, but for v1 it is acceptable as its own normalized output because the existing suites already treat it as a reusable layer.

### 9. `network`

Shared local network state.

Includes:

- interface status
- LAN address
- DNS
- subnet
- gateway
- VLAN host status when configured
- WAN/public IP support where available

### 10. `connectivity`

Shared probe and snapshot domain.

Includes:

- ping targets
- reachability
- probe timing
- speedtest snapshots

### 11. `pfsense`

Shared router/firewall telemetry domain.

Includes:

- fetch status
- SSH gate status
- interface counters
- logical interface names such as `wan`, `home`, `iot`, `guest`, `infra`, `cam`

### 12. `doctor`

Shared diagnostics layer.

Engine doctor should validate:

- dependencies
- config presence
- cache freshness
- provider health
- optional SSH target availability

Suites may extend doctor with suite-specific checks.

---

## Engine V1 Directory Model

Recommended XDG-style layout:

- `~/.config/gtex62-conky/`
- `~/.local/share/gtex62-conky/`
- `~/.cache/gtex62-conky/`

Meaning:

- `.config` = user configuration, profiles, and suite registration
- `.local/share` = persistent shared assets
- `.cache` = regeneratable raw, normalized, derived, and runtime state

Recommended cache structure:

```text
~/.cache/gtex62-conky/

shared/
  weather/
  aviation/
  air/
  solar/
  astro/
  calendar/
  system/
  network/
  connectivity/
  pfsense/

suites/
  osa/

runtime/
  locks/
  pids/
  stamps/

tmp/
```

Important rule:

- shared cache should be keyed by profile, not by suite

Example:

- `shared/weather/home/current.json`
- not `osa-weather/current.json`

---

## Shared Schema Direction

Shared contracts should be small, durable, and truth-oriented.

They should use:

- JSON
- explicit units
- explicit timestamps
- provider status
- provenance where merged values matter

They should avoid:

- suite-formatted rows
- vars files as shared interfaces
- widget-ready text output
- theme-driven provider behavior

### Examples

Weather:

- `shared/weather/<profile>/current.json`
- `shared/weather/<profile>/forecast_daily.json`
- `shared/weather/<profile>/status.json`

Air:

- `shared/air/<profile>/current.json`
- `shared/air/<profile>/status.json`

pfSense:

- `shared/pfsense/<profile>/status.json`
- `shared/pfsense/<profile>/interfaces.json`

Calendar:

- `shared/calendar/<profile>/events.json`
- `shared/calendar/<profile>/seasonal.json`
- `shared/calendar/<profile>/status.json`

Astro:

- `shared/astro/<profile>/ephemeris.json`
- `shared/astro/<profile>/sun_moon.json`
- `shared/astro/<profile>/status.json`

---

## Naming Direction

Use domain names, not script names.

Good:

- `weather/current.json`
- `weather/forecast_daily.json`
- `air/current.json`
- `network/status.json`
- `pfsense/interfaces.json`

Bad:

- `owm_current.json`
- `owm_days.vars`
- `sky.vars`
- `pfsense_current.json`

Raw/source-specific outputs may still use provider names inside a `raw/` layer, but shared normalized outputs should not expose legacy script naming as the public contract.

---

## What Must Stay Out Of The Engine

Do not let these become engine responsibilities:

- LCARS scaffold geometry
- OSA tactical table layout
- Tech-HUD rings and marquees
- Tri-HUD chassis logic
- notes widgets
- panel-ready display shims
- glyph mapping tied to a suite’s style
- font-specific presentation shaping

The engine should provide truth and runtime support.

Suites should provide visual interpretation.

---

## `gtex62-osa` Role

`gtex62-osa` is not a migration target.

It is the first native engine suite and the reference implementation for the contract.

That means `gtex62-osa` should prove:

- engine install and suite install separation
- suite discovery and manifest handling
- engine/suite version compatibility
- XDG path resolution
- shared collector/provider ownership
- normalized domain consumption
- suite-derived cache layering where needed

It should not try to prove legacy compatibility.

---

## `gtex62-osa` Data Needs

Based on the current OSA sketch, the suite needs these domains:

- `system`
- `time`
- `calendar`
- `astro`
- `weather`
- `aviation`
- `air`
- `solar`
- `network`
- `connectivity`
- optional `pollen`

Likely panel mapping:

- `SYS` -> `system`
- `TME` -> `time`, `calendar`
- `ORB` -> `astro`
- `WXR` -> `weather`, `aviation`
- `NET` -> `network`, `connectivity`, `pfsense`
- `ENV` -> `air`, `solar`, optional `pollen`

Important rule:

- OSA should consume normalized shared files and then build compact OSA-specific summaries under suite cache if needed.

Example:

```text
~/.cache/gtex62-conky/suites/osa/
  sys/
  tme/
  orb/
  wxr/
  net/
  env/
```

These suite caches may contain panel-oriented compact row models, but they should not replace shared normalized truth.

---

## `gtex62-osa` Manifest Direction

Recommended suite manifest responsibilities:

- suite identity
- suite version
- engine requirement
- declared Conky instances
- required shared domains
- profile bindings
- optional suite-derived cache namespaces
- defaults for launcher/theme options

Illustrative shape:

```yaml
suite_id: osa
name: gtex62-osa
version: 0.1.0
engine_requirement: ">=1.0,<2.0"

profiles:
  weather: home
  air: home
  calendar: local
  astro: home
  network: local
  pfsense: main_router

domains:
  required:
    - system
    - time
    - calendar
    - astro
    - weather
    - aviation
    - air
    - solar
    - network
    - connectivity
  optional:
    - pollen

launch:
  conky_instances:
    - widgets/osa-main.conky.conf

suite_cache:
  namespaces:
    - sys
    - tme
    - orb
    - wxr
    - net
    - env
```

This is only a design shape, not a locked syntax.

---

## Recommended Build Sequence

### Phase 1

Define engine path layer, manifest contract, and domain list.

### Phase 2

Implement shared provider/config model for:

- `weather`
- `air`
- `network`
- `pfsense`
- `calendar`
- `astro`

### Phase 3

Implement shared normalized schemas and cache layout.

### Phase 4

Build `gtex62-osa` as the first native engine suite.

### Phase 5

Validate real-world use and tighten contracts.

### Phase 6

Choose whether each legacy suite is:

- left standalone permanently
- partially reinterpreted
- rebuilt natively against the engine

Preferred long-term direction:

- rebuild legacy suites natively when their turn comes

---

## Recommended Rebuild Philosophy For Legacy Suites

When the time comes, do not port legacy suites file-for-file.

Instead:

1. inventory their domains and solved edge cases
2. preserve proven behavior
3. improve naming, cache layout, and module boundaries
4. rebuild the suite presentation natively against the engine contract

Acceptance target for each future rebuild:

- same useful data coverage
- same or better resilience
- better naming
- better cache organization
- less duplication
- no leakage of legacy folder politics into engine design

---

## Bottom Line

The audit supports a clean next-generation direction:

- legacy suites remain legacy for now
- `gtex62-osa` becomes the first native engine suite
- engine v1 focuses on shared truth domains and runtime support
- future native rebuilds reuse the engine but do not drag legacy structure into it

This gives you the benefits of the past work without freezing the future architecture around it.
