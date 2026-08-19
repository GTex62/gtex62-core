# SitRep Relocation Plan

Moving `sitrep.lua` out of `gtex62-tech-hud` into the engine as a suite-agnostic
`sitrep` command. This is what a future relocation session reads first: the Part 0 audit
findings, why Part 1 is currently blocked, the resume checklist, and the target file
split/layout.

Companion docs: [SitRep Architecture](sitrep-architecture.md) (the stable design this
relocation implements), [pfSense Provider Status](pfsense-provider-status.md) and
[AP Provider Status](ap-provider-status.md) (the data sources this widget must become a
pure consumer of — ARP/DHCP collection is the remaining blocker, see Part 0 Audit below).
Full prose history predating this split:
[archive/sitrep-engine-migration-2026-08-18.md](archive/sitrep-engine-migration-2026-08-18.md).

---

## Guardrails

- **`gtex62-tech-hud` and `gtex62-osa` are read-only for this effort.** Audit, read,
  cross-check against them — never edit.
- **Copy, not move.** The relocated `sitrep.lua`/`sitrep.conky.conf`/`theme-sitrep.lua` are
  freshly authored at the new engine location reading engine cache paths. The legacy
  `gtex62-tech-hud` copies are left running untouched via `~/.local/bin/sitrep` until the
  new one is verified — there is no step where the legacy files are deleted or edited as
  part of this relocation.
- **New binary name: `sitrep-e`.** The relocated launcher and its PID file
  (`conky-sitrep-e.pid` under `${XDG_RUNTIME_DIR:-$HOME/.cache}`) are distinct from the
  legacy `sitrep` / `conky-sitrep.pid`, so both can coexist during verification without
  colliding.
- **No suite dependency.** The engine-resident widget must launch and render with
  `CONKY_SUITE_DIR` unset — see Widget Relocation § Target Location below.

---

## SitRep as Cache Consumer

In the migrated model, SitRep's Lua view model reads from engine cache paths only.

```lua
-- lua/suite/pf.lua (SitRep view model)

local HOME  = os.getenv("HOME") or ""
local CACHE = os.getenv("GTEX62_CACHE_DIR") or (HOME .. "/.cache/gtex62-core")
local PF    = CACHE .. "/shared/pfsense/default/"

local function jq(path, filter)
  local cmd = string.format("jq -r %q %q 2>/dev/null", filter, path)
  local h = io.popen(cmd)
  if not h then return "" end
  local s = h:read("*a")
  h:close()
  return (s or ""):gsub("^%s*(.-)%s*$", "%1")
end

function M.gateway_online()
  return jq(PF .. "status.json", ".gateway.online // false")
end

function M.iface_ibytes(key)
  return tonumber(jq(PF .. "status.json", ".interfaces." .. key .. ".ibytes // 0"))
end

function M.ap_clients(ap_index)
  -- Returns array of {name, ip, mac} tables
  return jq(PF .. "ap_clients.json",
    ".aps[" .. ap_index .. "].clients[] | .name // .ip")
end

function M.cache_age_seconds()
  local h = io.popen("stat -c %Y " .. PF .. "status.json 2>/dev/null")
  if not h then return nil end
  local mtime = tonumber(h:read("*a"))
  h:close()
  if not mtime then return nil end
  return os.time() - mtime
end
```

### Staleness Indicator

The `ONLINE` status slot in the top-right of the widget becomes cache-aware:

| Condition | Display |
| --- | --- |
| Cache fresh, gateway online | `ONLINE` |
| Cache fresh, gateway offline | `OFFLINE` |
| Cache age > 120s (2× poll cadence) | `STALE · 4m ago` |
| `ssh_gate.tripped == true` in cache | `SSH DOWN` |
| `status.json` missing | `NO DATA` |

---

## sitrep.lua — File Split and Dead Code Removal

The current `sitrep.lua` contains three distinct Cairo widgets and a significant amount of
dead code from the original graphical SitRep design. Before relocation, the file must be
split and cleaned.

### Current File Contents

| Section | Lines (approx) | Status |
| --- | --- | --- |
| `conky_draw_sitrep()` and sitrep-specific helpers | ~40% of file | Keep — relocate to engine |
| `draw_system_impl()` / `conky_draw_system()` / `conky_draw_system_embed()` | ~25% of file | Move to tech-hud suite |
| `draw_network_impl()` / `conky_draw_network()` / `conky_draw_network_embed()` | ~25% of file | Move to tech-hud suite |
| Dead code from original graphical SitRep design | ~10% of file | Delete |

### Dead Code — Delete Entirely

These functions and variables are defined but never called in the `conky_draw_sitrep()`
draw path. They are remnants of the original gauge/arc-based SitRep design:

**Arc drawing infrastructure** — used only by system/network circle widgets, not SitRep:
- `draw_arc_meter()`
- `draw_text_arc()`
- `polar()`
- `arc_span_ccw()`
- `arc_span_cw()`

**Graphical meter functions** — defined, never called in sitrep draw path:
- `draw_meters()` — vertical bar meters for VRM/GPU/RAM/CPU
- `draw_pfsense_meters()` — paired in/out bar meters per VLAN; references a
  `conky_pf_rates()` function from the old pfSense arc widget era

**Network EMA smoothing** — belongs to `draw_network_impl`, not SitRep:
- `net_ema` table
- All EMA update logic inside `draw_network_impl`

**Unused summary function:**
- `pf_summary()` — defined, never called; superseded by `pf_data_full()`

**WAN IP helpers** — used only by `draw_network_impl`:
- `wan_ip_label_short()`
- `refresh_wan_ip()`

**OS version and age display** — used only by `draw_system_impl`:
- `os_label_text()`
- `get_root_birth_ts()`
- `OS_AGE_CACHE` table

**Seasonal tint system** — used only by system/network circle widgets:
- `current_season_label()`
- `read_seasonal_vars()`
- `day_of_year_for_date()`
- `SEASON_CACHE` table
- `blend_color()`

### Code to Move — System and Network Circle Widgets

`draw_system_impl()`, `conky_draw_system()`, and `conky_draw_system_embed()` are a
complete self-contained Cairo widget. Move to:

```
gtex62-tech-hud/lua/widgets/system.lua
```

`draw_network_impl()`, `conky_draw_network()`, and `conky_draw_network_embed()` are a
complete self-contained Cairo widget. Move to:

```
gtex62-tech-hud/lua/widgets/network.lua
```

The `_embed()` variants use `util.embedded_corner_offset()` from the suite's `util.lua`
and depend on `t.embedded_corners` from the suite theme — they are suite-coupled by
design and belong in the suite, not the engine.

### What Remains in sitrep.lua After Split

The cleaned engine-resident `widgets/sitrep/sitrep.lua` contains only:

**Utility functions** (keep as-is):
- `trim()`, `to_num()`, `clamp()`, `cparse()`
- `draw_text_right()`, `text_width()`, `draw_round_rect()`
- `fmt_bytes_iec()`, `fmt_int_commas()`, `fmt_uptime()`

**Theme loader** (keep, update path):
- `get_sitrep_theme()` — update to resolve from `GTEX62_CORE_DIR`, not `CONKY_SUITE_DIR`

**Data layer** (replace with engine cache reads):
- `parse_kv()` — remove once data source is JSON cache
- `pf_data_full()` — replace with `jq` reads from `status.json`, `router.json`
- `ap_cached_output()` — remove; engine provider writes cache directly
- `parse_ap_status()` — remove; engine provides structured `ap_status.json`
- `parse_ap_clients_named()` — remove; engine provides structured `ap_clients.json`
- `ap_blocks()` — replace with `jq` reads from `ap_status.json`, `ap_clients.json`

**Draw functions** (keep as-is — pure Cairo, no data coupling):
- `draw_pfsense_totals()`
- `draw_pfsense_status()`
- `draw_centered_segments()`
- `draw_hr_at()`
- AP block renderer inside `conky_draw_sitrep()`

**Main entrypoint** (keep, update data reads):
- `conky_draw_sitrep()` — update all data reads from `parse_kv/cparse/execi` pattern
  to `jq(cache_path, filter)` pattern

### Data Read Migration Map

Every data read in `conky_draw_sitrep()` maps to an engine cache file. Schemas for these
files are in [pfSense Provider Status](pfsense-provider-status.md) § Domain Schemas.

| Current Read | Pattern | Engine Cache | JSON Path |
| --- | --- | --- | --- |
| Gateway online | `pf-fetch-basic.sh medium` via execi | `status.json` | `.gateway.online` |
| pfSense version | `pf-fetch-basic.sh full` cached | `router.json` | `.version` |
| pfSense BIOS | same | `router.json` | `.bios_version` |
| Load average | same | `router.json` | `.load.l5` |
| CPU core count | same | `router.json` | `.ncpu` |
| Interface ibytes | same | `status.json` | `.interfaces.WAN.ibytes` |
| Interface obytes | same | `status.json` | `.interfaces.WAN.obytes` |
| pfBlockerNG IP count | same | `pfblockerng.json` | `.pfb_ip_total` |
| pfBlockerNG DNSBL count | same | `pfblockerng.json` | `.pfb_dnsbl_total` |
| pfBlockerNG hit pct | same | `pfblockerng.json` | `.pfb_dnsbl_pct` |
| Resolver total queries | same | `pfblockerng.json` | `.resolver_total` |
| Pi-hole active | same | `pihole.json` | `.active` |
| Pi-hole load | same | `pihole.json` | `.load15` |
| Pi-hole total queries | same | `pihole.json` | `.total` |
| Pi-hole blocked | same | `pihole.json` | `.blocked` |
| Pi-hole domains | same | `pihole.json` | `.domains` |
| AP CPU% | `ap_status_all_clients.sh` cached | `ap_status.json` | `.aps[n].cpu_pct` |
| AP client count | same | `ap_status.json` | `.aps[n].clients` |
| AP known client names | `ap_clients_named.sh` cached | `ap_clients.json` | `.aps[n].clients[].name` |
| AP unknown client IPs | same | `ap_clients.json` | `.aps[n].unknown[].ip` |

### Suite Dependency Removals

The following suite-coupled references must be removed or replaced in the engine-resident
file:

| Current Reference | Action |
| --- | --- |
| `SUITE_DIR` (all uses) | Replace with `CORE_DIR` from `GTEX62_CORE_DIR` env var |
| `CACHE_DIR` (legacy conky cache) | Replace with `GTEX62_CACHE_DIR` engine cache paths |
| `WD_BLACK_PATH` | Remove — disk label is a system widget concern, not SitRep |
| `util = dofile(SUITE_DIR .. "/lua/lib/util.lua")` | Replace with engine-resident util or inline the needed functions |
| `pcall(dofile, ... "/lua/widgets/widgets.lua")` | Remove — suite widget loader |
| `pcall(dofile, ... "/lua/widgets/pf_widget.lua")` | Remove — legacy pfSense widget |
| `CONKY_CACHE_DIR` / `PF_CACHE_DIR` / `AP_CACHE_DIR` | Replace with engine cache paths |

---

## Widget Relocation — Target Layout

### Current Location and Problem

```
~/.config/conky/gtex62-tech-hud/widgets/sitrep.conky.conf
```

The current `.conky.conf` resolves all geometry and theming through `gtex62-tech-hud/theme.lua`:

```lua
local SUITE_DIR = os.getenv("CONKY_SUITE_DIR")
               or (os.getenv("HOME") .. "/.config/conky/gtex62-tech-hud")
local theme = dofile(SUITE_DIR .. "/theme.lua")
local pos   = theme.layout_pos("sitrep")
SITREP_THEME = SUITE_DIR .. "/theme-sitrep.lua"
```

This means SitRep cannot launch without the tech-hud environment. If `CONKY_SUITE_DIR` is
unset and the tech-hud directory is absent, the config fails at `dofile`. This directly
violates the core principle: SitRep must work regardless of which suite is active.

### Target Location

```
~/.config/conky/gtex62-core/widgets/sitrep/
├── sitrep.conky.conf       ← decoupled config
├── sitrep.lua              ← Cairo draw entrypoint (file-split/dead-code work covered above)
├── theme-sitrep.lua        ← theme: monitor_head, palette resolution, colors/roles, strokes,
│                              frame_shadow/frame_lights FX, fonts/text/spacing
├── sitrep-palettes.lua     ← SitRep's own palette catalog
├── sitrep-layout.lua       ← scalable coordinate space: frame, scale_mode, scaled_frame
└── sitrep-panels.lua       ← panel geometry: pfSense, Pi-hole, pfBlockerNG, AP status/clients
```

SitRep lives in the engine, not in any suite. Each suite that previously carried a SitRep
panel retires it in favor of the `sitrep` command which launches this engine-resident widget.

> The original draft of this plan used `gtex62-conky-engine` as the target repo name —
> that repo doesn't exist on disk. The actual engine repo is `gtex62-core`; the path above
> reflects that.

### Design Direction (decided Aug 19, 2026)

The three-file "minimal, standalone" sketch this section originally carried predates
tonight's design decision and is superseded. SitRep-e's actual visual direction: it mimics
OSA's look, feel, borders, and panel style, and — importantly — reuses the same *structural
pattern* as OSA's own multi-file theme (`theme.lua` + `*-palettes.lua` + `*-layout.lua`,
resolved palette → `colors`/`roles`, shared FX blocks, engine `window_size()` /
`session_text_scale()`), while remaining fully self-owned. SitRep never reads OSA's theme,
palette, or layout files at runtime — it has its own copies, tuned to its own panels. The
only thing genuinely shared is the engine runtime module
(`$GTEX62_CORE_DIR/lua/runtime/window.lua`), the same runtime OSA itself calls into — not a
dependency on the OSA suite.

Reference for the pattern being mirrored (structure only, values are SitRep's own):
[`gtex62-osa/theme/osa-theme.lua`](../../gtex62-osa/theme/osa-theme.lua) and
[`gtex62-osa/theme/osa-layout.lua`](../../gtex62-osa/theme/osa-layout.lua). This also means
the old "no palette selection, no suite color roles" framing is dropped — SitRep gets its
own palette selection (env-var override) and its own `colors`/`roles`, just never OSA's.

### Decoupled conky.conf

The suite dependency is replaced with a core directory resolution. `theme-sitrep.lua` is
the single `dofile` target here — it internally cascades into
`sitrep-palettes.lua` → `sitrep-layout.lua` → `sitrep-panels.lua`, mirroring how OSA's
`theme.lua` loads `osa-palettes.lua`:

```lua
-- widgets/sitrep/sitrep.conky.conf

local CORE_DIR = os.getenv("GTEX62_CORE_DIR")
              or (os.getenv("HOME") .. "/.config/conky/gtex62-core")
local THEME_FILE = CORE_DIR .. "/widgets/sitrep/theme-sitrep.lua"
local theme = dofile(THEME_FILE)

conky.config = {
  alignment              = 'top_left',
  xinerama_head          = theme.monitor_head or 0,
  background             = false,
  double_buffer          = true,
  update_interval        = 1,

  use_xft                = true,

  own_window             = true,
  own_window_type        = 'desktop',
  own_window_hints       = 'undecorated,sticky,skip_taskbar,skip_pager,below',
  own_window_argb_visual = true,
  own_window_argb_value  = 0,
  own_window_transparent = true,
  own_window_class       = 'Conky',

  -- Fallback literals only; real geometry comes from theme.window_size(layout.scaled_frame).
  -- Wider/taller than the old minimal sketch — provisional pending final size/placement
  -- confirmation (see theme.monitor_head note below).
  minimum_width          = theme.min_w  or 900,
  maximum_width          = theme.max_w  or 1000,
  minimum_height         = theme.min_h  or 1200,

  gap_x                  = theme.gap_x  or 0,
  gap_y                  = theme.gap_y  or 0,

  draw_shades            = false,
  draw_borders           = false,
  default_color          = 'C0C0C0',
  color1                 = '808080',

  lua_load               = CORE_DIR .. "/widgets/sitrep/sitrep.lua",
  lua_draw_hook_pre      = 'draw_sitrep',
}

conky.text = [[]]
```

### theme-sitrep.lua — OSA-Pattern Theme

SitRep's theme follows OSA's structural pattern end to end — resolved palette, derived
`colors`/`roles`, `strokes`, `frame_shadow`/`frame_lights` FX, fonts/text/spacing, and the
engine's `window_size()` / `session_text_scale()` reused by calling into the engine runtime
directly (same as OSA does) rather than reimplemented. It never reads any OSA file; every
`dofile` target here is a sibling in `widgets/sitrep/`.

```lua
-- widgets/sitrep/theme-sitrep.lua

local theme = {}
local HOME = os.getenv("HOME") or ""
local CORE_DIR = os.getenv("GTEX62_CORE_DIR")
    or os.getenv("GTEX62_CONKY_ENGINE_DIR")
    or (HOME .. "/.config/conky/gtex62-core")
local WIDGET_DIR = CORE_DIR .. "/widgets/sitrep"

local palette_catalog = dofile(WIDGET_DIR .. "/sitrep-palettes.lua")
local layout = dofile(WIDGET_DIR .. "/sitrep-layout.lua")
theme.layout = layout

local function load_engine_runtime()
  local ok, runtime = pcall(dofile, CORE_DIR .. "/lua/runtime/window.lua")
  if ok and type(runtime) == "table" then
    return runtime
  end
  return nil
end

local engine_runtime = load_engine_runtime()

-- Monitor selection (0 = primary). Provisional per Aug 19, 2026 decision — pending final
-- size/placement confirmation once the widget is actually laid out on-screen.
theme.monitor_head = 0

-- Palette (own catalog — env override mirrors CONKY_OSA_PALETTE's pattern)
theme.default_palette = palette_catalog.default or "console_green"
theme.active_palette = os.getenv("CONKY_SITREP_PALETTE") or theme.default_palette
theme.palettes = palette_catalog.palettes or {}

theme.palette = theme.palettes[theme.active_palette] or theme.palettes[theme.default_palette]
theme.resolved_palette = theme.palette == theme.palettes[theme.active_palette]
    and theme.active_palette
    or theme.default_palette

theme.colors = {
  bg = theme.palette.bg,
  fg = theme.palette.fg,
  ink = theme.palette.ink,
}

theme.roles = {
  background = theme.colors.bg,
  foreground = theme.colors.fg,
  fill = theme.colors.fg,
  inverse_text = theme.colors.ink,
}

theme.strokes = {
  line = 1,
  frame = 8,
  frame_alpha = 0.99,
}

----------------------------------------------------------------
-- Theme FX — SitRep's own tuned values, own copy of the tables
-- (not shared with OSA's theme.frame_shadow / theme.frame_lights)
----------------------------------------------------------------
theme.frame_shadow = {
  enabled = true,
  color = { 0.0, 0.0, 0.0 },
  alpha_scale = 1.25,
  sides = { 1, 1, 1, 1 },
  side_alpha = { 1.0, 0.45, 0.45, 1.0 },
  bands = {
    { offset = 8.0,  width = 8.0, alpha = 0.40 },
    { offset = 10.0, width = 8.0, alpha = 0.30 },
    { offset = 12.0, width = 8.0, alpha = 0.20 },
    { offset = 16.0, width = 8.0, alpha = 0.10 },
  },
}

theme.frame_lights = {
  enabled = "auto",
  auto_bg_threshold = 0.70,
  color_mode = "auto",
  color_lift = 0.16,
  color_warmth = { 0.06, 0.03, 0.00 },
  radius_scale = 1.0,
  radius_y_scale = 1.0,
  alpha_scale = 1.0,
  top_frame_y_offset = 18,
  light_count = 6,
  light_gap = 290,
  lights = {
    -- SitRep-tuned light rig; same shape as OSA's, own count/placement to taste.
    { x = "center", y = "top_frame", radius = 40.0, radius_y = 20.0,
      color = { 1.0, 0.9, 0.9 }, alpha = 0.3 },
  },
}

----------------------------------------------------------------
-- Fonts / Text / Spacing
----------------------------------------------------------------
theme.fonts = {
  title = "Eurostile LT Std",
  data = "JetBrainsMono Nerd Font",
}

theme.text = {
  panel_title_pt = 18,
  body_pt = 16,
  body_sm_pt = 14,
  micro_pt = 12,
}

theme.spacing = {
  grid = 8,
  title_pad_x = 24,
  title_clearance = 8,
  box_title_x = 16,
}

-- Panel geometry (pfSense / Pi-hole / pfBlockerNG / AP status)
theme.panels = dofile(WIDGET_DIR .. "/sitrep-panels.lua")

function theme.session_text_scale()
  if engine_runtime and engine_runtime.session_text_scale then
    return engine_runtime.session_text_scale()
  end
  return 1.0
end

function theme.window_size(frame)
  if engine_runtime and engine_runtime.window_size then
    return engine_runtime.window_size(frame)
  end
  frame = frame or {}
  local scale = theme.session_text_scale()
  return {
    width = math.floor(((frame.width or layout.frame.width) / scale) + 0.5),
    height = math.floor(((frame.height or layout.frame.height) / scale) + 0.5),
  }
end

return theme
```

### sitrep-palettes.lua — SitRep's Own Palette Catalog

Same `default` + `palettes` shape as `osa-palettes.lua` (a role-3 `bg`/`fg`/`ink` table per
named palette), but this is SitRep's own file with its own values — inspired by OSA's
current palette, not read from it or shared at runtime:

```lua
-- widgets/sitrep/sitrep-palettes.lua

return {
  default = "console_green",
  palettes = {
    console_green = {
      bg  = { 0.05, 0.08, 0.05 },   -- dark green-black
      fg  = { 0.75, 0.90, 0.65 },   -- phosphor green
      ink = { 0.45, 0.60, 0.40 },   -- dimmed label
    },
    console_amber = {
      bg  = { 0.0, 0.0, 0.0 },
      fg  = { 1.0, 0.8, 0.2 },
      ink = { 0.5, 0.4, 0.1 },
    },
    console_blue = {
      bg  = { 0.03, 0.03, 0.05 },
      fg  = { 0.4, 0.75, 1.0 },
      ink = { 0.2, 0.35, 0.5 },
    },
  },
}
```

### sitrep-layout.lua — Scalable Coordinate Space

Same `frame` / `scale_mode` / `scaled_frame` pattern as `osa-layout.lua`, with SitRep's own
base frame — wider/taller than the old minimal sketch's narrow portrait dimensions — and
column/row definitions sized for SitRep's actual panels, not OSA's:

```lua
-- widgets/sitrep/sitrep-layout.lua

local layout = {}

-- SitRep's own coordinate space. Wider/taller than the legacy minimal design
-- (was ~460-560 x 800) to fit four status panels. Provisional pending final
-- size/placement confirmation.
layout.frame = {
  x = 0,
  y = 0,
  width = 900,
  height = 1200,
}

layout.scale_mode = "manual"
layout.scale = 1.0

layout.columns = {
  main = { x = 24, width = 852 },
}

layout.rows = {
  pfsense      = { y = 40,  height = 260 },
  pihole       = { y = 320, height = 200 },
  pfblockerng  = { y = 540, height = 200 },
  ap_status    = { y = 760, height = 400 },
}

local function _compute_scale()
  if layout.scale_mode == "auto" then
    local w = tonumber(os.getenv("CONKY_SCREEN_W"))
    local h = tonumber(os.getenv("CONKY_SCREEN_H"))
    local bw = layout.frame.width
    local bh = layout.frame.height
    if w and h and bw > 0 and bh > 0 then
      return math.min(w / bw, h / bh)
    end
  end
  return tonumber(layout.scale) or 1.0
end

local _s = _compute_scale()
layout.scaled_frame = {
  x      = math.floor(layout.frame.x * _s + 0.5),
  y      = math.floor(layout.frame.y * _s + 0.5),
  width  = math.floor(layout.frame.width * _s + 0.5),
  height = math.floor(layout.frame.height * _s + 0.5),
}

return layout
```

### sitrep-panels.lua — Panel Geometry

New — the old minimal design had no panel geometry at all since it wasn't meant to display
structured sections. This is SitRep's own set, one section per thing it actually shows;
none of it maps onto OSA's sys/net/tme/orb/wxr/env sections:

```lua
-- widgets/sitrep/sitrep-panels.lua

return {
  pfsense = {
    x = 0, y = 0, width = 852,
    header_h = 20, header_font_pt = 16,
    row_h = 20, rows = 8, row_font_pt = 14,
  },
  pihole = {
    x = 0, y = 0, width = 852,
    header_h = 20, header_font_pt = 16,
    row_h = 20, rows = 6, row_font_pt = 14,
  },
  pfblockerng = {
    x = 0, y = 0, width = 852,
    header_h = 20, header_font_pt = 16,
    row_h = 20, rows = 6, row_font_pt = 14,
  },
  ap_status = {
    x = 0, y = 0, width = 852,
    header_h = 20, header_font_pt = 16,
    row_h = 18, rows = 16, row_font_pt = 14,
    client_name_w = 220, client_ip_w = 140, client_mac_w = 160,
  },
}
```

### Launch Script

The `sitrep-e` command is a thin shell wrapper in the engine's `bin/` directory (named
`-e` — see Guardrails above — to coexist with the legacy `sitrep` command during
verification):

```bash
#!/usr/bin/env bash
# bin/sitrep-e
# Launch the SitRep operational console.
# Works regardless of which suite is active.

CORE_DIR="${GTEX62_CORE_DIR:-${HOME}/.config/conky/gtex62-core}"
CONF="${CORE_DIR}/widgets/sitrep/sitrep.conky.conf"
PID_FILE="${XDG_RUNTIME_DIR:-$HOME/.cache}/conky-sitrep-e.pid"

if [[ ! -f "$CONF" ]]; then
  echo "SitRep config not found: $CONF" >&2
  exit 1
fi

# Kill any existing sitrep-e instance
pkill -f "sitrep.conky.conf" 2>/dev/null || true
sleep 0.3

export GTEX62_CORE_DIR="$CORE_DIR"
conky -c "$CONF" &
echo $! > "$PID_FILE"
```

Symlink or add `bin/` to `$PATH` so `sitrep-e` works from any terminal context.

### Per-Suite Migration

Each suite that currently carries a SitRep panel handles it as follows during conversion:

| Suite | Action |
| --- | --- |
| `gtex62-tech-hud` | Remove `widgets/sitrep.conky.conf`; `sitrep-e` command replaces it |
| `gtex62-clean-suite` | Remove `apwbe` widget; `sitrep-e` command replaces it |
| `gtex62-tri-hud` | Audit for equivalent panel; retire in favor of `sitrep-e` |
| `gtex62-lcars` | Audit for equivalent panel; retire in favor of `sitrep-e` |
| `gtex62-osa` | No SitRep panel — `sitrep-e` available as standalone command only |

No suite carries a SitRep panel after migration. The widget lives in the engine and is
suite-agnostic by design.

---

## Relocation Checklist

### sitrep.lua File Split

- [ ] Extract `draw_system_impl` / `conky_draw_system` / `conky_draw_system_embed` →
      `gtex62-tech-hud/lua/widgets/system.lua`
- [ ] Extract `draw_network_impl` / `conky_draw_network` / `conky_draw_network_embed` →
      `gtex62-tech-hud/lua/widgets/network.lua`
- [ ] Delete all dead code from original graphical SitRep design (see dead code list above)
- [ ] Verify tech-hud suite still renders correctly after extraction
- [ ] Verify no remaining references to deleted functions in theme or other widget files

### Widget Relocation

- [ ] Create `widgets/sitrep/` directory in engine
- [ ] Write decoupled `sitrep.conky.conf` — resolves from `GTEX62_CORE_DIR`, no suite deps
- [ ] Write self-contained `theme-sitrep.lua` — no suite palette, no `theme.lua` dependency
- [ ] Move `sitrep.lua` Cairo draw entrypoint to `widgets/sitrep/sitrep.lua`
- [ ] Write `bin/sitrep-e` launch wrapper
- [ ] Verify `sitrep-e` launches cleanly with `CONKY_SUITE_DIR` unset
- [ ] Remove `sitrep.conky.conf` from `gtex62-tech-hud/widgets/` (only after `sitrep-e`
      is verified working — see Guardrails)

### SitRep View Model

- [ ] Write `lua/suite/pf.lua` consuming `status.json`, `ap_status.json`, `ap_clients.json`
- [ ] Implement `cache_age_seconds()` helper
- [ ] Implement `iface_rate_mbps()` with counter delta across draw cycles
- [ ] Map status classes to display strings and color roles
- [ ] Add staleness indicator to status slot
- [ ] Remove all direct SSH calls from SitRep Lua/scripts

### Verification

- [ ] `sitrep-e` works with engine running — data is live
- [ ] `sitrep-e` works with engine stopped — stale cache renders with age indicator
- [ ] `sitrep-e` works with no cache — `NO DATA` displays cleanly, no Lua errors
- [ ] SSH gate trip reflected in status slot — degrades gracefully
- [ ] APIPA device appears in APIPA section, not as UNKNOWN
- [ ] Counter wraparound on 32-bit interfaces handled without spike

---

## Relocation Session — Part 0 Audit (Aug 18, 2026)

**Status: BLOCKED pending decision.** Read-only audit of `gtex62-tech-hud`'s live SitRep
completed; nothing modified there. Findings below split into (A) ordinary path-coupling
fixes expected by this doc, and (B) a premise-level discrepancy that stops Part 1 from
starting until resolved.

### Files audited (read-only, all in `gtex62-tech-hud`)

- `widgets/sitrep.conky.conf`
- `lua/widgets/sitrep.lua` (2046 lines)
- `theme-sitrep.lua` (261 lines)
- `lua/lib/util.lua`, `lua/lib/theme-core.lua` (dependencies of the above)
- `~/.local/bin/sitrep` (launcher)
- `scripts/pf-fetch-basic.sh`, `ap_status_all_clients.sh`, `ap_clients_named.sh` (confirmed present, confirmed still legacy SSH scripts)

### A. Path-coupling findings — as expected, ordinary relocation fixes

These match what this doc already anticipated and just need doing in the Widget
Relocation steps above:

1. `sitrep.conky.conf` resolves `SUITE_DIR` and `dofile`s tech-hud's monolithic
   `theme.lua` for `theme.layout_pos("sitrep")` / `theme.monitor_head`. Replace with the
   decoupled `CORE_DIR`-based config above (no suite theme dependency).
2. `sitrep.lua` resolves `SUITE_DIR` (`CONKY_SUITE_DIR` env, fallback
   `~/.config/conky/gtex62-tech-hud`) at the top — needs `GTEX62_CORE_DIR` per the plan
   above.
3. `sitrep.lua` does `local util = dofile(SUITE_DIR .. "/lua/lib/util.lua")` —
   **unconditional, not `pcall`'d**. This is a hard dependency on tech-hud's shared
   util module, not yet flagged explicitly in the "Suite Dependency Removals" table
   above. Needs either an inlined subset of the util functions actually used, or a small
   engine-local `util.lua` under `widgets/sitrep/`.
4. `sitrep.lua` also does `pcall(dofile, .../widgets.lua)` and
   `pcall(dofile, .../pf_widget.lua)` — confirmed present exactly as the "Suite
   Dependency Removals" table above already calls out for removal.
5. `theme-sitrep.lua` is **not self-contained** as the target design above assumes — it
   does `dofile(SUITE_DIR .. "/lua/lib/theme-core.lua")` and pulls all colors from
   `palette.pfsense.*` (tech-hud's shared suite palette), not flat inline RGBA. The
   minimal `theme-sitrep.lua` above (no palette selection, no suite theme
   inheritance) does not exist yet in the legacy file — it needs to be authored fresh
   during relocation, not copied.
6. `get_sitrep_theme()` in `sitrep.lua` falls back to `util.get_theme()` (tech-hud's
   shared theme function) if `SITREP_THEME` / `theme-sitrep.lua` can't be found — this
   fallback path itself depends on the util.lua dependency in (3) and needs to be
   dropped or replaced.
7. `~/.local/bin/sitrep` hardcodes tech-hud's config path and a `conky-sitrep.pid`
   PID file under `${XDG_RUNTIME_DIR:-$HOME/.cache}`. Per the Guardrails above, the new
   `sitrep-e` launcher targets the new config path and a distinct
   `conky-sitrep-e.pid`, leaving this script untouched.
8. `WD_BLACK_PATH` env var is read at the top of `sitrep.lua` — matches the existing
   note to remove it (disk label is a system-widget concern; confirmed unused
   in the `conky_draw_sitrep()` path itself).

### B. Premise discrepancy — BLOCKING

The session brief that opened this audit stated SitRep's "data-sourcing is already
correct: no direct shell/execi/Conky-native reads, it's a pure cache consumer per the
existing migration doc." **This is not true of the live code, and it is not what this
doc's own checklist claimed either at the time.**

Confirmed directly in `lua/widgets/sitrep.lua`'s live `conky_draw_sitrep()` draw path:

- `get_pf_data()` → `pf_data_full()` (line 434) issues
  `${execi <poll> SUITE_DIR/scripts/pf-fetch-basic.sh full > <cache> &}` — a live shell-out
  to the legacy SSH-fetch script, not a cache read.
- `ap_blocks()` → `ap_cached_output()` (line 455) issues the same pattern against
  `scripts/ap_status_all_clients.sh` and `scripts/ap_clients_named.sh` — both legacy
  scripts that open their own SSH sessions (see [SitRep Architecture](sitrep-architecture.md)
  § Scripts in Production).
- Both write to a **suite-local flat-text file cache**
  (`~/.cache/conky/pfsense/sitrep_full.cache`, `~/.cache/conky/ap/*.cache`), parsed by a
  custom `parse_kv()` — not the engine's JSON cache at
  `~/.cache/gtex62-core/shared/pfsense/{profile}/status.json` at all.

This matches exactly the pre-migration "Current Architecture" shape (SitRep as
collector+database+analysis+display all at once) — see
[SitRep Architecture](sitrep-architecture.md). It also matched this doc's own migration
checklist at the time: "Write `lua/suite/pf.lua` consuming `status.json`..." and "Remove
all direct SSH calls from SitRep Lua/scripts" were both still unchecked.

Separately, even a rewritten cache-consumer SitRep couldn't have been fully served by the
core `pfsense` provider at the time of this audit: only `status.json` was implemented;
`router.json` (then still `system.json`), `pfblockerng.json`, `pihole.json`,
`ap_status.json`, `ap_clients.json` were all pending, and the AP provider itself hadn't
started. **This is now partially resolved** — see Resume checklist below.

**Why this blocked Part 1 as scoped:** a straight copy-and-repath of `sitrep.lua` into
`gtex62-core/widgets/sitrep/` would either (a) fail outright, since it depends on
tech-hud-local `scripts/`, `lua/lib/util.lua`, `lua/lib/theme-core.lua`,
`lua/widgets/pf_widget.lua` that won't exist at the new location, or (b) require
dragging the entire legacy direct-SSH fetch apparatus (`pf-fetch-basic.sh`,
`ap_status_all_clients.sh`, `ap_clients_named.sh`, `zyxel_cmd.sh`, `pf-ssh-gate.sh`) into
`gtex62-core` as new SitRep-owned files with their own private cache format — which is a
data-sourcing decision, not a relocation, and touches the exact "missing provider" case
session guardrails say to stop and confirm on rather than resolve solo.

**Decision (Aug 18, 2026):** Stopped the relocation for that session. Resume only once the
core `pfsense` provider is a genuine cache consumer's data source. No `gtex62-core/widgets/`
files were created that session. `gtex62-tech-hud`'s legacy SitRep is untouched and keeps
running via `~/.local/bin/sitrep` as before.

### Resume Checklist

1. ~~Finish the core `pfsense` provider's remaining pending domains (Pi-hole,
   pfBlockerNG, router/system)~~ — **done, Aug 18, 2026.** See
   [pfSense Provider Status](pfsense-provider-status.md) § Session History. ARP and DHCP
   collection remain pending there.
2. ~~Build the AP provider producing `ap_status.json` and `ap_clients.json`~~ —
   **done, Aug 19, 2026.** Shipped as `providers/ap/fetch_ap.sh` (own directory, not
   `providers/pfsense/` as originally sketched here — new device class, new auth model).
   See [AP Provider Status](ap-provider-status.md), now split out of
   [pfSense Provider Status](pfsense-provider-status.md) as its own doc.
3. Only then re-run Part 0 of a relocation session — the Part 0 findings above (section
   A) are still accurate and don't need re-auditing, just re-confirm nothing has drifted
   in `gtex62-tech-hud`'s files since Aug 18, 2026.
4. At that point `sitrep.lua`'s data layer (`pf_data_full`, `ap_cached_output`,
   `ap_blocks`, `parse_kv`, `parse_ap_status`, `parse_ap_clients_named`) gets rewritten
   to `jq` reads against the engine's JSON caches per the "SitRep as Cache Consumer" /
   "Data Read Migration Map" sections above, **before** or **as part of** the relocation
   — not after it, so the relocated widget is a true cache consumer from the day it
   lands in `gtex62-core/widgets/sitrep/`.

**Update (Aug 19, 2026):** the AP provider is now done — see Resume Checklist item 2 above
and [AP Provider Status](ap-provider-status.md). ARP/DHCP collection is still pending, so
this relocation remains blocked on that alone; re-run Part 0 (item 3 above) once it lands.
