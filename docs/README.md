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

## SitRep Migration

Split from one monolithic doc (`sitrep-engine-migration.md`, retired) into four, so
architecture, provider status, relocation mechanics, and unrelated roadmap items stop
mixing together. Full prose history predating the split is in
[archive/sitrep-engine-migration-2026-08-18.md](archive/sitrep-engine-migration-2026-08-18.md).

- [SitRep Architecture](sitrep-architecture.md) — stable design: purpose, core principle, current/future data-flow diagrams, device inventory
- [pfSense Provider Status](pfsense-provider-status.md) — current state of the core `pfsense` provider: domain schemas, gate-per-domain pattern, remaining work
- [SitRep Relocation Plan](sitrep-relocation-plan.md) — moving `sitrep.lua` out of `gtex62-tech-hud` into the engine: Part 0 audit, blocker, resume checklist, guardrails
- [Network Providers Roadmap](network-providers-roadmap.md) — unrelated proposed providers (VPN, WAN health, modem) drafted alongside the above, not started

## Archive

Superseded planning and design documents are in [archive/](archive/).
