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
   **Also verify the data source is an actual core domain cache, not a Conky built-in or
   direct OS/shell query** — even simple values (CPU%, mem%) must come from core, per the
   architecture gap found on sys-info (see note below).
3. **Geometry** — set `xinerama_head` to the correct monitor index; use `gap_x`/`gap_y`
   only for offset *within* that monitor, not absolute positioning.
4. **Rendering** — port Cairo drawing code, wire to `theme.*` / `layout.*` lookups (no
   hardcoded colors or pixel values). **No live `conky.text` block** — every other
   converted suite renders via Cairo with a blank `conky.text`; this is a hard
   requirement, not a style choice, since hardcoded Conky-native colors can't respond to
   a palette swap.
5. **Verify** — compare side-by-side against the original widget: position, data present,
   visual match. Check Conky stderr for Lua errors.
6. **Mark done** — record in the status table below before moving to the next widget.

---

## Current State Audit

Fill in as you verify each widget. Use this as the single source of truth for what's
actually done vs. assumed done.

| Widget | Original Source Confirmed? | Domain Wired? | Geometry Correct? | Rendering Matches? | Status |
| ------ | --------------------------- | -------------- | ------------------- | -------------------- | ------ |
| sys-info | ☑ legacy sys-info.conky.conf + lua/widgets.lua | ☑ system (shared/system/local current+processes+storage via monitor_helpers.lua) | ☑ head 1; gap 55,40 reproduces the legacy *rendered* position (see 2026-07-19 Part 2 note) | ☑ Cairo via clean_monitor.lua, blank conky.text, palette-driven; verified vs screenshots/sys-info.png | Done 2026-07-19 (arch gap closed) |
| net | ☑ legacy net-sys.conky.conf + net_extras.sh | ☑ network (shared/network/local) + connectivity (shared/connectivity/default); throughput fast-lane /sys statistics | ☑ same chassis window as sys-info | ☑ re-verified vs screenshots/network-info.png after move to Cairo (graphs now Cairo histograms) | Done 2026-07-19 |
| weather | ☑ legacy weather.conky.conf + lua/owm.lua (draw_main/forecast/metar/taf) | ☑ weather (shared/weather/home) + aviation (shared/aviation/home) | ☑ ambient chassis, weather block 90px below chassis top (legacy gap_y 130) | ☑ main block + tiles + METAR/TAF verified vs time-and-weather.png | Done 2026-07-19 |
| astro (orb) | ☑ legacy owm.lua draw_horizon/sun_labels + theme weather.arc | ☑ astro (shared/astro/home, canonical altitude/azimuth) | ☑ arc center at legacy weather.center offset within ambient chassis | ☑ arc/sun/moon/planets/labels verified vs screenshot + 6 simulated times of day | Done 2026-07-19 |
| time (tme) | ☑ legacy date-time.conky.conf + calendar.conky.conf + lua/calendar.lua | ☑ time/calendar read at draw time (per guide §1.2); cal_offset suite-local at suites/clean-e/tme/ | ☑ clock: ambient chassis head 1, top_middle, gap_y 40 (legacy date-time position); calendar: standalone top_right window at measured legacy position (see note below) | ☑ clock stack verified vs time-and-weather.png; calendar verified pixel-level (±2px) against the running legacy widget + calendar.png (borderless) | Done 2026-07-19 (calendar reposition confirmed) |
| music (msc) | ☐ | ☐ | ☐ | ☐ | Not started |
| notes | ☑ legacy notes.conky.conf + theme.lua notes_* keys | ☑ suite-local (no core domain): direct read of ~/Documents/conky-notes.txt via lua/suite/notes.lua, 3 s tick cache | ☑ standalone top_right head 1, gap_x 31 reproduces the legacy *rendered* position (see 2026-07-20 note); gap_y measured as 292 but later moved to 350 by user preference (2026-08-27) | ☑ Cairo via clean_notes.lua, blank conky.text, palette-driven; verified numerically vs the running legacy widget (±1 px) | Done 2026-07-20 |
| lyrics | ☐ | ☐ | ☐ | ☐ | Not started |
| pfsense (VLAN arcs) | ☑ legacy pfsense.conky.conf + theme-pf.lua + lua/pf_widget.lua + screenshots/pfsense.png | ☑ pfsense (shared/pfsense/main_router/ifaces.json, ~1s core poller, server-side rates) | ☑ head 1, bottom_middle 840×500 gap_y 150 (frame sized around the user-tuned r=400 dome) — legacy gap_y 740 deliberately NOT reproduced (see 2026-08-27 note) | ☑ Cairo arcs-only per guide §1.4, blank conky.text, palette-driven; dome verified vs pfsense.png (retired content excluded by design) | Done 2026-08-27 |

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
- Note: `lua/suite/net.lua` (OSA port reading `suites/clean-e/net/state.vars`) and
  `lua/suite/sys.lua` (OSA port with OSA-flavored display strings and fallback
  probing) are both unused by this chassis — the monitor view model is
  the monitor helpers module. **Resolved 2026-07-19 — both files deleted; see
  "Directory cleanup" note below.**

**Reopened — architecture compliance gap (found post-"done"):** `clean-monitor.conky.conf`
uses a live `conky.text` section with Conky built-ins (`${cpu}`, `${memperc}`,
`${fs_size /}`, `${nodename}`) and direct `execpi nvidia-smi ...` shell calls for all
SYS fields (CPU/RAM/disk/GPU/top-processes). This bypasses the core provider/cache
pattern entirely for those fields — no `system` domain cache is being read. NET fields
are correctly core-wired via `lua_parse` into `monitor_helpers.lua` reading
`shared/network/local/current.json` / `shared/connectivity/default/current.json`; SYS
fields are not. `conky.config` also has two hardcoded hex colors (`default_color`,
`color1`) that can't respond to a palette swap — a symptom of `conky.text` existing at
all, not a separate bug.

**Real fix, not a patch:** every other suite (OSA included) draws even simple text
values like CPU% through Cairo, reading from a core domain cache — not through Conky
built-ins, regardless of how efficiently Conky could provide them natively. "All suites
pull from core" is the actual standing goal, not a per-widget efficiency tradeoff. Full
fix requires: (1) a `system` core domain provider writing
`shared/system/[profile]/current.json` (CPU%, mem%, disk, top-N processes, GPU
util/temp/power/vram) if one doesn't already exist; (2) SYS half of
`monitor_helpers.lua` rewritten to read that cache instead of calling
`${cpu}`/`${memperc}`/`execpi nvidia-smi`; (3) rendering moved from `conky.text` to
Cairo draw calls reading `clean-palettes.lua`, same as every other widget; (4)
`conky.text` ends up blank, matching every other suite's pattern. This resolves the
hardcoded-color issue as a byproduct rather than needing a separate fix. **Not yet
executed as of this snapshot — prompt drafted, session pending.**

**Fix Part 1 (system provider) — DONE 2026-07-19.** Findings and changes:

- A `system` core provider already existed (`providers/system/fetch_system.sh`,
  scheduled by the launcher at `refresh_sec = 1` from `profiles/system/local.toml`)
  and was writing all four files — but only slow-lane identity: `current.json` had
  `cpu.model` with **no** `usage_percent`/`temperature_c`, no `memory` object, GPU
  model+driver only, and `processes.json` had an empty `top_cpu`. The collector
  even defined CPU%/RAM%/temp helpers but never called them — live telemetry was
  deliberately left to OSA's suite-local fast lane per `docs/system-schema.md`,
  which the "all suites pull from core" standing goal now overrides.
- Extended the collector to emit the full schema: `cpu.usage_percent` +
  `temperature_c`, `memory` (used/total/percent), `gpu` util/temp/power/vram
  (one combined `nvidia-smi` query), and populated `processes.json` `top_cpu`
  (top-10) plus new `top_mem` (name + `rss_bytes`, for the legacy RAM top-5 rows).
- CPU%/per-process% are `/proc` jiffies deltas against the previous run (state in
  `tmp/system_local_cpu.state`), i.e. true 1-second interval averages matching
  Conky's `${cpu}`/`${top cpu}` convention — not `top -bn1` (whose first sample
  reports since-boot averages). First run takes a 0.3 s two-point sample.
- Additive fields for the clean-monitor header: `hostname`, `user`, and
  `kernel.release_full` (raw `uname -r`; `kernel.release` keeps OSA's `-G`
  abbreviation untouched). Documented in `docs/system-schema.md`.
- Verified with `jq .` on all four files after two manual runs: values present and
  plausible, `status.json` state `ok`, steady-state runtime ~0.45 s. Note the
  refresh loop only runs while the core launcher is up — the widgets currently
  running were started with bare `conky -c`, so relaunch via `start-conky.sh`
  when verifying Part 2.

**Fix Part 2 (rewire + Cairo rendering) — DONE 2026-07-19.** The monitor chassis
is now architecturally compliant: blank `conky.text`, all data from core caches,
all colors from `clean-palettes.lua`. Changes:

- `lua/monitor_helpers.lua` rewritten as a pure-Lua view model (no `conky_parse`,
  no Conky color markup): SYS reads `shared/system/local/{current,processes,storage}.json`
  (one jq per file per second, tick-cached — same pattern as the NET readers,
  which were kept); NET readers now return structured rows instead of
  `${color}`-tagged strings. Throughput is fast-lane
  `/sys/class/net/<iface>/statistics` deltas with a per-second ring buffer
  (531 samples) feeding the Cairo graphs — guide §4.2 names throughput as fast
  lane; same precedent as NET's operstate.
- `frame.lua` `draw_sys_content`/`draw_net_content` (previously unused OSA-design
  leftovers) rewritten as the legacy character-grid text flow; `draw_monitor`
  threads a line cursor from SYS into NET. Slash bars, pipe columns, dash
  separators, VLAN table, and bordered white throughput histograms all match the
  legacy look. Dead OSA table/box helpers removed.
- New `lua/widgets/clean_monitor.lua` entrypoint (same pattern as
  clean_calendar.lua); `clean-monitor.conky.conf` rewritten to the pure-Cairo
  template — no font/default_color/color1/templates, `conky.text = [[]]`. The
  two hardcoded hex colors are gone with it, as predicted.
- Grid metrics (18 px mono glyphs, 23 px lines, columns at x 368/262) were
  measured off the accepted Conky-text rendering at this machine's font DPI and
  live in `panels.monitor_grid` / `panels.sys` / `panels.net`;
  `layout.monitor.frame` is now 598×1880.
- **Rendered-position pitfall again** (matches the calendar finding): the legacy
  conf said gap 40,30 but the Conky-text window rendered its first glyph at
  head-relative (57, 45); the Cairo window draws at gap + (7, 10), so
  `layout.monitor` uses gap 55,40 to reproduce the visible legacy position.
- Verified: relaunched via `start-conky.sh` (core launcher schedules all
  providers; system cache refreshing at 1 s), screenshots compared against
  `screenshots/sys-info.png` and `screenshots/network-info.png` — layout,
  columns, colors, and live data all match; pings live once the connectivity
  provider runs. No Lua errors.
- Note: `start-conky.sh` also launches the **unconverted** `clean-media` and
  `clean-pfsense` instances, whose OSA-leftover `gap 0,0` / `top_right`
  positions overlap the monitor chassis and calendar (pfSense collision already
  predicted below). Both were stopped manually after verification — convert
  their layouts before leaving them running.

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
- **Calendar reposition — fixed and confirmed 2026-07-19.** Root cause confirmed as the
  chassis-combination pitfall: folding the legacy standalone calendar widget into the
  `tme` chassis discarded its individual position (legacy `calendar.conky.conf` was its
  own `top_right` head-1 window, disjoint from the ambient chassis's top_middle
  footprint — no single Conky window can cover both). Fix: the calendar is now its own
  standalone instance, restoring the legacy structure — `widgets/clean-calendar.conky.conf`
  with `lua/widgets/clean_calendar.lua`, `frame.draw_calendar`/`panels.cal`, and
  `layout.calendar`; registered in `suite.toml` (`[[instances.standalone]] id = "calendar"`)
  and `start-conky.sh`. The ambient chassis shrank to 680×770 (clock + weather stack
  only), freeing the mid-monitor area below it for the music widget.
- Position was audited *empirically*, not from the legacy conf's raw gap values: the
  legacy conf says `top_right gap 0,30`, but the running legacy widget renders its grid
  at head-relative x 3411–3773, content top y 41 — a Conky window-autosize quirk plus
  the theme's `cal_origin_x = 78` draw offset baked a 67px right inset into the visible
  position. The suite-e window is snug (no draw offset) with `gap_x 67, gap_y 41` to
  reproduce the *visible* legacy position. Verified by measuring text bounding boxes in
  screenshots of both suites: legacy x 3421–3754 / y 47–265, suite-e x 3422–3752 /
  y 49–264 (±2px, font antialiasing). No overlap with the monitor chassis (top_left,
  x ≤ ~650).
- Rendering correction found during the audit: legacy final theme has `cal_border_lw = 0`
  (borderless cells, confirmed by calendar.png and the running legacy widget); the port's
  earlier `border_lw = 1` was wrong and is now 0.
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

**Directory cleanup — DONE 2026-07-19.** Resolves the two dead-code flags above:

- Deleted `lua/suite/net.lua` and `lua/suite/sys.lua` (OSA-port leftovers, replaced
  by the monitor helpers view model; grep confirmed nothing referenced them).
- Moved `lua/monitor_helpers.lua` → `lua/suite/monitor_helpers.lua` to match the
  convention every other widget view model follows (orb/tme/wxr/msc/pf all live in
  `lua/suite/`). Updated the `dofile` path in `lua/widgets/clean_monitor.lua` and
  path comments in `clean-monitor.conky.conf` and the module header; no logic change.
- Verified: relaunched via `start-conky.sh`, ran the monitor conf with stderr
  captured (no Lua errors), screenshot confirmed SYS + NET fully rendering with
  live data, identical to before the move. The unconverted `clean-media` /
  `clean-pfsense` instances were stopped again after the relaunch, per the
  Fix Part 2 note.

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

**notes completed 2026-07-20.** Root causes and measured values (kept as text so future
sessions can reuse them without reopening images):

- *Chassis-combination pitfall confirmed again* (same as calendar): the OSA design had
  notes as a media-chassis sub-panel (544×580 at panel x18,y332, wrap 72, 38 lines);
  legacy notes is its own `top_right` head-1 window, disjoint from the media chassis's
  legacy `top_middle` footprint (music gap 0,530; lyrics gap −600,300). Converted as a
  standalone instance: `widgets/clean-notes.conky.conf`, `lua/widgets/clean_notes.lua`,
  `lua/suite/notes.lua`, `frame.draw_notes`/`panels.notes`, and `layout.notes`;
  registered in `suite.toml` and `start-conky.sh`. `msc.lua`'s `notes_lines` (raw-line
  OSA reader, no wrapping) deleted with the media-chassis notes draw call.
- *Rendered-position pitfall, worst case yet*: legacy conf says `gap 0,210` with
  `maximum_width 310`, but the running legacy widget's window is at physical (7241, 287),
  445×1771 — Conky ignored `maximum_width` (fold width 39 chars × 10 px = 390 px of text)
  and rendered 77 px below gap_y. Measured rendered truth: text left abs x 7247
  (head-rel 3407), text right x 7636, first baseline y 308, line pitch exactly 20.0 px
  (verified over 85 lines), char advance 10.0 px → Cairo font 16.6 px (DejaVu Sans Mono,
  advance ratio 0.6028 — same calibration as the monitor grid's 10.85 px at 18 px).
- *Cairo window placement convention confirmed* (useful for all remaining widgets):
  Conky places the own_window at the alignment position offset 5 px outward, and the
  window is frame+10 in each dimension. So window_left(top_right) =
  3840 − gap_x + 5 − (frame_w + 10), window_top = gap_y − 5. Derivation for notes:
  frame 404×1810, x0 7, first_baseline 21 → gap_x 31, gap_y 292 puts text left at 3407
  and baseline 1 at 308. Confirmed post-launch: window at physical (7240, 287).
- *Wrap semantics*: `lua/suite/notes.lua` reproduces `fold -s -w 39 | sed -n 1,90p` in
  pure Lua (break after last blank in a 39-col segment, hard break when none, 90-line
  cap, 3 s refresh tick like the legacy `execi 3`; missing/empty file renders nothing).
  Verified byte-identical to GNU fold on the live notes file (86 lines) and on synthetic
  wrap cases. Tab-stop arithmetic intentionally not reproduced (file has no tabs).
- *Verified numerically* (diff-mask method: capture with widget minus background capture,
  threshold, row/column projections): suite-e text spans x 7247–7636 — **exact** match
  to legacy — first content row 311 vs legacy 312, last 2011 vs 2012 (±1 px, Cairo vs
  Xft antialiasing). Band-count differences are mask-segmentation artifacts (Xft glyph
  bleed merges adjacent line bands), not layout differences. No Lua errors on a
  stderr-captured run; single final screenshot confirms visual structure (calendar
  above, no overlap — notes text top ≈ y 295, calendar bottom y 265, same as legacy).
- *Measurement gotchas for future sessions*: `wmctrl -lG` on this desktop reports window
  positions at 2× physical scale but sizes at 1× — divide x,y by 2. And a background
  capture taken before midnight poisons a day-rollover diff: the calendar's
  today-highlight moved (Jul 19 → 20) and showed up as phantom bands at y 217–265 until
  masked out. Also: never put a conky conf name in a `pkill -f` pattern from this
  harness — the pattern matches the harness's own wrapper shell and kills it (exit 144);
  kill by PID instead.

**pfsense (VLAN arcs) completed 2026-08-27.** Root causes, decisions, and measured values:

- *Scope per guide §1.4*: this widget is the VLAN traffic-flow visualization only.
  The legacy widget's center meters (LOAD/MEM), "V1211" nameplate, ONLINE/OFFLINE
  gateway label (incl. SSH-pause suffix), SYSTEM/VERSION/CPU/BIOS/UPTIME infoline,
  cumulative-bytes totals table, and pfBlockerNG/Pi-hole status block are all retired
  to the core sitrep utility and were removed, not ported. Kept as the flow
  composition: concentric dome arcs, IN/OUT rate markers, dash-leader arc names,
  DN/UP end labels, and the "100%" apex label. The baseline hline was initially
  kept (judged composition, not status), then dropped by user choice — with the
  status text that hung off it retired, the bare line wasn't earning its place;
  it remains in panels.pfsense as `baseline.enabled = false` for easy revival.
- *Scaffold leftovers, not a blank slate*: `frame.lua` already had a
  `draw_pf_content` and `panels.pfsense` existed — but both were pre-§1.4 scaffolds:
  retired content baked in, `anchor_strength` ignored (flat concentric arcs), markers
  mapped on a full left→right sweep instead of the legacy ends→apex halves (IN
  180°→90°, OUT 0°→90°, apex = 100%), both directions drawn filled (legacy: IN
  filled / OUT hollow ring), idle markers hidden (legacy: rest visibly at the
  endpoints), name labels right-aligned *outside* the left endpoints (runs off-frame
  at r=300 in a 660 window; legacy draws dash-leader+name inward from the endpoint),
  and a hardcoded cap=1000 with no response curve. All rewritten to the legacy
  metaphor.
- *Data*: `lua/suite/pf.lua` rewritten from scratch. Old version read `status.json`
  (60s) and diffed byte counters client-side with ~10 jq calls per draw and no tick
  cache. New version reads `ifaces.json` (core's ~1s poller, server-side
  `rate_ibytes_per_sec`/`rate_obytes_per_sec`) with ONE jq per second (TSV batch
  filter), steps EMA only when a VLAN's `fetched_at` advances, and applies smoothing
  to the curve-scaled 0..1 value (OSA bidir-reader pattern; same
  smooth-after-curve reasoning). Null rates (cold start / wrap / degraded stub) skip
  the EMA step. Single public function `M.flow_fractions(panels.pfsense)` — the
  retired-scope accessors (cpu/mem/gateway/status/totals) are gone. No suite-side
  SSH gating — reads are cache-only; the circuit breaker is core-owned.
- *Scaling config ported to `panels.pfsense`*: legacy theme-pf.lua's sqrt curve
  (gamma 0.35), per-direction link caps (WAN 600 in / 50 out; HOME/IOT/INFRA
  100/100; GUEST 50 in / 100 out), zero floors, EMA alpha 0.35.
- *CAM added as the 6th (innermost) arc* — the VLAN postdates the legacy suite; the
  core provider serves it. Marker color is the palette accent (golden) since the
  legacy gray ramp is exhausted; caps 100/100; dash_count 36 (capped so the name
  clears CAM's resting OUT ring at the right endpoint). Two knock-on fixes vs the
  legacy 5-arc values: `top_label.dy` 94 → 116 (keeps ~22px clearance below the new
  innermost apex) — everything else ports unchanged (deltaR 36, anchor 0.5).
- *Legacy values audited, not trusted*: theme-pf's `arc.r = 380` never actually
  rendered — the legacy 640px window clamped it to ~312 via the widget's fit logic;
  `hline.length = 820` drew clipped. Suite-e uses r=300 / length 624 sized to the
  real frame. The legacy `T.colors.arc_in/arc_out` (SteelBlue1/sienna1) were unused
  by the final legacy rendering (direction is encoded filled-vs-hollow, VLAN by
  marker color), so the scaffold's `pf_arc_in`/`pf_arc_out` palette roles were
  removed from both palettes; `pf_arc_base` is the one palette role, with per-VLAN
  marker colors as fixed conventions in `theme.pf_markers` (same precedent as
  `theme.astro` planets). Legacy trail config (`pf.trail`) was never defined in the
  final theme (trails drew base-gray on gray, invisible) — omitted.
- *Font note (pre-existing, suite-wide)*: `fonts.data` = "JetBrainsMono Nerd Font
  Mono" is not installed on this machine (fc-match falls back to Noto Sans). The
  legacy widget used the same family name, so the accepted legacy look already was
  the fallback rendering; dash-leader lengths were tuned against that reality.
- *Verified*: relaunched with stderr captured — no Lua errors; `flow_fractions`
  exercised standalone in plain lua against the live cache (all 6 VLANs producing
  moving, smoothed fractions; idle GUEST at 0). Screenshot of the running widget
  (window at physical 5425,1635 — wmctrl 2×-position gotcha applies) compared
  against `screenshots/pfsense.png`'s dome region: arc nesting/stagger, idle
  markers resting on endpoints, live OUT rings riding the right side, label order
  and DN/UP placement all match; retired content absent by design. The unconverted
  `clean-media` instance (OSA-leftover `gap 0,1000`) was found overlapping the
  pfSense region mid-verify ("(not playing)" bleed-through) and was stopped again
  by PID, per the standing Fix Part 2 note — convert its layout before leaving it
  running.
- *Post-verify polish (same day, user-driven)*: dome enlarged to r=400 / dy=424 to
  taste; frame resized around it (840×500). Geometry then converted to the
  **zero-based standalone pattern** (calendar/notes precedent): `layout.pfsense`
  margins all 0, `panels.pfsense` box = frame at (0,0), dome self-centering via
  `width/2` — one box instead of two synced ones, which had already caused one
  off-center bug when they diverged. The old margin headroom is now implicit:
  keep `arc.r ≤ width/2 − 14` and `arc.dy ≥ r + 14` or the 12px markers (which
  ride ON the arc line) clip at the window edge — commented at both sites.
  Baseline hline dropped by choice (`baseline.enabled = false`, kept for easy
  revival). Window lifted off the bottom edge with `gap_y = 150` (bottom_middle:
  gap_y offsets upward from the monitor's bottom edge). The notes standalone was
  also nudged in the same pass: gap_y 292 → 350 by preference, so its vertical
  position is no longer the measured legacy reproduction (comment updated in
  clean-layout.lua).

---

## Notes for Next Widgets

- **Open items for the next session (as of 2026-08-27):** (1) the monitor chassis
  (sys/net) is Done in the table above but the user has further visual tweaks
  planned for it — treat those as polish on a converted widget, not a reopened
  conversion; (2) music and lyrics are the last unconverted widgets (media chassis
  layout is still the OSA leftover and overlaps the pfSense region when running).

- Weather, astro, and time are all core-domain widgets like sys-info/net — expect the same
  two failure modes (positioning, cache wiring) if problems recur. Diagnosis pattern from
  Steps 1–2 above applies directly.
- Music and lyrics are suite-local (no core domain) — data issues there will be in
  the Lua module's direct file read, not a cache path. (Notes, also suite-local, is
  done — its conversion above is the reference for this pattern.)
- **Core now has a media/lyrics provider that didn't exist when the above was written**
  (`gtex62-core/providers/media/fetch_lyrics.py` → `shared/media/local/lyrics.json`,
  confirmed live/updating as of 2026-08-27). The original conversion guide's domain
  mapping called lyrics suite-local-only because no core provider existed yet. Before
  converting music/lyrics, check whether lyrics should move to core-sourced instead of
  assuming the old suite-local pattern still holds — don't carry `msc.lua`'s current
  suite-local lyrics read forward on autopilot.
- **Chassis-combination positioning pitfall (found on `tme`, resolved):** the legacy
  suite ran calendar as its own independent Conky instance with its own position; the
  conversion initially folded it into the `tme` chassis. Combining previously-separate
  legacy widgets into one chassis carries over the chassis's own position, but does NOT
  automatically carry over each sub-element's original individual position — and if the
  sub-element's legacy position is *disjoint* from the chassis footprint (calendar:
  top_right vs top_middle), no internal offset can fix it; the widget must stay a
  standalone instance (that's how tme was resolved, and notes hit the same pitfall —
  now also standalone). If music or lyrics get combined into a shared chassis process,
  audit each sub-element's position individually against the legacy conf files before
  assuming the chassis's overall placement is sufficient.
- **Audit the *rendered* position, not just the conf values:** legacy calendar's conf
  said `gap 0,30` but rendered with a 67px right inset (window autosize + draw-origin
  offset). When a legacy widget's theme has origin/offset values or a derived window
  size, launch the legacy widget and measure where it actually draws — the conf's gap
  values alone can be misleading.
- **pfSense placement — resolved 2026-08-27 (and an exception to the "audit the
  rendered position" rule):** the legacy `pfsense.conky.conf`'s `top_middle, gap_y 740`
  predates correct monitor targeting — it offset from monitor 0 and pushed the window
  onto monitor 1 manually, so reproducing its rendered position would reproduce a bug,
  not intent. `layout.pfsense` was instead set to `bottom_middle` head 1 (660×520,
  gap 0,0) and confirmed by direct observation. `bottom_middle` verified as a real
  compiled-in alignment in the installed conky 1.19.6 binary, not an untested extension.
- **Core-sourcing pitfall (found on `sys-info`):** don't assume a value is fine to pull
  from a Conky built-in or shell command just because it would be simple/efficient to do
  so. Every value, however trivial, should come from a core domain cache and render via
  Cairo — check this explicitly during the Domain Map step (2), not just visually during
  Verify (5), since a widget can look completely correct while quietly bypassing core.
- pfsense (VLAN arcs) is last by design — it depends on the `pfsense` core provider and has
  its own known circuit-breaker pitfall (guide's "pfSense SSH Circuit Breaker" section).

---

## When All Widgets Are Done

Only then: assign finished widgets to chassis processes (`clean-monitor`, `clean-ambient`,
`clean-media`) and the standalone panels (`clean-calendar`, `clean-pfsense`), per the
original guide's chassis decision for clean-suite-e — amended 2026-07-19: the calendar is
a standalone instance rather than part of `clean-ambient`, because its legacy top_right
position is disjoint from the ambient chassis footprint. Run the full Theme / Rendering / Launch / Cleanup checklist
from the guide before calling the suite complete.
