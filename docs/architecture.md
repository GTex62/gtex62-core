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
    alerts/        — cross-cutting alert banner watcher (thresholds over other domains' caches)
    ap/            — Zyxel access-point fleet status and named clients
    astro/         — astronomical data (moon phase, solar events)
    aviation/      — METAR/TAF weather
    calendar/      — calendar events
    connectivity/  — speedtest snapshots
    github/        — GitHub traffic
    media/         — lyrics library (player status, cover art)
    modem/         — cable modem status (HTTP scrape via pfSense NAT path)
    mtr/           — Pi5 overnight mtr-capture trigger on sustained gateway outage
    net/           — fast-refresh display cache (ping, VLAN, WAN IP)
    network/       — NIC and interface state
    orb/           — ephemeris (planet/sun/moon positions)
    pfsense/       — pfSense firewall/SSH gate data
    solar/         — UV index and solar radiation
    system/        — CPU, RAM, GPU, storage
    time/          — clock rows (timezone names, times, dates)
    vpn/           — PIA WireGuard tunnel status (local piactl/wg, no SSH)
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
    alerts/        — banner.json alert queue + transition log
    astro/         — astronomical cache
    aviation/      — METAR/TAF cache
    calendar/      — calendar event cache
    connectivity/  — speedtest snapshot cache
    github/        — GitHub traffic cache
    media/         — lyrics cache
    modem/         — modem status cache
    mtr/           — mtr-trigger state cache
    net/           — fast-refresh net display cache
    network/       — NIC/interface state cache
    orb/           — ephemeris cache
    pfsense/       — pfSense data cache (also holds AP status/named-client cache — ap
                     has no shared/ap/ tree of its own, see docs/ap-provider-status.md)
    solar/         — UV/radiation cache
    system/        — system metrics cache
    time/          — clock data cache
    vpn/           — VPN tunnel status cache
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

| Domain       | Default TTL    | Notes                                                                                                            |
|--------------|----------------|------------------------------------------------------------------------------------------------------------------|
| net          | 1s             | Fast-track — VLAN, ping, WAN IP display                                                                          |
| time         | 1s             | Fast-track — clock rows                                                                                          |
| system       | 1s             | Fast-track — CPU, RAM, GPU, storage — see system-provider-status.md                                              |
| vpn          | 10s            | PIA WireGuard tunnel status                                                                                      |
| orb          | 60s            | Ephemeris positions                                                                                              |
| alerts       | 60s            | Cross-cutting; recomputes from other domains' caches, no cache_ttl_sec of its own                                |
| ap           | 120s           | Zyxel AP fleet status + named clients                                                                            |
| weather      | 300s           | Current conditions + forecast                                                                                    |
| air          | 900s           | AQI + pollution — see env-panel-provider-status.md                                                               |
| solar        | 300s           | UV + radiation (weather-derived) — see env-panel-provider-status.md                                              |
| modem        | 300s           | Cable modem status                                                                                               |
| aviation     | 600s           | METAR/TAF, independent metar_ttl_sec/taf_ttl_sec                                                                 |
| astro        | 60s            | Moon phase, solar events — see astro-provider-status.md                                                          |
| connectivity | on-demand      | Manual speedtest snapshots                                                                                       |
| network      | varies         | NIC state                                                                                                        |
| pfsense      | varies         | Firewall/SSH gate                                                                                                |
| github       | varies         | Traffic data                                                                                                     |
| mtr          | trigger-driven | Start/stop gated on SEVERE `gateway-offline`; live-pgrep-confirmed every poll while running (see `fetch_mtr.sh`) |
| media        | write-through  | Lyrics library — not TTL-cadence, see lyrics-library-design.md                                                   |

WAN IP (within net) is internally rate-limited to one external call per 30s
regardless of TTL. Cache is invalidated immediately on VPN state change.

connectivity's own `ping` probes (`.ping.primary`/`.ping.secondary` in its
`current.json`) have no consumer anywhere in this codebase — `net` computes
ping independently (see its row above) and owns display duty for it. This is
already the authoritative, pre-existing statement of net-vs-connectivity
ownership in `docs/net-provider-reference.md`'s Purpose section: "[net] is distinct
from... the connectivity domain (speedtest snapshots). The net provider acts
as a display-ready projection layer... refreshed at a faster cadence than
either." Start there for the full picture.
connectivity also has no `refresh_loop` wired in `gtex62-core-launch` (only
`initial_refresh`, hence "on-demand" above) — that gap currently only matters
for its speedtest staleness/age display, not ping. See the note above the
connectivity `initial_refresh` call in `bin/gtex62-core-launch` for the full
investigation.

---

## Design Principles

- Core defines how things work. Suites define how things look.
- Do not hardcode suite logic into core providers.
- Shared cache formats must remain stable across suites.
- Profile-based configuration — no suite names inside provider scripts.
- Keep cache deterministic and regeneratable.
- Separate data collection, normalization, and presentation.
- Prefer clarity over cleverness.
