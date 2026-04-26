# gtex62-core

Shared Lua/Conky foundation for gtex62 desktop suites.

Built for Conky; not affiliated with or part of the Conky project.

## Purpose

The core owns shared runtime behavior and normalized data contracts for
core-native Conky suites. Suites consume the core and keep ownership of
presentation, layout, theme, and suite-specific derived view models.

Current implementation scope:

- shared Lua runtime helpers
- suite launch/runtime patterns
- future provider and launcher ownership

The first shared helper extracted into the core is the runtime window
resolver used by `gtex62-osa`.

## Repository Boundary

Core-owned concerns:

- shared provider logic
- normalized cache schemas
- runtime/config/cache root conventions
- launch and profile orchestration
- common Lua helpers
- conversion architecture for future core-native suites

Suite-owned concerns:

- visual identity
- panel composition
- theme and layout files
- suite-specific assets
- suite-derived compact cache/view models
- Conky widget entrypoints

## Runtime Roots

Expected core-era runtime roots:

- config: `~/.config/gtex62-core/`
- data: `~/.local/share/gtex62-core/`
- cache: `~/.cache/gtex62-core/`

Expected suite repo roots remain under:

- `~/.config/conky/<suite-name>/`

Expected shared binary asset root:

- `~/.config/conky/gtex62-shared-assets/`

Legacy suites stay intact. Converted legacy suites should be created as sibling
core-native suites. Legacy suites can continue to coexist as standalone repos
while new suites target the shared core.

## Docs

- [Architecture](docs/architecture.md)
- [Next Generation Model](docs/next-generation-model.md)
- [Core-Driven Suite Notes](docs/core-driven-suite-notes.md)
- [gtex62 Core Rename Roadmap](docs/gtex62-core-rename-roadmap.md)
- [V1 Audit and OSA Contract](docs/v1-audit-and-osa-contract.md)
- [System Schema](docs/system-schema.md)
- [Astro Schema](docs/astro-schema.md)

`gtex62-osa` remains the first native suite and the reference consumer for the
initial core contract. OSA-specific render/cache notes live in the OSA repo.
