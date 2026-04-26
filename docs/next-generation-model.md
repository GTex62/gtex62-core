# gtex62 Core Architecture (Next Generation)

## Overview

This document defines the next-generation architecture for gtex62 desktop
suites using a shared foundation model.

This approach coexists with existing ("legacy") standalone suites and does not require immediate migration.

The current implementation targets Conky. The preferred future project identity
is `gtex62-core`, not `gtex62-conky-engine`, so the name emphasizes the personal
foundation rather than implying affiliation with Conky.

---

## Generational Model

### Legacy Suites (Unchanged)

Existing suites remain as-is:

Location:
~/.config/conky/<suite-name>

Characteristics:
- Fully standalone
- Independent GitHub repositories
- No dependency on core
- Maintained as needed

---

### Core-Based Suites (New Architecture)

New suites use a shared core.

First suite:
gtex62-osa

Characteristics:
- Thin, modular design
- Shared backend via core
- Reduced duplication
- Easier long-term maintenance

---

## Core Concept

### Core (Foundation)

Responsible for:
- Data collection and normalization
- Cache management
- Path resolution
- Shared assets
- Runtime and portal integration
- Common Lua helpers and modules

---

### Suites (Profiles)

Responsible for:
- Layout (chassis)
- Theme and palette
- Module selection
- Conky configuration model
- Optional extended data

---

## Rule

Core defines how things work.
Suite defines how things look and where they go.

---

## Repository Strategy

### Core Repository
gtex62-core

Previous repository name:
gtex62-conky-engine

Relationship:
Built for Conky; not affiliated with or part of the Conky project.

### Portal Repository or Command
gtex62-portal

The portal is the user-facing entry point for listing, launching, stopping,
restarting, and inspecting suites. It can begin as a terminal command similar to
the existing `startconky` flow, while preserving a command interface that can
later support a TUI or GUI.

### Suite Repositories
gtex62-osa (first)
future suites follow same model

---

## Installation Model

### Recommended Flow

1. Install suite
2. Suite installer:
   - checks for core
   - installs core if missing
   - validates version
   - installs suite
3. Launch via portal/core

---

## Core Install Behavior

- Installed once
- Reused across suites
- Updated independently

---

## Suite Install Behavior

- Installed independently
- Does not reinstall core
- Registers with core

---

## Directory Model (Core Era)

### Config
~/.config/gtex62-core/

### Data (Persistent Runtime State)
~/.local/share/gtex62-core/

### Shared Binary Assets
~/.config/conky/gtex62-shared-assets/

### Cache
~/.cache/gtex62-core/

---

## Cache Structure

~/.cache/gtex62-core/

shared/
  weather/
  astro/
  system/
  network/
  air/
  firewall/

suites/
  osa/
  lcars/
  tri-hud/

runtime/
  locks/
  pids/
  stamps/

tmp/

---

## Cache Rules

Shared:
- reusable across suites

Suite:
- derived or specialized data

Runtime:
- operational state

Temp:
- safe to delete

---

## Data Model

### Layers

1. Raw
2. Normalized (shared)
3. Extended (suite-specific)

---

## Weather Example

shared/weather/raw/
shared/weather/common/
suites/osa/weather/
suites/lcars/weather/

---

## Asset Strategy

Assets are NOT stored in cache.

Stored in:
~/.config/conky/gtex62-shared-assets/

Includes:
- wallpapers
- icons
- fonts

---

## Path Resolution System

Centralized path system required.

### Default Paths

CONFIG  -> ~/.config/gtex62-core
DATA    -> ~/.local/share/gtex62-core
CACHE   -> ~/.cache/gtex62-core

---

### Environment Overrides

Users may override:

GTEX62_CORE_DIR
GTEX62_CONFIG_DIR
GTEX62_DATA_DIR
GTEX62_CACHE_DIR
GTEX62_SUITES_DIR

---

### Precedence

1. Environment variables
2. Suite config
3. Core defaults
4. XDG fallback

---

Compatibility aliases during migration:

GTEX62_CONKY_ENGINE_DIR
GTEX62_CONKY_CONFIG_DIR
GTEX62_CONKY_DATA_DIR
GTEX62_CONKY_CACHE_DIR
GTEX62_CONKY_SUITES_DIR

New variables should take precedence over old aliases.

---

## Core Path Layer

All scripts must use shared path resolver.

No hardcoded paths.

---

## Conky Layout Flexibility

Core does NOT enforce layout.

Supported:
- single conf
- dual conf
- multi-instance

---

## Portal Model

Core provides launch orchestration. `gtex62-portal` provides the user-facing
entry point.

Responsibilities:
- detect installed suites
- allow selection
- verify compatibility
- launch selected suite
- show status and logs
- provide scriptable commands for future TUI or GUI frontends

Suggested initial command model:

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

---

## Versioning

Each suite defines:

core_requirement: ">=1.0,<2.0"

Compatibility fields such as `engine_requirement` may be accepted during the
rename period.

---

## Migration Strategy

1. Leave legacy suites unchanged
2. Build core
3. Build first core suite (gtex62-osa)
4. Validate architecture
5. Optionally migrate older suites
6. Rename `gtex62-conky-engine` to `gtex62-core` with compatibility shims
7. Introduce `gtex62-portal` as the stable suite entry point

---

## Design Principles

- Do not break working systems
- Centralize shared logic
- Keep suites lightweight
- Support customization
- Prefer clarity over abstraction

---

## Summary

This architecture enables:

- clean separation of concerns
- shared backend across suites
- scalable multi-suite environment
- optional migration path

Legacy remains stable.
Core drives the future.
