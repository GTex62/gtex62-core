# gtex62 Core Architecture

## Overview

This document defines a structured approach for converting multiple standalone
Conky suites into a single core-driven, multi-suite environment. The goal is to
reduce duplication, improve maintainability, and standardize data handling while
preserving flexibility for unique suite designs.

---

## Core Concept

Separate the system into two layers:

### Core (Foundation)

Responsible for:

- Data collection and normalization
- Cache management
- Shared assets
- Runtime and launch logic
- Common Lua helpers and modules
- Documentation framework

### Suites (Profiles / Skins)

Responsible for:

- Visual identity (themes, colors, fonts)
- Layout and chassis (Lua)
- Module selection
- Conky configuration structure (single/multi instance)
- Suite-specific data extensions

**Rule:** Core defines how things work. Suites define how things look and where they go.

---

## Directory Structure

### Core Root

```
core/
  bin/
  lib/
  providers/
  lua/
  modules/
  assets/
  docs/
```

### Suites

```
suites/
  lcars/
  tri-hud/
  tech-hud/
```

Each suite contains:

```
suite.conf
conky/
lua/
assets/
docs/
```

---

## Data Architecture

### Data Layers

1. Raw Data — direct API responses (e.g., OpenWeather)
2. Normalized (Shared) — standardized JSON usable by all suites
3. Derived (Suite-Specific) — enhanced or transformed data for specific suites

---

## Weather Example

```
shared/weather/raw/owm.json
shared/weather/common/weather_common.json
suites/lcars/weather/weather_extended.json
```

### Design Principle

- Shared layer is stable and minimal
- Suite layer adds complexity without breaking others

---

## Cache Architecture

### Root

```
~/.cache/gtex62-core/
```

### Structure

```
shared/
  weather/
  astro/
  system/
  network/
  connectivity/
  air/
  solar/
  aviation/
  pfsense/
  net/
  orb/

suites/
  lcars/
  tri-hud/
  tech-hud/

runtime/
  locks/
  pids/
  stamps/

tmp/
```

---

## Cache Rules

### Shared Cache

Used by multiple suites:

- Normalized weather
- System snapshots
- Astronomy data
- Network and connectivity state
- Ephemeris and planet positions (orb)
- Fast-refresh net display cache

### Suite Cache

Used by a single suite:

- LCARS extended weather
- Suite-specific rendering data

### Runtime

- Locks
- PIDs
- Timestamp markers

### Temporary

- Safe to delete

---

## Naming Conventions

### Directory Naming

Based on data domain, not script name.

Good:

```
weather/common/
network/pfsense/
```

Bad:

```
conver_dyn/
ap/
```

### File Naming

```
current.json
forecast.json
normalized.json
extended.json
status.json
snapshot.json
```

---

## Asset Strategy

### Shared Assets

```
~/.config/conky/gtex62-shared-assets/
  wallpapers/
  icons/
  fonts/
```

### Rules

- Cache only generated assets
- Store source assets outside cache

---

## Configuration Model

Each suite defines a suite.conf:

```yaml
suite_name: lcars

assets:
  wallpaper_dir: shared
  icons: shared

weather:
  provider: owm
  profile: lcars_extended
  cache_mode: shared_plus_suite

launch:
  conky_instances:
    - conky/main.conf
    - conky/side.conf
```

---

## Provider Model

```
providers/
  weather/
  astro/
  system/
  network/
  net/
  orb/
```

Each provider:

- Fetches raw data
- Produces normalized output
- Optionally produces extended output

---

## Conky Layout Flexibility

The core does NOT enforce layout.

Supported patterns:

- Single config (tri-hud)
- Dual config (LCARS)
- Multi-widget configs (tech-hud)

Suite controls:

```yaml
launch:
  conky_instances: [...]
```

---

## Migration Strategy

### Phase 1

Identify shared components: scripts, cache files, Lua helpers.

### Phase 2

Move shared logic into core.

### Phase 3

Normalize cache structure.

### Phase 4

Convert one suite (pilot).

### Phase 5

Convert remaining suites.

---

## Classification Model

For each file or script:

1. Always shared
2. Shared but extensible
3. Suite-specific

---

## Risk Management

### Avoid Over-Coupling

- Do not hardcode suite logic into core scripts

### Avoid Over-Abstraction

- Keep layouts explicit
- Avoid unnecessary frameworks

### Keep Interfaces Stable

- Shared JSON formats must remain consistent

---

## Design Principles

- Common where stable
- Specialized where necessary
- Keep cache deterministic and organized
- Separate data, presentation, and runtime
- Prefer clarity over cleverness

---

## Recommended System Layout

```
~/.config/gtex62-core/       — user configuration
~/.local/share/gtex62-core/  — persistent runtime state
~/.cache/gtex62-core/        — regeneratable data
~/.config/conky/gtex62-shared-assets/  — shared binary assets
```

---

## Summary

This architecture enables:

- Reduced duplication
- Cleaner cache structure
- Easier maintenance
- Faster development of new suites
- Consistent data handling

While preserving:

- Unique visual identities
- Flexible layout models
- Suite-specific enhancements
