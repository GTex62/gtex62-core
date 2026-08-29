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
normalization for these v1 domains:

| Core Domain | Covers | Cache Root |
| ----------- | ------ | ---------- |
| `system` | CPU/RAM/GPU/storage/processes/uptime | `shared/system/[profile]/` |
| `time` | Clock, timezone, UTC | (read directly at draw time) |
| `calendar` | Date, offset, seasonal | (read directly at draw time) |
| `astro` | Sun/moon/planets, altitude/azimuth, rise/set | `shared/astro/[profile]/` |
| `weather` | Current conditions, forecast | `shared/weather/[profile]/` |
| `aviation` | METAR, TAF, SIGMET/AIRMET | `shared/aviation/[profile]/` |
| `air` | AQI (OpenWeather + AirNow layering) | `shared/air/[profile]/` |
| `solar` | UV index, shortwave radiation | `shared/solar/[profile]/` |
| `network` | LAN interface, WAN IP, DNS, routing | `shared/network/[profile]/` |
| `connectivity` | Reachability probes, speedtest snapshots (ping *display* is `net`'s job, not this domain's — see architecture.md) | `shared/connectivity/[profile]/` |
| `pfsense` | Router/firewall telemetry via SSH | `suites/[id]/pf/` (suite-local) |

**Suite-local data** — data that does not go through core providers:

- Media player state (playerctl) — read at draw time
- Notes / flat text files — read at draw time
- Lyrics cache — suite-local cache
- AP status — suite-local cache (SSH-based, niche)
- Album art — suite-local cache

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

### 1.4 The pfSense Split Pattern

The pfSense widget in legacy suites conflates two distinct concerns that belong in different
places under the core-native model. Recognizing this split is important because it applies
to every suite that has a pfSense widget — **except `gtex62-osa`, which has none**.

**The three-way split:**

| Component | Owner | Reason |
| --------- | ----- | ------ |
| **VLAN traffic flow visualization** — arcs, meters, rate bars showing WAN/HOME/IOT/GUEST/INFRA throughput | Suite (standalone panel) | Each suite uses a different visual metaphor: arcs in clean-suite and tech-hud, meters in tri-hud, arc-variant in lcars. Same data, different drawing code. Suite owns it. |
| **pfSense raw data** — interface counters, rates, state | Core `pfsense` provider | Fetched once, cached in shared cache, consumed by any suite's VLAN flow panel |
| **Infrastructure status** — pfBlockerNG counts, Pi-hole stats, cumulative data totals, AP client status, gateway health | Core `sitrep` utility | Identical presentation across all suites. No visual identity. Terminal-launched diagnostic tool. |

**Suite VLAN flow panel** — each suite keeps a standalone `.conky.conf` that draws only the
traffic flow visualization for the WAN/VLAN interfaces. It reads from the core `pfsense`
provider cache. The drawing code is suite-owned and can use whatever visual metaphor fits
the suite's design language (arcs, meters, bars, LCARS-style indicators).

The suite's palette should include named arc/meter color roles (`arc_wan_in`, `arc_wan_out`,
`arc_home`, etc.) so the VLAN panel participates in palette switching alongside the rest of
the suite.

**Core sitrep utility** — a single terminal-launched Conky widget living in
`gtex62-core/widgets/sitrep/`. It has its own minimal utilitarian theme (dark, monospace,
no palette selection) and reads from core cache paths shared across all suites. No suite
needs to carry AP status, pfBlockerNG counts, Pi-hole stats, or data totals as a panel.
The `sitrep` command replaces per-suite equivalents like `apwbe` (clean-suite) and
`sitrep` (tech-hud).

**Practical result for each legacy suite conversion:**

- The legacy pfSense widget is split: drawing code for VLAN flow stays in the suite as a
  standalone panel; status/totals/AP drawing code is retired (replaced by sitrep).
- Any standalone AP widget in the suite is retired. AP status is covered by sitrep.
- The suite's `suite.toml` declares the `pfsense` domain in its `[data]` section so the
  core launcher schedules the provider, but the suite only draws the flow visualization.

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

**Not included by design:**

- `assets/`, `fonts/` — use `gtex62-shared-assets`
- `examples/` — in core
- `providers/` — in core
- Duplicate data fetch scripts — in core
- Legacy config backups

### 2.2 Suite Manifest (suite.toml)

#### Versioning

Each converted suite starts at `version = "0.1.0"` and advances independently. **Suite
conversions do not bump the core version.** The core version only changes when the core
itself changes — a new provider added, a cache schema updated, a launcher contract revised.
A suite conversion is a suite-side event; the core is unchanged by it.

The `core_requirement` field declares the minimum core version this suite needs. It only
needs updating if the conversion requires a new core capability that did not previously
exist (e.g., a missing provider the core must now add to support the suite).

| Event | What bumps |
| ----- | ---------- |
| New suite conversion begins | Suite `version` starts at `0.1.0` |
| Suite reaches stable / feature-complete | Suite `version` → `1.0.0` |
| Core adds a new provider or changes a cache schema | Core version bumps |
| Suite requires a new core capability | Suite `core_requirement` lower bound updates |

```toml
suite_id = "[suite-id]"
suite_name = "[Human Name]"
version = "0.1.0"
core_requirement = ">=1.0,<2.0"

[entrypoints]
theme_dir = "theme"
lua_dir = "lua"
widgets_dir = "widgets"
scripts_dir = "scripts"

[theme]
default_palette = "[palette-name]"
palette_catalog = "theme/[suite]-palettes.lua"

[instances]
# One entry per Conky process this suite launches.
# chassis = grouped windows; standalone = individual panel windows.
# type: "chassis" | "standalone"

[[instances.chassis]]
id = "monitor"
conf = "widgets/[suite]-monitor.conky.conf"
description = "System, network, and monitoring panels"

[[instances.chassis]]
id = "ambient"
conf = "widgets/[suite]-ambient.conky.conf"
description = "Weather, astronomy, and time panels"

[[instances.standalone]]
id = "pfsense"
conf = "widgets/[suite]-pfsense.conky.conf"
description = "pfSense router/firewall widget"
optional = true

[data]
# Declare which core domains this suite consumes.
# Core uses this to schedule providers at launch.
domains = ["system", "weather", "astro", "aviation", "network", "pfsense"]
```

---

## Phase 3 — Theme Conversion

Legacy suites typically have one or two monolithic `theme.lua` files that mix colors, fonts,
geometry, per-widget pixel offsets, and sometimes data config. Split this into four files.

### 3.1 Palette Catalog (`[suite]-palettes.lua`)

Extracts color identity only. One table per named color scheme. At minimum, port the existing
scheme as the default; add alternates as desired.

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

Follow the OSA pattern:

- **Slow lane**: Data that changes infrequently — machine identity, weather summary,
  astronomical events. Read from core normalized cache. Cache TTL is managed by the core
  provider scheduler.
- **Fast lane**: Live telemetry that must be responsive — CPU%, RAM%, network throughput,
  current time. Read directly via Conky variables or system calls at each draw cycle.
  Do not route fast-lane data through file cache.

### 4.3 Suite-Local Data

Domains with no core provider (media player, notes, AP status) still follow the same module
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

```bash
#!/usr/bin/env bash
# scripts/bootstrap-runtime.sh
# Delegates to core bootstrap; does not overwrite existing user config.

CORE_DIR="${GTEX62_CORE_DIR:-${HOME}/.config/conky/gtex62-core}"
exec "${CORE_DIR}/bin/gtex62-core-bootstrap-runtime" --suite "[suite-id]" "$@"
```

### 7.2 Suite Launcher

```bash
#!/usr/bin/env bash
# scripts/start-conky.sh

SUITE_DIR="${GTEX62_SUITE_DIR:-${HOME}/.config/conky/gtex62-[suite]-e}"
CORE_DIR="${GTEX62_CORE_DIR:-${HOME}/.config/conky/gtex62-core}"

# Bootstrap runtime if needed.
if [ ! -f "${HOME}/.config/gtex62-core/site.toml" ]; then
  "${SUITE_DIR}/scripts/bootstrap-runtime.sh"
fi

# Palette selection (optional interactive prompt).
PALETTE="${GTEX62_PALETTE:-}"
if [ -z "$PALETTE" ]; then
  echo "Select palette (default: default):"
  # list available palettes from catalog
  read -r PALETTE
  PALETTE="${PALETTE:-default}"
fi
export GTEX62_PALETTE="$PALETTE"
export CONKY_SUITE_DIR="$SUITE_DIR"

# Hand off to core launcher.
exec "${CORE_DIR}/bin/gtex62-core-launch" --suite "[suite-id]"
```

---

## Phase 8 — Verification Checklist

### Data

- [ ] Each core domain this suite uses has a running provider populating its cache
- [ ] Suite cache paths (`suites/[id]/`) exist and are populated at startup
- [ ] Status files exist for all declared domains and show `"state": "ok"`
- [ ] Suite-local data (music, notes, AP) readable at draw time without blocking

### Theme

- [ ] All legacy hardcoded colors removed from Lua modules; replaced with `theme.*` lookups
- [ ] All legacy hardcoded pixel positions removed; replaced with `layout.*` or `panels.*` lookups
- [ ] Palette selection at launch changes colors across all chassis
- [ ] No font fallback failures (test with a minimal system font set)

### Rendering

- [ ] Each chassis window is fully transparent where not drawn
- [ ] No Conky text output visible (all rendering is Cairo)
- [ ] Cairo drawing matches expected panel layout at target resolution
- [ ] No Lua errors in Conky stderr at startup or during refresh

### Launch

- [ ] `start-conky.sh` kills existing processes cleanly before re-launching
- [ ] Bootstrap is idempotent (re-running does not overwrite user config)
- [ ] Core launcher receives correct suite ID and resolves all paths
- [ ] Correct number of Conky processes running after launch
- [ ] PID files exist under `runtime/pids/`

### Cleanup

- [ ] No legacy script files present in the new suite repo (`scripts/` contains only
      launch/refresh helpers)
- [ ] No duplicate provider logic (all data scripts now live in core)
- [ ] No hardcoded IPs or credentials (moved to `site.toml` or gitignored user files)
- [ ] `suite.toml` `domains` list matches what the suite actually consumes

---

## Known Conversion Pitfalls

### Sky/Astronomy

Legacy suites may use a custom `sky_update.py` (PyEphem) that outputs `theta` angles
(horizontal arc-mapping convention). The core `astro` provider uses `altitude_deg` and
`azimuth_deg` (canonical, human-meaningful). When porting arc drawing code, replace
legacy theta arithmetic with azimuth-to-arc-angle conversion in the view model.

### pfSense SSH Circuit Breaker

The legacy `pf-ssh-gate.sh` circuit breaker logic must be preserved or superseded when
porting the pfSense widget. The core `pfsense` provider handles its own gating; do not
add a second gate in the suite scripts.

### Album Art Image Reload

Conky's `${image}` directive does not hot-reload a file unless its path changes. The
legacy `cover_line.lua` works around this by writing a mtime-named copy. Preserve this
pattern in the ported media module.

### Calendar Navigation Offset

Legacy calendar navigation uses a flat offset file (`cal_offset.txt`). This is suite-local
state and must remain so — it is not a core concern. Port it as-is to the suite-local cache
path: `suites/[id]/tme/cal_offset`.

### Monitor Targeting

Legacy suites often hardcode `gap_x` values assuming exact monitor dimensions (e.g., 2780px
for a dual-4K layout). In the new model, use `xinerama_head` to target a monitor and only
use `gap_x`/`gap_y` for intra-monitor offset. This survives resolution and monitor order
changes.

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
| Conky instances | 9 active (1 optional) |
| Lua modules | 8 |
| Data fetch scripts | 30+ |
| Theme files | 2 (theme.lua + theme-pf.lua) |
| External dependencies | curl, jq, playerctl, nvidia-smi, ssh, sqlite3, feh |
| Suite-local data (no core domain) | music (playerctl), notes (flat file), lyrics, AP |

### Chassis Decision

**Hybrid model — 3 grouped chassis + 1 standalone panel.**

| Process | Type | Panels | Rationale |
| ------- | ---- | ------ | --------- |
| `clean-monitor` | Chassis | SYS + NET | Core domains; always-on; co-located visually |
| `clean-ambient` | Chassis | WXR + ORB + TME | Core domains; ambient awareness group |
| `clean-media` | Chassis | MSC + NOTES + LYRICS | Suite-local; personal/media group |
| `clean-pfsense` | Standalone | VLAN flow arcs only | Visual metaphor is suite-specific; data from core |
| `sitrep` | Core utility | AP + pfBlockerNG + Pi-hole + totals + gateway | Shared across all suites; replaces `apwbe` |

The legacy `pfsense.conky.conf` widget is split per §1.4: the VLAN arc drawing code becomes
the `clean-pfsense` standalone panel; the status/totals/AP blocks are retired from the suite
and replaced by the shared `sitrep` core utility. The legacy `ap-wbe530.conky.conf` widget
is retired entirely — its data is now covered by `sitrep`.

### Domain Mapping

| Legacy Script(s) | Core Domain | Notes |
| --------------- | ----------- | ----- |
| `owm_fetch.sh`, `owm_fc_*.sh` | `weather` | Core provider replaces all OWM scripts |
| `sky_update.py` (PyEphem) | `astro` | Migrate theta → altitude/azimuth in orb.lua |
| `metar.sh`, `taf.sh`, `airsig_*.sh` | `aviation` | Core provider replaces all AVN scripts |
| `detect_iface.sh`, `net_extras.sh`, `wan_ip.sh` | `network` + `connectivity` | Core provider; suite-local VLAN view in net.lua |
| Conky built-ins + nvidia-smi | `system` | Core provider covers slow-lane; fast-lane stays direct |
| `pf-fetch-basic.sh`, `pf-ssh-gate.sh` | `pfsense` | Core provider; feeds VLAN flow panel + sitrep |
| `zyxel_cmd.sh`, `ap_status_*.sh` | → sitrep | Retired from suite; AP data consumed by sitrep core utility |
| pfBlockerNG / Pi-hole / totals (bottom half of `pf_widget.lua`) | → sitrep | Retired from suite; covered by sitrep core utility |
| playerctl | (suite-local) | Read at draw time in msc.lua |
| `~/Documents/conky-notes.txt` | (suite-local) | Direct read at draw time |
| Lyrics cache | (suite-local) | `suites/clean-e/msc/lyrics/` |

### New in clean-suite-e (not in original)

- `air` domain: AQI data (OpenWeather + AirNow) was absent in the original; added to
  the ambient chassis ENV sub-panel.
- Palette selection at launch: the original had a single fixed color scheme.
- `suite.toml` manifest: new; enables core discovery and version compatibility checks.

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

All paths relative to `$GTEX62_CACHE_DIR` (default `~/.cache/gtex62-core/`).

```text
shared/
  weather/[profile]/
    current.json          current conditions
    forecast.json         multi-day forecast
    status.json           provider health
  astro/[profile]/
    current.json          sun/moon/planet positions, rise/set times
    status.json
  aviation/[profile]/
    metar.json            parsed METAR
    taf.json              parsed TAF
    advisories.json       filtered SIGMET/AIRMET
    status.json
  system/[profile]/
    current.json          machine identity, CPU/RAM/GPU inventory
    processes.json        top processes
    storage.json          filesystem + swap
    status.json
  network/[profile]/
    current.json          interface, LAN/WAN, DNS, routing
    status.json
  connectivity/[profile]/
    current.json          reachability, speedtest
    status.json
  air/[profile]/
    current.json          AQI composite
    status.json
  solar/[profile]/
    current.json          UV, shortwave radiation
    status.json

suites/[suite-id]/
  pf/                     pfSense suite-local cache
  ap/                     AP suite-local cache
  net/                    suite-local network projections
  msc/                    media player + lyrics suite-local cache
    lyrics/

runtime/
  locks/
  pids/
  stamps/
```
