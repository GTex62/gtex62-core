# gtex62 Core Rename Roadmap

## Purpose

This document records the intended direction for renaming the shared engine layer
from `gtex62-conky-engine` to `gtex62-core`.

The current implementation is still Conky-specific, and it may remain
Conky-specific. The rename is not meant to hide that fact. It is meant to make
the ownership and role of the project clearer:

- `gtex62-core` is the personal foundation for gtex62 desktop suites.
- It currently targets Conky as the runtime surface.
- It is not part of Conky, affiliated with Conky, or a fork/extension of the
  Conky project.

The project name should emphasize the gtex62 foundation. The documentation can
state the Conky runtime dependency directly.

## Target Naming

### Core

`gtex62-core`

Role:
- shared Lua/Conky foundation
- path resolution
- cache and runtime conventions
- suite discovery and registration
- launch orchestration
- shared collectors
- normalized shared data
- common Lua helpers and drawing primitives where they are truly shared

Suggested description:

```text
gtex62-core is the shared Lua/Conky foundation for gtex62 desktop suites.
```

Relationship statement:

```text
Built for Conky; not affiliated with or part of the Conky project.
```

### Portal

`gtex62-portal`

Role:
- user-facing entry point for all gtex62 suites
- terminal-first launcher at the beginning
- stable command surface for future TUI or GUI frontends

Initial behavior can stay close to the existing `startconky` workflow, but the
command shape should be designed as a portal from the start.

Suggested command model:

```sh
gtex62-portal
gtex62-portal list
gtex62-portal start osa
gtex62-portal stop osa
gtex62-portal restart osa
gtex62-portal status
gtex62-portal logs osa
gtex62-portal config osa
```

Default interactive behavior is acceptable:

```sh
gtex62-portal
```

can open a simple terminal menu, while subcommands remain available for scripts,
future TUI screens, and future GUI actions.

## Naming Set

Target ecosystem names:

```text
gtex62-core         Shared Lua/Conky foundation
gtex62-portal       Suite launcher and control surface
gtex62-osa          OSA desktop suite
gtex62-clean-suite  Existing standalone/legacy suite
```

This keeps Conky out of the project identity while still allowing the docs to
be explicit about the runtime dependency.

## Why Not `gtex62-conky-core`

`gtex62-conky-core` is technically accurate, but it still makes Conky part of
the identity. The concern with the current name is not only length; it can read
as if the project is part of Conky's own work, an official extension, or a fork.

`gtex62-core` communicates the intended boundary more clearly:

- gtex62 owns the foundation.
- Conky is the current runtime target.
- Suites are the user-facing products built on top.

## Migration Principles

The rename should be handled as a compatibility migration, not as a blind search
and replace.

Principles:
- Do not break working suites unnecessarily.
- Update public identity before deleting old paths.
- Keep temporary compatibility shims for old paths and environment variables.
- Prefer a staged migration with clear verification after each phase.
- Keep the suite contract stable while paths and names change.

## Rename Scope

Expected areas to update:

- repository and directory names
- docs titles and references
- installer scripts
- launcher scripts
- suite manifests
- suite registration paths
- cache, config, and data roots
- environment variable names
- shell scripts
- Lua path resolvers
- README badges or project metadata
- release notes
- service, cron, or autostart entries if present

Expected references to audit:

```text
gtex62-conky-engine
gtex62-conky
GTEX62_CONKY_ENGINE_DIR
GTEX62_CONKY_CONFIG_DIR
GTEX62_CONKY_DATA_DIR
GTEX62_CONKY_CACHE_DIR
GTEX62_CONKY_SUITES_DIR
~/.config/gtex62-conky
~/.local/share/gtex62-conky
~/.cache/gtex62-conky
```

## Proposed Target Paths

The exact paths can be finalized during implementation, but the likely target
model is:

```text
~/.config/conky/gtex62-core/       repo checkout or local project root
~/.config/gtex62-core/             user configuration
~/.local/share/gtex62-core/        persistent runtime state
~/.cache/gtex62-core/              regeneratable cache data
~/.config/conky/gtex62-shared-assets/
```

The shared assets path can remain unchanged unless a broader asset rename is
needed later.

## Proposed Environment Variables

New names:

```text
GTEX62_CORE_DIR
GTEX62_CONFIG_DIR
GTEX62_DATA_DIR
GTEX62_CACHE_DIR
GTEX62_SUITES_DIR
GTEX62_PORTAL_DIR
```

Compatibility aliases during migration:

```text
GTEX62_CONKY_ENGINE_DIR -> GTEX62_CORE_DIR
GTEX62_CONKY_CONFIG_DIR -> GTEX62_CONFIG_DIR
GTEX62_CONKY_DATA_DIR   -> GTEX62_DATA_DIR
GTEX62_CONKY_CACHE_DIR  -> GTEX62_CACHE_DIR
GTEX62_CONKY_SUITES_DIR -> GTEX62_SUITES_DIR
```

During the transition, new variables should win when both old and new variables
are set. Old variables should emit a warning only in interactive or diagnostic
contexts, not during high-frequency Conky render loops.

## Implementation Phases

### Phase 1: Inventory

Build a complete reference map before changing behavior.

Tasks:
- search all repos for old project names and paths
- classify references as docs, code, config, installer, cache, or runtime
- identify launchers and autostart entries
- identify suite contracts that mention the engine by name
- record current cache/config/data locations

Suggested searches:

```sh
rg "gtex62-conky-engine|gtex62-conky|GTEX62_CONKY|startconky"
rg "\.cache/gtex62-conky|\.config/gtex62-conky|\.local/share/gtex62-conky"
```

### Phase 2: Docs and Identity

Update documentation before moving code.

Tasks:
- describe `gtex62-core` as the shared Lua/Conky foundation
- describe `gtex62-portal` as the suite launcher and control surface
- add the Conky relationship statement
- update architecture docs to separate project identity from runtime target
- add release or migration notes

### Phase 3: Path Resolver Compatibility

Update the central path resolver first.

Tasks:
- add support for new `GTEX62_*` variables
- keep support for old `GTEX62_CONKY_*` variables
- define precedence explicitly
- make all scripts use the resolver instead of hardcoded paths
- add diagnostics that can show resolved paths

Precedence:

1. new environment variables
2. old compatibility environment variables
3. suite config
4. new defaults
5. old fallback paths if needed

### Phase 4: Portal Command

Introduce `gtex62-portal` as the stable entry point.

Tasks:
- wrap or replace the current `startconky` behavior
- provide scriptable subcommands
- keep the default command usable as a terminal menu
- ensure suite launch goes through the same backend path as subcommands
- keep old launcher names as wrappers during transition

Initial subcommands:

```text
list
start <suite>
stop <suite>
restart <suite>
status
logs <suite>
config <suite>
doctor
```

### Phase 5: Repository and Directory Rename

After compatibility exists, rename the project.

Tasks:
- rename checkout directory from `gtex62-conky-engine` to `gtex62-core`
- update local symlinks or wrappers for old paths
- update suite references
- update install scripts
- update docs links
- update repo metadata if this is published

Temporary compatibility option:

```text
~/.config/conky/gtex62-conky-engine -> ~/.config/conky/gtex62-core
```

### Phase 6: Cache and State Migration

Move runtime locations after the code can read both old and new locations.

Tasks:
- create new config, data, and cache roots
- migrate persistent state where needed
- leave regeneratable cache behind or rebuild it
- make migration idempotent
- log what moved and what was skipped

Cache can usually be regenerated. Persistent state and suite registry data
should be migrated more carefully.

### Phase 7: Cleanup

Remove compatibility only after enough time has passed.

Tasks:
- remove old wrappers
- remove old environment variable aliases
- remove old path fallbacks
- update docs to mark the migration complete
- keep a short historical note for users upgrading old installs

## Verification Checklist

Before calling the rename complete:

- `gtex62-portal list` finds installed suites
- `gtex62-portal start osa` launches OSA
- `gtex62-portal stop osa` stops OSA cleanly
- `gtex62-portal restart osa` works repeatedly
- `gtex62-portal status` reports running state
- old launcher wrapper still works during compatibility period
- old environment variables still resolve during compatibility period
- new environment variables take precedence
- cache writes go to the expected new location
- suite-specific data still lands under the suite namespace
- docs no longer present `gtex62-conky-engine` as the future identity

## Documentation Tone

Use this wording pattern:

```text
gtex62-core is the shared Lua/Conky foundation for gtex62 desktop suites.
```

Avoid wording that makes the project sound official to Conky:

```text
Conky engine
Conky platform
Conky extension
Conky fork
```

When the runtime must be named, use direct dependency language:

```text
This project targets Conky as its current rendering/runtime surface.
```

## Current Decision

The preferred future naming is:

```text
gtex62-core
gtex62-portal
```

No code has been renamed yet by this document. It records the direction and the
safe sequence for performing the change later.
