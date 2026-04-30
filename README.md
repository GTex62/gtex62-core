# gtex62-core

Shared Lua/Conky foundation for core-native gtex62 desktop suites.

Built for Conky; not affiliated with or part of the Conky project.

## Table of Contents

- [Purpose](#purpose)
- [Repository Boundary](#repository-boundary)
- [Runtime Roots](#runtime-roots)
- [Configuration Model](#configuration-model)
- [Provider Model](#provider-model)
- [Bootstrap and Launch](#bootstrap-and-launch)
- [Shared Assets](#shared-assets)
- [Core-Native Suite Template](#core-native-suite-template)
- [Repository Layout](#repository-layout)
- [Docs](#docs)

## Purpose

`gtex62-core` is the common engine layer for new gtex62 Conky suites. It owns
the runtime conventions and shared data contracts so each suite can focus on
presentation instead of carrying duplicate providers, config examples, cache
helpers, fonts, and local setup files.

The first native consumer is [`gtex62-osa`](../gtex62-osa/README.md). OSA is the
reference suite for this model and should be used as the practical example for
future engine-driven suites.

## Repository Boundary

Core-owned concerns:

- runtime/config/cache root conventions
- runtime bootstrap templates
- suite launch and profile orchestration
- shared provider scripts
- normalized shared cache schemas
- common Lua helpers
- reusable diagnostics and status files
- conversion architecture for future core-native suites

Suite-owned concerns:

- visual identity
- panel composition
- theme and layout files
- suite-specific Lua drawing code
- suite-specific derived view models over engine cache
- Conky widget entrypoints
- suite-level documentation and visual references

Shared asset concerns:

- fonts
- wallpapers
- reusable icons
- shared data assets such as geo/coastline data

## Runtime Roots

Default engine roots:

```text
config  ~/.config/gtex62-core/
data    ~/.local/share/gtex62-core/
cache   ~/.cache/gtex62-core/
assets  ~/.config/conky/gtex62-shared-assets/
```

Suite repos remain under:

```text
~/.config/conky/<suite-name>/
```

Preferred environment variables:

- `GTEX62_CONFIG_DIR`
- `GTEX62_CACHE_DIR`
- `GTEX62_CORE_DIR`
- `GTEX62_SHARED_ASSETS`
- `GTEX62_SUITE_ID`

Compatibility aliases such as `GTEX62_CONKY_CACHE_DIR` may still be exported so
converted helpers keep working during the transition.

## Configuration Model

New users should normally edit one file first:

```text
~/.config/gtex62-core/site.toml
```

`site.toml` is the host/site-level source of truth for values shared by
multiple suites and providers:

- home location and timezone
- API keys
- network interface
- VLAN labels and hosts
- speedtest baseline/fallback tier
- aviation stations
- pfSense SSH target and interface mapping

Domain profiles live under:

```text
~/.config/gtex62-core/profiles/
```

Profiles are for per-domain overrides. They should inherit from `site.toml`
where practical so a new install does not require editing many files.

Suite bindings live under:

```text
~/.config/gtex62-core/suites/
```

For example, OSA uses:

```text
~/.config/gtex62-core/suites/osa.toml
```

## Provider Model

Providers write normalized cache below:

```text
~/.cache/gtex62-core/shared/<domain>/<profile>/
```

Suites should read the shared cache and render their own compact view models.
Provider scripts should not live in suite repos unless the logic is truly
suite-specific.

Current provider domains include:

- `system`
- `time`
- `calendar`
- `astro`
- `weather`
- `aviation`
- `air`
- `solar`
- `network`
- `connectivity`
- `pfsense`

Provider status files use the same basic shape:

```json
{
  "state": "ok",
  "profile": "local",
  "collector": "system",
  "generated_at": "2026-04-30T00:00:00Z",
  "note": ""
}
```

Suites can surface those status files inline instead of dedicating a whole
doctor widget to normal operation.

## Bootstrap and Launch

Runtime templates live in:

```text
examples/runtime/
```

Bootstrap helper:

```bash
bin/gtex62-core-bootstrap-runtime
```

Suite wrappers can delegate to it. OSA does this from:

```text
gtex62-osa/scripts/bootstrap-runtime-root.sh
```

Core launcher:

```bash
bin/gtex62-core-launch --suite <suite_id>
```

Suite `start-conky.sh` scripts should prepare suite-specific environment
values, optionally apply wallpaper/theme choices, and then hand off to the core
launcher.

## Shared Assets

Shared binary and data assets belong in:

```text
~/.config/conky/gtex62-shared-assets/
```

Expected subdirectories:

```text
fonts/
icons/
wallpapers/
data/
```

Suites should reference shared assets through `suite.toml` and the
`GTEX62_SHARED_ASSETS` environment variable rather than carrying duplicate
`assets/`, `fonts/`, or `wallpapers/` trees.

## Core-Native Suite Template

A core-native suite should generally look like this:

```text
gtex62-example-suite/
├── suite.toml
├── README.md
├── design/
├── docs/
├── lua/
│   ├── suite/
│   ├── ui/
│   └── widgets/
├── scripts/
├── theme/
└── widgets/
```

Suite README responsibilities:

- describe the visible suite and panel/widget map
- list suite entrypoints
- document suite-owned customization files
- link to this core README for runtime/config/provider behavior
- document only suite-specific troubleshooting

Core README responsibilities:

- runtime roots
- `site.toml` and profile model
- provider/cache contracts
- bootstrap/launcher behavior
- conversion rules for future suites

Avoid in new suite repos:

- `legacy/config/`
- provider scripts duplicated from core
- runtime `examples/`
- local copies of shared fonts, wallpapers, icons, or shared data assets
- large architecture sections copied from core docs

## Repository Layout

```text
gtex62-core/
├── bin/          # bootstrap and suite launcher entrypoints
├── docs/         # architecture, schemas, migration notes
├── examples/     # runtime templates copied into ~/.config/gtex62-core
├── lua/          # common Lua helpers
└── providers/    # shared provider scripts by domain
```

## Docs

- [Architecture](docs/architecture.md)
- [Next Generation Model](docs/next-generation-model.md)
- [Core-Driven Suite Notes](docs/core-driven-suite-notes.md)
- [gtex62 Core Rename Roadmap](docs/gtex62-core-rename-roadmap.md)
- [V1 Audit and OSA Contract](docs/v1-audit-and-osa-contract.md)
- [System Schema](docs/system-schema.md)
- [Astro Schema](docs/astro-schema.md)

OSA-specific render/cache notes live in the OSA repo:

- [gtex62-osa README](../gtex62-osa/README.md)
- [OSA Docs](../gtex62-osa/docs/README.md)
