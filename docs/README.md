# Core Docs

Reference documentation for the `gtex62-core` shared engine.

`gtex62-core` is the shared Lua/Conky foundation for gtex62 desktop suites.
It owns data collection, cache management, path resolution, and launch
orchestration. Suites own visual identity, layout, and rendering.

## Architecture

- [Architecture](architecture.md) — two-repo structure, provider pattern, cache layout, TTL table, design principles

## Provider Reference

- [Net Provider](net-provider.md) — state.vars and vlan.tsv formats, key reference, refresh model
- [Orb Provider](orb-provider.md) — ephemeris.vars format, per-body key reference, location resolution

## Schemas

- [System Schema](system-schema.md) — normalized system domain: current.json, processes.json, storage.json
- [Astro Schema](astro-schema.md) — normalized astro body schema: altitude, azimuth, rise/set, legacy theta

## Suite Conversion

- [Legacy Suite Conversion Guide](legacy-suite-conversion-guide.md) — phased guide for converting standalone suites to core-native

## Archive

Superseded planning and design documents are in [archive/](archive/).
