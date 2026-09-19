# Core Launcher — Design

Standardizing suite launch (suite selection → mode → palette → wallpaper → launch)
into one core-owned flow, replacing the current per-suite scattered scripts.

---

## Current State (What Exists Today)

| Script | Suite(s) | Does |
| ------ | -------- | ---- |
| `conkystart` | dispatcher | **Untracked personal script at `~/.local/bin/conkystart`** (aliased in `~/.bash_aliases`) — not in either repo. Lists suite dirs, dispatches to suite-specific script. Already special-cases a hardcoded "osa + sitrep" combo menu entry (`COMBO_LABEL`), launching both in sequence and propagating OSA's palette/wallpaper choice to SitRep via env-var override (see below) |
| `conkystart_legacy` | dispatcher (dead) | Also untracked at `~/.local/bin/`, predates the combo-label logic. Confirmed zero references anywhere — not aliased, not invoked by any script or the current `conkystart`. Dead weight, not a fallback path in use |
| `start-conky.sh` (OSA) | gtex62-osa | Palette selection (flat list, single axis) + wallpaper (shared-assets, with None) + hands off to core launcher |
| `start-conky.sh` (LCARS, legacy) | gtex62-lcars | Wallpaper only (per-suite dir) — not actually invoked by conkystart; superseded by launch-lcars.sh |
| `launch-lcars.sh` | gtex62-lcars | Mode (dark/alt) + palette (flat list from theme-core.lua) → execs start-conky.sh |
| `launch-tri-hud.sh` | gtex62-tri-hud | Mode (dark/light) + palette (flat list from theme-core.lua) → execs start-conky.sh |

Three different behaviors for what should be one conceptual flow. `conkystart`
special-cases LCARS and tri-hud by name to route around the mode step OSA doesn't have.
Wallpaper handling is inconsistent: OSA pulls from shared-assets; LCARS's (unused)
script pulls from a per-suite directory that duplicates what's likely the same images
across every suite that still has one.

**Existing combo precedent.** `conkystart`'s hardcoded OSA+SitRep combo entry already
does exactly the kind of choice-propagation the generalized multi-select design (below)
needs, just fixed to one pair: it launches OSA first, reads back the palette/wallpaper
OSA's own `start-conky.sh` wrote to its normal "remember last choice" cache files
(`$CACHE_ROOT/runtime/osa-palette`, `osa-wallpaper`), and exports them as
`GTEX62_CONKY_PALETTE_OVERRIDE` / `GTEX62_CONKY_WALLPAPER_OVERRIDE` before launching
SitRep. Both OSA's and SitRep's `start-conky.sh` already honor these env vars — if the
override value matches a name in that suite's own catalog, it's used silently; if not,
each suite prints a warning and falls back to prompting. That graceful fallback is real,
working code today, not a proposal — the generalized per-group propagation in Palette
(below) builds on this exact mechanism rather than inventing a new one.

---

## Standardized Flow

One core-owned launcher, one sequence, covering however many suites are selected per
invocation (see Suite Selection below — this is no longer assumed to be exactly one):

### 0. Bootstrap Precondition (before any suite)

Before Mode/Palette/Wallpaper/Launch, the launcher checks whether the
runtime root is populated. Runtime root resolution reuses the fallback
chain every provider script and the bootstrap script already use — no new
discovery mechanism:

```bash
${GTEX62_CONFIG_DIR:-${GTEX62_CONKY_CONFIG_DIR:-$HOME/.config/gtex62-core}}
```

"Populated" means `core.toml` (or `site.toml` — either is unconditionally
written by `gtex62-core-bootstrap-runtime` regardless of suite presence)
exists directly under that root. A single stat on that file, not a bare
directory-existence check — a stray empty directory (manual `mkdir`, a
failed/partial prior run) shouldn't pass the gate. This check does not
walk `profiles/` for per-provider completeness; that narrower gap is
already covered by the 60s TTL fallback (see Bootstrap Gap in the project
CLAUDE.md) and duplicating it here would slow every launch.

If the check fails — a fresh clone that's never had
`gtex62-core-bootstrap-runtime` run — the launcher fails immediately with a
plain terminal message pointing at the README/bootstrap script, and does
not attempt to load any suite's theme-core file, palette, or Conky/Lua
stack.

This is universal, not suite-specific: it protects every suite (OSA, SitRep,
Doctor, future suites) from attempting to start against a nonexistent config
directory. No suite needs its own defensive handling for a zero-bootstrap
launch — the launcher refuses to get that far.

### 1. Suite Selection (multi-select)

The dispatcher lists installed suite dirs, same directory-presence scan as today's
`is_suite_dir` — unchanged. Selection becomes **multi-select**: space/comma-separated
numbers, plain-terminal `read -rp`, no new dependency. This replaces `conkystart`'s
current hardcoded single `COMBO_LABEL` ("osa + sitrep") menu entry, which doesn't
scale — every additional suite multiplies the number of possible fixed-label combos
combinatorially, recreating the exact per-suite special-casing problem this document
exists to eliminate.

**Legacy-suite menu handling needs no code.** The directory scan already naturally
includes or excludes a suite based on what's installed under `~/.config/conky/`. There
is no "hide legacy suites" flag or toggle, and none is needed — a user (including the
maintainer) who wants a legacy suite gone from their own menu just moves or removes its
directory. Stated explicitly here so this isn't rebuilt as a feature later.

**Required test case:** a legacy suite with no palette catalog and no `tone_modes`
(Group E below — tech-hud today) selected solo, or alongside core-native suites in a
multi-select, must fall through the same conditional Mode/Palette logic gracefully —
same handling as any other Group E member, no special-casing.

### 2. Mode (conditional, per suite)

Prompted once per selected suite whose theme-core file defines `tone_modes`; skipped
per suite that doesn't. Detected, not hardcoded per suite — core checks for the
table's presence rather than special-casing suite names. Same conditional logic as
before, now applied across however many suites are in the current selection instead
of assumed to be exactly one.

- **Present today:** LCARS, tri-hud (both use the tone-ladder palette shape with
  `tone0`–`tone4` + `energy`, where mode is a role-inversion function over that ladder —
  not a separate palette, see `lyrics-library-design.md`-style precedent of documenting
  the actual mechanism rather than assuming from naming)
- **Absent:** OSA, SitRep, Doctor, clean-suite-e, tech-hud — flat/simple palette shapes
  with no tone ladder to invert. No mode prompt; go straight to palette.

### 3. Palette (once per distinct catalog group present)

Prompted once per distinct **catalog group** present in the selection, not once per
suite — the answer for a group propagates to every selected suite in that group.

**A group is defined by file-hash identity of the palette/theme-core file, never by
shape or name similarity.** Verified directly (2026-09-18 investigation): LCARS and
tri-hud both use the tone-ladder mechanism (`tone0`–`tone4` + `energy` + `tone_modes`)
but are genuinely separate catalogs — grouping by shared shape would have produced a
false-positive combo. Confirmed groups today:

| Group | Suites | Catalog |
| ----- | ------ | ------- |
| A | OSA, SitRep, Doctor | Byte-identical `osa-palettes.lua`/`palettes.lua`, 63 flat-role (`bg`/`fg`/`ink`) entries. Safe combo candidate — shared prompt. |
| B | clean-suite-e | Standalone, 2 entries, different role shape (`bg`/`fg`/`ink`/`dim`/`accent`/`ok`/`warn`/`err`/...). |
| C | LCARS | Standalone, 61 tone-ladder entries. |
| D | tri-hud | Standalone, 60 tone-ladder entries. Shares the tone-ladder *mechanism* with C, not the catalog — confirmed even the 5 same-named utility palettes (`aqi`, `planets`, `seasons`, `dark`) that are byte-identical between C and D have a real divergence in `light` mode's tone-inversion behavior (LCARS inverts tone2↔tone3 as well as tone0↔tone4; tri-hud only inverts tone0↔tone4). Not the same group. |
| E | tech-hud (legacy) / tech-hud-e (future) | No palette catalog exists at all today — no `palettes[name]` table, no launch-time prompt. Not a group until conversion happens and a catalog gets designed. |

**Group membership is not permanent.** Re-check by file hash on every launch (or at
least whenever any suite's palette file changes) — a group that was correct at design
time can drift the moment one suite's catalog is edited independently of the others'.

Each suite still keeps its own palette file — grouping is a launcher-side optimization
to avoid redundant prompts, not a change to file ownership. Core does not need to
understand the internal shape (3-role, 5-tone ladder, gray-ramp-plus-accents) to group
or list — it only needs the file's contents (for hashing) and a list of names plus a
default, same as OSA's existing `choose_palette` awk pattern-matching already does
generically.

**Propagation mechanism:** the same `GTEX62_CONKY_PALETTE_OVERRIDE` /
`GTEX62_CONKY_WALLPAPER_OVERRIDE` env-var handoff `conkystart` already uses for its
OSA→SitRep combo (see Current State) — generalized from one hardcoded pair to any
number of suites sharing a group. Each suite's existing fallback behavior (override
name not found in its own catalog → warn and prompt instead) carries over unchanged.

### 4. Wallpaper (once per launch — universal across groups, unverified)

Prompted once for the entire launch, applying to every selected suite regardless of
palette group — same `gtex62-shared-assets/wallpapers` source and `None` option
(index 0) as today's `choose_wallpaper`.

**Not independently confirmed.** This "once, universal" behavior is inferred from
today's two-suite, same-group OSA→SitRep combo code, which only ever exercises a
single wallpaper prompt across a single group. Whether it should also hold across a
selection spanning multiple palette groups (e.g. OSA + LCARS together) hasn't been
checked against working precedent the way the palette grouping was — flagged here as
an assumption carried into the design, not a verified fact.

**Cleanup implication:** legacy suites (LCARS, tri-hud, and presumably clean-suite,
tech-hud pre-conversion) that ship their own `wallpapers/` directory are carrying
redundant, duplicated image sets — the same disk and download cost paid once per suite
instead of once total. Once the core launcher always resolves against shared-assets,
these per-suite directories can be deleted as part of each suite's conversion cleanup
checklist — **for converted suites only.**

**Legacy suites are frozen, not migrated.** The original (non-core-native) versions of
each suite remain published on GitHub as-is and receive no further updates once the
core-native conversion ships. Their per-suite `wallpapers/` directories, standalone
scripts, and everything else about their current structure stays intact — none of the
consolidation or cleanup in this document applies retroactively to the legacy repos.
Users who prefer the original standalone suite can still get it from GitHub; the
core-native version is the going-forward path, not a forced migration.

**Naming convention:** converted suites get an `-e` suffix appended to the existing
`gtex62-` prefixed name — `gtex62-clean-suite-e`, `gtex62-tech-hud-e`, `gtex62-lcars-e`,
`gtex62-tri-hud-e` — living alongside (not replacing) their legacy directories
(`gtex62-clean-suite`, `gtex62-lcars`, etc.). This means `conkystart`'s existing
directory-scan discovery (`is_suite_dir` over `$CONKY_ROOT`) already lists legacy and
converted versions of the same suite side by side with no naming collision and no
special-casing needed — a user can have both `gtex62-lcars` and `gtex62-lcars-e`
installed and pick either from the same suite list. The `-e` suffix marks a
*conversion* specifically — a suite built core-native from inception never gets one,
regardless of how many suites exist. OSA, SitRep, and Doctor all have no `-e` variant
for this reason: none of them started as a legacy standalone suite that was converted,
so there's no pre-existing legacy directory for an `-e` name to live alongside.

### 5. Launch

All selected suites started in sequence — each handed off to the core launcher
binary / conky process start, same as OSA's current `CORE_LAUNCHER --suite <id>`
pattern, generalized from `conkystart`'s existing OSA-then-SitRep sequencing to
however many suites were selected.

---

## Interface Scope

**GUI is off the table — ruled out, not deferred.** This entire stack has zero
non-terminal dependencies anywhere; a GUI toolkit would be the first one, for a
problem that's just a handful of short text lists (suite names, mode names, palette
names, wallpaper names). Current build target is the state machine described above,
using today's plain `read -rp` / multi-select-by-number prompts — no new dependency.

A checkbox-style TUI (`dialog`/`fzf`) over that same state machine is a distinct,
later follow-up, not in scope for this build — see Open Items.

---

## Consolidation Path

**Before:** `conkystart` (untracked, `~/.local/bin/`) → name-based special case for
LCARS/tri-hud, plus one hardcoded fixed-label combo (OSA+SitRep) → one of three
divergent scripts (`start-conky.sh` variants, `launch-lcars.sh`, `launch-tri-hud.sh`),
each independently implementing some subset of {mode, palette, wallpaper}.

**After:** `conkystart` → one core launcher entry point for every suite, covering any
number of selected suites per invocation. The launcher:

0. Checks the bootstrap precondition — resolves the runtime root via
   `${GTEX62_CONFIG_DIR:-${GTEX62_CONKY_CONFIG_DIR:-$HOME/.config/gtex62-core}}`
   and stats `core.toml` under it. If missing, fails immediately with a
   plain terminal message pointing at the README/bootstrap script; no
   suite's theme-core file, palette, or Conky/Lua stack is touched.
1. Lists installed suite dirs (directory-presence scan, unchanged); prompts
   multi-select instead of a single choice or a fixed combo label.
2. For each selected suite, checks its theme-core file for `tone_modes`
   presence → prompts mode or skips, per suite.
3. Groups selected suites by palette-file hash; prompts palette once per
   distinct group present, propagates the answer to every suite in that
   group via the existing `GTEX62_CONKY_PALETTE_OVERRIDE` mechanism.
4. Reads `gtex62-shared-assets/wallpapers`; prompts wallpaper once for the
   whole launch (universal across groups — unverified, see Wallpaper above).
5. Execs the core process launcher for each selected suite in sequence.

No suite-named special cases in `conkystart` itself, and no fixed combo label. Mode
and Palette detection are the same conditional/grouping logic regardless of how many
suites are selected. `launch-lcars.sh` and `launch-tri-hud.sh` are retired — their
mode/palette logic moves into the shared launcher's conditional steps 2/3, reading
each suite's own theme-core file rather than being duplicated per script. The legacy,
unused LCARS `start-conky.sh` (wallpaper-only, per-suite dir) is retired outright.
`conkystart_legacy` is not part of this path at all — confirmed dead, not a fallback
worth preserving.

---

## Open Items

- **Where does the core launcher live?** Now sharper than "presumably `gtex62-core`":
  today's real dispatcher (`conkystart`) is an untracked personal script at
  `~/.local/bin/conkystart`, outside both repos entirely — not previously known, since
  earlier searches only checked the two repos and found nothing. Undecided whether the
  consolidated launcher gets committed into `gtex62-core` and installed via bootstrap
  (replacing the untracked personal copy — a real, and not obviously easy, migration
  for an already-aliased daily-use script), or stays a standalone personal script
  outside version control as it is today.
- **Detecting `tone_modes` presence.** Needs a concrete mechanism — likely the same awk
  pattern-matching approach `launch-lcars.sh`/`launch-tri-hud.sh` already use to read
  `tone_palettes`, extended to check for a `tone_modes` table in the same file, rather
  than a new detection method.
- **Per-suite wallpaper directory retirement.** Not yet actioned — flagged here as a
  cleanup step to fold into each suite's conversion checklist (clean-suite-e's Cleanup
  section already has a "no legacy script files" item; this is the wallpaper-directory
  equivalent).
- **Wallpaper "once per launch, universal across groups."** Unverified — see Wallpaper
  step above. Only confirmed against today's two-suite, same-group OSA→SitRep combo;
  needs checking against an actual cross-group multi-select before being treated as
  settled behavior rather than an inference.
- **Checkbox-style TUI (`dialog`/`fzf`).** A distinct, later follow-up over the same
  state machine described in Interface Scope — not in scope for this build, which
  targets the plain `read -rp`/multi-select-by-number prompts with no new dependency.
