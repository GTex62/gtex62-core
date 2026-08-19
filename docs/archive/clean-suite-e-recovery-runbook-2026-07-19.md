# clean-suite-e Conversion — Recovery Runbook

Picking back up a stalled conversion. Goal: get unstuck with one small, visible win first,
then re-sequence the rest of the conversion widget-by-widget instead of chassis-by-chassis.

---

## Why This Stalled

Per the conversion guide's Phase 0, the audit (widget inventory, layout geometry, chassis
decision) should happen *before* any new code is written. What actually happened:

- Layout was copied from `gtex62-osa` instead of clean-suite's own original geometry.
- SYS/NET widget was built next, partially works, missing data.
- Everything else was left mid-conversion or untouched.
- Widgets are pinned to screen edges (gap_x/gap_y using OSA's monitor assumptions, not clean-suite's).

None of this is a design failure. It's a missing reference (the Phase 0 audit output) plus
one known pitfall (monitor targeting) from the guide's own pitfalls section. Nothing here
requires a restart.

---

## Revised Strategy: Widget-by-Widget, Not Suite-by-Suite

The original guide groups widgets into chassis (Monitoring, Ambient, Media) and converts
each chassis as a unit. For clean-suite-e, given the stall, convert **one widget fully**
— audit, geometry, data, rendering, verified against original — before starting the next.
Chassis grouping still applies at the end (assigning finished widgets to their
`clean-monitor` / `clean-ambient` / `clean-media` process), but it's the last step, not
a constraint during conversion.

This also sets the pattern for `tech-hud`, `lcars`, and `tri-hud` — each is close to a
single-widget conversion with variations, so whatever process works here transfers almost
directly.

### Per-Widget Conversion Checklist

For each widget, in order:

1. **Audit** — pull the original widget's exact geometry (position, size, monitor), theme
   values, and data source(s) from the *original* `gtex62-clean-suite` files. Do not
   reference OSA or any other suite.
2. **Domain map** — confirm which core domain(s) feed this widget (§1.2 of the guide) and
   verify the cache path exists and is populated (`shared/[domain]/[profile]/current.json`).
3. **Geometry** — set `xinerama_head` to the correct monitor index; use `gap_x`/`gap_y`
   only for offset *within* that monitor, not absolute positioning.
4. **Rendering** — port Cairo drawing code, wire to `theme.*` / `layout.*` lookups (no
   hardcoded colors or pixel values).
5. **Verify** — compare side-by-side against the original widget: position, data present,
   visual match. Check Conky stderr for Lua errors.
6. **Mark done** — record in the status table below before moving to the next widget.

---

## Current State Audit

Fill in as you verify each widget. Use this as the single source of truth for what's
actually done vs. assumed done.

| Widget | Original Source Confirmed? | Domain Wired? | Geometry Correct? | Rendering Matches? | Status |
| ------ | --------------------------- | -------------- | ------------------- | -------------------- | ------ |
| sys-info | ☑ legacy sys-info.conky.conf + lua/widgets.lua | ☑ system (shared/system/local) + Conky fast-lane | ☑ head 1, gap 40,30 (legacy values) | ☑ verified vs screenshots/sys-info.png | Done 2026-07-19 |
| net | ☑ legacy net-sys.conky.conf + net_extras.sh | ☑ network (shared/network/local) + connectivity (shared/connectivity/default) | ☑ same chassis window as sys-info | ☑ verified vs screenshots/network-info.png | Done 2026-07-19 |
| weather | ☑ legacy weather.conky.conf + lua/owm.lua (draw_main/forecast/metar/taf) | ☑ weather (shared/weather/home) + aviation (shared/aviation/home) | ☑ ambient chassis, weather block 90px below chassis top (legacy gap_y 130) | ☑ main block + tiles + METAR/TAF verified vs time-and-weather.png | Done 2026-07-19 |
| astro (orb) | ☑ legacy owm.lua draw_horizon/sun_labels + theme weather.arc | ☑ astro (shared/astro/home, canonical altitude/azimuth) | ☑ arc center at legacy weather.center offset within ambient chassis | ☑ arc/sun/moon/planets/labels verified vs screenshot + 6 simulated times of day | Done 2026-07-19 |
| time (tme) | ☑ legacy date-time.conky.conf + calendar.conky.conf + lua/calendar.lua | ☑ time/calendar read at draw time (per guide §1.2); cal_offset suite-local at suites/clean-e/tme/ | ☑ ambient chassis: head 1, top_middle, gap_y 40 (legacy date-time position) | ☑ clock stack + calendar verified vs time-and-weather.png / calendar.png | Done 2026-07-19 |
| music (msc) | ☐ | ☐ | ☐ | ☐ | Not started |
| notes | ☐ | ☐ | ☐ | ☐ | Not started |
| lyrics | ☐ | ☐ | ☐ | ☐ | Not started |
| pfsense (VLAN arcs) | ☐ | ☐ | ☐ | ☐ | Not started |

---

## Immediate Next Session: Fix What's Already Built

Don't start a new widget yet. Finish the one that's closest to done.

### Step 1 — Fix monitor positioning (mechanical, ~30–60 min)

For `sys-info` and `net`:

- Open the original `gtex62-clean-suite` conf files, find the intended monitor and
  approximate position for each widget.
- In the converted `.conky.conf`, set `xinerama_head` to that monitor's index.
- Zero out or reduce `gap_x`/`gap_y` to intra-monitor offsets only — remove any absolute
  pixel value that assumed a specific total canvas width (e.g., the 2780px dual-4K
  assumption called out in the guide's pitfalls section).
- Relaunch and confirm the widget sits where it did in the original, not pinned to (0,0).

### Step 2 — Diagnose missing data (data path, ~30–60 min)

For whichever of sys-info / net still shows partial data after Step 1:

- Check the relevant cache file directly: `shared/system/[profile]/current.json` or
  `shared/network/[profile]/current.json` under `$GTEX62_CACHE_DIR`.
- If the cache file is missing or stale, the core provider isn't running or isn't writing
  — check provider logs, not the Lua module.
- If the cache file has full data but the widget shows partial: the Lua reader is likely
  looking at the wrong key path or an old field name from the legacy script's JSON shape.
- Fix one data field at a time; don't rewrite the whole reader.

### Step 3 — Verify and mark done

Update the status table above for sys-info and net once both are confirmed correct.
This is the "first widget fully converted" milestone — everything after this follows the
same six-step checklist per widget.

**Completed 2026-07-19.** Actual root causes found:

- *Positioning*: `layout.monitor` in `theme/clean-layout.lua` had `xinerama_head = 0`,
  `gap 0,0` (OSA assumption). Legacy suite used `monitor_head = 1` (secondary, DP-4)
  with sys-info at gap 40,30. Fixed in the layout file.
- *Missing data*: not a field-name mismatch — `lua/monitor_helpers.lua`, which defines
  every `${lua_parse ...}` function the chassis conf uses, had never been created, so
  all lua-sourced fields (separators, slash bars, top-process lists, all NET rows)
  rendered empty while Conky built-ins still showed. Created it: SYS helpers ported
  from legacy `lua/widgets.lua` (styling from `clean-theme.lua`), NET readers wired to
  `shared/network/local/current.json` and `shared/connectivity/default/current.json`
  (one jq call per file per second, tick-cached). LAN link state is fast-lane via
  `/sys/class/net/<iface>/operstate`.
- Note: `lua/suite/net.lua` (OSA port reading `suites/clean-e/net/state.vars`) is
  unused by this chassis and still points at an unpopulated OSA-pattern path — revisit
  or retire it when the pfsense/Cairo widgets are converted.

**time (tme) completed 2026-07-19.** Root causes and notes:

- Ambient chassis geometry was OSA-flavored (`head 0, top_right, gap 0,0`). Legacy stack
  is top_middle head 1: date-time at gap_y 40, weather at gap_y 130. Chassis now sits at
  the date-time position (680×1120) with the weather block 90px below chassis top.
- `frame.lua` draw_tme_content was OSA's design (left-aligned clock + compact 12px-cell
  boxed calendar). Rewritten as the legacy centered clock stack (%H:%M:%S 30px, UTC line
  "UTC HH:MM (ZONE ±H)", YYYY.MM.DD) + legacy calendar.lua port (50×32 bordered cells,
  nav-arrow title, weekend gray #777, today in accent).
- Calendar month navigation offset ported as suite-local state at
  `suites/clean-e/tme/cal_offset` (guide pitfall "Calendar Navigation Offset").
- Deviation from legacy: the calendar renders at the bottom of the ambient chassis, not
  at the monitor's top_right corner — consequence of the recorded chassis decision
  (TME folded into clean-ambient). Cell geometry/colors match the legacy calendar 1:1.
- Sunrise/sunset arc-end labels will use "SR"/"SS" (final legacy theme values) rather
  than the older "Sunrise"/"Sunset" seen in the Nov-2025 screenshot.

**weather completed 2026-07-19.** Root causes and notes:

- `frame.lua` draw_wxr_content was OSA's tabular design (SKY/WX/TEMP header tables).
  Rewritten as the legacy composition: city + current icon + temp/humidity inside the
  arc (offsets are the legacy theme.weather.main values), hline/vline dividers, 5-tile
  forecast strip (dates computed today+i like legacy), METAR/TAF text blocks.
- Data was already correctly wired: wxr.lua reads shared/weather/home and
  shared/aviation/home. Added `legacy_current()` / `legacy_forecast()` accessors for the
  legacy display fields (city, "94°", "59%", icon code, tile hi/lo); reused the existing
  pure-Lua METAR/TAF wrappers (legacy wrap values 43/5 and 60/4/5 preserved in panels).
- Weather icons come from `gtex62-shared-assets/icons/owm/` — verified bit-identical
  (md5) to the legacy suite's own icons/owm set. Override dir via
  `GTEX62_SHARED_ASSETS_DIR`.

**astro (orb) completed 2026-07-19.** Root causes and notes:

- *Data*: orb.lua (OSA port) read `suites/clean-e/orb/ephemeris.vars` — a suite-local
  path that was never populated (same failure mode as net). Rewritten against the core
  astro domain (`shared/astro/[profile]/current.json`, profile from suite config,
  default home) using canonical `altitude_deg`/`azimuth_deg` per the guide's
  Sky/Astronomy pitfall.
- *Arc orientation*: the OSA frame.lua mapping had East at the LEFT end — mirrored
  vs the legacy south-facing arc (West left, East right, South apex). Angle handling
  now matches legacy owm.lua: y-up math angles (theta = frac·180°, y = cy − r·sinθ),
  never raw compass azimuth into Cairo's y-down/clockwise frame (compass north = 270°
  in Cairo terms). Compass→arc conversion frac = (azimuth − 90)/180 lives in the view
  model only.
- *Body mapping*: sun and moon are TIME-mapped rise→set (legacy behavior); the OSA
  azimuth-mapped sun would vanish whenever azimuth < 90° (summer mornings). Planets
  stay azimuth-mapped and hide below horizon or off-arc (az outside 90–270°).
- Sun/moon drawing is gated BOTH on the rise→set time window (legacy is_day; robust
  against a stale cache still reporting daytime altitude after sunset) and on provider
  altitude (hides the moon mid-window when below horizon).
- Verified at six simulated times of day (fake clock against live cache): sunrise →
  right/East end, morning → east side, solar midday → apex, afternoon → west side,
  pre-sunset → left/West end, night → hidden with SR/SS labels flipped.

---

## Notes for Next Widgets

- Weather, astro, and time are all core-domain widgets like sys-info/net — expect the same
  two failure modes (positioning, cache wiring) if problems recur. Diagnosis pattern from
  Steps 1–2 above applies directly.
- Music, notes, and lyrics are suite-local (no core domain) — data issues there will be in
  the Lua module's direct file read, not a cache path.
- pfsense (VLAN arcs) is last by design — it depends on the `pfsense` core provider and has
  its own known circuit-breaker pitfall (guide's "pfSense SSH Circuit Breaker" section).

---

## When All Widgets Are Done

Only then: assign finished widgets to chassis processes (`clean-monitor`, `clean-ambient`,
`clean-media`) and the `clean-pfsense` standalone panel, per the original guide's chassis
decision for clean-suite-e. Run the full Theme / Rendering / Launch / Cleanup checklist
from the guide before calling the suite complete.
