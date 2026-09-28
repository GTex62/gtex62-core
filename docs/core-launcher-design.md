# Core Launcher — Design

Standardizing suite launch (suite selection → mode → palette → wallpaper → launch)
into one core-owned flow, replacing the current per-suite scattered scripts.

---

## Current State (What Exists Today)

| Script | Suite(s) | Does |
| ------ | -------- | ---- |
| `conkystart` | dispatcher | **Untracked personal script at `~/.local/bin/conkystart`** (aliased in `~/.bash_aliases`) — not in either repo. Lists suite dirs, dispatches to suite-specific script. Already special-cases a hardcoded "osa + sitrep" combo menu entry (`COMBO_LABEL`), launching both in sequence and propagating OSA's palette/wallpaper choice to SitRep via env-var override (see below). This location is a stopgap — see Installation Location for the decided replacement |
| `conkystart_legacy` | dispatcher (dead) | Also untracked at `~/.local/bin/`, predates the combo-label logic. Confirmed zero references anywhere — not aliased, not invoked by any script or the current `conkystart`. Dead weight, not a fallback path in use |
| `start-conky.sh` (OSA) | gtex62-osa | Palette selection (flat list, single axis) + wallpaper (shared-assets, with None) + hands off to core launcher |
| `start-conky.sh` (Doctor) | gtex62-doctor | Same front-door shape as OSA's, built 2026-09-23 (gtex62-doctor `790809b`): toolchain gate → foreground bootstrap → palette (Group A catalog) and wallpaper prompts, both honoring the `GTEX62_CONKY_*_OVERRIDE` handoff → detached core launcher. Self-stop only (scoped `pkill` of its own widgets); no suite-exclusivity block. Discovered by `conkystart`'s directory scan (its script is executable), so it appears in the menu and launches standalone; it is not part of any combo |
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
SitRep. OSA's, SitRep's, and Doctor's `start-conky.sh` already honor these env vars — if the
override value matches a name in that suite's own catalog, it's used silently; if not,
each suite prints a warning and falls back to prompting. That graceful fallback is real,
working code today, not a proposal — the generalized per-group propagation in Palette
(below) builds on this exact mechanism rather than inventing a new one.

**Existing bootstrap behavior: self-healing auto-bootstrap (retained by decision).**
OSA's, SitRep's, and Doctor's `start-conky.sh` check for `core.toml` and their own
`suites/<id>.toml`; clean-suite-e's checks only `suites/clean-e.toml`. If the file is
missing, each runs its bootstrap wrapper and carries on: a fresh clone doesn't stop, it
generates the runtime root from templates (placeholder values and all) and starts.
Until 2026-09-19 OSA, SitRep, and clean-suite-e sent the wrapper's output to
`/dev/null`, so the bootstrap's "fill in `site.toml`" instructions never appeared; that
is fixed (see Step 0). Doctor, built later (2026-09-23), calls its wrapper in the
foreground from the start. A fail-fast gate was designed as the alternative and
rejected — see Step 0.

---

## Standardized Flow

One core-owned launcher, one sequence, covering however many suites are selected per
invocation (see Suite Selection below — this is no longer assumed to be exactly one):

### 0. First-Run Bootstrap (self-healing; output must be visible)

Each core-native suite's front door (`start-conky.sh`) checks for its runtime files
and, if missing, runs its bootstrap wrapper in the foreground and carries on. This
self-healing behavior is retained: a fresh clone starts, with placeholder config,
rather than stopping.

**Non-optional requirement: the wrapper's output must reach the terminal.** The front
door calls the wrapper with its output *not* redirected. This is the only path to the
bootstrap's "Fill in local site defaults ... in `site.toml`" guidance for anyone who
never installs Doctor, so it is required regardless of what else is built. It was a
regression in all three front doors (each ended the call with `>/dev/null`), fixed
2026-09-19. Verified against a fresh scratch runtime root, using each suite's
committed `HEAD` script versus the working-tree script: before, no bootstrap output
reached the terminal; after, 35–37 lines did, including "Runtime root prepared at:"
and the `site.toml` next steps. Doctor's front door was checked the same way on
2026-09-27: 37 lines reached the terminal, a fresh root received `suites/doctor.toml`,
and the shipped `core.toml` carries `[doctor] enabled = true`, so a first-run Doctor
launch has its provider on without a manual edit.

#### Superseded: the fail-fast bootstrap gate

The original design had the launcher stat `core.toml` under the runtime root
(resolved via the existing `GTEX62_CONFIG_DIR` / `GTEX62_CONKY_CONFIG_DIR` /
`$HOME/.config/gtex62-core` fallback chain) and, if missing, fail immediately with a
plain terminal message pointing at the README, loading nothing. It was never built,
and is now **superseded**, not merely deferred:

- Doctor is built (gtex62-doctor `790809b`, 2026-09-23) and covers this ground more
  usefully than a one-shot terminal message could. Its CONFIG box, fed by core's
  `fetch_doctor.sh`, shows live per-field status: time zone, lat, and lon as values, and
  whether the OpenWeather and AirNow keys are set (presence only — a set key shows just
  `NOMINAL`), with `BLANK` for anything unset. Its DCM takeover raises a fixed-text entry
  with a `PROC:` line per provider condition — for example AIR and ASTRO report missing
  coordinates as "Set `[location] lat`/`lon` in the ... profile or `site.toml`", and
  WEATHER asks for the API key and coordinates in its profile — with long-form
  procedures in `gtex62-doctor/docs/doctor-qrh.md`. Building the hard gate would
  duplicate a worse version of what Doctor does for anyone who installs it.
  **Limits, so this isn't over-read:** the CONFIG box is a status readout and carries no
  remediation text itself, and a config value that is present but still a placeholder
  raises no row NOTE — whether DCM should raise an entry for it is still an open
  question in `doctor-design.md` (also flagged in the QRH).
- For anyone who doesn't install Doctor, the visible bootstrap output above carries the
  same "fill in `site.toml`" guidance at the moment it's relevant.
- Fail-fast would also have reversed working behavior in three suites and added a
  manual bootstrap step to every fresh install.

The self-healing auto-bootstrap writes `~/.config/gtex62-core/`, which is consistent
with the "never write outside the repo clone without explicit action" principle under
Installation Location: the runtime root is the bootstrap's own designated target,
and that principle governs placing files elsewhere in the user's environment (for
example `~/.local/bin`).

### 0b. Baseline Toolchain (before any suite)

The one pre-launch gate in this design: `command -v jq` and `command -v python3`, as
**one combined check** (bash builtin, no new dependency). If either is missing, print
which one(s), point at the suite README's Requirements section, and exit 1 before
anything else runs — including before the auto-bootstrap block in Step 0.

First measured 2026-09-19 across the 23 launcher-invoked provider entry points: `jq` was
referenced by 20 (87%) and `python3` by 18 (78%). Re-measured 2026-09-27 across the 24
that exist now, after the Doctor provider (`python3` only, no `jq`) landed: `jq` 20
(83%), `python3` 19 (79%). Every entry point still needs at least one of them; none
needs neither. They are gated together, not separately, because their numbers are too
close to justify different treatment. Run empirically against the four local-only domains (`time`,
`system`, `calendar`, `astro`) with each tool broken in turn: without `jq`, none reach
an `ok` status and `system` writes no output at all; without `python3`, only `system`
survives, degraded.

**Placement matters as much as the check.** Suite `start-conky.sh` scripts detach the
core launcher with `>/dev/null 2>&1` (OSA `start-conky.sh`, SitRep, clean-suite-e, Doctor), so
anything the launcher prints is discarded. This check must run in the foreground
front door, before any redirect or detach. A launcher-side copy can only be a backstop
for running `gtex62-core-launch` directly from a terminal.

**Status:** implemented 2026-09-19 in the `scripts/start-conky.sh` of gtex62-osa,
gtex62-sitrep, and gtex62-clean-suite-e — the same block in each, ahead of the
bootstrap call and every redirect. Verified per suite with a restricted `PATH`
(neither tool, `jq` only, `python3` only): each prints which tool(s) are missing,
exits 1, and leaves no side effects; the real scripts were never run past the gate
because each one `pkill`s its suite's live conky windows. Each suite's README
Requirements section now lists `python3` (clean-suite-e had no Requirements section
and gained one). gtex62-doctor's front door (built 2026-09-23) carries the same block,
verified 2026-09-27 the same way: all three restricted-`PATH` cases print what's
missing, exit 1, and leave no side effects. Doctor's README Requirements section lists
`jq` and `python3`.

#### Standard for what earns a pre-launch gate

A condition is gated only if it is **silent and near-total, together** — not either
alone:

- *Silent:* today it fails with no visible signal (the launcher's output is
  discarded, meters just freeze). A loud failure already tells the user what's wrong.
- *Near-total:* it takes out nearly every provider entry point, measured rather than
  assumed. Not "strictly total" — no single tool is needed by all 24. The measured
  gap is wide (`jq` 83%, `python3` 79%, then `ssh` 38%, `curl` 25%, `sshpass` 4%;
  re-measured 2026-09-27), so no fixed percentage cutoff is claimed.
- Also required: a single root cause, and deterministically checkable before any
  suite loads.

Near-total but loud, or silent but partial, belongs in Doctor.

#### Considered and excluded

- **Malformed `core.toml`/`site.toml` — Doctor only.** Not total: only the launcher,
  `fetch_alerts.sh`, and `fetch_doctor.sh` reference `core.toml`, and 7 of the 24 entry
  points (`alerts`, `modem`, `mtr`, `orb`, `system`, `time`, `vpn`) never read
  `site.toml` in code (an earlier count of 6 wrongly counted `alerts`, whose only
  mention is a comment). Providers don't fail
  identically: the shell providers use line-matching `awk`, which never validates
  syntax; the Python loaders swallow parse errors into `{}` and fall back to defaults.
  Tested cases: a garbage line elsewhere leaves every key readable, an unclosed
  section header loses only that section's keys, an unterminated string is still read.
  A parse-check would also add a `python3` 3.11+ (`tomllib`) dependency to a launcher
  that is pure bash and awk today. And "malformed" has no single definition here: the
  shipped `profiles/time/local.toml.example` fails strict parsing (unquoted
  `America/Chicago` keys) and works only because its parser is hand-rolled. This is
  not a missing-file analogue either: a never-bootstrapped install is total because the
  launcher itself exits at its `SUITE_TOML` check, which a malformed file doesn't
  trigger. "Doctor only" is a placement decision, not an existing capability:
  `fetch_doctor.sh` doesn't flag a malformed file today either — on a `tomllib`
  rejection it falls back to a lenient line-oriented reader, matching how the launcher
  and providers read the same files.
- **Per-domain tools — Doctor only:** `curl` (4 domains fully dependent), `ssh`,
  `sshpass` (the AP scraper only), `ephem` (`astro`, `orb`), `requests` (`media`), and
  Python 3.11+ (`modem`, `media`, the AP script).

### 1. Suite Selection (one main suite, plus companions)

The dispatcher lists installed suite dirs — the same directory-presence scan as today's
`is_suite_dir`, unchanged. Selection is **at most one main suite plus any number of
companions**, entered as space- or comma-separated numbers at a plain-terminal
`read -rp` prompt, no new dependency.

This is the model the front doors already enforce, not a new restriction: OSA's and
clean-suite-e's `start-conky.sh` each stop every other running suite when they launch,
except companions ("Only one main suite may run at a time"). A flat any-combination
multi-select would let a user pick pairs that destroy each other, since the second
launch kills the first. Companion status is declared data — `[launch] companion = true`
in the suite's `suite.toml` (see Front-Door Contract); a suite with no such key, or no
manifest at all, is a main suite. Today that makes SitRep and Doctor companions and OSA
and clean-suite-e mains.

This replaces `conkystart`'s hardcoded `COMBO_LABEL` ("osa + sitrep"), which doesn't
scale — every new suite multiplies the fixed labels — and is exactly the per-suite
special-casing this document exists to eliminate. The menu tags companions, and a
selection containing more than one main suite is refused with a message naming them,
then re-prompted.

**Legacy suites are opaque pass-through.** They have no `suite.toml` (LCARS, tri-hud,
tech-hud and clean-suite all checked 2026-09-27), so they are mains. Selecting one
launches it through its own script, with the same precedence as today's `conkystart`
(`launch-lcars.sh` / `launch-tri-hud.sh` / `start-conky.sh`), with no palette grouping,
no mode prompt, and no override handoff; it keeps its own prompts. This is consistent
with "frozen, not migrated" (see Wallpaper): the consolidated launcher can reach legacy
suites but never changes them.

**Legacy-suite menu handling needs no code.** The directory scan already naturally
includes or excludes a suite based on what's installed under `~/.config/conky/`. There
is no "hide legacy suites" flag or toggle, and none is needed — a user (including the
maintainer) who wants a legacy suite gone from their own menu just moves or removes its
directory. Stated explicitly here so this isn't rebuilt as a feature later.

**Required test cases:**

- A legacy main alone: launches through its own script, untouched by grouping.
- A legacy main plus companions: the main launches first (see Launch), companions after.
- Two mains selected: refused before anything launches.
- OSA + SitRep + Doctor: one palette prompt (all Group A), one wallpaper prompt.
- clean-suite-e as main + SitRep: two palette prompts (Group B, Group A).

### 2. Mode (deferred until a converted suite needs it)

Mode is a role-inversion function over the tone-ladder palette (`tone0`–`tone4` +
`energy`, `tone_modes`), and only LCARS and tri-hud have it — both legacy, reached by
pass-through with their own mode prompts. No core-native suite has a mode step, so
**the first build has none**: nothing would exercise it. It arrives with `lcars-e` /
`tri-hud-e`, when those exist.

When it does: prompted once per selected suite whose theme-core file defines
`tone_modes`, skipped otherwise — detected from the file, never from suite names. The
detection mechanism is still open (see Open Items).

- **Present today (legacy, pass-through):** LCARS, tri-hud — both use the tone-ladder
  palette shape; mode is an inversion function over that ladder, not a separate palette.
- **Absent:** OSA, SitRep, Doctor, clean-suite-e, tech-hud — flat/simple palette shapes
  with no tone ladder to invert.

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
| A | OSA, SitRep, Doctor | Byte-identical `osa-palettes.lua`/`palettes.lua`, 63 flat-role (`bg`/`fg`/`ink`) entries. Safe combo candidate — shared prompt. Re-verified 2026-09-27: all three still hash identically (`f1743dbc…`), Doctor's copy committed and unmodified. |
| B | clean-suite-e | Standalone, 2 entries, different role shape (`bg`/`fg`/`ink`/`dim`/`accent`/`ok`/`warn`/`err`/...). |
| C | LCARS | Standalone, 61 tone-ladder entries. Legacy today — pass-through, not grouped; becomes a live group only when `lcars-e` exists. |
| D | tri-hud | Standalone, 60 tone-ladder entries. Shares the tone-ladder *mechanism* with C, not the catalog — confirmed even the 5 same-named utility palettes (`aqi`, `planets`, `seasons`, `dark`) that are byte-identical between C and D have a real divergence in `light` mode's tone-inversion behavior (LCARS inverts tone2↔tone3 as well as tone0↔tone4; tri-hud only inverts tone0↔tone4). Not the same group. Legacy today — pass-through, not grouped. |
| E | tech-hud (legacy) / tech-hud-e (future) | No palette catalog exists at all today — no `palettes[name]` table, no launch-time prompt. Not a group until conversion happens and a catalog gets designed. |

**Locating a suite's catalog:** each core-native `suite.toml` already declares it —
`[theme] palette_catalog` (all four checked 2026-09-27) — so the launcher reads the path
from the manifest and hashes that file, rather than assuming a path (the front doors
hardcode the same value today). `palette_format` can't be used to group: all four
declare `"role3"`, including clean-suite-e, whose catalog has a different role shape.
Under the one-main-plus-companions model a selection spans at most two groups today: the
main suite's, plus Group A for SitRep and Doctor.

**Group membership is not permanent.** Re-check by file hash on every launch (or at
least whenever any suite's palette file changes) — a group that was correct at design
time can drift the moment one suite's catalog is edited independently of the others'.

Each suite still keeps its own palette file — grouping is a launcher-side optimization
to avoid redundant prompts, not a change to file ownership. Grouping is shape-agnostic:
it hashes the file's contents and never looks inside. *Listing* the names to prompt from
is not: it depends on the file's syntax, and there are two today. Group A's files are
`return { default = "…", palettes = { name = { … } } }`, which OSA's, SitRep's and
Doctor's `choose_palette` awk relies on; clean-suite-e's assigns
`palettes["name"] = { … }` into a local table. The default comes from the manifest's
`[theme] default_palette` either way.

**Decided and validated 2026-09-27:** the manifest declares the syntax with `[theme]
palette_catalog_syntax` — `nested-table` (Group A) or `assigned-keys` (clean-suite-e) —
and the launcher keeps one small POSIX-awk extractor per value. `palette_format` is
unchanged and unrelated: it labels the role shape, and all four suites say `role3`. A
suite with no value, or one the launcher doesn't know, is simply not listed: the launcher
passes it no palette override and the suite prompts for itself, the same fallback legacy
suites get. A new catalog layout means adding an extractor to core and a new value.

The prototype was checked against the real catalogs of all four suites, under both gawk
and mawk. Each extractor's name set equals the keys of the real Lua table (63, 63, 63 and
2, read by `lua5.4`, not by awk); Group A's output is byte-identical to the front doors'
own extraction, including order and group headings; every manifest default is among the
listed names; and a wrong declaration yields zero names, which is detectable. The
tone-ladder shape (LCARS, tri-hud) has no value yet; it gets one when `lcars-e` /
`tri-hud-e` exist.

**Propagation mechanism:** the same `GTEX62_CONKY_PALETTE_OVERRIDE` /
`GTEX62_CONKY_WALLPAPER_OVERRIDE` env-var handoff `conkystart` already uses for its
OSA→SitRep combo (see Current State) — generalized from one hardcoded pair to any
number of suites sharing a group. Each suite's existing fallback behavior (override
name not found in its own catalog → warn and prompt instead) carries over unchanged.
clean-suite-e conforms too, with one difference: its front door never prompts, so it maps
the override onto its own `GTEX62_PALETTE` and warns and ignores an unknown name instead
of prompting (see Front-Door Contract).

### 4. Wallpaper (once per launch; each suite applies it)

Prompted once for the whole launch: the same `gtex62-shared-assets/wallpapers` source
and `None` option (index 0) as today's `choose_wallpaper`. The choice is passed to every
managed suite as `GTEX62_CONKY_WALLPAPER_OVERRIDE`, and **each suite's front door applies
it itself** with `feh`, as they do today; repeated applies of the same image are
harmless. Decided 2026-09-27 over having the launcher apply it once, because it needs no
front-door change. One accepted wart for the first build: clean-suite-e has no
wallpaper step, so a clean-suite-e-only selection makes the prompt a no-op.

**Not independently confirmed** for a selection spanning palette groups. "Once,
universal" is inferred from today's same-group OSA→SitRep combo. Under the
one-main-plus-companions model the realistic cross-group case is clean-suite-e (Group B)
as main with SitRep or Doctor (Group A) as companions — not, as an earlier draft had it,
OSA + LCARS, which is two mains and can't coexist. Still unchecked against a live
launch.

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

### 5. Launch (main first, then companions)

The launcher starts each selected suite through its own front door — core-native suites
via `scripts/start-conky.sh` (toolchain gate, self-healing bootstrap, override-aware
prompts, detached core launch), legacy suites via their own scripts — with the palette
and wallpaper overrides exported. Sequentially: **the main suite first, companions
after.** The order is required, not cosmetic: the legacy `start-conky.sh` scripts each
carry a blanket `pkill -x conky` near the top (LCARS, tri-hud, tech-hud, clean-suite;
checked 2026-09-27), which would kill any companion already running. Core-native mains skip
companions through the manifest flag, but the same order is safe for them and keeps one
rule.

**Exclusivity — implemented and confirmed live.** OSA's and clean-suite-e's front doors
used to kill every sibling suite's widgets (`pkill -f "$other_dir/widgets/"`) except a
hardcoded `gtex62-sitrep`. Doctor is meant to run beside a main suite (its README says so)
but wasn't exempt: **confirmed live 2026-09-27**, launching OSA after Doctor killed Doctor.
(It was first spotted by simulating the string match against Doctor's real conky command
line. Only OSA was exercised live; clean-suite-e's identical block was read from code, not
observed.)

Fixed 2026-09-27 by replacing the name list with the `companion` manifest flag: a main
suite's kill loop now skips any sibling whose `suite.toml` declares `[launch] companion =
true` (SitRep and Doctor do), and siblings with no manifest or no key are stopped exactly
as before. Verified by running each modified front door's real loop text against the real
`~/.config/conky` tree with `pkill` replaced by a logger: for both OSA and clean-suite-e
the only change from the old loop's targets is Doctor dropping out, and the
`is_companion()` reader passes 14 edge-case manifests (false, missing key, wrong table,
commented-out, quoted, array table, trailing comments, no manifest). **Confirmed live
2026-09-27:** with Doctor running, launching OSA did not kill it, and neither did launching
clean-suite-e (the first time that path was ever observed).

---

## Front-Door Contract

The launcher owns the prompts; each suite's front door (`scripts/start-conky.sh`) stays
a working standalone entry point that the launcher drives through environment variables.
A conforming front door:

1. Runs the toolchain gate, then the self-healing bootstrap with visible output, before
   any redirect or detach (Steps 0 and 0b).
2. Accepts `GTEX62_CONKY_PALETTE_OVERRIDE` and `GTEX62_CONKY_WALLPAPER_OVERRIDE`. A valid
   value is used silently with no prompt; an invalid one warns and then prompts (existing
   behavior); unset means prompt, as when run standalone. A front door that never prompts
   (clean-suite-e) warns and ignores an unknown palette instead, and one with no
   wallpaper step ignores the wallpaper variable.
3. Exits 0 after detaching the core launcher; non-zero with a message otherwise.
4. Enforces exclusivity by the manifest: a main suite stops other running non-companion
   suites, a companion stops only itself.
5. Records the last choice under `$CACHE_ROOT/runtime/<suite>-palette` / `-wallpaper`
   (existing behavior; the launcher doesn't depend on it).

**Manifest key.** A new `[launch]` table in `suite.toml`:

```toml
[launch]
companion = true   # may run beside a main suite; never stopped by one
```

Default false. Read by main front doors' sibling-kill loops through `is_companion()`
(`awk`, in the same style as the core launcher's existing manifest parsing, and
byte-identical in OSA's and clean-suite-e's `start-conky.sh`), and, once built, by the
launcher for selection. Set in SitRep's and Doctor's `suite.toml` as of 2026-09-27; OSA and
clean-suite-e omit it (mains), as does any manifest missing the key and any legacy suite,
which has no manifest at all. Documented in `legacy-suite-conversion-guide.md`.

**Second manifest key.** `[theme] palette_catalog_syntax` (see Palette). Read only by the
launcher; the front doors ignore it. Set in all four suites' `suite.toml` as of
2026-09-27: `nested-table` for OSA, SitRep and Doctor, `assigned-keys` for
clean-suite-e.

**Conformance today** (read from code, 2026-09-27):

| Front door | Toolchain gate | Visible bootstrap | Override vars | Exclusivity |
| ---------- | -------------- | ----------------- | ------------- | ----------- |
| OSA | yes | yes | yes | stops non-companion siblings via the manifest read (2026-09-27) |
| SitRep | yes | yes | yes | none (companion) |
| Doctor | yes | yes | yes | none (companion) |
| clean-suite-e | yes | yes | palette: yes, mapped onto `GTEX62_PALETTE` (confirmed live 2026-09-27); wallpaper: n/a, no wallpaper step | stops non-companion siblings via the manifest read (2026-09-27) |

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

## Installation Location

**Decided: versioned in `gtex62-core/bin/`** — e.g. `gtex62-core/bin/gtex62-conkystart`
— not an untracked personal file. It is part of the repo clone, so a `git pull` updates
it and bootstrap has nothing to copy or install; it lives there and nowhere else: no
writes outside the repo clone, no `sudo`, no touching `/bin`, `/usr/bin`, or
`/usr/local/bin` — ruled out entirely, since those are root-owned and this project has
no reason to require elevated permissions.

Bootstrap does **not** create a `~/.local/bin` symlink itself, and does not
interactively prompt for one either — that's left entirely to the user, documented as
an optional one-line README instruction:

```bash
ln -s ~/.config/conky/gtex62-core/bin/gtex62-conkystart ~/.local/bin/conkystart
```

for anyone who wants the convenience of invoking it by name instead of full path.
Running the script directly, unlinked, works identically — the symlink is pure
convenience layered on top of something already fully functional, not a required
setup step.

**Rationale:** an installer silently placing a file in someone's personal `bin/` —
even a directory that's already commonly on `$PATH` — is the kind of uninvited write
that erodes trust in a dotfiles-style project, regardless of how convenient the end
result is. Bootstrap should never modify anything outside the repo clone without the
user's own explicit action.

This replaces today's untracked `~/.local/bin/conkystart` (see Current State).
Repointing the existing `~/.bash_aliases` entry at the new versioned path or the new
symlink is the user's own action to take when they're ready — not something bootstrap
does for them.

---

## Consolidation Path

**Before:** `conkystart` (untracked, `~/.local/bin/`) → name-based special case for
LCARS/tri-hud, plus one hardcoded fixed-label combo (OSA+SitRep) → one of three
divergent scripts (`start-conky.sh` variants, `launch-lcars.sh`, `launch-tri-hud.sh`),
each independently implementing some subset of {mode, palette, wallpaper}.

**After:** `gtex62-core/bin/gtex62-conkystart` (versioned in the clone — see Installation
Location) → one launcher that drives every suite through its front door, for one main
suite plus any companions per invocation:

0. First-run bootstrap (self-healing, retained), in each front door: if the suite's
   runtime files are missing, run the bootstrap wrapper in the foreground with output
   visible, then continue. The fail-fast gate originally planned here is superseded
   (see Step 0).
0b. Baseline toolchain check, in each front door — `command -v jq` and
   `command -v python3` as one combined check; if either is missing, print which and
   exit before anything runs (including step 0). Done in OSA, SitRep, clean-suite-e,
   and Doctor.
1. List installed suite dirs (directory-presence scan, unchanged); prompt for one main
   suite plus any companions, tagging companions from each `suite.toml`. Refuse more
   than one main. Legacy suites (no manifest) are mains reached by pass-through.
2. Mode — deferred until a converted suite needs it.
3. Group the selected managed suites by palette-file hash (path from `[theme]
   palette_catalog`); prompt palette once per distinct group; hand the answer to each
   suite in the group via `GTEX62_CONKY_PALETTE_OVERRIDE`.
4. Prompt wallpaper once from `gtex62-shared-assets/wallpapers`, with `None`; hand it to
   each suite via `GTEX62_CONKY_WALLPAPER_OVERRIDE`; each suite applies it (universal
   across groups — unverified, see Wallpaper).
5. Launch the main suite first, then companions, each through its own front door.

No suite-named special cases in the launcher, and no fixed combo label. The legacy
suites' scripts (`launch-lcars.sh`, `launch-tri-hud.sh`, the per-suite `start-conky.sh`)
stay exactly as they are in their frozen repos and are reached by pass-through. When
`lcars-e` and `tri-hud-e` are built they will not carry those scripts: their mode and
palette handling moves into the launcher's steps 2 and 3. `conkystart_legacy` is not
part of this path at all — confirmed dead, not a fallback worth preserving.

---

## Path to Completion

**Decisions (2026-09-27):** companion status by manifest flag, not a name list; legacy
suites are opaque pass-through; the mode step is deferred; each suite applies the
wallpaper itself; palette names are listed through a manifest-declared catalog syntax; the first build covers OSA + SitRep + Doctor (one Group A prompt
round), plus clean-suite-e as a main and legacy pass-through.

1. **Exclusivity fix** (independent of the launcher) — **done 2026-09-27**, simulated and then
   confirmed live: `[launch] companion = true` in SitRep's and Doctor's `suite.toml`, and
   OSA's and clean-suite-e's kill loops read each sibling's manifest instead of the
   hardcoded `gtex62-sitrep`. Doctor survives a later OSA or clean-suite-e launch.
2. **Front-door conformance** — **done 2026-09-27:** clean-suite-e honors
   `GTEX62_CONKY_PALETTE_OVERRIDE` by mapping it onto its own `GTEX62_PALETTE`, verified
   against the real catalog (10 cases, including a regex-metacharacter name and a preset
   `GTEX62_PALETTE` that a bad override must not clobber) and end to end through the real
   theme file, then **confirmed live 2026-09-27** by launching the real front door with
   `GTEX62_CONKY_PALETTE_OVERRIDE=dark` (the last hop into a running conky window, which
   the harness couldn't reach). It deliberately gained no palette prompt and no
   wallpaper step. (The
   `[launch]` key is documented in `legacy-suite-conversion-guide.md`.)
   **POSIX palette listing** — also done 2026-09-27, found while validating the manifest
   field. OSA's, SitRep's and Doctor's `choose_palette` used a three-argument `match()`, a
   gawk extension and the only gawk-only awk in core, the providers, or any front door. Under
   mawk it was a syntax error: the name list came back empty, so the palette prompt — and the
   combined-launch override handoff, which depends on the same list — silently did nothing and
   the suite launched with its default palette. They now use the POSIX `nested-table`
   extractor. Verified by running the whole extracted function, old and new, under gawk and
   mawk for six cases per suite (Enter, a number, the last entry, a valid override, an invalid
   override falling back to the prompt, an out-of-range choice): old/gawk, new/gawk and
   new/mawk are identical in every case, including the exported variable and the cached
   choice, and old/mawk reproduces the bug (0 menu rows).
3. **Build `bin/gtex62-conkystart`, first version** — **built 2026-09-27; live acceptance
   pending.** One bash file needing only bash, POSIX awk and coreutils; sourcing it defines
   the functions without running anything. It does the directory scan, selection under the
   one-main rule, hash grouping from `palette_catalog` with the per-syntax extractors,
   override handoff, one wallpaper prompt, main-first launch and legacy pass-through.
   `--dry-run` does every prompt and prints each planned front-door invocation and its
   environment, starting nothing — a first-class feature, because every front door
   `pkill`s its suite's live windows. `--conky-root DIR` (or `GTEX62_CONKY_ROOT`) points it
   at another tree, which is what makes it testable. A front door that fails doesn't stop
   the rest: the launcher names it and exits 1. The remembered last choice (`runtime/
   <suite_id>-palette` / `-wallpaper`) is the prompt default, else the manifest default.

   **Tests** live in `tests/conkystart/` (`run-tests.sh`, `fixture.sh`) and run under both
   gawk and mawk: 76 checks each, against a synthetic tree whose fake front doors only log
   what they receive, so nothing can `pkill`. The fixture covers every case listed under
   Suite Selection plus grouping, hash sensitivity, unlistable catalogs, remembered
   choices, environment hygiene, dry run and error paths. **Mutation check:** the launcher
   was deliberately broken 25 ways (two mains allowed, stale overrides leaking, grouping
   by name or by nothing, companions first, legacy given overrides, dry run launching,
   swallowed failures, and so on) and the tests caught all 25. One initially survived —
   nothing distinguished suites sharing a catalog's exact bytes but declaring different
   syntaxes — so a fixture pair for that case was added.

   **Real tree, `--dry-run`, scripted input** (against the eight suites in
   `~/.config/conky`, under both awks): OSA + SitRep + Doctor gives one 63-name prompt and
   the same override for all three; clean-suite-e + SitRep gives two prompts (2 names, then
   63); OSA + clean-suite-e is refused; LCARS and tri-hud plan through `launch-lcars.sh` /
   `launch-tri-hud.sh` and tech-hud through `start-conky.sh`, none with overrides. This
   layer caught a bug the fixture could not: globbing `*/` sorts with the trailing slash, so
   `gtex62-clean-suite-e` listed before `gtex62-clean-suite`, which also made numbered
   selection pick the wrong suite. The fixture had no name that prefixes another; one was
   added (the test failed first), and discovery now sorts plain names.

   **Remaining: live acceptance** — a real launch of OSA + SitRep + Doctor (one palette
   prompt, all three up with the same palette), then clean-suite-e + Doctor (Doctor
   survives), then one legacy pass-through.
4. **Cutover** (the maintainer's own actions): repoint the `~/.bash_aliases` entry,
   retire `conkystart_legacy` and the old untracked script. The planned paragraph in
   core's README still says bootstrap installs the launcher; correct it when this lands.
5. **Later, not in scope:** the mode step (with `lcars-e` / `tri-hud-e`), the checkbox
   TUI, verifying the wallpaper assumption across groups, and retiring per-suite
   wallpaper directories in converted suites.

---

## Open Items

- **Detecting `tone_modes` presence.** Deferred with the mode step, but the mechanism is
  still open — likely the same awk pattern-matching approach `launch-lcars.sh` /
  `launch-tri-hud.sh` already use to read `tone_palettes`, extended to check for a
  `tone_modes` table in the same file, rather than a new detection method.
- **Per-suite wallpaper directory retirement.** Not yet actioned — flagged here as a
  cleanup step to fold into each converted suite's conversion checklist (clean-suite-e's
  Cleanup section already has a "no legacy script files" item; this is the
  wallpaper-directory equivalent).
- **Wallpaper "once per launch, universal across groups."** Unverified — see Wallpaper.
  Needs checking against a live clean-suite-e-plus-companion launch before being treated
  as settled behavior rather than an inference.
- **Wallpaper prompt is a no-op for a clean-suite-e-only selection**, since that front
  door has no wallpaper step. Accepted for the first build; a `[launch]` key declaring
  whether a suite applies wallpapers could suppress the prompt later.
- **Checkbox-style TUI (`dialog`/`fzf`).** A distinct, later follow-up over the same
  state machine described in Interface Scope — not in scope for this build, which
  targets the plain `read -rp`/multi-select-by-number prompts with no new dependency.
