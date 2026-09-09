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

Unresolved as of this doc. No fix proposed here — filed as observations for whoever picks
each one up.

### 1. pfSense VPN totals dropped to 0.00 during the outage — by design?

Observed in the SitRep pfSense panel. Not investigated — no `vpn` domain field
documenting expected behavior on WAN loss was found in
[pfSense Provider Status](pfsense-provider-status.md) while writing this doc. Core
(`vpn`/`pfsense` domains).

### 2. OSA NET panel: WAN IP field shows garbled/concatenated digits instead of blanking

First occurrence: `108.67.222.222  53:` then cut off by the table column edge, while the
connection was down (should show nothing, or a placeholder, for no connection). Second
occurrence later in the same outage (`@14:30Z`): "a scramble of numbers again — possibly a
concatenation of IP addresses." Between these, `@13:59Z`, it briefly rendered correctly as
a single `-`. Source of the garbled value (which cache field, and why it isn't clamped to
a valid-IP shape or blanked) not identified. OSA display bug
(`lua/suite/net.lua`/NET panel), core `net`/`connectivity` cache as the likely data
source.

### 3. DOCSIS status flapping between `IN PROGRESS` / `NO DATA` / `NOMINAL`

Cycled repeatedly across the outage window, sometimes contradicting the actual connection
state (e.g. `@13:59Z` internet was back up but DOCSIS still showed `NO DATA`). Looked like
it might just be landing on different points of a refresh cycle each observation, but not
confirmed against the `modem` provider's actual polling/state logic. Core `modem` domain.

### 4. Alert Banner cleared while VPN status stayed DEAD/fluctuating

The "KS Blocking Traffic" banner cleared even though VPN status remained `DEAD` (observed
fluctuating — possibly intermittently connecting and resolving, which may explain the
discrepancy, but not confirmed). Relationship between the `alerts` domain's banner logic
and the `vpn` domain's own state not traced. Core `alerts`/`vpn` domains.

### 5. MTR (PI5) "RUNNING" status line — how does it resolve?

`MTR (PI5) // RUNNING - <elapsed>` stayed active correctly through the outage (elapsed
time counted up properly: `0H 28M` → `2H 08M` across observations). Open question: does
it resolve only via the script's own kill-time, does a manual stop on the Pi5 also clear
it, and does the display side re-poll to confirm the script is actually still running (vs.
trusting a stale "started" marker)? Not traced against `mtr`'s actual trigger/kill logic —
`mtr` has no dedicated provider-status doc yet (see
[Architecture](architecture.md)'s provider listing). Core `mtr` domain.

### 6. Layout nit: MTR line position under the CM1000 column (low priority)

`MTR (PI5) // RUNNING - 00:28` is short enough to fit under the CM1000 column but appears
elsewhere in the list; should sit at the end of that column's rows instead. OSA display
positioning, not a data issue.

### Related, already-noted-as-redundant

`DOC STATE` alert (the DOCSIS state line itself) was independently flagged as feeling
redundant next to whatever surfaces DOCSIS status elsewhere on the panel — noted here in
case it's relevant context for whoever looks at #3, not filed as its own open question.

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
