# Core Docs

Reference documentation for the `gtex62-core` shared engine.

`gtex62-core` is the shared Lua/Conky foundation for gtex62 desktop suites.
It owns data collection, cache management, path resolution, and launch
orchestration. Suites own visual identity, layout, and rendering.

## Architecture

- [Architecture](architecture.md) — two-repo structure, provider pattern, cache layout, TTL table, design principles

## Provider Reference

Per-provider implementation status: what's shipped, output schemas, configuration,
known constraints/quirks. Coverage across all 20 provider domains is uneven — see each
doc's own scope, and [Architecture](architecture.md)'s provider directory listing for
the full domain set including ones with no dedicated doc yet.

- [pfSense Provider Status](pfsense-provider-status.md) — current state of the core `pfsense` provider: domain schemas, gate-per-domain pattern, remaining work
- [AP Provider Status](ap-provider-status.md) — Zyxel access-point domain: auth/transport, MAC↔IP client join, MSMTCH mismatch detection
- [Weather Provider Status](weather-provider-status.md) — OpenWeather current conditions + forecast: schemas, known staleness-detection gap
- [Aviation Provider Status](aviation-provider-status.md) — METAR/TAF split-endpoint fetch, per-field degraded envelope, Aug 2026 TAF stuck-data incident
- [ENV Panel Provider Status](env-panel-provider-status.md) — `air` (OpenWeather + AirNow AQI/pollution) and `solar` (weather-derived UV/radiation) domains behind OSA's ENV/ATMOS panel: schemas, TTL-key mismatch between the two, `solar` status.json provider-field quirk
- [Net Provider](net-provider.md) — state.vars and vlan.tsv formats, key reference, refresh model
- [Orb Provider](orb-provider.md) — ephemeris.vars format, per-body key reference, location resolution
- [AirGradient Engine Integration](airgradient-engine-integration.md) — indoor AQI (`air` domain) design: collector/engine/display separation
- [Lyrics Library Design](lyrics-library-design.md) — `media` domain design: library-vs-cache distinction, write-through safety

## Schemas

- [System Schema](system-schema.md) — normalized system domain: current.json, processes.json, storage.json
- [Astro Schema](astro-schema.md) — normalized astro body schema: altitude, azimuth, rise/set, legacy theta

## Suite Conversion

- [Legacy Suite Conversion Guide](legacy-suite-conversion-guide.md) — phased guide for converting standalone suites to core-native
- [Core Launcher Design](core-launcher-design.md) — core-native launcher design for converted suites

## SitRep Migration

Split from one monolithic doc (`sitrep-engine-migration.md`, retired) into four, so
architecture, provider status, relocation mechanics, and unrelated roadmap items stop
mixing together. Full prose history predating the split is in
[archive/sitrep-engine-migration-2026-08-18.md](archive/sitrep-engine-migration-2026-08-18.md).
The relocation-mechanics doc of the four is itself now superseded — SitRep was built out
as its own sibling repo (`gtex62-sitrep`) rather than relocated into this engine as
planned — and has moved to [archive/sitrep-relocation-plan.md](archive/sitrep-relocation-plan.md)
as a historical record of the original approach.

- [SitRep Architecture](sitrep-architecture.md) — stable design: purpose, core principle, current/future data-flow diagrams, device inventory
- [Network Providers Roadmap](network-providers-roadmap.md) — vpn/modem (built) and network-health (not started), drafted together in one investigation session

## Changelog

- [CHANGELOG.md](../CHANGELOG.md) — dated entries per landed change; started covering only the pfSense/AP/VPN/modem family, now covers new work on any provider (see its own scope note)

## Archive

Superseded planning and design documents are in [archive/](archive/).
