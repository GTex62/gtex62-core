# Core Launcher — Design

Standardizing suite launch (mode → palette → wallpaper → launch) into one core-owned
flow, replacing the current per-suite scattered scripts.

---

## Current State (What Exists Today)

| Script | Suite(s) | Does |
| ------ | -------- | ---- |
| `conkystart` | dispatcher | Lists suite dirs, dispatches to suite-specific script |
| `start-conky.sh` (OSA) | gtex62-osa | Palette selection (flat list, single axis) + wallpaper (shared-assets, with None) + hands off to core launcher |
| `start-conky.sh` (LCARS, legacy) | gtex62-lcars | Wallpaper only (per-suite dir) — not actually invoked by conkystart; superseded by launch-lcars.sh |
| `launch-lcars.sh` | gtex62-lcars | Mode (dark/alt) + palette (flat list from theme-core.lua) → execs start-conky.sh |
| `launch-tri-hud.sh` | gtex62-tri-hud | Mode (dark/light) + palette (flat list from theme-core.lua) → execs start-conky.sh |

Three different behaviors for what should be one conceptual flow. `conkystart`
special-cases LCARS and tri-hud by name to route around the mode step OSA doesn't have.
Wallpaper handling is inconsistent: OSA pulls from shared-assets; LCARS's (unused)
script pulls from a per-suite directory that duplicates what's likely the same images
across every suite that still has one.

---

## Standardized Flow

One core-owned launcher, one sequence, per suite:

### 1. Mode (conditional)

Only prompted if the suite's theme-core file defines `tone_modes`. Detected, not
hardcoded per suite — core checks for the table's presence rather than special-casing
suite names.

- **Present today:** LCARS, tri-hud (both use the tone-ladder palette shape with
  `tone0`–`tone4` + `energy`, where mode is a role-inversion function over that ladder —
  not a separate palette, see `lyrics-library-design.md`-style precedent of documenting
  the actual mechanism rather than assuming from naming)
- **Absent:** OSA, clean-suite, tech-hud — flat/simple palette shapes with no tone
  ladder to invert. No mode prompt; go straight to palette.

### 2. Palette (always)

Every suite has one. Presented as a flat, named list — core reads whatever the suite's
own palette file exposes (a `palettes` table, a `tone_palettes` table, whatever the
suite calls it) and lists the entries. Core does not need to understand the internal
shape (3-role `bg`/`fg`/`ink`, 5-tone ladder, gray-ramp-plus-accents) — it only needs a
list of names and a default, same as the existing `choose_palette` logic in OSA's script
already does generically via awk pattern matching.

Each suite keeps its own palette file — no sharing between suites, even where starting
values converge (clean-suite and tech-hud have near-identical color needs today but get
separate `clean-palettes.lua` / `tech-hud-palettes.lua` files, per the guide's Core Rule:
visual identity is Suite-owned, and shared-today doesn't mean shared-forever).

### 3. Wallpaper (always)

Always sourced from `gtex62-shared-assets/wallpapers` — never a per-suite directory.
List includes a `None` entry (index 0) for users who don't want wallpaper touched at
launch, matching OSA's existing `choose_wallpaper` behavior.

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
installed and pick either from the same suite list. OSA has no `-e` variant since it was
built core-native from the start rather than converted.

### 4. Launch

Hand off to the core launcher binary / conky process start, same as OSA's current
`CORE_LAUNCHER --suite <id>` pattern.

---

## Consolidation Path

**Before:** `conkystart` → name-based special case → one of three divergent scripts
(`start-conky.sh` variants, `launch-lcars.sh`, `launch-tri-hud.sh`), each independently
implementing some subset of {mode, palette, wallpaper}.

**After:** `conkystart` → one core launcher entry point for every suite. The launcher:

1. Reads the suite's theme-core file; checks for `tone_modes` presence → prompts mode
   or skips.
2. Reads the suite's palette file; prompts palette (always).
3. Reads `gtex62-shared-assets/wallpapers`; prompts wallpaper with `None` option
   (always).
4. Execs the core process launcher with resolved suite ID + selections.

No suite-named special cases in `conkystart` itself. `launch-lcars.sh` and
`launch-tri-hud.sh` are retired — their mode/palette logic moves into the shared
launcher's conditional step 1/2, reading each suite's own theme-core file rather than
being duplicated per script. The legacy, unused LCARS `start-conky.sh` (wallpaper-only,
per-suite dir) is retired outright.

---

## Open Items

- **Where does the core launcher live?** Presumably `gtex62-core`, alongside the other
  Core-owned responsibilities (launch orchestration, PID management) per the guide's
  Core Rule table. Not yet decided whether this is a new script or an extension of the
  existing `CORE_LAUNCHER` binary referenced in OSA's `start-conky.sh`.
- **Detecting `tone_modes` presence.** Needs a concrete mechanism — likely the same awk
  pattern-matching approach `launch-lcars.sh`/`launch-tri-hud.sh` already use to read
  `tone_palettes`, extended to check for a `tone_modes` table in the same file, rather
  than a new detection method.
- **Per-suite wallpaper directory retirement.** Not yet actioned — flagged here as a
  cleanup step to fold into each suite's conversion checklist (clean-suite-e's Cleanup
  section already has a "no legacy script files" item; this is the wallpaper-directory
  equivalent).
