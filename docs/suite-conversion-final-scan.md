# Suite Conversion — Final Compliance Scan

Run once per suite, after its own recovery runbook shows every widget/panel marked Done.
Answers one question: **does this suite actually meet the core-native conversion goals,
or does it just look finished?** Not a re-verification of things already verified — a
systematic check for gaps that individual widget sessions wouldn't have caught on their
own, because they were each scoped to one widget at a time.

Suite-agnostic by design. Each suite has a different shape:

- `gtex62-clean-suite-e` — many widgets across several chassis (monitor, ambient, media,
  standalone calendar, standalone pfsense)
- `gtex62-tech-hud-e` — roughly three widgets
- `gtex62-lcars-e` — one widget, most features as panels within it
- `gtex62-tri-hud-e` — one widget, all features embedded

This scan doesn't assume any particular count or grouping. It reads whatever the target
suite's own recovery runbook defines as its widget/panel list and checks each one against
the same criteria, regardless of how many there are or how they're chassis-grouped.

---

## Cost Discipline (read this before starting)

This is a breadth task — checking many files against known criteria — not a depth task
requiring new problem-solving. It does not need Fable; Opus is the right tool for this.

**Do not re-verify visually.** Every widget already has documented root-cause notes in
its runbook, and several have exact measured pixel/color values recorded as text. Treat
those as ground truth. Do not re-screenshot a widget that's already marked Done with
supporting notes — that duplicates cost for zero new information.

**Only visually check something if the runbook shows it as genuinely undocumented or
unresolved** — e.g. a "pending" flag that was never followed up, a deviation noted but
never confirmed fixed, or a widget marked Done without any verification detail recorded
(a red flag on its own, see Section 1 below).

**Read once, check many things per read.** Don't re-open the same file multiple times for
different checklist items — read each suite file once and check it against every
applicable section below in that pass.

---

## Section 1 — Runbook Integrity

Before checking the suite's code, check whether its own runbook is trustworthy:

- Does every widget/panel the suite actually has appear in the status table? (Cross-check
  against the suite's actual directory contents — `widgets/*.conky.conf` and
  `lua/suite/*.lua` — not just the table as given, in case something was built but never
  logged.)
- Any row marked Done with no supporting root-cause/verification note? That's a widget
  that *might* be fine but has no evidence — flag it for the one type of re-check this
  scan does allow (see Cost Discipline above).
- Any row still showing "pending," "reopened," "in progress," or similar, with no later
  entry confirming resolution? These are real open items, not scan findings — surface
  them plainly rather than re-diagnosing from scratch.

## Section 2 — Core-Sourcing Compliance

For each widget/panel, per the guide's Core Rule (core defines data provision, suite
defines rendering):

- Does every displayed value trace back to a core domain cache
  (`shared/[domain]/[profile]/*.json`), not a Conky built-in, `execpi`, or direct
  shell/OS call? Check this even for values that would be simple to provide natively —
  simplicity is not an exemption (this is exactly the gap found on clean-suite-e's
  sys-info).
- Any suite-local data path that duplicates something a core domain now already provides
  (e.g. a leftover local fetch script that a core provider has since superseded)?

## Section 3 — Rendering Compliance

- Is `conky.text` blank in every widget's `.conky.conf`? A non-empty `conky.text` block
  is a compliance failure regardless of whether it renders correctly — it means colors
  are Conky-native and can't respond to a palette swap.
- Do all colors trace back to the suite's own palette file (`[suite]-palettes.lua` or
  equivalent), not hardcoded hex/RGBA values anywhere in `conky.config`, theme files, or
  widget Lua?
- Does the suite have its own palette file — not sharing one with another suite, even if
  another suite's values happen to be similar? (Per the Core Rule: visual identity is
  Suite-owned, even when starting values converge.)

## Section 4 — Geometry Compliance

- Does every widget/panel's position match its legacy reference, per the runbook's
  recorded measurements? Don't re-measure — read the recorded values.
- **Chassis-combination check:** for any widget/panel that combines multiple
  previously-separate legacy elements (or, for single-widget suites like LCARS/tri-hud,
  any panel that combines multiple legacy panels), confirm each sub-element's position
  was individually audited against the legacy reference — not just the container's
  overall position. This is the pitfall clean-suite-e's calendar hit; check for it
  proactively in any suite with chassis/panel grouping.
- Any known placeholder or leftover value from another suite's pattern (e.g. an
  OSA-inherited `xinerama_head`/`gap` default) still present anywhere, even in an
  unconverted/not-yet-relevant section?

## Section 5 — Dead Code / Cleanup

- Any leftover files from the legacy port that are no longer referenced by anything live
  (grep for `require`/`dofile` references before concluding something is dead — confirm,
  don't assume)?
- Directory structure consistent with the established convention: widget view models in
  `lua/suite/`, entrypoints in `lua/widgets/`, palette/layout/theme/panels in `theme/`,
  conf files in `widgets/`? Flag anything sitting outside this pattern.
- Does the suite's `wallpapers/` directory (if present) still exist redundantly, or has
  it been retired in favor of `gtex62-shared-assets/wallpapers` per the core launcher
  design?

## Section 6 — Launch/Palette Integration

- Is the suite registered correctly with the core launcher (per `core-launcher-design.md`
  if that consolidation has landed, or the suite's own `start-conky.sh`/dispatcher entry
  if not yet)?
- If the suite has a `tone_modes` table (mode toggle, LCARS/tri-hud-style): does the
  launch flow correctly offer mode before palette? If it doesn't have one (OSA/clean-suite/
  tech-hud-style): confirm no mode prompt is incorrectly present.
- Does wallpaper selection resolve against shared-assets, with a `None` option?

## Section 7 — Summary

End with a compact pass/fail table, one row per widget/panel (as many rows as the suite
actually has — don't pad to match another suite's count):

| Widget/Panel | Core-Sourced | Rendering Clean | Geometry Confirmed | Dead Code Clear | Verdict |
| ------------ | ------------ | ---------------- | -------------------- | ----------------- | ------- |

Plus a short list of anything that failed a check, with enough detail to turn directly
into a follow-up session prompt — this scan's job is to find gaps, not fix them.
