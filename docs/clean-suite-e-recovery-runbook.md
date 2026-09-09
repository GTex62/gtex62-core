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
| net | ☑ legacy net-sys.conky.conf + net_extras.sh | ☑ network (shared/network/local) for interface/VLAN/WAN fields + net (shared/net/local/state.vars) for ping — CF_1111_MS/GOOGLE_8888_MS, fixed 2026-08-28 (was connectivity's current.json, a dead-end cache that never refreshed past launch; see note below); throughput fast-lane /sys statistics | ☑ same chassis window as sys-info; **individually audited 2026-08-29 (F3)** — fixed chassis-relative y0 = 1013 (`panels.net.y0`), independent of SYS's line count; see F3 note below | ☑ re-verified vs screenshots/network-info.png after move to Cairo (graphs now Cairo histograms) | Done 2026-07-19 (F3 position fix 2026-08-29) |
| weather | ☑ legacy weather.conky.conf + lua/owm.lua (draw_main/forecast/metar/taf) | ☑ weather (shared/weather/home) + aviation (shared/aviation/home) | ☑ ambient chassis, weather block 90px below chassis top (legacy gap_y 130) | ☑ main block + tiles + METAR/TAF verified vs time-and-weather.png | Done 2026-07-19 |
| astro (orb) | ☑ legacy owm.lua draw_horizon/sun_labels + theme weather.arc | ☑ astro (shared/astro/home, canonical altitude/azimuth) | ☑ arc center at legacy weather.center offset within ambient chassis | ☑ arc/sun/moon/planets/labels verified vs screenshot + 6 simulated times of day | Done 2026-07-19 |
| time (tme) | ☑ legacy date-time.conky.conf + lua/calendar.lua (clock stack) | ☑ time read at draw time (per guide §1.2) | ☑ ambient chassis head 1, top_middle, gap_y 40 (legacy date-time position) | ☑ clock stack verified vs time-and-weather.png | Done 2026-07-19 |
| calendar | ☑ legacy calendar.conky.conf + lua/calendar.lua | ☑ time/calendar read at draw time (per guide §1.2); cal_offset suite-local at suites/clean-e/tme/ | ☑ standalone top_right window, head 1, 362×273 gap 67,41 — reproduces the *measured* rendered legacy position (see note below) | ☑ verified pixel-level (±2px) against the running legacy widget + calendar.png (borderless) | Done 2026-07-19 (calendar reposition confirmed) |
| music (msc) | ☑ legacy music.conky.conf + lua/music.lua + cover_line.lua + screenshots/music*.png | ☑ split: playback/volume/cover suite-local (playerctl/pactl at draw time); arc geometry DERIVED from panels.orb.arc by reference (legacy weather-arc mirror, see 2026-08-28 note); volume during playback fixed to prefer pactl (system volume) over playerctl's own MPRIS field 2026-08-29 | ☑ media chassis top_middle head 1, 2460×1340 gap 0,413 — reproduces the *measured* rendered legacy positions (arc center abs (5755,938); legacy confs' raw gaps are not the rendered truth); width retuned 1700→2460 same day by commit 2f7573c to give lyrics its full ~785px clip capacity, table updated 2026-08-29 (F7) | ☑ Cairo via clean_media.lua, blank conky.text, palette-driven; HR/arc/markers/labels verified numerically vs the running legacy widget (progress dot y identical, x −5 = deliberate ambient-axis alignment); marquee + idle verified; volume marker re-verified live during active playback 2026-08-29 | Done 2026-08-28 |
| notes | ☑ legacy notes.conky.conf + theme.lua notes_* keys | ☑ suite-local (no core domain): direct read of ~/Documents/conky-notes.txt via lua/suite/notes.lua, 3 s tick cache | ☑ standalone top_right head 1, gap_x 31 reproduces the legacy *rendered* position (see 2026-07-20 note); gap_y measured as 292 but later moved to 350 by user preference (2026-08-27) | ☑ Cairo via clean_notes.lua, blank conky.text, palette-driven; verified numerically vs the running legacy widget (±1 px) | Done 2026-07-20 |
| lyrics | ☑ legacy music-lyrics.conky.conf + lua/lyrics.lua + theme.lyrics | ☑ CORE media domain (shared/media/local/lyrics.json, providers/media/fetch_lyrics.py; docs/lyrics-library-design.md) — suite side is display-only, no fetching | ☑ same media chassis window; panel at in-window (1296,5) 400×1324 reproduces the *measured* legacy rendered position (text left abs 6211, header baseline 441) | ☑ Cairo, palette-driven; verified pixel-exact vs the running legacy widget (identical text bbox 6212..6585 × 428..1326, 284 text rows, identical band starts); state messages + linger verified | Done 2026-08-28 |
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
  deliberately left to OSA's suite-local fast lane per `docs/system-provider-status.md`,
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
  abbreviation untouched). Documented in `docs/system-provider-status.md`.
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
  `layout.monitor.frame` is now 568×1980 (corrected 2026-08-29, F7 — this note
  said 598×1880 since the commit that created it, 578325e; that number was
  never true in committed code, and it had also been transcribed into
  `panels.lua`'s header comment, fixed separately by F1).
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

**Reopened — NET ping display frozen after launch (found 2026-08-28):**
Part 2's note above ("pings live once the connectivity provider runs") turned
out to be true only for the very first read. Root cause: connectivity has no
`refresh_loop` in `bin/gtex62-core-launch` — only `initial_refresh` — so its
`current.json` never updates again after the suite launches (confirmed by
watching the cache file's mtime stay frozen across minutes of wall-clock
time, independent of the widget; see the note above the connectivity
`initial_refresh` call in `bin/gtex62-core-launch` for the full
investigation, including why this is a day-one launcher omission and not an
abandoned continuous-refresh conversion). `monitor_helpers.lua`'s own
per-second tick-cache was working correctly the whole time — it just had
nothing new to read.

Fixed by switching NET's ping reader to `shared/net/local/state.vars`
(`CF_1111_MS`/`GOOGLE_8888_MS`), matching OSA's own pattern exactly — `net`
independently re-implements ping against the same two hosts and already has a
correctly-wired 1s `refresh_loop`, unlike connectivity. Verified live: 12
consecutive per-second reads through `mon.net_ping()`, all genuinely
different values, in lockstep with `state.vars`'s advancing mtime. Also
confirmed connectivity's `ping` object has no consumer anywhere in the
codebase — it was never the display source, `net` was. `gtex62-core-launch`
was deliberately left untouched; the refresh_loop gap is real but is now
understood to matter only for connectivity's speedtest staleness/age display,
not ping.

The **Domain Wired?** cell for `net` in the status table above has been
updated in place to reflect this fix.

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

**music (msc) + lyrics completed 2026-08-28.** The last two widgets — converted together as
the media chassis (MSC + LYRICS; notes went standalone 2026-07-20). Decisions and measured
values:

- *Domain split confirmed, not assumed*: lyrics is now CORE-owned — `providers/media/`
  `fetch_lyrics.py` → `shared/media/local/lyrics.json` (display-ready lines, LRC stripped
  provider-side; authoritative doc is **`docs/lyrics-library-design.md`**, not the pfsense
  provider doc). Playback state, volume/mute, and cover art remain suite-local
  (playerctl/pactl at draw time) — `providers/media/` has no player/cover collector, per
  that doc's deliberate scope split. `msc.lua` rewritten accordingly: its old suite-local
  lyrics cache read (`suites/clean-e/msc/lyrics/`, never populated) is gone; one jq per 2s
  tick reads lyrics.json. Suite manifest now declares `media` in `[data] domains`; runtime
  `suites/clean-e.toml` got an explicit `media = "local"`.
- *Provider-lag UX*: lyrics.json refreshes on the provider's ~60s loop, so after a track
  change (or playback start) it briefly describes the wrong/no track. The view model
  compares lyrics.json's track against the live playerctl track and reports state
  `"searching"` on mismatch → panel shows "Searching…" (legacy showed the same while its
  own fetch was throttled). All other lyrics.json states map to the legacy messages
  (not_found/offline/instrumental; `ok` → lines). The saved-path footer shows when
  `source ≠ "local"` (fetched online this cycle) — write-through promotes the track to
  the library, after which reads are `local` and the footer disappears, like legacy.
- *Weather-arc mirror preserved as a DERIVATION, not a copy* (user-flagged as deliberate,
  hard-won): legacy music.lua took its arc geometry from `theme.weather.*` at draw time
  (`get_arc_geometry_weather()`); `theme.music.arc`'s own r=140/200→−20 were dead config
  (verified: only its colors were read) and were NOT carried forward. In the port,
  `panels.msc.arc` REFERENCES `panels.orb.arc` fields (r/start/end/dy) and
  `panels.msc.baseline.length` references `panels.wxr.hline.length` (460 — the HR line
  mirrors the weather hline) at panels.lua load time. This is config-level live
  derivation: both chassis load the same panels.lua, so an ambient-arc retune propagates
  to the music arc on the next relaunch. A draw-time runtime read was considered and
  rejected as meaningless — the two are separate Conky processes with no runtime channel,
  and the geometry is static config; load-time reference is the strongest coupling that
  exists in this architecture. The trail color is `theme.astro.arc_night` by reference
  (legacy progress_color 242424 = gray14 = the horizon arc's night gray); the volume
  marker red is a fixed convention in new `theme.msc` (theme.astro precedent).
- *Rendered-position pitfall, both windows*: legacy `music.conky.conf` (conf: 640×270
  top_middle gap 0,530) actually rendered at physical (5307,734) 906×389 with the arc
  center at (5760,938) = window-relative (width/2, 204 = weather.center.y);
  `music-lyrics.conky.conf` (conf: 560×940 gap −600,300) rendered at (6201,413) 795×1324.
  Both measured off the running legacy widgets with a live MPRIS player (VLC
  `--no-audio`, silent). The media chassis is ONE top_middle window (1700×1340 at this
  point in the conversion, gap 0,413 → window at (4905,408); retuned to 2460×1340 later
  the same day by commit 2f7573c to give lyrics its full clip capacity — see the status
  table's msc row) covering both rendered footprints — legitimate under the
  chassis-combination pitfall because both legacy windows share the top_middle anchor on
  head 1 (unlike calendar/notes, whose top_right positions were disjoint from their
  chassis). gap_x 0 + full-width msc panel keeps the legacy auto_x self-centering: the
  music arc axis renders at abs 5755, IDENTICAL to the converted ambient arc's axis (both
  are 5px left of true monitor center — the suite-wide panel-width/2 convention, accepted
  since the ambient conversion). The chassis window rectangle overlaps the ambient and
  pfSense windows; drawn content boxes are disjoint (verified against all running
  widgets).
- *Album Art Image Reload pitfall — resolved differently, documented*: the legacy
  mtime-named-copy workaround existed only to defeat `${image}`'s no-hot-reload; the
  Cairo port has no `${image}`, so it's obsolete. The replacement constraint is that
  Cairo loads PNG only, while `mpris:artUrl` is typically JPEG (and file:// URLs are
  percent-encoded — the legacy pipeline silently failed on VLC's encoded URLs and fell
  back to the horn icon). `msc.lua` now URL-decodes, fetches http(s) art via curl, and
  converts to `suites/clean-e/msc/covers/current.png` (ImageMagick, ≤128px) only when the
  art source changes; idle/artless falls back to the shared-assets horn icon. Art
  placement itself was normalized: the legacy theme's `art` values (62×60 at center−13)
  never matched what `${image}` rendered (`-p`/`-s` were not honored as configured —
  measured; the accepted screenshots show ~88–148px art seated in the bowl), so the port
  draws a deterministic aspect-fit 88×88 box centered on the arc axis at center+68,
  between the album and artist lines — matching the accepted music.png composition.
- *Verified numerically* (window-id captures, same-second suite-e vs legacy):
  LYRICS **pixel-exact** — text bbox abs 6212..6585 × 428..1326, 284 text rows, identical
  band-start positions. MUSIC: HR line y 892/893 (sub-pixel), progress dot y identical to
  the decimal (1059.0) with exactly the deliberate 5.0px axis shift; red volume marker y
  exact; endpoint labels/title/album/artist positions match the theme model that today's
  legacy render also matches. Marquee verified live on an over-wide title (Chopin, 49
  chars): scrolls at the configured 18px/s within the clipped field, album line correctly
  static. Idle state verified after a 10s+ linger: music panel shows the inactive
  message, horn, 0:00/−0:00, and volume marker (pactl fallback works with no player,
  like legacy); lyrics panel hides. No Lua errors on stderr-captured runs.
- *Bug found during verify*: the view model's jq filter lost all lyric lines —
  jq's comma binds inside an unparenthesized trailing pipe target, so `.lines[]` was
  applied to the constructed header array (an error, silently discarded via 2>/dev/null).
  Fixed with explicit parens; commented at the call site.
- *Idle bars*: implemented but disabled (`panels.msc.bars.animate_idle = false`),
  matching the final legacy theme (music2.png shows the older enabled look) — pfSense
  baseline precedent, kept for easy revival.
- *Small cleanups folded in*: `theme.slash.empty_color` now pulls new palette role
  `slash_empty` (both palettes); `theme.pf_markers` comment reworded so the theme.astro
  precedent explicitly covers the legacy five with CAM as the palette-dependent
  exception; stale "MSC + NOTES + LYRICS" headers in clean_media.lua /
  clean-media.conky.conf fixed; dead `draw_hbar` helper removed from frame.lua.
- *Note*: the converted media chassis was left RUNNING after verification (started with
  `conky -c` alongside the launcher-started instances) — the standing "stop clean-media
  after verifying" note applied to the unconverted OSA-leftover layout and is now
  retired. The next `start-conky.sh` relaunch picks it up normally. The legacy music and
  music-lyrics widgets launched for measurement were stopped by PID.

**Reopened — volume marker frozen during active playback (found and fixed
2026-08-29):** Not a stale-read bug — both the idle and playing paths in
`read_player_state()` (`lua/suite/msc.lua`) were reading real, live values, just from
two genuinely different volume controls. Idle reads only `pactl get-sink-volume`
(system output/sink volume). While playing, the code preferred playerctl's `{{volume}}`
field first — the *player's own* MPRIS `Volume` property — falling back to pactl only
when that was unparseable. This exactly mirrors the legacy `get_volume_frac()` priority
order (playerctl-first, pactl-fallback, called unconditionally), so it's a preexisting
quirk carried over faithfully, not a conversion regression.

Root cause confirmed live: launched a real MPRIS player (VLC, `--intf dummy`, playing a
generated test tone) and set `pactl` sink volume to 50%, 80%, then 20% — `playerctl
volume` reported a constant 0.649994 through all three changes. VLC's MPRIS `Volume` is
its own internal software gain, decoupled from the system mixer; it never moves in
response to system volume changes (tray, hardware keys, `pactl`). The "stuck at 50%"
symptom the user saw was just whatever that player's internal gain happened to be —
coincidental, not a hardcoded fallback literal.

Fix: flipped the priority in the playing branch to match the idle branch — pactl
(system volume) first, playerctl's own `{{volume}}` field only as a fallback when pactl
itself is unavailable. Single source of truth for both states now.

Verified live end to end (not just the view model): relaunched `clean-media.conky.conf`
directly (`conky -c widgets/clean-media.conky.conf`) with VLC actively playing, screenshot
via `import -window <id>` at three distinct pactl volumes (30% / 90% / 55%) — the red
marker moved to the correct arc position each time, independent of the yellow playback
progress marker's position. Then stopped VLC and confirmed the idle path still tracks a
fourth pactl change (65%) correctly, matching pre-fix idle behavior. View-model level
(`M.player().volume_frac`) also checked directly across four pactl values (30/60/90/45%)
while `status = Playing`, all exact.

Also reproduced, in the process, the runbook's own documented pitfall ("never put a
conky conf name in a `pkill -f` pattern from this harness — the pattern matches the
harness's own wrapper shell and kills it, exit 144; kill by PID instead") — hit it
firsthand launching the test conky instance, confirming the existing warning is still
accurate.

**Monitor chassis polish — two bugs fixed 2026-08-29 (compliance-scan follow-up):**

- *NET header text clipped by the frame's right edge.* `frame.lua`'s
  `draw_net_content` right-aligned the "Updated: HH:MM:SS" pair against a
  `right_x` computed as the separator-line width **plus 4 extra chars**
  (`(sep_count + 4) * char_px`). At `sep_count = 50` that lands at x≈593,
  but `layout.monitor.frame.width` is 568 (the "598×1880" comment in
  `panels.lua` was already known-stale per the compliance scan's §1
  finding — 598 was never true in committed code) — so the last ~2
  characters rendered past the window edge and were clipped. Confirmed
  live before fixing: screenshot showed `Updated: 20:55:4` cut off after
  the seconds' tens digit. Fix: dropped the stray `+ 4`, so the header's
  right edge now matches the separator line's own right edge (549.5px,
  comfortably inside the 568px frame with ~18px to spare — matching
  `layout.monitor.margin.right = 18`). Verified live: relaunched
  `clean-monitor.conky.conf`, screenshot shows the full string
  (`Updated: 20:56:47`) rendering inside the frame with visible margin.
- *`theme.sep.count` dead config, confirmed live* — matches the compliance
  scan's §3 finding exactly: `frame.lua` read `panels.sys.sep_count` (also
  50) for the dash separator count in both SYS and NET content, never
  `theme.sep.count`; two copies of the same constant, only one wired up.
  **This also closes the scan's F4 dead-config item** (the `theme.sep.count`
  half of F4 — the other half, calendar's two hardcoded RGBA colors and
  `panels.cal.calendar.week_start`, is still open). Decision: kept
  `theme.sep.count` as the sole source of truth and deleted
  `panels.sys.sep_count` — `theme.lua` already holds the analogous
  "how many repeated glyphs" style dial for the SYS slash bars
  (`theme.slash.count`), so a user tuning separator-dash density would
  look there first, and `panels.lua` is documented as per-widget
  *geometry*, not suite-wide style. `frame.lua` now reads
  `theme.sep.count` in both `draw_sys_content` and `draw_net_content`
  (the NET header's `right_x` derives from the same value, since it
  right-aligns to the separator line's width). Verified live: set
  `theme.sep.count = 20`, relaunched, confirmed SYS's dash lines visibly
  shortened suite-wide (proving the wiring, not just the math) — the
  resulting header-label overlap at that extreme test value is expected
  (20 dashes is narrower than the "GOnion Network" label itself) and not
  a new bug; reverted to 50 and re-verified clean.
- *Third item raised alongside these bugs — not yet implemented, holding
  for a separate follow-up per instruction:* the user wants SYS's dash
  count reduced (~5 fewer) and NET switched from dashes to solid
  separator lines with its own independent width (legacy NET used solid
  lines, not dashes — a different visual convention from SYS, which the
  current shared `sep_str`/`sep()` helper doesn't distinguish). SYS's
  count would now be a one-line change to `theme.sep.count`. NET's
  solid-line style has no equivalent to reuse — `frame.lua` has no
  solid-line separator drawing path at all (only the dash-repeat
  `sep_str` helper) — so it needs new draw logic (e.g. a `draw_hline`-style
  call) and a new NET-specific width/style config, decoupled from
  `theme.sep.count` so tuning one doesn't move the other. This will also
  need to reconcile with NET's header `right_x`, which currently derives
  from the shared dash `sep_count` — once NET has its own line width,
  `right_x` should switch to deriving from that instead.
- Incidentally re-hit the runbook's own documented `pkill -f` pitfall a
  third time (see the 2026-08-29 volume-marker note above) — this time via
  `kill $(pgrep -f ".../clean-monitor.conky.conf")`, which is the same
  pattern class (any `-f` match against a conf path can catch the
  harness's own wrapper shell), not just literal `pkill -f`. Killed the
  test conky instance's supervising shell (exit 144); recovered by
  restarting via `scripts/start-conky.sh`, which resynced all six
  chassis/standalone PID files. Widening the standing warning: avoid
  `-f` process matching against conf paths in this harness at all,
  `pkill` or `pgrep` alike — match by bare PID instead.

**F1 (compliance-scan follow-up) — panel frame-geometry derivation
generalized to every remaining panel, 2026-08-29.** Commit `2f7573c` did
this for the media chassis only (panels.msc/panels.lyrics deriving from
`layout.media.frame.width` instead of a copy); this session did the same
for everything else the scan's §4 table flagged:

- `panels.wxr.width`, `panels.orb.width`, `panels.tme.width`, and
  `panels.tme.boxes.clock.width` now read a local `AMBIENT_W =
  layout.ambient.frame.width` instead of each repeating `680`.
- `panels.cal.width`/`.height` now read `layout.calendar.frame`.
- `panels.notes.width`/`.height` now read `layout.notes.frame` — see the
  "silent duplicate, confirmed" note below.
- `panels.pfsense.width`/`.height` now read `layout.pfsense.frame` — see
  "pfSense, the priority case" below.
- All values were confirmed numerically unchanged before/after (`lua -e`
  dump of the loaded `panels` table: wxr/orb/tme/clock width all still
  680, cal 362×273, notes 404×1810, pfsense 840×500) — this was a pure
  refactor, not a retune.

*pfSense, the priority case — comment now matches reality.* Before this
session, `panels.pfsense`'s comment already asserted "Box equals
layout.pfsense's frame at (0,0)" but the box was still a hardcoded
840×500 literal — true only because nothing had touched either value
since the post-verify retune (660×520 -> 840×500 around the user-tuned
r=400 dome, see the 2026-08-27 pfsense completion note above) drifted
them apart yet. This is the exact divergence-prone pattern the same note
says "already caused one off-center bug" the first time two boxes for
one window went out of sync. Fixed: `panels.pfsense.width`/`.height` now
read `layout.pfsense.frame` directly (`local PF_FRAME =
layout.pfsense.frame`), so the comment's claim is enforced by code.
Verified live (see below) with particular attention paid here given the
history.

*The ambient/media arc-axis mirror — this was the actual stakes.*
`panels.msc.arc` references `panels.orb.arc` by value at load time (the
deliberate weather-arc mirror from the music/lyrics conversion, see the
2026-08-28 note above), and "the music arc axis renders at the same x as
the ambient arc axis" only holds if BOTH chassis self-center on
`width/2` of their OWN frame. Media already did (commit `2f7573c`);
ambient didn't until this session's WXR/ORB/TME fix. Verified live, not
just by inspection: temporarily widened `layout.ambient.frame.width`
680 -> 880, relaunched `clean-ambient` + `clean-media`, screenshotted
both windows, and confirmed by direct pixel measurement (window_left
from `wmctrl -lG` [÷2 for the physical-vs-reported 2x position scale,
per the notes-widget measurement gotcha above] + local arc-center pixel
from the screenshot) that both arc axes landed at the identical absolute
x (5755 — the same value the 2026-08-28 media note already recorded for
both), confirmed visually with a marker line overlaid on crops of both
screenshots. `media_widened.png` was byte-identical to the unwidened
capture, confirming zero coupling in the other direction. Reverted to
680 and reconfirmed both windows returned to their original `wmctrl`
geometry before moving on.

*Notes: confirmed silent duplicate, kept derived rather than deleted.*
Per the scan's flag, `panels.notes.width`/`.height` are read by nothing
— `draw_notes_content` (`frame.lua`) only uses `panel.x`/`panel.y` and
`panel.grid.*`. Decision: derive from `layout.notes.frame` rather than
delete, since (a) it costs nothing, (b) every other panel in the file
carries width/height as part of its standard shape, and (c) a derived-
but-unused field can't go silently stale the way a hardcoded-but-unused
one already had (404×1810 happened to still match the frame, not
because anything enforced it).

*`panels.net.graph.width` — decided NOT to derive, decoupling
preserved.* The scan's text described this value as "531," but by the
time this session read the live file it was already `500` — the prior
session's commit `e09c875` had already tuned it 531 -> 500 and
deliberately broken its old coincidental equality with
`lua/suite/monitor_helpers.lua`'s `TP.maxlen` (the throughput
ring-buffer sample count, still 531), flagging the leftover duplicate
"tracked separately under F1." This session's call: leave
`panels.net.graph.width` a literal, not derived from
`layout.monitor.frame.width` (568). Two reasons: (1) no clean formula
ties either 500 or 531 to 568 — both were tuned by eye for on-screen
headroom, not computed from the frame; (2) `monitor_helpers.lua` is a
pure data view model (Phase 4 of the conversion guide) that has never
loaded `theme/panels.lua` — wiring it in for one constant would cross
the data/presentation line the whole suite otherwise respects. Re-read
`draw_net_content`'s graph-drawing loop to confirm the coupling risk is
one-directional: the ring buffer may safely hold MORE samples than the
graph draws (older samples compute an off-panel x and are skipped), so
`TP.maxlen ≥ graph.width` is safe; a graph WIDER than the buffer would
show a permanently blank strip on its left edge. Documented at both
definition sites (`panels.lua` and, informally, this note) so a future
width bump raises both by hand together.

*Margin-consistency audit.* `layout.monitor` and `layout.ambient`
carried non-zero `margin` blocks (`top 24, left 18, right 18, gap 18`)
while `layout.calendar`/`layout.notes`/`layout.pfsense` were all
zero-margin "snug" frames. Grepped `lua/` + `theme/` + `widgets/` for
any consumer of `layout.*.margin` — none exists anywhere; SYS/NET
position off `panels.monitor_grid`, and WXR/ORB/TME position off their
own panel x/y/dy offsets, none of it touching `.margin`. Confirmed dead,
not load-bearing — an OSA-era leftover from the same original-copy
problem the "Why This Stalled" section at the top of this runbook
already documents. Zeroed both to match the snug-frame convention,
noted why in a comment at each site.

*Two stale header comments fixed* (also flagged by the scan's §4 note):
`panels.lua`'s "MONITOR CHASSIS (598 × 1880)" -> "(568 × 1980,
layout.monitor.frame)"; "PFSENSE STANDALONE (660 × 520)" -> "(layout.pfsense.frame,
840 × 500)".

*Verification method*: relaunched via `scripts/start-conky.sh` before
and after the refactor, capturing window IDs/geometry via `wmctrl -lG`
(all six windows reappeared at byte-identical position AND size) and
screenshots via `import -window` for all six chassis/standalone windows.
`media`/`notes`/`calendar` screenshots were byte-identical before vs
after. `monitor`/`ambient`/`pfsense` showed only the expected live-data
deltas (clock seconds ticking, CPU/RAM percentages, throughput graph
bars, VLAN marker positions, sun-icon position) confirmed via
`compare -metric AE` + visual inspection of the diff masks — no
structural/positional differences. No Lua errors (`luac -p` clean on
both touched files; suite relaunched without stderr errors).

**F3 (compliance-scan follow-up) — NET individually audited and anchored
to a fixed position, 2026-08-29.** The scan flagged NET as the one
converted panel with no recorded pixel value: `frame.lua`'s
`draw_monitor` ran `draw_sys_content` then threaded its returned
end-of-content cursor into `draw_net_content`, so NET's vertical origin
was emergent — wherever SYS's text flow happened to end, not a measured
position. **Upfront correction to the scan's own claim**: the scan named
`mon.disk_rows()` as the concrete trigger — "filesystem rows are not
capped... mounting or unmounting a filesystem shifts every NET row below
it by 23px." That specific claim does **not** reproduce against the
actual code: `disk_rows()` iterates a hardcoded 2-entry label list, not
the live filesystem array, so no mount/unmount of any real or synthetic
filesystem changes its row count — verified below. The scan was wrong
about the trigger. It was right that NET's position was architecturally
emergent, and that the general risk class (SYS's line count silently
changing and dragging NET with it) was real, just via a different,
still-live mechanism (`gpu_present()` / top-N row counts, see below) —
that's what this fix actually addresses, not the disk-mount scenario as
literally described.

- *Investigated both options per the scan's framing.* Before picking,
  checked `mon.disk_rows()` itself (`lua/suite/monitor_helpers.lua`):
  it iterates a hardcoded 2-entry `DISK_ROWS` spec list (`/ROOT`, `/WD`),
  not the live `.filesystems[]` array from `storage.json` — a missing
  entry just renders dash placeholders in the same row, it doesn't drop
  the row. **Verified live/standalone**: fed the function synthetic
  `storage.json` payloads (zero filesystems, an unrelated `/USB` entry,
  `/WD` absent) via a `GTEX62_CACHE_DIR`-pointed harness — row count
  stayed at exactly 2 in every case. So `disk_rows()` was already
  deterministically bounded; the scan's "filesystem rows are not
  capped" claim did not hold against the actual code. Option B's
  proposed action (cap it) had nothing left to do.
- *Checked ambient/media for an analogous unbounded-row situation*, per
  the instruction to look for the more direct parallel before choosing.
  Neither has one: `draw_ambient` calls `draw_wxr_content` /
  `draw_orb_content` / `draw_tme_content` independently, and `draw_media`
  calls `draw_msc_content` / `draw_lyrics_content` independently —
  `draw_monitor`'s cursor-threading between `draw_sys_content` and
  `draw_net_content` was the *only* place in `frame.lua` where one
  content function's draw position depends on another's runtime output.
  Every other combined chassis already uses individually fixed, measured
  sub-positions (ambient's weather 90px below chassis top; media's msc/
  lyrics rendered-position measurements) — confirming Option A matches
  the codebase's standing convention, and monitor's threading was the
  outlier, not precedent to extend.
- *Residual real risk, distinct from disk_rows()*: SYS's total line
  count still depends on `mon.gpu_present()` (5 lines vs. 1) and on
  `top_cpu_rows`/`top_mem_rows` returning fewer than their 5-row request
  on a near-idle box — either would have silently moved NET under the
  old threaded design with no visible cause, same fragility class the
  scan was pointing at even though its named trigger (mount/unmount)
  turned out to be a non-issue.
- **Decision: Option A.** Added `panels.net.y0 = 1013` (chassis-relative,
  fixed) in `theme/panels.lua`. `frame.lua`'s `grid_cursor()` now takes
  an optional `y0` override; `draw_net_content` builds its own cursor
  from `panels.net.y0` instead of receiving `cur` from `draw_sys_content`
  as a parameter, and `draw_sys_content` no longer returns a cursor.
  `M.draw_monitor` now calls both content functions independently,
  matching `draw_ambient`/`draw_media`. NET's old leading `nl() x4`
  (four blank lines before its header) was folded into the measured
  `y0` value instead of staying a draw-time offset.
- *Value derivation, measured not guessed*: ran `draw_sys_content`'s
  exact line-advance sequence against this machine's live caches (GPU
  present, 5 top_cpu + 5 top_mem + 2 disk rows, the same "audit the
  rendered position" discipline used for calendar/notes/media) — SYS's
  content ends at cursor y 921 (chassis-relative, `monitor_grid`
  units); +4 lines (23px each) for the gap NET's header used to open
  with = 1013. This preserves today's "NET follows immediately after
  SYS" visual relationship as a snapshot, the same way legacy's own
  fixed 750px sys-info/net-sys offset was itself just a chosen number —
  just measured against this port's grid instead of legacy's. A future
  change to SYS's content that shifts where its text naturally ends
  will now show a gap or overlap rather than silently relocating NET;
  that tradeoff is Option A's own stated one, accepted here since the
  ambient/media precedent treats it as normal (both already show minor
  seams between their own individually-positioned sub-elements when
  content varies).
- **Verified live under the actual failure condition**: temporarily
  added a synthetic third `DISK_ROWS` entry (`/NAS_Data`) to
  `monitor_helpers.lua`, relaunched via `start-conky.sh`, and confirmed
  via screenshot + pixel diff (`compare -metric AE`, cropped to the
  "GOnion Network" header region) that NET's header rendered at
  **0 differing pixels** vs. the pre-change screenshot, while SYS
  visibly grew by one full line above it (3 disk rows shown, CPU/RAM/
  GPU/footer all shifted down 23px as expected). This is the direct
  proof that NET is now decoupled from SYS's line count — a real mount/
  unmount wouldn't have moved anything either way (per the disk_rows()
  finding above), so the synthetic row was used to actually exercise a
  SYS-row-count change, which is the true failure-condition class the
  scan was warning about. Reverted the synthetic row immediately after
  and relaunched again to confirm the suite returned to its normal
  2-disk-row state with NET still at the same measured position. No Lua
  errors on any of the three relaunches (`luac -p` clean on both touched
  files throughout).
- Updated `panels.lua`'s MONITOR CHASSIS header comment and `frame.lua`'s
  SYS+NET section comment to describe the independent-positioning
  architecture instead of the retired cursor-threading one.

**F2 (compliance-scan follow-up) — monitor profile resolution routed
through suite config, 2026-08-29.** `lua/suite/monitor_helpers.lua`
resolved its profiles by a different mechanism from every other view
model in the suite (orb.lua, wxr.lua, pf.lua, msc.lua, tme.lua all read
`[profiles]` out of `$GTEX62_CONFIG_DIR/suites/clean-e.toml`):

- `NET_JSON` was a hardcoded literal path
  (`shared/network/local/current.json`) — no profile variable at all.
- `SYS_PROFILE` came from `os.getenv("GTEX62_SYSTEM_PROFILE") or
  "local"` — nothing in the suite exports that var, so it was always
  `"local"`.
- The scan's snapshot also named a `CONN_PROFILE` /
  `GTEX62_CONNECTIVITY_PROFILE` env var at this same spot. It no longer
  exists in the file — the 2026-08-28 NET-ping-freeze fix (see above)
  already dropped connectivity as a data source entirely when NET's ping
  reader moved to `net`'s `state.vars`, taking the connectivity-profile
  variable with it. Confirmed via grep: nothing in `monitor_helpers.lua`
  reads `connectivity` any more (one stale comment in
  `clean-monitor.conky.conf` is the only surviving mention, untouched —
  out of this fix's scope). So the actual live bug was two hardcoded
  profiles, not three.
- The runtime `suites/clean-e.toml` already declared `network = "local"`
  and `connectivity = "default"` under `[profiles]` — both inert as far
  as this chassis was concerned, since nothing read them for it. Looked
  config-driven; was a hardcoded copy that happened to currently match.

*The GTEX62_NET_PROFILE question.* The same 2026-08-28 ping-freeze fix
that switched NET's ping reader to `shared/net/<profile>/state.vars`
also added its own override,
`NET_PROFILE = os.getenv("GTEX62_NET_PROFILE") or "local"` — deliberately,
matching this file's *existing* `SYS_PROFILE`/`CONN_PROFILE` env-var
convention at the time. Investigated whether that makes it a legitimate,
separate exception rather than more of the same bug, per instruction not
to assume:

- `docs/net-provider-reference.md`'s own **Suite Consumption** section is
  unambiguous: "Suites read from `shared/net/<profile>/` and resolve the
  profile from their suite TOML `[profiles] net` key (default
  `"local"`)." That is the documented, authoritative resolution
  mechanism for this exact domain — an env var is not mentioned anywhere
  in that doc.
- The env var was added specifically *because* it matched this file's
  own then-existing pattern — but that pattern is precisely the
  anti-pattern this fix removes from the same file. Keeping `net` on env
  resolution while moving `system`/`network` to config would leave the
  file internally inconsistent for no documented reason, and would still
  leave `suites/clean-e.toml`'s eventual `net` entry inert for this one
  reader.
- **Conclusion: not a legitimate exception — folded in.** `NET_PROFILE`
  now resolves from suite config exactly like `SYS_PROFILE` and the new
  `NETWORK_PROFILE`, with the env var removed. This matches
  `docs/net-provider-reference.md` and restores single-mechanism consistency
  across the whole file.

*Fix.* Ported the `parse_simple_toml`-into-`RUNTIME_ROOT ..
"/suites/" .. SUITE_ID .. ".toml"` pattern (pf.lua's copy, byte-identical
parser) into `monitor_helpers.lua`. All three profiles now derive from
one `SUITE_PROFILES` table read once at module load:
`SYS_PROFILE = SUITE_PROFILES.system or "local"`,
`NETWORK_PROFILE = SUITE_PROFILES.network or "local"`,
`NET_PROFILE = SUITE_PROFILES.net or "local"` — same fallback defaults
the hardcoded/env-var versions always produced, so no behavior change
until the config is actually edited. `NET_JSON` is now built from
`NETWORK_PROFILE` instead of the literal path. Added explicit
`system = "local"` and `net = "local"` entries to the runtime
`suites/clean-e.toml` `[profiles]` block (matching `gtex62-osa`'s own
`suites/osa.toml`, which already declares `system` explicitly rather
than relying on silent fallback) — makes both profiles genuinely tunable
instead of merely defaulting correctly.

*Adjacent cleanup, same finding (scan §2 "two literal suite-config
paths").* `wxr.lua:95` and `msc.lua:86` each hardcoded the literal
string `"suites/clean-e.toml"` despite both files already defining and
using a `SUITE_ID` variable elsewhere (`wxr.lua:9`/`:189`,
`msc.lua:25`/`:89`) — copy-paste-vs-reference, not a design gap. Both
now build the path from `SUITE_ID`.

*Verified live, under an actual config change* (not just code
inspection — same bar as the NET-ping-freeze fix, which also "looked
wired" until tested):

1. Baseline screenshot of the running `clean-monitor` window: SYS and
   NET both fully populated (disk rows, CPU/RAM/GPU, NIC identity,
   WAN/LAN IPs, DNS, VLAN gateway table, live throughput graphs).
2. Set `system`, `net`, and `network` to a nonexistent profile literal
   (`"bogus-test-profile"`) in the runtime `suites/clean-e.toml` and
   relaunched via `scripts/start-conky.sh`.
3. **NET visibly broke on screen**: "Network Interface: NIC UNKNOWN",
   WAN Status "Offline", WAN/LAN IP/DNS/Subnet all "—", "VLAN Gateways:
   VLAN data unavailable" — because the `network` provider, given an
   unrecognized profile with no matching `profiles/network/*.toml`,
   wrote only `status.json` under the new
   `shared/network/bogus-test-profile/` dir, no `current.json`, so
   `NET_JSON` (now correctly pointed at that bogus-profile path) had
   nothing to read.
4. SYS and NET-ping stayed populated with plausible live values even
   under the bogus profile — this is not a fix failure. Inspected the
   cache directly: `shared/system/bogus-test-profile/current.json` and
   `shared/net/bogus-test-profile/state.vars` were both freshly created
   and populated with real host telemetry, because the `system` and
   `net` providers are host-local and run regardless of whether a
   profile-specific TOML exists (matching the architecture doc's "missing
   profile TOML falls back to a 60s TTL" note, for `system`) — unlike
   `network`, which needs profile config to know what to query. The
   `system` cache file even self-reports
   `"profile": "bogus-test-profile"` inside its own JSON — direct proof
   the Lua reader built and read that exact bogus path, not the old
   `local` one. Ping values in the bogus `state.vars` (`CF_1111_MS`,
   `GOOGLE_8888_MS`) matched what was on screen, confirming `NET_PROFILE`
   resolution also took effect, just without a visible break for this
   particular domain's data shape.
5. Reverted all three to `"local"` and relaunched again: full screenshot
   comparison against the step-1 baseline — SYS and NET both fully
   restored (disk/CPU/RAM/GPU, NIC identity, WAN/LAN/DNS/Subnet, all 5
   VLAN gateway rows). Throughput graphs started blank (fresh process,
   empty ring buffer) — expected, not a regression.
6. Confirmed via `wmctrl`/`pgrep` after the final relaunch: exactly six
   conky processes, one per chassis/standalone, no orphans from the two
   test relaunches. `luac -p` clean on every `.lua` file in the suite.
   Screenshotted `clean-ambient` and `clean-media` (unaffected windows
   that still exercise the touched `wxr.lua`/`msc.lua` code paths) —
   both rendered normally (weather arc/forecast/METAR/TAF; idle media
   panel with horn icon and volume markers), confirming the `SUITE_ID`
   fix didn't change behavior since `SUITE_ID` already resolved to
   `"clean-e"` either way. Deleted the three `bogus-test-profile` cache
   directories afterward.

**F2 follow-up — narrow pre-emptive slice of F7, 2026-08-29.** F2's fix
(above) hand-added `system = "local"` and `net = "local"` to the *live*
runtime `~/.config/gtex62-core/suites/clean-e.toml`. That file isn't
tracked by git and isn't generated from a static `.example` template the
way `osa.toml`/`sitrep.toml` are — grepped
`examples/runtime/suites/` and found no `clean-e.toml.example` there at
all. The actual generator is a heredoc inside
`gtex62-clean-suite-e/scripts/bootstrap-runtime.sh` (invoked by
`start-conky.sh` only when `clean-e.toml` doesn't already exist, and
also directly by a fresh install / recovery). Left alone, that heredoc
would have silently regenerated `clean-e.toml` *without* `system`/`net`
on the next from-scratch bootstrap (new machine, deleted runtime dir,
recovery), quietly reverting today's F2 fix for anyone who didn't know
to redo it by hand — the same "looks fixed until the next full
resync" trap this session was warned about. This is a **narrow,
early slice of F7** (`docs/clean-suite-e-scan.html`'s "Resync bootstrap
and docs" item) — just the two entries F2 depends on, done pre-emptively
so they don't silently regress before a full F7 session gets to the rest
of that item's list.

- Added `system = "local"` and `net = "local"` to the `[profiles]` block
  inside the heredoc at `gtex62-clean-suite-e/scripts/bootstrap-runtime.sh`
  (same position/order as the live file).
- **Deliberately NOT done here** (left for a full F7 session, per
  instruction): dropping the stale `air` entry from the same block,
  ceasing to create the dead `suites/clean-e/{pf,net}` cache dirs (the
  script still `mkdir -p`s both — neither is read by any current view
  model, per the earlier directory-cleanup notes), cleaning the existing
  empty `pf`/`net`/`orb` dirs on disk, and — noticed in the course of
  this narrow fix but *not* part of it either — the heredoc's
  `[profiles]` block is also still missing `media = "local"` (added to
  the *live* file during the 2026-08-28 music/lyrics conversion, never
  backported to this generator; scan's F7 item already flags this as
  "add media and system"). All of these are real, all are F7's to fix as
  a set — not folded in here to keep this slice narrow, per instruction.
- **Verified without touching the live config**: ran
  `scripts/bootstrap-runtime.sh` with `GTEX62_CONFIG_DIR`/
  `GTEX62_CACHE_DIR` pointed at a scratch directory under the session
  scratchpad (never the live `~/.config/gtex62-core`), exercising the
  "file doesn't exist yet" creation branch — the exact branch a fresh
  install or recovery would hit. `diff -u` between the freshly generated
  scratch `clean-e.toml` and the live file showed exactly one line of
  difference: the live file's trailing `media = "local"` (the
  pre-existing, separately-tracked F7 gap noted above, correctly left
  alone). Every other line — including the new `system`/`net` entries —
  matched byte-for-byte. `bash -n` clean on the edited script. The core
  bootstrap utility's other generated files (`core.toml`, `site.toml`,
  profile TOMLs, `osa.toml`/`sitrep.toml`) also wrote successfully into
  the scratch dir during the same run, confirming the edit didn't
  disturb anything else the script produces. Scratch directory deleted
  after the diff.

**F5 (compliance-scan follow-up) — dead functions swept from the ported
view models, 2026-08-29.** The scan's §5 named 22 unreachable exported
functions (`wxr.lua` 9, `tme.lua` 12, `orb.lua` 1, `monitor_helpers.lua` 1)
left behind by the 2026-07-19 directory cleanup, which swept dead *files*
(`net.lua`/`sys.lua`) but never dead functions inside surviving modules.
Line numbers in the scan were long stale by this session (F1 moved
`frame.lua` to `lua/ui/frame.lua` and rewrote `panels.lua`; F2/F3 rewrote
chunks of `monitor_helpers.lua`), so every name was re-confirmed with a
fresh repo-wide grep before deleting anything, per instruction — including
checking for the `arc_fraction_for_azimuth`-class near-miss (an
externally-dead-looking name that's actually live via an internal call)
on every candidate.

- **`orb.lua` — 1 deleted.** `moon_rise_set` had zero callers anywhere
  (`sun_rise_set` is the one actually read, at `frame.lua:568`). Deleted
  cleanly; `pick_today_rise_set` (its shared helper) stays live via
  `sun_rise_set`.
- **`monitor_helpers.lua` — 1 deleted.** `sys_available` had zero callers
  (checked every other `M.*` export against `frame.lua` too — all 28 of
  the rest are read). Deleted; `refresh_sys` stays live via `sys_value`.
- **`wxr.lua` — 9 named deleted, plus a further cascade.** All 9
  (`status_lines`, `current_box_title`, `current_headers`, `current_row`,
  `forecast_box_title`, `forecast_headers`, `forecast_rows`,
  `station_model_box_title`, `station_model`) confirmed dead — `frame.lua`
  only ever calls `legacy_current`/`legacy_forecast`/`current_metar_lines`/
  `forecast_taf_lines`. Removing the 9 wrappers left their entire backing
  implementation newly dead too (nothing else read it): the whole
  OWM-sky/METAR-station-model decoder tree — `decode_current`,
  `decode_forecast_rows`, `decode_station_model`, `forecast_glyphs`,
  `forecast_date_label`, `parse_station_model`, and ~25 wind/visibility/
  temp/altimeter/cloud/remarks/tendency/wx-glyph parsing helpers below it
  — plus the "DATA // NOMINAL" status-state machine (`weather_data_state`,
  `aviation_data_state` — the latter already had *zero* callers even
  before this sweep, a second dead function the named list didn't catch),
  `json_number`, `json_timestamp`/`parse_timestamp`/`parse_iso_utc`,
  `format_hhmm_local/_utc`, `file_exists`, `session_start_ts`,
  `metar_observation_ts`, `taf_issue_ts`. Traced the whole closure by grep
  count per name (def + call-sites) before deleting each one — file shrank
  376 lines from ~1045. `wxr.lua:341`'s `dofile("lua/lib/weather_codes.lua")`
  (a path that only exists in the read-only `gtex62-osa`/`gtex62-lcars`
  suites; pcall-wrapped, silently set `WEATHER_CODES = false` here) had its
  only three callers all inside this dead tree (`decode_current`,
  `decode_station_model`, `forecast_glyphs`) — confirmed, then deleted
  `load_weather_codes` and the `dofile` call itself, not just its
  now-orphaned result. `extract_ob_line` and `aviation_station` survive —
  both are also used by the live `decode_metar_lines` path.
- **`tme.lua` — 12 named deleted, plus a further cascade.** All 12
  (`calendar_box_title`, `calendar_event_dates`, `calendar_events`,
  `calendar_title`, `calendar_today`, `calendar_weeks`, `clock_box_title`,
  `clock_rows`, `local_date`, `local_time`, `status_lines`, `utc_time`)
  confirmed dead — `frame.lua` only calls `local_time_hms`/`utc_line`/
  `date_line`/`calendar_view`. Same cascade pattern as wxr.lua: with the
  12 wrappers gone, their entire backing tree became dead too — the
  calendar-events/astro-sunrise "next event" status line
  (`event_status_line`, `sun_event_status_line`, `parse_calendar_status`,
  `parse_json_events`, `parse_event_lines`, `days_from_today`,
  `format_countdown`) and the whole core-cache profile-resolution stack
  built only to feed it (`calendar_profile_id`/`astro_profile_id`/
  `time_profile_id`, `*_shared_dir`, `*_json_path`, `calendar_profile`,
  `event_cache_path`, `extra_events_path`, `engine_config`,
  `engine_cache_root`, `suite_config`, `parse_simple_toml`, `read_file`,
  `command_output`, `normalize_spaces`) and the clock-table decoders
  (`parse_time_rows`, `parse_time_local`, `tz_date_parts`). Confirmed
  `tz_date_parts()`'s `TZ=... date ...` shell call was reachable only from
  the dead `M.clock_rows`, exactly as flagged — it disappears with the
  sweep, no separate core-sourcing fix needed since it was never reachable
  in production. `build_weeks`/`days_in_month`/`weekday_su0` survive —
  `M.calendar_view` (live) uses `build_weeks` too, so that one didn't go
  with the rest of the OSA-inherited calendar-table API. File shrank from
  485 to 133 lines — nearly everything left was serving only the dead
  wrappers.
- **Judgment call, not just the named list**: the task explicitly allowed
  trimming further unreachable code found nearby while in these files, not
  just the scan's named functions — taken here because the cascade was a
  direct, mechanical consequence of deleting the named wrappers (removing
  a dead export and leaving its now-orphaned private implementation in
  place would have been half a sweep), not a separate unscoped hunt.
  `orb.lua` and `monitor_helpers.lua` had no such cascade — both were
  already tight, single-purpose modules with no OSA-inherited parallel API
  to strip.
- **Verified.** `luac -p` clean on all four touched files. Standalone
  `lua -e` smoke test of each module's surviving public API against live
  caches (`wxr.current_metar_lines`/`forecast_taf_lines`/`legacy_current`/
  `legacy_forecast`; `tme.local_time_hms`/`utc_line`/`date_line`/
  `calendar_view`; `orb.sun_rise_set`/`sun_arc_fraction`/
  `moon_arc_fraction`/`planet_arc_fractions`/`apex_label`;
  `monitor_helpers.os_name`/`cpu_percent`/`net_iface_title`) — all
  returned real values, no errors. Relaunched the full suite via
  `scripts/start-conky.sh`: all six chassis/standalone processes came up
  and stayed up (checked immediately and again 5s later — no crash-after-
  launch). Additionally ran `clean-monitor`/`clean-ambient`/`clean-calendar`
  (the three confs that load the touched view models) directly with stderr
  captured for 5s each, alongside the launcher-managed instances, then
  killed the test PIDs directly (not by `pkill -f` against the conf name,
  per this runbook's own standing warning) — stderr showed only conky's
  normal window-creation lines, no Lua errors.

**F4 (compliance-scan follow-up) — calendar's two hardcoded colors moved
to the palette; two dead config keys resolved, 2026-08-29.** The
`theme.sep.count` half of F4 was already closed by the monitor-chassis-
polish session above; this session closes the remaining half — the
scan's §3 rendering-compliance fail — plus the two §3 dead-config keys
named alongside it.

- *Line numbers re-verified, both stale.* The scan named
  `panels.lua:215-216`; by this session the calendar block had moved to
  `panels.lua:286-287` (F1/F5 restructuring in between). Re-found by
  fresh grep before touching anything, per standing instruction.
- *Not exempt, confirmed against the actual rationale.* Read
  `theme.astro`/`theme.pf_markers`'s documented exemption in full
  (`clean-theme.lua`'s own comments, ported to §3's wording): sun/moon/
  planet colors are physical-object conventions, pfSense per-VLAN marker
  colors are legacy direction/brightness encoding. `panels.cal.calendar`'s
  `grid_color` (cell border) and `weekend_color` (Su/Sa day-number tint)
  carry no such rationale — ordinary UI chrome, same class as
  `slash_empty`/`pf_arc_base` (both already palette roles). Fixed
  accordingly, not treated as a third exemption.
- *New palette roles* `cal_grid`/`cal_weekend` added to both palettes in
  `clean-palettes.lua`, same RGBA values the hardcoded literals had for
  `default` (`{0.35,0.35,0.35,0.55}` / `{0.47,0.47,0.47,1.00}`, exact
  preservation — this is a wiring fix, not a retune). `dark` variant
  reuses `slash_empty`'s blue-shifted gray base for `cal_grid`
  (`{0.30,0.32,0.38,0.55}`) and applies the same +0.12/channel lift
  `default` uses between `slash_empty` and `weekend_color` to get
  `cal_weekend` (`{0.42,0.44,0.50,1.00}`) — consistent with how the rest
  of the dark palette derives its grays, not a fresh guess.
- *Wired through `theme.cal`, not `panels.cal`* — matching the
  `theme.pf = { arc_base = ... }` precedent (color/style lives in
  `clean-theme.lua`, consumed by name from `frame.lua`; `panels.lua` stays
  geometry-only, same principle the sep_count note above already
  established for `panels.sys`). Added `theme.cal = { grid_color =
  palette.cal_grid, weekend_color = palette.cal_weekend }` in
  `clean-theme.lua`; `frame.lua`'s `draw_cal_content` now reads
  `theme.cal.grid_color`/`theme.cal.weekend_color` (literal fallback kept
  for safety, unchanged) instead of `panel.calendar.grid_color/
  weekend_color`. The two RGBA literals were deleted from
  `panels.cal.calendar` in `panels.lua`, replaced with a comment pointing
  at `theme.cal` — same treatment as the sep_count duplicate.
- **`theme.sep.count` — confirmed still correctly wired, no action
  needed.** Grepped `frame.lua`: both `draw_sys_content` and
  `draw_net_content` read `theme.sep.count` (with a literal `50`
  fallback only), and `panels.sys.sep_count` no longer exists anywhere in
  `panels.lua` — exactly the state the monitor-chassis-polish session
  above left it in. Note the live value is currently `46`, not the `50`
  that session's own note describes reverting to — a later, undocumented
  hand-tune (plausibly the "SYS's dash count reduced ~5 fewer" item that
  same note flagged as *not yet implemented, holding for a follow-up*).
  Out of this session's scope to chase further; flagged here so a future
  session doesn't mistake it for drift.
- **`panels.cal.calendar.week_start = "SU"` — confirmed dead, deleted.**
  Grepped the whole tree: zero readers anywhere. Week start is hardcoded
  via `lua/suite/tme.lua`'s `weekday_su0` (`os.date(...).wday - 1`, always
  Sunday-first) inside `build_weeks`, and `frame.lua`'s weekday header
  uses a hardcoded `{"Su","Mo","Tu","We","Th","Fr","Sa"}` label array.
  **Decision: delete, not wire up** — unlike `theme.sep.count`, which had
  a live counterpart to consolidate into, `week_start` has no live
  counterpart to fold into; making it real would mean rewriting
  `weekday_su0`'s column math *and* rotating the frame.lua label array
  together, a small feature addition with no stated user need (nothing in
  this suite's history asks for a Monday-start week), not a wiring fix.
  Deleted the dead key from `panels.lua`.
- **Verified the palette wiring actually takes effect, not just that the
  values moved files.** Baseline screenshot of the running
  `clean-calendar` window (window `0x06800002`, `372×283` — legacy
  `362×273` frame + Cairo's `+10` window-placement convention) matched
  the accepted look: borderless grid (`border_lw = 0`), dim gray Su/Sa
  weekend numbers, today (Aug 29) in accent gold. Noted mid-verification
  that `grid_color` never actually renders today — `border_w > 0` gates
  the stroke and `border_lw` is legacy's borderless `0` — so proving its
  wiring needed a temporary `border_lw = 1` alongside the palette swap,
  not just the color change alone.
  - Temporarily set (both reverted after): `default` palette's
    `cal_grid` → vivid red `{1,0,0,1}`, `cal_weekend` → vivid cyan
    `{0,1,1,1}`, and `panels.cal.calendar.border_lw` → `1`.
  - Killed the running calendar process by bare PID (`kill 3062940` —
    not `pkill -f` against the conf path, per this runbook's own standing
    warning, hit firsthand by two earlier sessions), relaunched directly
    (`conky -c widgets/clean-calendar.conky.conf`) with the same env the
    core launcher uses. Stderr showed only normal window-creation lines,
    no Lua errors.
  - Screenshot confirmed the swap rendered: red cell-border grid lines on
    every cell, cyan Su/Sa day numbers, today (29) still gold (`colors
    .accent`, untouched by this test) — direct proof both new roles reach
    the draw call, not just the palette file.
  - Reverted all three temporary values, killed the test process by PID,
    then did a full clean relaunch via `scripts/start-conky.sh` (not a
    second manual `conky -c`) so the launcher's own PID-file tracking
    resynced — the manual test relaunch had left
    `clean-e-clean-calendar-conky.pid` stale (still pointing at the
    original, now-dead PID). Confirmed after: exactly six conky
    processes, one per chassis/standalone, calendar's PID file updated to
    the new live PID. Final screenshot of the same window ID/geometry is
    pixel-identical to the pre-test baseline — borderless grid, dim
    weekend gray, gold today-highlight — confirming normal appearance is
    fully restored and matching the legacy `calendar.png` reference's
    composition (borderless cells, dimmed weekend column, accent
    today-highlight; different month, same structure).
  - `luac -p` clean on all four touched files
    (`panels.lua`/`clean-theme.lua`/`clean-palettes.lua`/`frame.lua`)
    throughout, including immediately before the final relaunch.
- This closes F4 in full and resolves the compliance scan's §3
  rendering-compliance finding — §3 has no remaining open items.

**F7 (compliance-scan follow-up) — bootstrap and docs resynced,
2026-08-29.** Re-verified every item on the scan's F7 list fresh rather than
reapplying it blindly, since F1–F5 had already closed some of it in passing
(F2's own follow-up note above pre-emptively closed part of this item too).
Findings and fixes, in the order F7 posed them:

- **`bootstrap-runtime.sh` `[profiles]` block.** Confirmed `system`/`net`/
  `network` were already present (F2's follow-up, 2026-08-29) — no action
  needed there. Confirmed `media = "local"` was still missing from the
  generator (present on the *live* runtime file since the 2026-08-28
  music/lyrics conversion, never backported) and `air = "home"` was still
  emitted despite `suite.toml`'s `[data] domains` list deliberately excluding
  `air` (commented there as "reserved for a future ENV sub-panel"). Added
  `media`, dropped `air`, in the heredoc. Also dropped the stale `air = "home"`
  line from the *live* `~/.config/gtex62-core/suites/clean-e.toml`, so the
  generator and the live file agree — the live file wasn't itself part of the
  scan's literal ask, but the verify step below requires a zero-line diff
  against it, which wasn't possible while it still carried the same stale
  entry the generator was being fixed to drop.
  - Verified with the same scratch-dir method the F2 follow-up used:
    `GTEX62_CONFIG_DIR`/`GTEX62_CACHE_DIR` pointed at a scratch dir under the
    session scratchpad, ran `bootstrap-runtime.sh`'s "file doesn't exist"
    branch, `diff -u` against the live file. First pass (generator fixed,
    live file not yet touched) showed exactly one line of difference — the
    live file's leftover `air = "home"`. After dropping `air` from the live
    file, re-ran the same diff: **zero differences** — `media`/`system`/`net`/
    `network` all present in both, `air` absent from both, every other line
    byte-identical. Scratch directory deleted after.
- **Dead `pf`/`net` cache dirs.** Re-confirmed via grep: `pf.lua` reads
  `shared/pfsense/<profile>/ifaces.json` under `$CACHE_ROOT` directly, never
  `suites/clean-e/pf/`; `lua/suite/net.lua` doesn't exist (deleted
  2026-07-19, per the Directory cleanup note above) so nothing reads
  `suites/clean-e/net/` either. Both confirmed dead. Stopped the generator
  from `mkdir -p`ing either (kept `msc/`, which is live — `msc.lua`'s cover-art
  cache). The scan's noted orphan `orb/` was also still present on this
  machine and empty; grepped for any live reader of `suites/clean-e/orb/` —
  none (the astro conversion moved `orb.lua` onto the core `astro` domain
  2026-07-19; only a stale comment in `orb.lua` still names the old path,
  not a real read) — and it was never created by the current generator
  either (not in its `mkdir -p` list even before this session's edit), so
  it's a leftover from an earlier version of the script or a manual
  bootstrap, not a live regression. Removed all three empty dirs
  (`pf`/`net`/`orb`) from `~/.cache/gtex62-core/suites/clean-e/`; `msc/`
  (with its populated `covers/` subdir) untouched.
- **README.md.** All five inaccuracies confirmed still present (none had
  been touched by F1–F5, which were code-focused) — fixed to match current
  reality, not the scan's original wording where reality has since moved:
  removed the false "`start-conky.sh` prompts for a palette" claim (F6 is
  deferred, no prompt exists — see the deferral note below); moved NOTES out
  of the Media chassis table into its own Standalone section (standalone
  since 2026-07-20); added standalone sections for both Calendar and Notes
  (previously omitted entirely); the ambient chassis's TME row no longer
  claims "month calendar" now that Calendar has its own listing; pfSense's
  VLAN list corrected from 5 to 6 (added CAM, confirmed live in
  `panels.pfsense.iface_order` — `WAN`/`HOME`/`IOT`/`GUEST`/`INFRA`/`CAM`);
  the WXR row no longer states SIGMET/AIRMET as current functionality —
  confirmed `panels.wxr.aviation.advisories.enabled = false` is still the
  live value (comment: "off in legacy theme as well"), so the row now notes
  it as drawn-but-disabled rather than removing all mention or overstating
  it as live. Two further inaccuracies found in the same pass, outside the
  scan's named five but the same "match current reality" defect class: "AQI
  panel added (air domain, not in original suite)" in the What Changed
  section — false, grepped `theme/`/`lua/`/`widgets/` for any AQI panel and
  found none, consistent with `air` being deliberately unwired (see the
  bootstrap-generator finding above); and "9 Conky processes consolidated
  into 3 chassis + 1 standalone" — undercounts the standalones now that
  calendar/notes/pfsense are all standalone (3, not 1). Both corrected.
- **`panels.lua` header comments.** Confirmed both scan-flagged headers
  (`598 × 1880`, `660 × 520`) are still correct as F1 left them (`568×1980`
  read from `layout.monitor.frame`; `840×500` read from `layout.pfsense.frame`
  — actually a comment describing a value the code now derives, per F1's own
  note above). Grepped every chassis/standalone header comment in the file
  (`MONITOR`/`AMBIENT`/`CALENDAR`/`MEDIA`/`PFSENSE`, plus the NOTES section
  header, which carries no fixed dimension) against its live
  `layout.*.frame` value — no further drift found, despite pfsense/media/
  monitor all having been retuned multiple times tonight (F1–F4). No changes
  needed.
- **Recovery runbook.** Both scan-flagged stale values confirmed still
  present and fixed: the msc status-table row still said `1700×1340`
  (superseded the same day by commit `2f7573c`, which retuned
  `layout.media.frame.width` to `2460` for lyrics' full clip width — confirmed
  against `theme/clean-layout.lua`'s live value and the commit's diff) — row
  updated to `2460×1340`, with a note on the retune; the same stale number
  also appeared in the music+lyrics completion note's narrative measurement
  (not itself named by the scan, but the identical fact, so corrected for
  consistency rather than left contradicting the fixed row). The Fix Part 2
  note's `598×1880` claim for `layout.monitor.frame` was also still present
  (F1's panels.lua-header fix and the monitor-chassis-polish session's own
  note both already superseded this number without circling back to correct
  the original Fix Part 2 text it was transcribed from) — corrected to
  `568×1980`, confirmed against the live `layout.monitor.frame` value. Gave
  Calendar its own status-table row (previously folded into `time (tme)`,
  the scan's §1 finding) — split the old combined row: `tme` now covers only
  the clock stack, `calendar` is a new row carrying the calendar-specific
  cells (data source, geometry `362×273` gap `67,41`, verification), matching
  the standalone-row treatment `notes` and `pfsense` already had.

**F1–F7 status: all addressed.** F1 (frame-geometry derivation), F2 (monitor
profile routing), F3 (NET position audit), F4 (calendar palette colors), and
F5 (dead-function sweep) all closed in earlier sessions tonight per their own
notes above; F7 (this session) closes the bootstrap/docs resync. **F6
(palette + wallpaper selection at launch) remains open by deliberate
decision, not oversight or an unaddressed gap**: `clean-suite-e` never had a
launch-time palette or wallpaper prompt at any point in this conversion, in
the legacy suite it was converted from, or before that — the scan's own §6
finding was about a capability the *conversion guide* expects every suite to
have eventually (`core-launcher-design.md`'s Open Items), not a regression
introduced by this port. Porting OSA's `choose_palette`/`choose_wallpaper`
(or landing the core-launcher consolidation those Open Items depend on) is a
real, scoped feature addition — tracked as F6 for whenever that's prioritized,
not folded into this docs/bootstrap resync.

---

## Notes for Next Widgets

- **Open items (updated 2026-08-28):** (1) the monitor chassis (sys/net) is Done in
  the table above but the user has further visual tweaks planned for it — treat those
  as polish on a converted widget, not a reopened conversion; (2) ~~music and lyrics
  are the last unconverted widgets~~ **all widgets are now converted** — the next step
  is the "When All Widgets Are Done" section below (chassis assignment is already the
  final shape: monitor/ambient/media chassis + calendar/notes/pfsense standalones, so
  what remains there is the guide's full Theme / Rendering / Launch / Cleanup
  compliance scan).

- Weather, astro, and time are all core-domain widgets like sys-info/net — expect the same
  two failure modes (positioning, cache wiring) if problems recur. Diagnosis pattern from
  Steps 1–2 above applies directly.
- ~~Music and lyrics are suite-local (no core domain)~~ **Resolved 2026-08-28**: the
  split landed as lyrics = core media domain, playback/volume/cover = suite-local —
  see the music+lyrics completion note above and `docs/lyrics-library-design.md`.
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
