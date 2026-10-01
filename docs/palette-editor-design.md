# Palette Editor — Design

A standalone tool for building new `bg`/`fg`/`ink` palette entries for OSA, SitRep, and
Doctor with live visual feedback, instead of hand-editing `palette.lua` and relaunching
to check the result. Modeled loosely on `orrery_colors.py` (a third-party Conky
colour-editing tool with a live-rendered preview pane), adapted to this project's
palette format and to the core launcher's palette-grouping mechanism described in
`core-launcher-design.md`.

**Status (2026-09-30): design phase, no code written.** Every decision below came out
of a design conversation working forward from `orrery_colors.py` as a reference point,
narrowing it down to what this project's palette model actually needs. Nothing has been
built or spiked yet — see Open Questions for what has to be answered before it can be.

Reference implementations: `orrery_colors.py` (third-party — colour picker, live
preview architecture, in-place file editing pattern); `osa-palettes.lua` (the palette
file format and existing catalog, copied wholesale into `gtex62-sitrep` and
`gtex62-doctor`); `core-launcher-design.md` (the hash-based palette grouping this tool
must not break).

---

## Motivation

Palettes are currently authored by hand in `palette.lua` and checked by launching a
suite and looking at it. There's no way to compare a candidate palette against the real
widget before committing it, and no check that a chosen `bg`/`fg`/`ink` triple is
actually legible — the catalog already ships a few low-contrast entries
(`court_gray` at 1.94:1, `warning_red` at 2.90:1) that read as deliberate choices, but
there's no way to tell a deliberate low-contrast pick from an accidental one at write
time.

## Relationship to the Core Launcher

`core-launcher-design.md` groups suites for a shared palette prompt by **file-hash
identity** of `palette.lua`, re-checked on every launch, not by an assumed convention.
OSA, SitRep, and Doctor currently form one group (Group A, hash `f1743dbc…` as of
2026-09-27) because their `palette.lua` files are byte-identical. This tool's entire
write discipline exists to keep that true after every save — see Byte-Identical Writes
below. The editor does not need its own drift-detection logic: the launcher already
re-hashes on every launch and will simply split the group (three prompts instead of
one) if a write ever left the three files out of sync. That behavior doubles as the
tool's own correctness check — see Live Confirmation.

## Scope: Group A Only

This design covers OSA, SitRep, and Doctor — Group A, the byte-identical `bg`/`fg`/`ink`
catalog — and nothing else. LCARS and tri-hud (Group D) use a different data model
entirely: a 60-entry tone-ladder (`tone0`–`tone4` style steps) with mode-based
inversion, and the two suites don't even apply it identically — LCARS inverts
tone2↔tone3 as well as tone0↔tone4 in light mode, tri-hud only inverts tone0↔tone4.
That's not the same shape with different values; it's a different data model *and*
different per-suite rendering rules for the same data. A candidate written identically
to both would not necessarily produce the same result on both, which breaks the
byte-identical-write assumption this whole tool leans on. A tone-ladder editor, if ever
built, is a distinct tool, not a mode this one also handles.

This also matches where the launcher itself currently stands: the mode step and
`tone_modes` detection are both explicitly deferred in `core-launcher-design.md`'s Open
Items, and LCARS/tri-hud haven't been converted to `-e` suites — they're still frozen,
legacy pass-through. Building tone-ladder support into this tool would mean designing
against ground the launcher hasn't caught up to yet.

**Open:** whether clean-suite-e's catalog (its own 2-entry launcher group, separate
from Group A) shares Group A's flat `bg`/`fg`/`ink` shape. If so, this tool likely
extends to it cheaply — another write target, another preview option. If its shape
differs the way LCARS/tri-hud's does, the same exclusion applies. Unconfirmed — check
`clean-suite-e`'s palette file before assuming either way.

## Location

Untracked, personal tooling — not a repo, not published, not cloned by anyone's
install. Lives at `/home/gtex62/.config/conky/gtex62-private/scripts/`, alongside
`gthb_format.py` (the existing private GITHUB-stats formatter in the same directory),
following the precedent `doctor-qrh.md` already documents for that domain — GITHUB's
`PRIVATE` state is hardcoded specifically because its dependency "lives outside both
repos in a private directory." Same category of tool, same directory.

One difference from `gthb_format.py` worth noting: GITHUB's script is invoked *by*
core (`fetch_doctor.sh` and `status.json` reference it), so its privacy is enforced
structurally — no other install can reach it regardless. The palette editor has no
equivalent protection, since it needs to read and write into `gtex62-osa`,
`gtex62-sitrep`, and `gtex62-doctor`'s real clone paths — all public repos. That's
accepted: the tool itself stays private and untracked, same as `conkystart`, but the
files it writes to are exactly as public as they already are. Nothing about the tool's
location changes that.

## Palette File Format

Each suite's `palette.lua` (`osa-palettes.lua` and its copies) is a flat table:

```lua
return {
  default = "amber",
  palettes = {
    amber = { bg = {0.0, 0.0, 0.0}, fg = {1.0, 1.0, 0.0}, ink = {0.0, 0.0, 0.0} },
    -- ...
  },
}
```

63 entries as of 2026-09-30, organized under comment-header groups: Core, Signal,
Material, Cartographic, Dusk, LCD, Court. Every entry is exactly three RGB triples
(0.0–1.0 floats) — `bg`, `fg`, `ink`. This is a materially simpler shape than
`orrery_colors.py`'s 4-colour-plus-5-slider model, and most of that tool's control
surface (opacity/depth sliders, viewing angle, colour count) does not apply here — see
Editor Scope.

**`bg`/`fg`/`ink` are not symmetric roles.** `bg`↔`ink` contrast is intentionally low
across most of the catalog (median 1.37:1; several entries at exactly 1.00:1 —
`amber`, `cyan`, `white`, `phosphor`, `aurora_green`, `nebula_magenta`, `warning_red`,
`hearth`). `ink` reads as a shadow/recess colour meant to sit close to `bg`, not as
legible text. `bg`↔`fg` is the real readability axis (catalog range: 1.94:1 to
19.56:1, median ~5.58:1). The contrast check (below) only ever warns on `bg`↔`fg`.

## Contrast Rule

Calculated (WCAG relative-luminance formula) against the full existing catalog rather
than assumed from the textbook AA threshold (4.5:1), because the catalog already ships
several entries below that number as deliberate choices. Using 4.5:1 as the warning
threshold would flag roughly a third of the existing catalog every time it's previewed,
which would train the warning to be ignored. The floor that's actually been shipped and
accepted is `court_gray` at 1.94:1.

- **Checked pair:** `bg`↔`fg` only. `bg`↔`ink` is excluded — see Palette File Format.
- **Warning threshold:** ~2:1, just under the catalog's own historical floor. Catches a
  genuinely broken pick without flagging existing shipped palettes.
- **Dismissible, not blocking.** A low-contrast pick can be a deliberate aesthetic
  choice (as `warning_red` and `court_gray` already are); the warning informs the
  decision, it doesn't override it.

## Editor Scope

What carries over from `orrery_colors.py` and what doesn't, given the simpler palette
shape above:

| Orrery feature | This tool |
| --- | --- |
| 4 colour swatches (`HTML_base`/`accent`/`second`/`warm`) | 3 swatches (`bg`/`fg`/`ink`) |
| Saturation/value square + hue strip | Saturation/hue wheel (Affinity/Photoshop-style — user's existing muscle memory) |
| Opacity/depth sliders (5) | None — no equivalent concept in this palette format |
| Viewing angle (3D-orbit-specific) | None |
| Backdrop tester (Dark/Slate/Grey/Light) | None — see Preview; this project's `bg` is part of the palette itself, not a transparent-window concern, so the relevant check is the contrast rule, not a wallpaper test |
| Preset grid (flat, 8 buttons) | Grouped/scrollable list, matching the file's own Core/Signal/Material/Cartographic/Dusk/LCD/Court comment-header groups |
| "New"/"Saved" swatch comparison | Kept, same purpose |
| Hex entry field | Kept; palette file stores 0.0–1.0 floats, so the editor converts on read/write |
| Live-dragging preview | Not kept as-is — see Preview |
| "Apply and restart conky" | Not in the tool — see Live Confirmation |

## Preview

**Fixed to SitRep only**, not a suite selector and not an all-three view.

- SitRep was established as the hardest legibility case among the three (dense
  single-panel layout, confirmed against it during the OSA→SitRep palette-catalog
  port). If a palette reads well there, it reads well on OSA and Doctor.
- An all-three view was considered and dropped: OSA's frame is 1736×1368, versus
  SitRep+Doctor combined side by side at roughly 1832×960 — different enough in shape
  and size that no single fixed preview frame fits both without either wasted space or
  scaling distortion.
- A two-view split (OSA solo / SitRep+Doctor paired, matching how the suites are
  actually run day to day) was also considered and dropped in favor of staying with
  the single SitRep view, for simplicity.

**Rendering approach: real suite launch, not a live-dragged synthetic preview and not a
generic schematic mockup.** Two alternatives were considered and both rejected:

1. A standalone Cairo renderer (`orrery_preview.lua`'s approach, drawing one frame
   outside Conky's live loop) — rejected because it would be a second rendering
   implementation that could drift from the real one, and because none of the suites'
   Cairo drawing is currently structured to be called outside Conky's own
   `conky_draw_pre()` cycle.
2. A generic schematic (outer edge / inner panel / table with highlights, standing in
   for any of the three suites) — rejected because it can't answer the actual
   question this tool exists for: whether a specific suite's real layout, at its real
   font sizes and information density, stays legible. A simplified mockup fails
   silently in the specific case that matters (SitRep's dash-leader alignment, real
   information density) and risks reading as falsely legible if drawn at any scale
   larger than the suite's true size.

Instead: launch the real SitRep suite against the candidate palette and screenshot it —
the same investigative technique already used elsewhere for this project. No second
implementation, no drift risk by construction, at the cost of a launch-and-wait cycle
rather than live dragging. Given palette decisions here are three discrete colour
picks, not continuous tuning, "adjust, click preview, wait, look" is an acceptable
rhythm.

**Mechanics:**

- **Palette injection:** write the candidate into a scratch copy of SitRep's
  `palette.lua` under a throwaway name, then launch through the existing
  `GTEX62_CONKY_PALETTE_OVERRIDE` mechanism (already honored by all three suites'
  `start-conky.sh`) rather than building a new config-injection path.
- **Sizing:** SitRep's `layout.lua` already supports `scale_mode = "auto"`, which
  computes `min(w/bw, h/bh)` against `CONKY_SCREEN_W`/`CONKY_SCREEN_H` to fit the
  suite's 752×960 base frame into a given space. The preview launch uses a scratch
  copy of `layout.lua` with `scale_mode` forced to `"auto"` and those two env vars set
  to the preview pane's real pixel dimensions — the committed `layout.lua`
  (`scale_mode = "manual"`, `scale = 1.25`) is never touched. This retires the earlier
  idea of a separately-scaled or enlarged preview: the suite fits itself.
- **Must not collide with a real running instance.** If SitRep is already open on the
  desktop, the preview launch needs either an off-screen/virtual display or a distinct
  instance identity that the suite-exclusivity kill logic won't treat as a collision
  with the live one.
- **Real data, not synthetic.** The preview shows whatever's actually live (real CPU%,
  real provider states, real VLAN traffic) — a feature for legibility-under-real-
  conditions, but a possible source of noise if something unrelated is mid-fault at
  preview time.

## Byte-Identical Writes

Apply always writes the candidate palette to all three suites' `palette.lua` files —
OSA, SitRep, and Doctor — as a single named entry, appended under a new comment-header
group (following the file's existing Core/Signal/Material/... convention) rather than
replacing anything. There is no single-suite-only Apply path; splitting Apply from a
separate "copy to all three" action was considered and dropped, since the palette is
already treated as one shared thing across the three suites, not three independently
maintained ones, and a two-step commit only creates a state where the files can be
left out of sync if the second step is forgotten.

The write must be **byte-identical** across all three files — same value formatting
(fixed decimal places, normalized hex/float casing), not merely equivalent values
expressed differently — because Group A membership is determined by whole-file hash,
not by parsing and comparing values. `orrery_colors.py`'s `apply_settings` pattern
(fixed `"%.2f"` formatting, only rewriting values that actually changed, leaving
everything else byte-for-byte alone) is the model to follow here, generalized to a
three-file write instead of one.

## Revert

Scoped to whatever the last Apply actually touched (always all three files, given
Byte-Identical Writes above) — a `.bak` snapshot per file taken immediately before
each write, tripled the way `orrery_colors.py` snapshots one file before overwriting
it.

## Live Confirmation

The tool does not restart Conky and has no "Apply and restart" action — that
responsibility stays with `gtex62-conkystart` (the core launcher), used normally, in
the terminal, separately from the editor. This is deliberate, not a missing feature:

- The launcher already handles multi-suite coordination (kill/relaunch,
  suite-exclusivity, hash-based grouping) correctly and is tested; duplicating any of
  it inside the editor would be a second implementation of logic that already exists.
- Running the launcher after Apply doubles as a correctness check on the write itself,
  not just a visual one: selecting OSA + SitRep + Doctor and getting **one** shared
  palette prompt confirms the three files actually hashed identically. Getting three
  separate prompts instead means the byte-identical write did not hold, which is
  useful diagnostic information this design would not otherwise surface.

---

## Resolved Decisions

- Preview limited to SitRep only — established hardest legibility case, avoids the
  aspect-ratio/sizing mismatch of an all-three or two-view layout.
- Contrast check covers `bg`↔`fg` only, threshold ~2:1 (catalog-calibrated, not
  WCAG 4.5:1); dismissible, never blocking.
- Preview renders the real suite via launch-and-screenshot, not a standalone Cairo
  renderer and not a generic schematic mockup.
- Preview sizing uses each suite's existing `scale_mode = "auto"` mechanism against a
  scratch `layout.lua`, not a new scaling scheme.
- Palette candidates are injected via the existing `GTEX62_CONKY_PALETTE_OVERRIDE`
  mechanism against a scratch `palette.lua`, not a new config path.
- Apply always writes to OSA, SitRep, and Doctor together, byte-identical, as one new
  named catalog entry — no single-suite-only save path.
- Restart/launch is explicitly out of scope for the tool; `gtex62-conkystart` in the
  terminal is the confirmation step, and doubles as a correctness check on the write.
- Colour picker uses a saturation/hue wheel (Affinity/Photoshop-style), not
  `orrery_colors.py`'s square-plus-strip.
- Scope is Group A only (OSA/SitRep/Doctor) — LCARS/tri-hud's tone-ladder model is
  excluded as a different data model, not a variant of this one.
- Untracked, personal tool at `gtex62-private/scripts/`, alongside `gthb_format.py` —
  not a repo, not published. Writes into OSA/SitRep/Doctor's public repos are accepted;
  only the tool itself stays private.

## Open Questions

- **Renderer harness feasibility** — whether launching SitRep off-screen/virtualized
  for a screenshot-and-close cycle is straightforward, and how to avoid colliding with
  an already-running live instance. Flagged throughout this design as the first thing
  to spike (with Claude Code) before building anything else.
- **New-entry naming convention** — a single overwritable `USER` entry per catalog, or
  a prompted name per save (`USER_ICE`, `USER_EMBER`, ...) allowing several custom
  palettes to coexist. Not settled; cheaper to decide before the append logic exists
  than to retrofit after `USER` is hardcoded anywhere that reads the catalog.
- **Runtime dependency** — confirming `tkinter` (or an equivalent) is an acceptable
  dependency here the way it was for the third-party reference tool. Location is
  resolved (see Location); this is only about what the script requires to run.
- **Preview pane target dimensions** — the exact pixel size to hand the scratch
  `layout.lua` as `CONKY_SCREEN_W`/`CONKY_SCREEN_H`. Should land on values that keep
  the resulting auto-scale close to 1.25 (the suites' own grid-friendly design scale —
  see the 8px-grid device-pixel reasoning in `layout.lua`'s comments) rather than an
  arbitrary fraction that could reintroduce the sub-pixel blur the grid snapping was
  built to avoid.
