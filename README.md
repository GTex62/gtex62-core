# gtex62-conky-engine

Shared runtime and provider engine for engine-native Conky suites.

## Purpose

The engine owns shared runtime behavior and normalized data contracts for
engine-native Conky suites. Suites consume the engine and keep ownership of
presentation, layout, theme, and suite-specific derived view models.

Current implementation scope:

- shared Lua runtime helpers
- suite launch/runtime patterns
- future provider and launcher ownership

The first shared helper extracted into the engine is the runtime window
resolver used by `gtex62-osa`.

## Repository Boundary

Engine-owned concerns:

- shared provider logic
- normalized cache schemas
- runtime/config/cache root conventions
- launch and profile orchestration
- common Lua helpers
- conversion architecture for future engine-native suites

Suite-owned concerns:

- visual identity
- panel composition
- theme and layout files
- suite-specific assets
- suite-derived compact cache/view models
- Conky widget entrypoints

## Runtime Roots

Expected engine-era runtime roots:

- config: `~/.config/gtex62-conky/`
- data: `~/.local/share/gtex62-conky/`
- cache: `~/.cache/gtex62-conky/`

Expected suite repo roots remain under:

- `~/.config/conky/<suite-name>/`

Expected shared binary asset root:

- `~/.config/conky/gtex62-shared-assets/`

Legacy suites stay intact. Converted legacy suites should be created as sibling
engine-native suites, commonly using the `-engine` suffix when a legacy original
must coexist with its converted version.

## Docs

- [Architecture](docs/architecture.md)
- [Next Generation Model](docs/next-generation-model.md)
- [Engine-Driven Suite Notes](docs/engine-driven-suite-notes.md)
- [V1 Audit and OSA Contract](docs/v1-audit-and-osa-contract.md)
- [System Schema](docs/system-schema.md)
- [Astro Schema](docs/astro-schema.md)

`gtex62-osa` remains the first native suite and the reference consumer for the
initial engine contract. OSA-specific render/cache notes live in the OSA repo.
