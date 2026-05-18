# gtex62 Core Architecture

## Overview

The gtex62 Conky system is split into two layers:

- **`gtex62-core`** — shared engine, providers, launcher, and data cache
- **Suites** — independent repos (e.g. `gtex62-osa`) for visual identity and layout

Core defines how things work. Suites define how things look.

---

## Repository Layout

Each suite is a separate git repository. Core is its own repo.

```text
~/.config/conky/gtex62-core/     — engine repo
~/.config/conky/gtex62-osa/      — OSA suite repo
~/.config/conky/gtex62-lcars/    — LCARS suite repo (example)
```

Changes to core affect all suites. Commit and push each repo independently.

---

## Core Directory Structure

```text
gtex62-core/
  bin/
    gtex62-core-launch            — main launcher (starts providers + Conky)
    gtex62-core-bootstrap-runtime — installs runtime config from examples/
    gtex62-conky-launch           — Conky wrapper
  providers/
    air/           — AQI and pollution (AirNow + OpenWeather)
    astro/         — astronomical data (moon phase, solar events)
    aviation/      — METAR/TAF weather
    calendar/      — calendar events
    connectivity/  — speedtest snapshots
    github/        — GitHub traffic
    net/           — fast-refresh display cache (ping, VLAN, WAN IP)
    network/       — NIC and interface state
    orb/           — ephemeris (planet/sun/moon positions)
    pfsense/       — pfSense firewall/SSH gate data
    solar/         — UV index and solar radiation
    system/        — CPU, RAM, GPU, storage
    time/          — clock rows (timezone names, times, dates)
    weather/       — current conditions and forecast
  lua/             — shared Lua helpers and runtime modules
  examples/
    runtime/       — installable config templates (.example files)
  docs/            — architecture and provider reference docs
```

---

## Suite Directory Structure

Each suite repo is self-contained:

```text
gtex62-osa/
  conky/           — Conky config files
  lua/
    suite/         — data modules (net.lua, wxr.lua, tme.lua, env.lua, orb.lua, …)
    ui/            — drawing code (frame.lua)
  theme/           — theme and palette files
  scripts/         — suite startup script
  docs/            — suite-specific docs
  CLAUDE.md        — AI session instructions
```

---

## Provider Pattern

Every provider follows the same contract:

```text
providers/<domain>/fetch_<domain>.sh <profile>
  → ~/.cache/gtex62-core/shared/<domain>/<profile>/
```

Profile resolved from: `~/.config/gtex62-core/profiles/<domain>/<profile>.toml`

Suite declares its profiles in: `~/.config/gtex62-core/suites/<suite>.toml`

```toml
[profiles]
net     = "local"
orb     = "home"
weather = "home"
time    = "local"
```

---

## Cache Structure

```text
~/.cache/gtex62-core/
  shared/
    air/           — AQI + pollution cache
    astro/         — astronomical cache
    aviation/      — METAR/TAF cache
    calendar/      — calendar event cache
    connectivity/  — speedtest snapshot cache
    github/        — GitHub traffic cache
    net/           — fast-refresh net display cache
    network/       — NIC/interface state cache
    orb/           — ephemeris cache
    pfsense/       — pfSense data cache
    solar/         — UV/radiation cache
    system/        — system metrics cache
    time/          — clock data cache
    weather/       — weather cache
  suites/          — suite-specific cache (if needed)
  runtime/
    locks/
    pids/
    stamps/
  tmp/             — safe to delete
```

Each domain cache is profile-scoped:

```text
shared/<domain>/<profile>/
  current.json     — primary data file (most domains)
  state.vars       — key=value format (net)
  ephemeris.vars   — key=value format (orb)
  vlan.tsv         — tab-separated rows (net VLAN)
  status.json      — provider run metadata
  fetch.log        — provider log
```

---

## Runtime Configuration

User-editable config lives outside the repo:

```text
~/.config/gtex62-core/
  profiles/<domain>/<profile>.toml   — provider settings and TTLs
  suites/<suite>.toml                — suite profile bindings
  site.toml                          — site-wide defaults (location, timezone)
  core.toml                          — engine settings
```

Templates for all of the above are installed by:

```bash
bash ~/.config/conky/gtex62-core/bin/gtex62-core-bootstrap-runtime
```

**Bootstrap gap:** when a new provider is added to core, its `.toml.example`
must be created under `examples/runtime/` and bootstrap must be re-run.
A missing profile TOML causes the launcher to fall back to a 60-second TTL,
making fast-track meters (VLAN, ping) appear frozen.

---

## Provider TTLs

| Domain       | Default TTL | Notes                                   |
|--------------|-------------|-----------------------------------------|
| net          | 1s          | Fast-track — VLAN, ping, WAN IP display |
| time         | 1s          | Fast-track — clock rows                 |
| system       | 1s          | Fast-track — CPU, RAM, GPU, storage     |
| orb          | 60s         | Ephemeris positions                     |
| weather      | 300s        | Current conditions + forecast           |
| air          | 300s        | AQI + pollution                         |
| solar        | 300s        | UV + radiation                          |
| astro        | varies      | Moon phase, solar events                |
| connectivity | on-demand   | Manual speedtest snapshots              |
| network      | varies      | NIC state                               |
| aviation     | varies      | METAR/TAF                               |
| pfsense      | varies      | Firewall/SSH gate                       |
| github       | varies      | Traffic data                            |

WAN IP (within net) is internally rate-limited to one external call per 30s
regardless of TTL. Cache is invalidated immediately on VPN state change.

---

## Design Principles

- Core defines how things work. Suites define how things look.
- Do not hardcode suite logic into core providers.
- Shared cache formats must remain stable across suites.
- Profile-based configuration — no suite names inside provider scripts.
- Keep cache deterministic and regeneratable.
- Separate data collection, normalization, and presentation.
- Prefer clarity over cleverness.
