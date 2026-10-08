# Core Docs

Reference documentation for the `gtex62-core` shared engine.

`gtex62-core` is the shared Lua/Conky foundation for gtex62 desktop suites.
It owns data collection, cache management, path resolution, and launch
orchestration. Suites own visual identity, layout, and rendering.

## Architecture

- [Architecture](architecture.md) — two-repo structure, provider pattern, cache layout, TTL table, design principles

## Provider Reference

Per-provider implementation status: what's shipped, output schemas, configuration,
known constraints/quirks. Listed alphabetically by domain. Coverage across the engine's
22 provider domains (`airgradient` has no separate status page: its design document below is
also its status and schema reference) is uneven: `alerts` is covered inside [SitRep Architecture](sitrep-architecture.md)'s
"Alert Banner Watcher" section rather than a dedicated doc, and `doctor` has its own
section further down this page. `calendar`, `connectivity`, `mtr`, `network`, and `time`
have no written doc beyond their own script comments and [Doctor Missing
Conditions](doctor-missing-conditions.md)'s per-domain MISSING-condition notes —
investigated and judged not to warrant one (each is either trivial or its one real quirk
is already fully captured there). See [Architecture](architecture.md)'s provider
directory listing for the full domain set.

- [AirGradient Provider Design](airgradient-provider-design.md) — `airgradient` domain (its own domain, not part of `air`): indoor air quality over the device's local HTTP API, `status.json` schema, partial-payload handling, ENV-panel indoor view, wiring checklist; provider, advisor and OSA display implemented, shadow mode
- [Ventilation Advisor Design](ventilation-advisor-design.md) — engine-side open/close-windows verdict for the `airgradient` domain: rules, thresholds, tested reference code, acceptance test (fixtures in `tests/airgradient/fixtures/`); provider, advisor and OSA display implemented, shadow mode
- [ENV Provider Status](env-provider-status.md) — `air` (OpenWeather + AirNow AQI/pollution) and `solar` (weather-derived UV/radiation) domains behind OSA's ENV/ATMOS panel: schemas, TTL-key mismatch between the two, `solar` status.json provider-field quirk
- [AP Provider Status](ap-provider-status.md) — Zyxel access-point domain: auth/transport, MAC↔IP client join, MSMTCH mismatch detection
- [Astro Provider Status](astro-provider-status.md) — sun/moon/planet positions (a *different* domain from `orb` — see its own Scope section), promoted out of the former `astro-schema.md`
- [Aviation Provider Status](aviation-provider-status.md) — METAR/TAF split-endpoint fetch, per-field degraded envelope, Aug 2026 TAF stuck-data incident
- [GitHub Provider Status](github-provider-status.md) — personal-use traffic-stats domain: entirely systemd-timer-driven (outside the launcher's TTL mechanism), no `"degraded"` state (a known convention mismatch vs. weather/aviation/network)
- [Lyrics Library Design](lyrics-library-design.md) — `media` domain design: library-vs-cache distinction, write-through safety
- [MEDIA Event-Driven Refresh Design](media-event-driven-design.md) — `media` domain, draft: replacing MEDIA's poll with an MPRIS D-Bus listener; measurements, launcher-integration open questions, standing test-safety note
- [Bug: lyrics blank after a fetch when the library write fails](2026-09-20-lyrics-publish-then-searching-bug.md) — `media` domain; violates lyrics-library-design.md's "not a blank widget"; resolved
- [Bug: failed lyrics lookup cached as "not found" for 12 hours](2026-09-20-lyrics-failed-lookup-cached-as-miss-bug.md) — `media` domain; a timeout/5xx is recorded as a genuine miss; inherited from tech-hud; open
- [Modem Provider Status](modem-provider-status.md) — CM1000 HTTP-scrape domain: auth flow, DOCSIS event-log T3 undercount/clock-skew saga, burst-vs-trickle alerting, promoted out of [Network Providers Roadmap](network-providers-roadmap.md)
- [Net Provider Reference](net-provider-reference.md) — state.vars and vlan.tsv formats, key reference, refresh model
- [Orb Provider Reference](orb-provider-reference.md) — ephemeris.vars format, per-body key reference, location resolution
- [pfSense Provider Status](pfsense-provider-status.md) — current state of the core `pfsense` provider: domain schemas, gate-per-domain pattern, remaining work
- [System Provider Status](system-provider-status.md) — machine/OS truth (`current.json`/`processes.json`/`storage.json`/`status.json`), fast-lane/slow-lane split with OSA `SYS`, promoted out of the former `system-schema.md`
- [VPN Provider Status](vpn-provider-status.md) — PIA WireGuard domain: killswitch vs. killswitch_mode split, REKEY-AFTER-TIME-based health classification, promoted out of [Network Providers Roadmap](network-providers-roadmap.md)
- [Weather Provider Status](weather-provider-status.md) — OpenWeather current conditions + forecast: schemas, known staleness-detection gap

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
- [Network Providers Roadmap](network-providers-roadmap.md) — full investigation log behind `vpn`/`modem` (current state now in their own provider-status docs above) plus `network-health` (not started), drafted together in one investigation session

## Doctor

`gtex62-doctor` is a standalone suite, scaffolded the same way as `gtex62-sitrep` (own
repo, runs alongside another suite), that reports on the health of every `gtex62-core`
provider domain in one place. These docs stay in core rather than moving into that repo
because they describe core-owned state (provider metadata, TTLs, cache/toggle semantics)
that the doctor repo consumes, not anything specific to the doctor repo's own code —
same rationale as the SitRep docs above.

- [Doctor Design](doctor-design.md) — suite Doctor vs. core Doctor distinction, state vocabulary, reference implementations (tech-hud, tri-hud)
- [Doctor Missing Conditions](doctor-missing-conditions.md) — per-provider MISSING (and other non-OK NOTE tag) semantics, verified against real provider scripts
- [Doctor QRH](../../gtex62-doctor/docs/doctor-qrh.md) — full remediation procedures behind DCM's `PROC:` lines, one per condition (lives in the `gtex62-doctor` repo, beside the suite that renders it)

## Incident Logs

Dated observation logs spanning multiple domains/repos, too broad for any one provider's
own doc — same shape as the dated incident sections inside the `-provider-status.md` docs
above, split out standalone when a single incident touches several of them at once.

- [Comcast Outage Observations — Aug 31, 2026](2026-08-31-comcast-outage-observations.md) — live cross-panel/cross-repo notes from an intermittent outage; one item (WXR TAF stuck-data) resolved same-day and cross-referenced, six items filed as GitHub issues across both repos

## Changelog

- [CHANGELOG.md](../CHANGELOG.md) — dated entries per landed change; started covering only the pfSense/AP/VPN/modem family, now covers new work on any provider (see its own scope note)

## Archive

Superseded planning and design documents are in [archive/](archive/).
