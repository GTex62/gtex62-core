# Comcast Outage — Observations (Aug 31, 2026)

Live observations captured across `gtex62-sitrep` and OSA (`gtex62-osa`) panels during an
intermittent Comcast outage, roughly `11:45Z`–`16:40Z+` on 2026-08-31. Originally kept as
a raw scratch file (`docs/SitRep_OSA_Issues_2026_08_31.txt`) for easy access during the
incident; extracted here, same `-provider-status.md`-family dated-incident shape as
[Aviation Provider Status](aviation-provider-status.md)'s "Aug 31, 2026 — TAF stuck-data
incident" section, because these observations span multiple domains and both repos rather
than fitting inside any one provider's own doc.

---

## Resolved — Not Carried Forward

- **WXR TAF stuck at `140251Z`, 17–18 days stale.** This is the exact incident
  [Aviation Provider Status](aviation-provider-status.md)'s "Aug 31, 2026 — TAF stuck-data
  incident" section root-caused and fixed the same day (aviationweather.gov rejecting the
  `hours=0&sep=true` query params with HTTP 400). Full writeup lives there, not repeated
  here.
- **ORB panel unchanged all day** (`DATA // NOMINAL`, `EPHEMERIS // ACTIVE`). Expected —
  ephemeris positions don't need outage-time refresh to stay valid; not a bug.
- **ENV panel going `DATA // STALE - AIR CACHE`, `SRC` showing derived (`DRV`) solar.**
  Expected given `air`'s 900s TTL and no internet to refresh it, and `solar`'s synthetic
  fallback when Open-Meteo is unreachable — see
  [ENV Provider Status](env-provider-status.md). Not a bug.

---

## Open Questions

Filed as GitHub issues (2026-09-09) rather than tracked as prose here — this section just
points at them. Full original context for each is above and in the timeline below.

| # | Issue | Domain | Repo |
| --- | --- | --- | --- |
| 1 | [pfSense VPN totals dropped to 0.00 during outage — expected or bug?](https://github.com/GTex62/gtex62-core/issues/1) | `vpn` / `pfsense` | core |
| 2 | [NET panel: WAN IP field shows garbled/concatenated digits instead of blanking](https://github.com/GTex62/gtex62-osa/issues/1) | NET panel | osa |
| 3 | [DOCSIS status flapping between IN PROGRESS / NO DATA / NOMINAL](https://github.com/GTex62/gtex62-core/issues/2) | `modem` | core |
| 4 | [Alert Banner cleared while VPN status stayed DEAD](https://github.com/GTex62/gtex62-core/issues/3) | `alerts` / `vpn` | core |
| 5 | [MTR (PI5) RUNNING status line — clarify resolution/clear conditions](https://github.com/GTex62/gtex62-core/issues/4) | `mtr` | core |
| 6 | [NET panel: MTR (PI5) status line should sit at end of CM1000 column](https://github.com/GTex62/gtex62-osa/issues/2) | NET panel layout | osa |

Issue #3 (DOCSIS flapping) also carries the note that the `DOC STATE` alert line was
separately flagged as feeling redundant next to wherever DOCSIS status is otherwise
surfaced on the panel — see that issue for the full observation.

---

## Observed Timeline (condensed, approximate times)

- `~11:45Z` — Outage begins.
- `@13:00Z` — ENV panel: `DATA // STALE - AIR CACHE`. WXR/ORB still `NOMINAL`.
- `@13:30Z` — WXR panel: `DATA // STALE`. DOCSIS: `NO DATA` (from `IN PROGRESS`).
- `@13:59Z` — Network back online (pages load). DOCSIS still `NO DATA`. WXR `DATA` back to
  `NOMINAL` despite `SRC`/`MTR`/`TAF` timestamps not having changed. ENV still
  `STALE - AIR CACHE`. NET panel WAN IP briefly correct (single `-`).
- `@14:04Z` — Connection intermittent. MTR (PI5) at `2H 08M`, still running correctly.
- `@14:14Z` — Back online. DOCSIS `IN PROGRESS`. VPN connected, pings good.
- `@14:18Z`–`@14:21Z` — Intermittent again; DOCSIS `NO DATA`.
- `@14:30Z` — Intermittent. WXR `AVT` MTR field updated to `13:54Z` (TAF still frozen at
  `02:51Z` — this is the already-resolved TAF incident, see above). WAN IP garbled again.
- `@15:04Z` — DOCSIS `NOMINAL`, pings ~60ms/~25ms.
- `@15:11Z` — Dropped again. DOCSIS `NOMINAL` but no pings, VPN `DEAD`.
- `@15:50Z` — Stable, pings ~21ms both targets.
- `@16:40Z` — Comcast down again (log ends here).
