# Legacy Suite Conversion Guide

Converting a standalone Conky suite to the core-native engine-driven model.

---

## Purpose

This guide documents the process for converting a legacy gtex62 Conky suite — one with its
own scattered scripts, inline data fetches, and monolithic theming — into a core-native suite
that delegates data collection to the engine while keeping full ownership of visual identity,
layout, and rendering.

It is written to be reusable across all legacy suite conversions:
`gtex62-clean-suite`, `gtex62-lcars`, `gtex62-tech-hud`, `gtex62-tri-hud`.

The `gtex62-clean-suite-e` conversion is used throughout as the worked reference example.

**Last reconciled with core 0.9.1 (2026-09-25).** Re-check §1.2 (domain table), §2.2 and the
Appendix whenever core adds a provider domain or changes a cache schema — those are the
sections that drift.

### Conversion status

| Legacy suite | Converted suite | Status |
| ------------ | --------------- | ------ |
| `gtex62-clean-suite` | `gtex62-clean-suite-e` | Converted — every widget Done in [clean-suite-e-recovery-runbook.md](clean-suite-e-recovery-runbook.md) |
| `gtex62-tech-hud` | `gtex62-tech-hud-e` | Not started — directory exists but is empty |
| `gtex62-lcars` | `gtex62-lcars-e` | Not started |
| `gtex62-tri-hud` | `gtex62-tri-hud-e` | Not started |

Suites built core-native from the start (`gtex62-osa`, `gtex62-sitrep`, `gtex62-doctor`) are
the best current reference for anything this guide leaves vague — see their `suite.toml`,
`scripts/start-conky.sh` and `lua/suite/` modules.

### Companion documents

| Document | Use it for |
| -------- | ---------- |
| [architecture.md](architecture.md) | Provider pattern, cache layout, TTL table |
| [core-launcher-design.md](core-launcher-design.md) | Launch flow, palette groups, `-e` naming, toolchain gate |
| [clean-suite-e-recovery-runbook.md](clean-suite-e-recovery-runbook.md) | Worked per-widget conversion, root causes, measured values |
| [suite-conversion-final-scan.md](suite-conversion-final-scan.md) | The compliance scan to run once a suite's widgets are all Done |
| [doctor-design.md](doctor-design.md) | Adding a converted suite's domains to Doctor's coverage |
| Per-domain `*-provider-status.md` / `*-reference.md` | Exact schemas — see [README.md](README.md) |

### Conversion order

1. Phase 0 audit of the legacy suite (§0), written down before any code.
2. Chassis and domain decisions (§1), including which legacy scripts map to which provider.
3. Scaffold, manifest and binding file (§2), then the suite launcher (§7) so it can be
   relaunched after every step.
4. **Convert one widget at a time** — audit, domain map, geometry, rendering, verify, mark
   done — following the per-widget checklist in the recovery runbook. Assign finished widgets
   to a chassis process last, not first.
5. Verification checklist (§8), then the [final compliance scan](suite-conversion-final-scan.md).

---

## Core Rule (Reminder)

> **Core defines how things work. Suite defines how things look and where they go.**

The conversion is largely the exercise of enforcing this boundary where it did not previously
exist. Legacy suites mixed data fetch, cache management, and rendering into the same files.
Core-native suites draw a hard line:

| Responsibility | Owner |
| -------------- | ----- |
| Data collection and normalization | Core (shared providers) |
| Cache lifecycle and structure | Core |
| Path resolution and env exports | Core |
| Launch orchestration and PID management | Core |
| Shared assets (fonts, wallpapers, icons, geodata) | gtex62-shared-assets |
| Visual identity, palette, fonts | Suite |
| Layout and chassis geometry | Suite |
| Panel composition and arrangement | Suite |
| Cairo drawing and rendering | Suite |
| Domain view models over shared cache | Suite |
| Suite-local derived data | Suite |

---

## Phase 0 — Pre-Conversion Audit

Before writing a single line of new code, audit the legacy suite completely. The goal is a
full inventory that drives every conversion decision.

### 0.1 Widget Inventory

List every Conky instance. For each record:

- Filename (`.conky.conf`)
- Purpose / what it displays
- Approximate pixel dimensions
- Which monitor / screen position
- Whether it is always-on or optional/commented out

### 0.2 Lua Module Inventory

List every Lua file under `lua/`. For each record:

- What visual elements it draws or what data it produces
- What external data sources it reads (files, shell commands, cache paths)
- What theme values it consumes
- Whether it has any state (caching, mtime tracking, etc.)

### 0.3 Script Inventory

List every file under `scripts/`. For each record:

- What data domain it belongs to (weather, network, astro, etc.)
- What external service or system it calls (API, SSH, local command)
- What cache file(s) it writes
- Approximate execution time / whether it blocks

### 0.4 Theme Inventory

Document the existing theme system:

- How many theme files exist and what each covers
- What global values are set (fonts, colors, geometry, monitor targeting)
- What per-widget overrides exist
- Whether there is a palette/color-scheme concept already

### 0.5 Data Flow Map

For each widget, draw the path from raw data to rendered pixel:

```text
[external source] → [fetch script] → [cache file] → [Lua reader] → [Cairo draw]
```

This map becomes the basis for assigning each step to either Core or Suite in the
converted architecture.

### 0.6 Hardcoded Values Inventory

Find and list:

- Hardcoded IP addresses (pfSense host, AP IPs, etc.)
- Hardcoded paths
- Hardcoded monitor/screen assumptions
- Hardcoded API keys or credentials
- Hardcoded font names with no fallback

These become either `site.toml` entries (core config), suite manifest entries, or
user-provided gitignored files in the new model.

---

## Phase 1 — Conversion Decisions

### 1.1 Chassis Model

A "chassis" is one transparent Conky process drawing one Cairo window.

**Choose a chassis model based on how the legacy suite's widgets are used:**

| Model | Use When | Notes |
| ----- | -------- | ----- |
| **Single chassis** | All widgets are on one screen in a unified layout | Most like OSA; cleanest architecture |
| **Hybrid (2–3 chassis)** | Widgets span monitors or serve distinct functional groups | Group by function; each chassis is one .conky.conf |
| **Standalone panel** | A widget is niche, optional, or reused across suites | Keep as its own process; still engine-driven for data |
| **Multi-window** | Existing suite already has 5+ independent processes with no natural grouping | Accept N chassis; still port each to engine-driven data |

**Standalone panel criteria** — keep a panel as its own Conky process when:

- It is niche or optional (not shown by all users of the suite)
- It monitors a specific piece of infrastructure others may not have (pfSense, Zyxel AP, etc.)
- It is likely to be reused or referenced in other suites
- Its refresh cadence or data dependencies are fundamentally different from its neighbors

**Hybrid chassis grouping heuristic:**

Group panels by functional relationship, not by size:

- Monitoring group: system metrics, network, router/firewall stats
- Ambient group: weather, astronomy, time/calendar
- Media/personal group: music, notes, lyrics

### 1.2 Domain Mapping

Map every legacy data script to a core provider domain. The core owns fetching and
normalization for the 21 domains below (all under `providers/<domain>/`, all writing
`~/.cache/gtex62-core/shared/<domain>/<profile>/` — `pihole`, `pfblockerng`, `router` and
`ap` are sub-caches inside the `pfsense` tree, not domains of their own). Exact schemas live in
each domain's status/reference doc; the Appendix lists the files.

#### Weather and environment

| Core Domain | Covers | Notes |
| ----------- | ------ | ----- |
| `weather` | Current conditions, daily forecast | Replaces every legacy `owm_*` script. 300s TTL |
| `aviation` | METAR, TAF, SIGMET/AIRMET | Replaces `metar*.sh`, `taf*.sh`, `airsig_*.sh`. METAR/TAF have independent TTLs |
| `air` | AQI and pollution (OpenWeather + AirNow) | Replaces `owm_air_fetch.sh`. See [env-provider-status.md](env-provider-status.md) |
| `solar` | UV index, shortwave radiation | Replaces `solar_fetch.sh` / `solar_derive.py` / `solar_read.py` |
| `astro` | Sun/moon events, altitude/azimuth, rise/set | Replaces `sky_update.py`, `moon_times.sh`. **Not the same domain as `orb`** |
| `orb` | Sun/moon/planet ephemeris as `ephemeris.vars` | OSA's ORB panel. Pick `astro` or `orb` per widget — see [astro-provider-status.md](astro-provider-status.md) |

#### Machine, time and calendar

| Core Domain | Covers | Notes |
| ----------- | ------ | ----- |
| `system` | CPU/RAM/GPU live telemetry, storage, top processes, hostname/kernel | 1s fast-track. Live CPU%/RAM%/GPU are core's job — see §4.2 |
| `time` | Clock rows: timezone names, times, dates | 1s fast-track. Read from the cache, not `date`, so every suite shows one clock |
| `calendar` | Events (`events.json`) and seasonal sub-cache (`seasonal.json`) | Replaces `event_update.py` / `seasonal_update.py`. 86400s TTL |

#### Network and infrastructure

| Core Domain | Covers | Notes |
| ----------- | ------ | ----- |
| `network` | NIC/interface state, LAN/WAN, DNS, routing | Replaces `detect_iface.sh` |
| `net` | Display-ready fast projection: ping, VLAN latency rows, WAN IP, node table | 1s. Replaces `net_extras.sh`, `wan_ip.sh`, `wan_read.sh`. **The source for ping display** — see the pitfall in "Known Conversion Pitfalls" |
| `connectivity` | Reachability probes, speedtest snapshots | On-demand; no refresh loop. Replaces `speedtest_snapshot.sh` |
| `pfsense` | Router/firewall telemetry over SSH: `ifaces.json` (~1s flow rates), `status.json`, `arp`, `leases`, `gateway_history`, plus `pihole`, `pfblockerng`, `router`, `ap_status`, `ap_clients` sub-caches | `shared/pfsense/[profile]/`. Replaces `pf-fetch-basic.sh`, `pf-ssh-gate.sh`, `pfsense_fetch.sh`, `zyxel_cmd.sh`, `ap_status_*.sh` |
| `ap` | Zyxel access-point fleet status and named clients | Writes into the `pfsense` cache tree. Opt-in (dual-gated) |
| `vpn` | PIA WireGuard tunnel status (local `piactl`/`wg`, no SSH) | Opt-in (dual-gated) |
| `modem` | Cable-modem status via HTTP scrape through the pfSense NAT path | Opt-in (dual-gated) |
| `mtr` | Pi5 overnight mtr capture, triggered by sustained gateway outage | Opt-in (dual-gated) |
| `alerts` | Cross-cutting alert banner: thresholds over other domains' caches | Opt-in (dual-gated); ships enabled |

#### Media and meta

| Core Domain | Covers | Notes |
| ----------- | ------ | ----- |
| `media` | Lyrics library and player status (`lyrics.json`) | Flag-only toggle. See [lyrics-library-design.md](lyrics-library-design.md). Album art and volume stay suite-local |
| `github` | GitHub traffic totals | **Maintainer-only**: profile-file toggle only, ships disabled, depends on a private helper. Replaces LCARS's `github_traffic_fetch.*` |
| `doctor` | Provider-health report over every other domain | Suite-driven: only starts for a suite whose binding lists `"doctor"` in `[domains]` |

**Which domains run.** Three mechanisms, none of them the suite's own `suite.toml`:

- **Universal domains** (`air`, `astro`, `aviation`, `calendar`, `connectivity`, `net`, `network`,
  `solar`, `system`, `time`, `weather`) always run; turn one off with `enabled = false` in its
  profile TOML.
- **Dual-gated domains** (`vpn`, `ap`, `modem`, `alerts`, `mtr`, `pihole`) run only if the
  `core.toml [providers]` flag is true **and** the launching suite's binding file lists the
  domain in `[domains]`. A converted suite that never draws them should simply not list them.
- **Flag-only** (`media`, the `[providers.pfsense]` sub-flags) — the `core.toml` flag alone decides.

See the README's Provider Toggles section and [doctor-missing-conditions.md](doctor-missing-conditions.md)
for what each domain reports when it is off, missing or stale.

**Suite-local data** — data with no core provider, read at draw time or kept in a suite cache:

- Media *playback* state, volume and album art (playerctl / pactl) — `suites/[id]/msc/`
- Notes / flat text files (e.g. `~/Documents/conky-notes.txt`)
- Calendar navigation offset (`suites/[id]/tme/cal_offset`)
- Fast-lane throughput counters (`/sys/class/net/<iface>/statistics`) and link `operstate`

AP status and lyrics were previously listed here as suite-local. They are not any more: AP is
the core `ap` domain and lyrics are the core `media` domain (suite side is display-only).

**Baseline toolchain.** `jq` and `python3` are hard requirements of most providers (87% and 78%
of launcher-invoked entry points). A converted suite's `start-conky.sh` must gate on both —
see §7.2 — and list them, and `curl` where relevant, in its README Requirements section.

### 1.3 Standalone vs. Grouped Widget Decision Log

Document the explicit decision for every widget in the audit. Example format:

| Widget | Decision | Reason |
| ------ | -------- | ------ |
| sys-info | Group (Monitoring chassis) | Core domain; always-on |
| weather | Group (Ambient chassis) | Core domain; always-on |
| pfsense | Standalone (VLAN flow only) | Visual metaphor varies per suite; see §1.4 |
| ap-wbe530 | Retired → sitrep | Status-only; no suite-specific visual; see §1.4 |
| music | Group (Media chassis) | Suite-local; personal use |

---

### 1.3a Legacy Script → Provider Map (per suite)

Starting points for the Phase 0 audit of each remaining suite. Verified against the scripts
directories on 2026-09-25; the audit still has to confirm behavior, not just names.

| Legacy script(s) | Present in | Replace with |
| ---------------- | ---------- | ------------ |
| `owm_fetch.sh`, `owm_fc_*.sh`, `owm_current_icon.sh` | tech-hud, lcars, tri-hud | `weather` (icons come from `gtex62-shared-assets/icons/owm/`) |
| `metar*.sh`, `taf_wrap.sh`, `airsig_*.sh`, `station_latlon.sh` | tech-hud, lcars, tri-hud | `aviation` |
| `owm_air_fetch.sh`, `atmos_read.py` | lcars, tri-hud | `air` |
| `solar_fetch.sh`, `solar_derive.py`, `solar_read.py` | lcars, tri-hud | `solar` |
| `sky_update.py`, `moon_times.sh` | tech-hud, tri-hud | `astro` (or `orb` for planet arcs) |
| `event_update.py`, `seasonal_update.py` | tech-hud, tri-hud | `calendar` (`events.json`, `seasonal.json`) |
| `detect_iface.sh` | tech-hud, tri-hud | `network` |
| `net_extras.sh`, `wan_ip.sh`, `wan_read.sh` | tech-hud, lcars | `net` (+ `network` for interface state) |
| `speedtest_snapshot.sh` | lcars, tri-hud | `connectivity` |
| `pf-fetch-basic.sh`, `pf-ssh-gate.sh`, `pfsense_fetch.sh`, `pfsense_ssh_gate.sh`, `pf-rate-*-test.sh` | tech-hud, lcars, tri-hud | `pfsense` (VLAN flow panel only, §1.4) |
| `zyxel_cmd.sh`, `ap_status_all*.sh`, `ap_clients_named.sh` | tech-hud | Retired → SitRep; core `ap` domain |
| `github_traffic_fetch.*`, `install-github-traffic-timer.sh`, `systemd/` | lcars | `github` (maintainer-only; core ships the systemd timer under `systemd/`) |
| `doctor.sh` | tech-hud, tri-hud | Core `doctor` domain / `gtex62-doctor`; see [doctor-design.md](doctor-design.md) |
| `conky-env.sh`, `set-screen-size.sh` | all | Retired — path/env resolution is core's, monitor targeting is `xinerama_head` (§ Monitor Targeting) |
| `install-fonts.sh`, `uninstall-fonts.sh` | all | `gtex62-core/scripts/install-fonts.sh` (fonts live in shared-assets) |
| `generate_palette_pdf.py` | lcars, tri-hud | `gtex62-core/scripts/generate_palette_pdf.py` |
| `start-conky.sh`, `launch-lcars.sh`, `launch-tri-hud.sh` | per suite | Rewritten per §7; `tone_modes` handling is described in [core-launcher-design.md](core-launcher-design.md) |
| `mint_version.sh`, `notes_wrap.sh` | tech-hud | Suite-local — port as Lua reading at draw time (clean-suite-e's `notes.lua` reproduces `fold -s -w N`) |

Suites whose legacy version predates a provider (LCARS/tri-hud had no MTR/VPN/modem story)
need no mapping for it — do not add a panel just because a domain now exists.

### 1.4 The pfSense Split Pattern

The pfSense widget in legacy suites conflates two distinct concerns that belong in different
places under the core-native model. Recognizing this split is important because it applies
to every suite that has a pfSense widget — **except `gtex62-osa`, which has none**.

**The three-way split:**

| Component | Owner | Reason |
| --------- | ----- | ------ |
| **VLAN traffic flow visualization** — arcs, meters, rate bars showing WAN/HOME/IOT/GUEST/INFRA throughput | Suite (standalone panel) | Each suite uses a different visual metaphor: arcs in clean-suite and tech-hud, meters in tri-hud, arc-variant in lcars. Same data, different drawing code. Suite owns it. |
| **pfSense raw data** — interface counters, rates, state | Core `pfsense` provider | Fetched once, cached in shared cache, consumed by any suite's VLAN flow panel |
| **Infrastructure status** — pfBlockerNG counts, Pi-hole stats, cumulative data totals, AP client status, gateway health, VPN, modem, outage alerts | `gtex62-sitrep` (sibling suite repo) | Identical presentation across all suites. No per-suite visual identity. Runs alongside any main suite. Data comes from the core `pfsense` sub-caches, `ap`, `vpn`, `modem`, `mtr` and `alerts` domains. |

**Suite VLAN flow panel** — each suite keeps a standalone `.conky.conf` that draws only the
traffic flow visualization for the WAN/VLAN interfaces. It reads from the core `pfsense`
provider cache. The drawing code is suite-owned and can use whatever visual metaphor fits
the suite's design language (arcs, meters, bars, LCARS-style indicators).

The suite's palette should include named arc/meter color roles (`arc_wan_in`, `arc_wan_out`,
`arc_home`, etc.) so the VLAN panel participates in palette switching alongside the rest of
the suite.

**SitRep** — a core-native suite in its own repo, `~/.config/conky/gtex62-sitrep/` (the
original plan to house it inside core was abandoned; see
[sitrep-architecture.md](sitrep-architecture.md) and the archived relocation plan). It is the
one suite allowed to run alongside any main suite, and every main suite's `start-conky.sh`
deliberately leaves it alone. It reads core cache paths shared across all suites, so no
converted suite needs to carry AP status, pfBlockerNG counts, Pi-hole stats, or data totals as
a panel. It replaces per-suite equivalents like `apwbe` (clean-suite) and `sitrep` (tech-hud).

**Practical result for each legacy suite conversion:**

- The legacy pfSense widget is split: drawing code for VLAN flow stays in the suite as a
  standalone panel; status/totals/AP drawing code is retired (replaced by sitrep).
- Any standalone AP widget in the suite is retired. AP status is covered by sitrep.
- The suite's binding file (`~/.config/gtex62-core/suites/<id>.toml`, see §2.2) lists `pfsense`
  in `[domains]` and binds a `pfsense` profile, so the core launcher schedules the provider;
  the suite only draws the flow visualization.
- Read `shared/pfsense/[profile]/ifaces.json` (core's ~1s poller, server-side
  `rate_ibytes_per_sec` / `rate_obytes_per_sec`), **not** `status.json` (60s) with client-side
  byte-counter diffs. clean-suite-e's `pf.lua` does one `jq` per second and smooths after the
  response curve; copy that.
- Do not read the SSH gate or add one — reads are cache-only and the circuit breaker is
  core-owned.
- Do check whether the pfSense sub-flag is enabled and render an explicit DISABLED state; see
  [suite-conversion-final-scan.md](suite-conversion-final-scan.md) Section 2. clean-suite-e's
  VLAN-flow arc is the known counter-example.

---

## Phase 2 — Repository Scaffold

### 2.1 Directory Structure

Every core-native suite follows this template. Names are prefixed with the suite ID.

```text
gtex62-[suite-id]-e/
├── suite.toml                          # Suite manifest
├── README.md                           # User guide and panel map
├── design/                             # Visual reference material
├── docs/                               # Suite-specific notes
├── lua/
│   ├── suite/                          # Domain view models
│   │   ├── sys.lua
│   │   ├── net.lua
│   │   ├── tme.lua
│   │   ├── wxr.lua
│   │   └── [other domains...]
│   ├── ui/
│   │   └── frame.lua                   # Cairo panel renderer
│   └── widgets/                        # Conky Lua entrypoints
│       ├── [suite]_[chassis].lua       # One per chassis/standalone
│       └── [...]
├── theme/
│   ├── [suite]-palettes.lua            # Color scheme catalog
│   ├── [suite]-theme.lua               # Fonts, strokes, frame effects
│   ├── [suite]-layout.lua              # Per-chassis frame geometry
│   └── panels.lua                      # Panel + box definitions
├── scripts/
│   ├── start-conky.sh                  # Palette/wallpaper selection → core launcher
│   └── bootstrap-runtime.sh            # Delegates to core bootstrap
└── widgets/
    ├── [suite]-[chassis].conky.conf    # One per chassis/standalone
    └── [...]
```

`lua/widgets/` and `lua/ui/frame.lua` are how clean-suite-e is laid out (one entrypoint per
chassis/standalone). OSA is a single-window suite with one `widgets/osa-main.conky.conf`; the
core README's "Core-Native Suite Template" is the canonical short form.

**Naming.** A converted suite gets an `-e` suffix and lives *beside* its legacy directory
(`gtex62-lcars` → `gtex62-lcars-e`); the legacy repo is frozen and left untouched. A suite built
core-native from the start never gets a suffix. Details in
[core-launcher-design.md](core-launcher-design.md).

**Not included by design:**

- `assets/`, `fonts/`, `icons/`, `wallpapers/` — use `gtex62-shared-assets` (a leftover
  per-suite `wallpapers/` directory is a cleanup item, see the final scan)
- `examples/` — in core
- `providers/` — in core
- Duplicate data fetch scripts — in core
- Legacy config backups (`bak/`, `legacy/config/`)
- Large architecture sections copied from core docs — link to them instead

### 2.2 Suite Manifest and Runtime Binding

A converted suite has **two** TOML files with different jobs. Confusing them is the most common
first-run failure.

| File | Lives in | Read by | Purpose |
| ---- | -------- | ------- | ------- |
| `suite.toml` | the suite repo | the launcher (`[[instances.*]]` conf paths only) and humans | Suite identity, version, assets, palette catalog, which Conky windows to start |
| `suites/<suite-id>.toml` | `~/.config/gtex62-core/` (runtime root) | the launcher (`suite_repo`, `[profiles]`, `[domains]`) | Binds the suite to provider profiles and declares which opt-in domains it consumes |

The launcher exits with `Suite config not found` if the binding file is missing, so it must be
created on first run — see §7.1.

#### Versioning

Each converted suite starts at `version = "0.1.0"` and advances independently. **Suite
conversions do not bump the core version.** The core version only changes when the core
itself changes — a new provider added, a cache schema updated, a launcher contract revised.
A suite conversion is a suite-side event; the core is unchanged by it.

The `core_requirement` field declares the minimum core version this suite needs. It only
needs updating if the conversion requires a new core capability that did not previously
exist (e.g., a missing provider the core must now add to support the suite). A suite that
depends on a newer core feature should say so in its README (gtex62-doctor v0.1.0 requires
core 0.9.1 for the `STARTING` state and `fast_track` flag).

| Event | What bumps |
| ----- | ---------- |
| New suite conversion begins | Suite `version` starts at `0.1.0` |
| Suite reaches stable / feature-complete | Suite `version` → `1.0.0` |
| Core adds a new provider or changes a cache schema | Core version bumps |
| Suite requires a new core capability | Suite `core_requirement` lower bound updates |

#### `suite.toml` (in the suite repo)

Match the shape of `gtex62-osa`, `gtex62-sitrep` and `gtex62-clean-suite-e`:

```toml
suite_id = "[suite-id]"                 # "clean-e" for gtex62-clean-suite-e — not the dir name
name = "gtex62-[suite-id]-e"
version = "0.1.0"
core_requirement = ">=1.0,<2.0"

[repo]
layout = "core-native"

[entrypoints]
theme_dir = "theme"
lua_dir = "lua"
widgets_dir = "widgets"
scripts_dir = "scripts"

[assets]
design_dir = "design"
docs_dir = "docs"
shared_assets_dir = "../gtex62-shared-assets"
fonts_dir = "../gtex62-shared-assets/fonts"
icons_dir = "../gtex62-shared-assets/icons"
wallpapers_dir = "../gtex62-shared-assets/wallpapers"

[theme]
default_palette = "[palette-name]"
palette_catalog = "theme/[suite]-palettes.lua"
palette_format = "role3"                # see §3.1 — "role3" is what OSA/SitRep/clean-e declare

# One block per Conky process this suite starts. The launcher starts every conf listed
# here, in order, and writes a PID file per instance. With no [[instances.*]] block at all
# it falls back to OSA's single widgets/osa-main.conky.conf — don't rely on that.
[[instances.chassis]]
id = "monitor"
conf = "widgets/[suite]-monitor.conky.conf"
description = "System and network panels"

[[instances.standalone]]
id = "pfsense"
conf = "widgets/[suite]-pfsense.conky.conf"
description = "VLAN flow visualization"
optional = true
```

`id` and `description` are informational; the launcher only reads the `conf` lines. `optional`
is likewise informational today — an optional instance is still started if listed, so
comment it out (or leave it out) rather than relying on the flag.

The `[data] domains = [...]` block that clean-suite-e's `suite.toml` carries (and that earlier
versions of this guide prescribed) is **not read by the launcher**. Domain gating comes from
the binding file below. Keep the list if it helps readers, but treat it as documentation and
keep it in step with the binding file.

#### `suites/<suite-id>.toml` (runtime binding)

Modelled on `examples/runtime/suites/osa.toml.example`:

```toml
suite_id = "[suite-id]"
name = "gtex62-[suite-id]-e"
suite_repo = "__SUITE_REPO__"
suite_manifest = "__SUITE_REPO__/suite.toml"
enabled = true

[profiles]
# One profile per domain the suite consumes. A domain missing here falls back to the
# launcher's own default profile name for it.
weather = "home"
aviation = "home"
astro = "home"
network = "local"
net = "local"
connectivity = "default"
pfsense = "main_router"
media = "local"

[domains]
# Consulted by suite_has_domain() — this is what starts the dual-gated domains
# (vpn/ap/modem/alerts/mtr/pihole/doctor). List only what the suite actually draws.
required = ["system", "time", "weather", "astro", "aviation", "network", "pfsense"]
optional = []

[suite_cache]
namespaces = ["msc", "tme"]             # only suite-local dirs the suite really writes
```

`__SUITE_REPO__` is substituted by the core bootstrap. There are two ways to get this file into
place, and a conversion needs exactly one of them:

- **Ship a template in core** — add `examples/runtime/suites/<suite-id>.toml.example`
  (OSA, SitRep and Doctor do this). It is a core change, so it needs the normal core
  commit, and it is picked up by `gtex62-core-bootstrap-runtime --suite-dir <suite>`.
- **Have the suite's bootstrap write it** — clean-suite-e's `scripts/bootstrap-runtime.sh`
  still writes `suites/clean-e.toml` itself if absent (a fallback that predates the core
  template). Its inline copy omits `time`, `calendar` and `[domains]`; the core template is the
  fuller one.

clean-suite-e now has a core template (`examples/runtime/suites/clean-e.toml.example`), so its
bootstrap no longer has to write the file; the suite's own fallback is retained for runs without
core's examples. Prefer the core template for any new suite that will be distributed.

#### Profile files

Every profile named in `[profiles]` needs an installed TOML under
`~/.config/gtex62-core/profiles/<domain>/<profile>.toml`, or the launcher falls back to a **60s
TTL** and fast-track meters (VLAN, ping, system) appear frozen — the *bootstrap gap*. Templates
are in `examples/runtime/profiles/<domain>/`; note `pfsense` ships as `main_router`, `mtr` as
`pi5`, `connectivity`/`github` as `default`, `net`/`network`/`system`/`time`/`vpn`/`modem`/`calendar`
as `local`, and `weather`/`air`/`aviation`/`astro`/`solar`/`orb` as `home`. Re-run
`gtex62-core-bootstrap-runtime` after adding any provider, and check `ls
~/.config/gtex62-core/profiles/<domain>/` before debugging a frozen meter.

---

## Phase 3 — Theme Conversion

Legacy suites typically have one or two monolithic `theme.lua` files that mix colors, fonts,
geometry, per-widget pixel offsets, and sometimes data config. Split this into four files.

### 3.1 Palette Catalog (`[suite]-palettes.lua`)

Extracts color identity only. One table per named color scheme. At minimum, port the existing
scheme as the default; add alternates as desired.

**Pick the catalog shape deliberately — the launcher parses it.** Several shapes exist today:

| Shape | Used by | Notes |
| ----- | ------- | ----- |
| **role3** — `return { default = "amber", palettes = { name = { bg, fg, ink } } }` | OSA, SitRep, Doctor (byte-identical 63-entry catalog) | What `palette_format = "role3"` declares. The launcher's `choose_palette` awk reads `default =`, the `palettes = {` block, `-- Group` comment lines as menu headings, and `name = {` entries |
| **Named-role table** — `palettes["default"] = { bg, fg, ink, dim, accent, ok, warn, err, ... }` | clean-suite-e (2 entries) | Richer roles, but also declared `role3` in its manifest — the launcher only needs names and a default |
| **Tone ladder** — `tone0`–`tone4` + `energy`, plus a `tone_modes` table | LCARS (61), tri-hud (60) | Mode (dark/light/alt) is a role-inversion over the ladder, not a separate palette. Converting these means the launcher must also prompt for mode first |
| None | tech-hud | No catalog exists — designing one is part of its conversion |

Do not share a palette file with another suite, even if starting values converge — visual
identity is suite-owned. The launcher groups suites by *file hash* to avoid duplicate prompts;
that is a launcher optimization, not shared ownership, and group membership can drift the moment
one catalog is edited (see [core-launcher-design.md](core-launcher-design.md)).

**How the choice reaches the theme.** The suite's `start-conky.sh` exports a suite-specific
variable (OSA: `CONKY_OSA_PALETTE`; clean-suite-e's theme reads `GTEX62_PALETTE`), and the theme
file falls back to `default` when it is unset or unknown. When the palette is chosen by an
earlier suite in a combined launch, the hand-off variable is `GTEX62_CONKY_PALETTE_OVERRIDE`
(wallpaper: `GTEX62_CONKY_WALLPAPER_OVERRIDE`); honor it, and fall back to prompting with a
warning if the name is not in your catalog.

**Include a named role for every suite-specific meter** (`pf_arc_base`, `net_up`/`net_down`,
`slash_empty`, `cal_grid`, `cal_weekend` in clean-suite-e) so every widget participates in
palette switching. Anything left as a hardcoded hex value in a conf or Lua file will not follow
a palette change.

```lua
-- [suite]-palettes.lua
local palettes = {}

palettes["default"] = {
  name        = "Default",
  bg          = { 0.05, 0.05, 0.07, 0.82 },
  fg          = { 1.00, 1.00, 1.00, 0.90 },
  ink         = { 0.63, 0.63, 0.63, 0.80 },
  accent      = { 1.00, 0.84, 0.29, 1.00 },  -- golden
  ok          = { 0.00, 1.00, 0.00, 0.85 },
  warn        = { 1.00, 0.65, 0.00, 0.90 },
  err         = { 1.00, 0.33, 0.33, 0.90 },
}

-- Add alternate palettes here as the suite matures.

return palettes
```

### 3.2 Theme File (`[suite]-theme.lua`)

Loads the selected palette and defines non-geometric, non-per-panel settings: fonts, stroke
widths, frame effects, global alpha values.

```lua
-- [suite]-theme.lua
local HOME       = os.getenv("HOME") or ""
local SUITE_DIR  = os.getenv("CONKY_SUITE_DIR") or (HOME .. "/.config/conky/gtex62-[suite]-e")
local palette_id = os.getenv("GTEX62_PALETTE") or "default"

local catalog = dofile(SUITE_DIR .. "/theme/[suite]-palettes.lua")
local palette = catalog[palette_id] or catalog["default"]

local theme = {}
theme.palette  = palette
theme.colors   = { bg = palette.bg, fg = palette.fg, ink = palette.ink }
theme.accent   = palette.accent
theme.status   = { ok = palette.ok, warn = palette.warn, err = palette.err }

theme.fonts = {
  title  = "Inter Bold",
  data   = "JetBrainsMono Nerd Font",
  base   = "DejaVu Sans",
  mono   = "DejaVu Sans Mono",
}
theme.sizes = { title = 11, label = 10, data = 10, small = 9 }

theme.strokes = { line = 1.0, frame = 1.5, meter = 8.0 }
theme.alpha   = { panel_bg = 0.72, separator = 0.35, inactive = 0.45 }

theme.frame_shadow = { enabled = true, alpha_scale = 0.18 }
theme.frame_lights = { enabled = false }

return theme
```

### 3.3 Layout File (`[suite]-layout.lua`)

Chassis geometry only. One section per Conky process, defining the outer frame dimensions and
column/row structure. No per-widget values here.

```lua
-- [suite]-layout.lua
local layout = {}

layout.monitor = {
  frame  = { x = 0, y = 0, width = 540, height = 1080 },
  margin = { top = 28, left = 20, right = 20, gap = 20 },
}

layout.ambient = {
  frame  = { x = 0, y = 0, width = 680, height = 780 },
  margin = { top = 28, left = 20, right = 20, gap = 20 },
}

-- Standalone widgets define their own minimal frame.
layout.pfsense = {
  frame  = { x = 0, y = 0, width = 660, height = 740 },
  margin = { top = 28, left = 20, right = 20, gap = 20 },
}

return layout
```

### 3.4 Panels File (`panels.lua`)

One entry per named panel. Defines position, size, title, and sub-box structure within the
chassis. These are the only coordinates that reference pixel offsets for individual panels.

```lua
-- panels.lua
local panels = {}

-- Monitoring chassis panels
panels.sys = {
  title  = "SYS",
  x = 20, y = 40, width = 500, height = 340,
  boxes  = {
    cpu     = { x = 12, y = 64, width = 476, height = 120 },
    ram     = { x = 12, y = 200, width = 476, height = 80 },
    gpu     = { x = 12, y = 296, width = 476, height = 80 },
  }
}

panels.net = {
  title  = "NET",
  x = 20, y = 400, width = 500, height = 260,
  -- ...
}

-- Add remaining panels here.

return panels
```

---

## Phase 4 — Domain View Models

For each core data domain the suite consumes, write a view model Lua module under
`lua/suite/`. Each module reads from the normalized core cache and exposes functions that
the frame renderer calls at draw time.

### 4.1 Module Structure

```lua
-- lua/suite/[domain].lua

local HOME      = os.getenv("HOME") or ""
local CACHE     = os.getenv("GTEX62_CACHE_DIR")
               or os.getenv("GTEX62_CONKY_CACHE_DIR")
               or (HOME .. "/.cache/gtex62-core")

local DOMAIN_CACHE = CACHE .. "/shared/[domain]/[profile]/"

local M = {}

-- Read a file; return nil if missing.
local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

-- Query JSON with jq; return trimmed string or "" on failure.
local function jq(path, filter)
  local cmd = string.format("jq -r %q %q 2>/dev/null", filter, path)
  local h = io.popen(cmd)
  if not h then return "" end
  local s = h:read("*a")
  h:close()
  return (s or ""):gsub("^%s*(.-)%s*$", "%1")
end

-- Public API consumed by frame.lua
function M.some_value()
  return jq(DOMAIN_CACHE .. "current.json", ".field_name // \"--\"")
end

return M
```

### 4.2 Fast Lane vs. Slow Lane

**Core is the source for every displayed value.** That is the standing goal, and it overrides
any per-widget argument that a Conky built-in would be cheaper: clean-suite-e's SYS panel was
first shipped with `${cpu}`, `${memperc}` and `execpi nvidia-smi` and had to be reopened and
rebuilt on the `system` provider.

- **Slow lane** — identity and summaries: weather, astro events, aviation, hostname/kernel,
  storage. Read the normalized cache. TTLs are managed by the provider scheduler.
- **Fast lane** — cadence, not source. Fast domains (`system`, `time`, `net`) are still core
  domains: they refresh at ~1s and the suite reads them each draw tick. Do not bypass them with
  Conky built-ins or shell calls.
- **Genuine suite-side exceptions**, and only these: interface throughput graphs (a per-second
  ring buffer of `/sys/class/net/<iface>/statistics` deltas), link `operstate`, media playback
  position/volume, and other state core has no provider for (§4.3).

**View-model performance rules** (from OSA and clean-suite-e):

- One `jq` per cache file per tick, with a tick-cache in the module, not one `jq` per field.
  A draw hook at 0.5s that shells out ten times will show.
- Provider files are written atomically since core 0.9.0, so a read is safe at any moment;
  a JSON parse that fails should keep showing the last good value rather than blanking.
- Cache rows that hold `null` (cold start, counter wrap, degraded stub) must not step smoothing
  filters or draw as zero.
- Cache age is a first-class input. A provider that stops writing leaves plausible-looking stale
  values; check `status.json` `state` (and `generated_at`) for anything the widget presents as
  live, and render an explicit stale/unavailable state.
- Never gate providers from the suite. SSH gating, TTL skipping and circuit breaking are core's.

### 4.3 Suite-Local Data

Domains with no core provider (media playback, notes, calendar offset) still follow the same module
pattern — they just read from suite-local cache paths or directly from the source:

```text
~/.cache/gtex62-core/suites/[suite-id]/[domain]/
```

---

## Phase 5 — Frame Renderer

`lua/ui/frame.lua` is the Cairo drawing engine. It is called once per draw cycle by each
chassis's Conky entrypoint.

### 5.1 Entry Signature

```lua
-- Called from the Lua draw hook in each chassis entrypoint.
function frame.draw(cr, chassis_id, theme, layout, panels, domain_modules)
  -- Draw background
  -- Iterate over panels belonging to this chassis
  -- For each panel: draw frame, title, separators, then content
end
```

### 5.2 Panel Rendering Pattern

```lua
-- For each panel in the chassis:
--   1. Draw panel background (rounded rect, themed alpha)
--   2. Draw panel title (uppercase, accent color)
--   3. Draw separator line under title
--   4. Call the panel's content renderer, which calls domain module functions
```

### 5.3 Porting Legacy Drawing Logic

When porting from a legacy Lua file:

1. Identify the geometric constants — move them to `panels.lua` or `[suite]-layout.lua`.
2. Identify the color/font references — replace with `theme.*` lookups.
3. Identify the data reads (jq calls, file reads, conky_parse) — move to the domain module.
4. What remains is pure drawing logic — keep it in `frame.lua` or panel-specific helpers.

---

## Phase 6 — Conky Entrypoints

### 6.1 Widget Config (`.conky.conf`)

Each chassis or standalone panel needs one `.conky.conf`. They share the same structure:

```lua
-- widgets/[suite]-[chassis].conky.conf
conky.config = {
  -- Window behavior
  own_window            = true,
  own_window_type       = "desktop",
  own_window_argb_visual = true,
  own_window_argb_value = 0,          -- full transparency; drawing handled by Cairo
  own_window_hints      = "undecorated,below,sticky,skip_taskbar,skip_pager",

  -- Position (set via xinerama_head or gap_x/gap_y from layout)
  alignment             = "top_left",
  gap_x                 = 0,
  gap_y                 = 0,
  xinerama_head         = 0,

  -- Frame size (must match layout.[chassis].frame dimensions)
  minimum_width         = 540,
  minimum_height        = 1080,
  maximum_width         = 540,

  -- Rendering
  double_buffer         = true,
  update_interval       = 0.5,

  -- Lua
  lua_load              = "lua/widgets/[suite]_[chassis].lua",
  lua_draw_hook_pre     = "conky_draw_[chassis]",
}

conky.text = [[]]   -- Pure Cairo rendering; no Conky text output.
```

**Position strategy for multi-monitor layouts:**

Use `xinerama_head` + `alignment` to target a monitor, then `gap_x` / `gap_y` for precise
offset within that monitor. Avoid absolute pixel math that encodes monitor resolution — it
breaks when resolution changes.

**Match the legacy *rendered* position, not its conf values.** Legacy Conky-text widgets
routinely render somewhere other than their `gap_x`/`gap_y` say (window autosize, ignored
`maximum_width`, a theme draw offset). Every clean-suite-e widget that was ported from the conf
values alone was wrong. Measure the running legacy widget, then derive the gaps:

- Conky places an `own_window` at the alignment position offset 5 px outward, and the window is
  `frame + 10` in each dimension. For a `top_right` window:
  `window_left = screen_w − gap_x + 5 − (frame_w + 10)`, `window_top = gap_y − 5`.
- Measure by diffing a screenshot with the widget against a background capture (threshold,
  then row/column projections) rather than by eye; expect ±1–2 px from Cairo vs Xft antialiasing.
  Take the background capture on the same day — a calendar's today-highlight rolling over
  midnight shows up as a phantom band.
- Text metrics differ between Xft and Cairo: calibrate the Cairo font size to the legacy
  character advance (clean-suite-e: 18 px monospace for a 10.85 px grid cell, 16.6 px for a
  10.0 px advance; DejaVu Sans Mono advance ratio ≈ 0.6028).
- On a scaled desktop, `wmctrl -lG` reports positions at 2× physical and sizes at 1× — divide
  x,y by 2.
- Never put a conf name in a `pkill -f` pattern from an agent harness: the pattern matches the
  harness's own wrapper shell. Kill by PID (or by the suite's `widgets/` directory path from a
  real script, as the launchers do).
- Record the measured values as text in the suite's runbook so later sessions never re-open
  screenshots.

**Standalone vs. folded widgets.** If a legacy element was its own window on a different part
of the screen, keep it as its own `[[instances.standalone]]` — folding it into a chassis
discards its position, because no single Conky window can span both footprints. This is the
*chassis-combination pitfall* (clean-suite-e's calendar and notes both hit it): audit each
sub-element's position individually, not just the container's.

### 6.2 Lua Entrypoint (`lua/widgets/[suite]_[chassis].lua`)

```lua
-- lua/widgets/[suite]_[chassis].lua
require "cairo"

local HOME      = os.getenv("HOME") or ""
local SUITE_DIR = os.getenv("CONKY_SUITE_DIR") or (HOME .. "/.config/conky/gtex62-[suite]-e")

-- Lazy-load modules on first draw to avoid startup errors.
local initialized = false
local theme, layout, panels
local sys, net   -- domain modules for this chassis

local function init()
  if initialized then return end
  theme  = dofile(SUITE_DIR .. "/theme/[suite]-theme.lua")
  layout = dofile(SUITE_DIR .. "/theme/[suite]-layout.lua")
  panels = dofile(SUITE_DIR .. "/theme/panels.lua")
  sys    = dofile(SUITE_DIR .. "/lua/suite/sys.lua")
  net    = dofile(SUITE_DIR .. "/lua/suite/net.lua")
  initialized = true
end

function conky_draw_[chassis]()
  if conky_window == nil then return end
  local cs = cairo_xlib_surface_create(
    conky_window.display, conky_window.drawable,
    conky_window.visual, conky_window.width, conky_window.height)
  local cr = cairo_create(cs)

  init()

  local frame = dofile(SUITE_DIR .. "/lua/ui/frame.lua")
  frame.draw(cr, "[chassis]", theme, layout, panels, { sys = sys, net = net })

  cairo_destroy(cr)
  cairo_surface_destroy(cs)
end
```

---

## Phase 7 — Launch Wiring

### 7.1 Bootstrap Script

The wrapper delegates to core bootstrap with `--suite-dir` (there is no `--suite` flag on the
bootstrap; `--suite <id>` belongs to the *launcher*). Bootstrap never overwrites an existing
file unless `--force` is passed.

```bash
#!/usr/bin/env bash
# scripts/bootstrap-runtime.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CORE_REPO="${GTEX62_CORE_DIR:-${GTEX62_CONKY_ENGINE_DIR:-$HOME/.config/conky/gtex62-core}}"
CORE_BOOTSTRAP="${GTEX62_CORE_BOOTSTRAP:-$CORE_REPO/bin/gtex62-core-bootstrap-runtime}"

export CONKY_SUITE_DIR="$SUITE_DIR"
"$CORE_BOOTSTRAP" --suite-dir "$SUITE_DIR" "$@"
```

It installs, from `examples/runtime/`: `core.toml`, `site.toml`, `devices.toml`, every domain
profile, and `suites/<id>.toml` if a template exists for the suite. If the suite has no core
template, the wrapper must also write `suites/<id>.toml` itself (clean-suite-e's
`bootstrap-runtime.sh`, §2.2) and create the suite-local cache directories it really uses
(`$CACHE_ROOT/suites/<id>/<ns>`, `$CACHE_ROOT/runtime/pids`).

### 7.2 Suite Launcher

Model `scripts/start-conky.sh` on OSA's or clean-suite-e's rather than writing one from scratch;
the parts that matter, in order:

1. **Resolve and export the environment** — `CONKY_SUITE_DIR`, `GTEX62_CONFIG_DIR`,
   `GTEX62_CACHE_DIR`, `GTEX62_SUITE_ID`, `GTEX62_SHARED_ASSETS(_DIR)`, `GTEX62_WALLPAPERS_DIR`
   (each with its `GTEX62_CONKY_*` twin, which older code still reads).
2. **Baseline toolchain gate, before anything else** — `jq` *and* `python3`, one combined
   check, print which is missing, exit 1. It must run in the foreground front door, before any
   `>/dev/null` redirect or detach, because the launcher's own output is discarded. Copy the
   block verbatim from OSA's `start-conky.sh`.
3. **Self-healing bootstrap** — if `core.toml` or `suites/<id>.toml` is missing, run the
   bootstrap wrapper **in the foreground with its output visible**. This is the only place a
   fresh install is told to fill in `site.toml`; two of the three original front doors piped
   it to `/dev/null` and it had to be fixed.
4. **Stop the suite's own previous run** — read `runtime/pids/<id>-launcher.pid` and
   `<id>-conky.pid`, kill, wait; then `pkill -f "$SUITE_DIR/widgets/"` to catch the rest.
   Scope by the suite's own `widgets/` path — a blanket `pkill -x conky` kills SitRep.
5. **Suite exclusivity** — kill every *other* suite's `widgets/` processes except
   `gtex62-sitrep`, so only one main suite runs at a time.
6. **Palette (and mode, for tone-ladder suites), then wallpaper** — honor
   `GTEX62_CONKY_PALETTE_OVERRIDE` / `GTEX62_CONKY_WALLPAPER_OVERRIDE`, remember the last choice
   under `$CACHE_ROOT/runtime/<id>-palette` / `<id>-wallpaper`, list wallpapers from
   `gtex62-shared-assets/wallpapers` with a `None` option. Prompt for mode first only if the
   suite's catalog defines `tone_modes`; otherwise never show a mode prompt.
7. **Hand off, detached** — `"$CORE_LAUNCHER" --suite "<suite-id>"`.

```bash
CORE_LAUNCHER="${GTEX62_CORE_LAUNCHER:-${GTEX62_CONKY_LAUNCHER:-$CORE_REPO/bin/gtex62-core-launch}}"
nohup "$CORE_LAUNCHER" --suite "[suite-id]" >/dev/null 2>&1 &
```

The core launcher then starts the providers this suite's binding enables, starts every conf in
`suite.toml [[instances.*]]`, and writes `runtime/pids/<suite-id>-<conf-basename>-conky.pid` per
instance plus `<id>-launcher.pid`. The first instance is the one refresh loops watch: when it
exits the loops terminate, so list the always-on chassis first and any optional window last.

Legacy `launch-lcars.sh` / `launch-tri-hud.sh` mode-then-palette logic is being absorbed into the
consolidated launcher ([core-launcher-design.md](core-launcher-design.md), `gtex62-conkystart`,
planned); until it lands, port their behavior into the converted suite's own `start-conky.sh`.

---

## Phase 8 — Verification Checklist

### Data

- [ ] Each core domain this suite uses has a running provider populating its cache
- [ ] Every profile in `suites/<id>.toml [profiles]` has an installed TOML under
      `~/.config/gtex62-core/profiles/` (no 60s-TTL fallback, no frozen fast-track meters)
- [ ] `suites/<id>.toml [domains]` lists exactly the dual-gated domains the suite draws
- [ ] Suite cache paths (`suites/[id]/`) exist and are populated at startup
- [ ] Status files exist for all declared domains and show `"state": "ok"`
- [ ] Every value shown as live traces to a core cache — no Conky built-ins, `execpi` or shell
      calls (§4.2); ping comes from `net`, not `connectivity`
- [ ] Disabled providers render an explicit disabled/unavailable state, not zero data
- [ ] Suite-local data (music, notes) readable at draw time without blocking

### Theme

- [ ] All legacy hardcoded colors removed from Lua modules; replaced with `theme.*` lookups
- [ ] All legacy hardcoded pixel positions removed; replaced with `layout.*` or `panels.*` lookups
- [ ] Palette selection at launch changes colors across all chassis
- [ ] The suite has its own palette file (not shared with another suite)
- [ ] `conky.text` is blank in every `.conky.conf` — a non-empty block means Conky-native colors
      that cannot follow a palette swap
- [ ] No font fallback failures (test with a minimal system font set)

### Rendering

- [ ] Each chassis window is fully transparent where not drawn
- [ ] No Conky text output visible (all rendering is Cairo)
- [ ] Cairo drawing matches expected panel layout at target resolution
- [ ] Each widget's position matches the *measured* legacy rendered position (§6.1), and every
      sub-element of a folded chassis was audited individually
- [ ] No Lua errors in Conky stderr at startup or during refresh

### Launch

- [ ] `start-conky.sh` kills existing processes cleanly before re-launching
- [ ] Bootstrap is idempotent (re-running does not overwrite user config)
- [ ] Core launcher receives correct suite ID and resolves all paths
- [ ] Correct number of Conky processes running after launch
- [ ] PID files exist under `runtime/pids/` (`<id>-launcher.pid` plus one per instance)
- [ ] `start-conky.sh` gates on `jq` and `python3` before any redirect, prints bootstrap output,
      and scopes its `pkill` to the suite's own `widgets/` directory
- [ ] Only SitRep is exempt from suite exclusivity
- [ ] Combined launch: `GTEX62_CONKY_PALETTE_OVERRIDE` is honored, with a warning and prompt
      fallback for an unknown name

### Cleanup

- [ ] No legacy script files present in the new suite repo (`scripts/` contains only
      launch/refresh helpers)
- [ ] No duplicate provider logic (all data scripts now live in core)
- [ ] No hardcoded IPs or credentials (moved to `site.toml` or gitignored user files)
- [ ] `suite.toml` and the binding file agree on which domains the suite consumes
- [ ] No per-suite `wallpapers/`, `fonts/`, `icons/` or `assets/` copies (shared-assets only)
- [ ] No leftover OSA-port modules or files nothing `require`s/`dofile`s (grep before deleting)
- [ ] No OSA-inherited `xinerama_head` / `gap` values in any conf, including unconverted ones
- [ ] README Requirements lists `jq`, `python3` and the suite's own tools (`playerctl`, `pactl`, ...)
- [ ] If the suite should appear in Doctor, its domains are covered by Doctor's suite binding
      (Doctor already reports every provider domain — see [doctor-design.md](doctor-design.md))
- [ ] [suite-conversion-final-scan.md](suite-conversion-final-scan.md) has been run once every
      widget in the runbook is marked Done

---

## Known Conversion Pitfalls

### Sky/Astronomy

Legacy suites may use a custom `sky_update.py` (PyEphem) that outputs `theta` angles
(horizontal arc-mapping convention). The core `astro` provider uses `altitude_deg` and
`azimuth_deg` (canonical, human-meaningful). When porting arc drawing code, replace
legacy theta arithmetic with azimuth-to-arc-angle conversion in the view model.

Hard-won specifics from clean-suite-e's ORB port:

- **`astro` and `orb` are different domains.** OSA's ORB panel reads `orb`'s `ephemeris.vars`;
  OSA's TME reads `astro`'s `current.json`. clean-suite-e's arc uses `astro`. Choose per widget.
- Convert compass azimuth to arc position in the **view model only**: `frac = (azimuth − 90)/180`,
  and use y-up math angles (`y = cy − r·sinθ`). Feeding compass azimuth straight into Cairo's
  y-down/clockwise frame puts north at 270°.
- A south-facing legacy arc has West at left, East at right, South at the apex. OSA's mapping
  is mirrored; do not copy it.
- Sun and moon are **time-mapped** rise→set in the legacy suites; azimuth-mapping them makes the
  sun vanish whenever azimuth < 90° (summer mornings). Planets stay azimuth-mapped and hide when
  below the horizon or outside 90–270°.
- Gate drawing on both the rise→set window and provider altitude, so a stale cache cannot draw
  a daytime sun after sunset.
- Verify at several simulated times of day with a fake clock against the live cache.

### pfSense SSH Circuit Breaker

The legacy `pf-ssh-gate.sh` circuit breaker logic must be preserved or superseded when
porting the pfSense widget. The core `pfsense` provider handles its own gating — a gate per
domain (`pf-ssh-gate.sh` is now a core utility with a `GATE_STATE_DIR` override); do not
add a second gate in the suite scripts. See [pfsense-provider-status.md](pfsense-provider-status.md).

### Ping Comes From `net`, Not `connectivity`

`connectivity`'s `current.json` has `ping` fields, but the domain has an `initial_refresh` and
**no `refresh_loop`** in `gtex62-core-launch`, so they freeze at launch. Nothing reads them.
`net` re-implements ping against the same hosts at 1s and owns display duty:
`shared/net/[profile]/state.vars` (`CF_1111_MS`, `GOOGLE_8888_MS`) and `vlan.tsv`. clean-suite-e
shipped NET reading `connectivity` and had to be reopened. Use `connectivity` only for speedtest
snapshots (whose age display also does not refresh continuously). Details:
[architecture.md](architecture.md), [net-provider-reference.md](net-provider-reference.md).

### Don't Copy OSA Leftovers

Suites converted by copying OSA inherit OSA's monitor assumptions (`head 0`, `top_right`,
`gap 0,0`), OSA-flavored view models reading suite-local caches that nothing populates
(`suites/<id>/net/state.vars`, `suites/<id>/orb/ephemeris.vars`), and OSA's tabular panel design.
Read the *legacy* suite's files for geometry and drawing, and core caches for data. Delete
unused OSA-port modules once nothing references them.

### Missing Profile Means a Silent 60s TTL

Adding a provider (or a suite binding that names a new profile) without installing the profile
TOML does not error — meters just stop moving. Re-run
`gtex62-core-bootstrap-runtime`, then `ls ~/.config/gtex62-core/profiles/<domain>/`. Doctor
flags this as a `ttl_fallback`.

### Disabled vs. Empty

A domain can be off (core toggle or profile `enabled = false`), in cold-start grace, stale, or
genuinely zero. Do not let a disabled domain fall through to a value that looks like real zero
data: check the toggle or a missing cache file and draw an explicit disabled/unavailable state
(SitRep's `ap.lua`/`pihole.lua`/`vpn.lua`/`pf.lua` are the reference). What each domain reports in
each condition is in [doctor-missing-conditions.md](doctor-missing-conditions.md).

### Skip-If-Fresh Cadence and Atomic Reads

Since core 0.9.0/0.9.1 providers treat a cache as fresh only when under 80% of its TTL and write
JSON atomically (temp file + `mv`). Suites should not add their own skip or retry logic, and
should not treat a momentarily empty file as a permanent failure.

### Legacy Content Belongs in SitRep, Not in a Panel

pfBlockerNG, Pi-hole, totals, AP status, VPN, modem, MTR and outage alerts are SitRep's job.
Porting them into a converted suite recreates the duplication the conversion is removing.

### Album Art Image Reload

Conky's `${image}` directive does not hot-reload a file unless its path changes. The
legacy `cover_line.lua` works around this by writing a mtime-named copy. Preserve this
pattern in the ported media module.

Lyrics are now the core `media` domain (`lyrics.json`, write-through library, idle fast path):
the suite side is display-only and must not fetch, cache or score lyrics itself. Playback state,
volume (prefer `pactl` system volume over MPRIS during playback) and cover art stay suite-local.
The docs README lists two `media` bug write-ups (one resolved, one — failed lookups cached as a miss for 12 hours — still open); check them before debugging blank or stuck lyrics.

### Calendar Navigation Offset

Legacy calendar navigation uses a flat offset file (`cal_offset.txt`). This is suite-local
state and must remain so — it is not a core concern. Port it as-is to the suite-local cache
path: `suites/[id]/tme/cal_offset`.

### Monitor Targeting

Legacy suites often hardcode `gap_x` values assuming exact monitor dimensions (e.g., 2780px
for a dual-4K layout). In the new model, use `xinerama_head` to target a monitor and only
use `gap_x`/`gap_y` for intra-monitor offset. This survives resolution and monitor order
changes. OSA's own `monitor_head` in `theme/osa-theme.lua` is edited locally per machine; a
converted suite needs an equivalent single place to set it.

### Theme Hot-Reload

If the legacy suite hot-reloads the theme on every draw (useful during development), preserve
that behavior in the view model layer by wrapping the `dofile` call with a TTL check. Remove
it or gate it behind a debug flag before release — it adds measurable overhead at 0.5s
intervals.

---

## Case Study: gtex62-clean-suite-e

### Background

`gtex62-clean-suite` is the first legacy suite and the first conversion target. It was the
initial Conky suite created, predating the core model entirely, and serves as the canonical
reference for applying this guide.

### Audit Summary

| Category | Count |
| -------- | ----- |
| Conky instances | 9 active (1 optional) → 6 converted (3 chassis + 3 standalone) |
| Lua modules | 8 |
| Data fetch scripts | 30+ |
| Theme files | 2 (theme.lua + theme-pf.lua) |
| External dependencies | curl, jq, playerctl, nvidia-smi, ssh, sqlite3, feh |
| Suite-local data (no core domain) | music (playerctl), notes (flat file), lyrics, AP |

### Chassis Decision

**Hybrid model — 3 grouped chassis + 3 standalone panels** (the original plan had 3 chassis + 1
standalone; the calendar and notes were split out during conversion, see the chassis-combination
pitfall in §6.1).

| Process | Type | Panels | Rationale |
| ------- | ---- | ------ | --------- |
| `clean-monitor` | Chassis | SYS + NET | Core domains; always-on; co-located visually |
| `clean-ambient` | Chassis | WXR + ORB + TME | Core domains; ambient awareness group |
| `clean-media` | Chassis | MSC + LYRICS | Playback suite-local; lyrics from core `media` |
| `clean-calendar` | Standalone | CAL | Legacy calendar was its own top-right window, disjoint from the ambient chassis |
| `clean-notes` | Standalone | NOTES | Legacy notes was its own top-right window; suite-local flat file |
| `clean-pfsense` | Standalone | VLAN flow arcs only | Visual metaphor is suite-specific; data from core |
| `gtex62-sitrep` | Separate suite | AP + pfBlockerNG + Pi-hole + totals + gateway | Shared across all suites; replaces `apwbe` |

The legacy `pfsense.conky.conf` widget is split per §1.4: the VLAN arc drawing code becomes
the `clean-pfsense` standalone panel; the status/totals/AP blocks are retired from the suite
and replaced by SitRep. The legacy `ap-wbe530.conky.conf` widget is retired entirely — its data
is now covered by SitRep.

Conversion followed the widget-by-widget order in
[clean-suite-e-recovery-runbook.md](clean-suite-e-recovery-runbook.md) after the original
chassis-by-chassis attempt stalled on OSA-copied geometry — see that runbook for every root
cause, measured value and re-opened item.

### Domain Mapping

| Legacy Script(s) | Core Domain | Notes |
| --------------- | ----------- | ----- |
| `owm_fetch.sh`, `owm_fc_*.sh` | `weather` | Core provider replaces all OWM scripts |
| `sky_update.py` (PyEphem) | `astro` | Theta → altitude/azimuth conversion lives in `orb.lua` (the suite's view model) |
| `metar.sh`, `taf.sh`, `airsig_*.sh` | `aviation` | Core provider replaces all AVN scripts |
| `detect_iface.sh` | `network` | Interface/VLAN/WAN fields |
| `net_extras.sh`, `wan_ip.sh` | `net` | Ping and VLAN latency (`state.vars`, `vlan.tsv`) — *not* `connectivity` (see pitfall) |
| Conky built-ins + nvidia-smi | `system` | Extended 2026-07-19 to emit CPU%, memory, GPU util/temp/power/vram, top-CPU/top-mem processes, hostname, kernel; only throughput graphs stay fast-lane |
| `pf-fetch-basic.sh`, `pf-ssh-gate.sh` | `pfsense` | `ifaces.json` feeds the VLAN flow panel |
| `zyxel_cmd.sh`, `ap_status_*.sh` | → SitRep | Retired from suite; core `ap` domain feeds SitRep |
| pfBlockerNG / Pi-hole / totals (bottom half of `pf_widget.lua`) | → SitRep | Retired from suite |
| Lyrics scripts | `media` | Core provider; suite is display-only |
| playerctl / pactl | (suite-local) | Playback state, volume, cover art at draw time in `msc.lua` |
| `~/Documents/conky-notes.txt` | (suite-local) | `notes.lua`, pure-Lua `fold -s -w 39` port, 3 s tick |
| `cal_offset.txt` | (suite-local) | `suites/clean-e/tme/cal_offset` |

### New in clean-suite-e (not in original)

- `air` domain (AQI) was absent in the original and is **not yet wired** — clean-suite-e's
  `suite.toml` records it as reserved for a future ENV sub-panel.
- Palette selection at launch: the original had a single fixed color scheme.
- `suite.toml` manifest and the runtime binding `suites/clean-e.toml`: new; the binding is
  what the core launcher actually reads for profiles and domain gating.
- Lyrics moved to the core `media` domain, and ping moved to `net` after the first attempt
  read the wrong cache.

### Theme Conversion Summary

| Legacy File | Converted To |
| ----------- | ------------ |
| `theme.lua` | `clean-palettes.lua` (colors) + `clean-theme.lua` (fonts/strokes) + `clean-layout.lua` (geometry) + `panels.lua` (panel/box definitions) |
| `theme-pf.lua` | Merged into `panels.lua` (pfSense panel geometry) + `clean-palettes.lua` (pfSense arc colors as named roles) |

The pfSense arc color roles (`arc_wan_in`, `arc_wan_out`, etc.) are added as named entries
in the default palette so the pfSense standalone widget can consume them from the same
theme system as the rest of the suite.

---

## Appendix: Quick Reference — Core Cache Paths

All paths relative to `$GTEX62_CACHE_DIR` (default `~/.cache/gtex62-core/`). The profile
column is the name the example template ships under; a suite binds whichever it likes in
`suites/<id>.toml [profiles]`. File lists are from the live cache on 2026-09-25 — the
per-domain status/reference docs are authoritative for schemas.

```text
shared/
  weather/[home]/
    current.json          current conditions
    forecast_daily.json   multi-day forecast (normalized)
    raw_current.json  raw_forecast.json
    status.json           provider health
  astro/[home]/
    current.json          sun/moon events, altitude/azimuth, rise/set
    status.json
  orb/[home]/
    ephemeris.vars        key=value per-body ephemeris (OSA ORB panel)
  aviation/[home]/
    current.json          parsed METAR/TAF/advisories
    metar_raw.txt  taf_raw.txt  station_model_raw.txt
    status.json
  air/[home]/
    current.json          AQI composite
    raw_openweather.json  raw_airnow_*.json
    status.json
  solar/[home]/
    current.json          UV, shortwave radiation
    status.json
  system/[local]/
    current.json          identity + live CPU/RAM/GPU + hostname/kernel
    processes.json        top_cpu, top_mem
    storage.json          filesystem + swap
    status.json
  time/[local]/
    current.json          clock rows
    status.json
  calendar/[local]/
    events.json  events_cache.txt  seasonal.json
    status.json
  network/[local]/
    current.json          interface, LAN/WAN, DNS, routing
    status.json
  net/[local]/
    state.vars            ping, WAN IP, node/speedtest projection (1s)
    vlan.tsv              VLAN latency rows
    status.json  vpn_state.cache
  connectivity/[default]/
    current.json          reachability, speedtest (ping fields are dead — see pitfalls)
    status.json
  pfsense/[main_router]/
    status.json           CPU/MEM/gateway (60s)
    ifaces.json           per-VLAN byte counters + server-side rates (~1s) — VLAN flow panel
    arp.json  leases.json  gateway_history.json
    router.json  pihole.json  pfblockerng.json
    ap_status.json  ap_clients.json     ← `ap` domain writes here
  vpn/[local]/vpn.json
  modem/[local]/status.json
  mtr/[pi5]/mtr_state.json
  alerts/[main_router]/banner.json  alert_log.txt
  media/[local]/
    lyrics.json  lyrics_state.json  lyrics_last_hit.json  status.json
  github/[default]/current.json  *.total  status.json      (maintainer-only)
  doctor/[local]/status.json                                (suite-driven)

suites/[suite-id]/
  msc/                    media playback + cover-art suite-local cache
  tme/cal_offset          calendar navigation offset
  [other namespaces]      only what the binding's [suite_cache] declares and the suite writes

runtime/
  locks/
  pids/                   [suite-id]-launcher.pid, [suite-id]-[conf]-conky.pid
  stamps/
  [suite-id]-palette  [suite-id]-wallpaper     remembered launch choices
```

Runtime configuration (not cache) lives in `~/.config/gtex62-core/`: `core.toml` (provider
toggles), `site.toml` (location, keys, interface, VLANs, pfSense target), `devices.toml`,
`profiles/<domain>/<profile>.toml`, and `suites/<suite-id>.toml`.
