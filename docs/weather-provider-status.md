# Weather Provider Status

Current implementation state of the core `weather` provider: script location, output
schemas, configuration, and known constraints. Written retroactively (Aug 31, 2026) to
close a provider-documentation coverage gap identified across `docs/` — `weather` shipped
as part of the initial engine baseline (April 2026) and had never had its own doc. This
follows the same `-provider-status.md` structure used by
[pfSense Provider Status](pfsense-provider-status.md) and
[AP Provider Status](ap-provider-status.md), rather than inventing a new shape.

Companion docs: [Architecture](architecture.md) (provider pattern, cache layout, TTL
table — weather's row there was the only prior mention this domain had),
[Aviation Provider Status](aviation-provider-status.md) (sibling atmospheric-data domain,
same `current.json`-plus-`status.json` cache shape, written the same session — its Known
Quirks / History section is what this domain's own per-field staleness fix, below, was
ported from).

---

## Implementation Status

### `providers/weather/fetch_openweather.sh` ✓ COMPLETE (last touched Aug 31, 2026)

OpenWeather-sourced current conditions + 6-day daily forecast for the OSA/SitRep WXR
panel family. Structurally simple relative to the pfSense/aviation domains — no SSH, no
gate, no circuit breaker: a plain `curl` against a public REST API, gated only by a TTL
check. Implements:

- Profile/site TOML resolution chain for lat/lon, units, language, API key
  (`profiles/weather/{profile}.toml`, falling back to `site.toml`'s
  `[location.home]`/`[credentials]` sections)
- Independent TTL check before each of two HTTP calls (current and forecast each have
  their own `is_fresh` check against their own raw cache file, though both currently
  share one `cache_ttl_sec` value — see Known Constraints)
- Two upstream endpoints: OpenWeather's `/data/2.5/weather` (current) and
  `/data/2.5/forecast` (3-hourly, reduced to one row per day)
- Response-shape validation before caching (`jq -e '.weather and .main and .wind and
  .clouds'` for current, `.list and .city` for forecast) — a malformed/empty response is
  discarded, not cached
- No SSH gate/circuit-breaker — the sole failure signal is `curl -fsS --max-time 8`'s
  exit code
- **Per-field state tracking (`CURRENT_STATE`/`FORECAST_STATE`) feeding a degraded
  envelope** (Aug 31, 2026 — see Known Quirks / History below), same convention as
  [Aviation Provider Status](aviation-provider-status.md)'s `metar`/`taf` sub-objects
- Output to `shared/weather/{profile}/current.json`,
  `shared/weather/{profile}/forecast_daily.json`, and
  `shared/weather/{profile}/status.json`

### Naming Convention Exception

The script is `fetch_openweather.sh`, not `fetch_weather.sh` — a deliberate divergence
from [Architecture](architecture.md)'s stated `providers/<domain>/fetch_<domain>.sh`
pattern, previously undocumented anywhere. `provider` is a first-class field in both
`status.json` and `current.json` (currently always `"openweather"`, sourced from the
profile TOML's `provider` key, default `openweather`) — the naming suggests the intent
was to allow a second `weather`-domain source living under the same `providers/weather/`
directory (e.g. an NWS-sourced script) without a filename collision, though no second
source exists today and nothing else in the codebase reads or branches on `provider`.
Documented here as intentional-by-convention, not drift — but not verified against the
original author intent; see Remaining Work.

---

## Output Schemas

### status.json

`shared/weather/{profile}/status.json` — written by `fetch_openweather.sh`.

```json
{
  "state": "degraded",
  "profile": "home",
  "provider": "openweather",
  "generated_at": "2026-08-31T14:23:00Z",
  "provider_updated_at": "2026-08-31T14:20:00Z",
  "note": "forecast fetch failing; serving cached data from 2026-08-30T09:12:04Z",
  "current": {
    "state": "ok",
    "last_ok": "2026-08-31T14:20:00Z",
    "age_seconds": 180
  },
  "forecast": {
    "state": "error",
    "last_ok": "2026-08-30T09:12:04Z",
    "age_seconds": 105776
  }
}
```

Flatter than the pfSense-family envelope (`profile`/`collector`/`generated_at` there vs.
`profile`/`provider`/`generated_at` here — no `collector` key, no `ssh_gate` object,
since there's no SSH/gate to report on). `provider_updated_at` is the upstream
observation timestamp (OpenWeather's own `dt` field, current-conditions payload only) —
distinct from `generated_at`, which is always this script's own wall-clock run time.

**Per-field sub-objects (`current`/`forecast`)** — `state`/`last_ok`/`age_seconds`, added
Aug 31, 2026 (see Known Quirks / History below), mirroring
[Aviation Provider Status](aviation-provider-status.md)'s `metar`/`taf` shape exactly:
each is derived from that field's own raw cache file's mtime
(`raw_current.json`/`raw_forecast.json`), not a separately tracked timestamp. Same two
subtleties as aviation's fields apply here: `state` reflects only *this run's* fetch
attempt (stays `"ok"` without an attempt when the field's own TTL hasn't expired, telling
you nothing about the data's actual age — that's what `age_seconds` is for); `last_ok`/
`age_seconds` always reflect the raw file's mtime regardless of whether a fetch was
attempted this run, so a field can show `state: "error"` while `last_ok` points at a much
older successful fetch. `null`/`null` when no raw file exists at all (true cold start).
These sub-objects are **only present in the `"ok"`/`"degraded"` path** — the early-exit
stub states (`"disabled"`, and the total-failure `"error"` case below) write the flatter,
original envelope shape with no `current`/`forecast` keys, matching aviation's
`write_status()`-vs-full-envelope split.

#### State Field Values

| Value | Meaning |
| --- | --- |
| `"ok"` | Both `current` and `forecast` fetches (or TTL-skips) succeeded/are fresh this run |
| `"degraded"` | Exactly one of `current`/`forecast` failed this run; the other is fine. `note` names which field and, when available, since when (`last_ok`) — added Aug 31, 2026, same modem/vpn-derived convention as aviation's degraded state |
| `"disabled"` | Profile has `enabled = false` in TOML |
| `"error"` | Missing profile TOML, missing credentials/coordinates, or **no raw cache file exists yet for either field** (cold start where both current and forecast failed their first-ever fetch) — no `current`/`forecast` sub-objects in this case, no output written beyond the status stub |

Before Aug 31, 2026, this domain had no `"degraded"` state and no per-field sub-objects
at all — see Known Quirks / History for what that gap looked like in practice and why it
was fixed the same session it was found.

### current.json

`shared/weather/{profile}/current.json` — written by `fetch_openweather.sh`, sourced
from OpenWeather's `/data/2.5/weather`.

```json
{
  "profile": "home",
  "provider": "openweather",
  "generated_at": "2026-08-31T14:23:00Z",
  "provider_updated_at": "2026-08-31T14:20:00Z",
  "location": {
    "name": "Cordova",
    "lat": 35.15,
    "lon": -89.75,
    "timezone": "America/Chicago"
  },
  "temp_f": 91.4,
  "humidity_pct": 58,
  "pressure_hpa": 1015,
  "cloud_percent": 40,
  "wind_deg": 210,
  "wind_mph": 6.9,
  "wx_code": 802,
  "icon": "03d",
  "description": "scattered clouds"
}
```

`wx_code` is OpenWeather's own condition-ID space (200s thunderstorm, 300s drizzle, 500s
rain, 600s snow, 700s atmosphere, 800s clear/clouds, 900s extreme) — passed through
unmapped; any icon/label mapping is a display-side concern. All numeric fields
(`temp_f`/`humidity_pct`/`pressure_hpa`/`cloud_percent`/`wind_deg`/`wind_mph`/`wx_code`)
are `jq`'s `empty` (key omitted from the JSON entirely, not `null`) if the corresponding
upstream field is missing — the response-shape validation at fetch time makes this rare
in practice but not impossible for a sub-field the validation doesn't check.

### forecast_daily.json

`shared/weather/{profile}/forecast_daily.json` — written by `fetch_openweather.sh`,
sourced from OpenWeather's `/data/2.5/forecast` (3-hourly data, reduced to one row per
day).

```json
{
  "generated_at": "2026-08-31T14:23:00Z",
  "timezone": "America/Chicago",
  "days": [
    {
      "day_name": "MON",
      "date": "2026-09-01",
      "high_f": 93.0,
      "low_f": 74.0,
      "cloud_percent": 20,
      "wx_code": 800,
      "icon": "01d"
    }
  ]
}
```

Up to 6 days (`.[:6]`), today included and clamped to today's already-observed high/low
via `current.json`'s live `temp_f` (`[$raw_hi, $current_temp] | max`/`min`) so an
early-morning forecast row doesn't under-report a high the day has already reached.
Representative row for icon/condition selection is the 10:00–16:00 local slot when
present (`$mid`), falling back to the day's first row otherwise. `wx_code` picks the
day's most "significant" condition via a fixed severity rank (thunderstorm > freezing
rain > snow > rain/drizzle > atmosphere/haze > extreme > everything else), not simply the
midday value, so a day with a brief afternoon storm buried in mostly-clear 3-hourly
samples still surfaces the storm.

---

## Configuration

`profiles/weather/{profile}.toml`:

```toml
profile_id = "home"
provider = "openweather"
enabled = true

[location]
name = "home"
# Defaults come from site.toml [location.home].
# lat =
# lon =
# timezone =

[request]
units = "imperial"
lang = "en"
cache_ttl_sec = 300

[credentials]
# Defaults come from site.toml [credentials].openweather_api_key.
# owm_api_key =
```

`lat`/`lon`/`timezone` fall back to `site.toml`'s `[location.home]`; `owm_api_key` falls
back to `site.toml`'s `[credentials] openweather_api_key`. `cache_ttl_sec` (default 300s)
gates both the current and forecast HTTP calls identically — see Known Constraints below.
The shipped template also carries an `[events]` block (`cache_ttl_sec`,
`extra_events_file`) that this script never reads at all — likely copy-pasted from a
sibling profile template; flagged, not corrected here.

---

## Known Quirks / History

### Aug 31, 2026 — No-partial-failure-state gap found and fixed

**Found while writing this doc's first pass**, not from a live incident (contrast with
[Aviation Provider Status](aviation-provider-status.md)'s Aug 2026 TAF entry, which *was*
a live incident): `status.json`'s end-of-script `write_status "ok" ...` call fired
unconditionally once both `RAW_CURRENT` and `RAW_FORECAST` existed on disk — it checked
**presence, not freshness**. A failed HTTP fetch only removed the *tmp* file; if a
previous successful fetch had already populated `RAW_CURRENT`/`RAW_FORECAST`, the script
re-derived `current.json`/`forecast_daily.json` from that stale raw file on every
subsequent run, stamped a brand-new `generated_at`, and reported `state: "ok"` —
indefinitely, for as long as the API kept failing. This is the exact failure shape that
caused the aviation TAF incident (stuck-but-present cache, `"ok"`-forever state) before
*that* domain's fix shipped — weather had no equivalent incident on record, but had no
defense against one either, and was fixed proactively rather than waiting for one.

**Fix:** ported aviation's per-field pattern directly — `field_status_json()` (identical
helper, added verbatim) plus `CURRENT_STATE`/`FORECAST_STATE` tracking around each of the
two fetch attempts. `status.json`'s `"ok"`-path write was replaced with a `current`/
`forecast` sub-object envelope and a `"degraded"` state for a single-field failure — see
the status.json schema above for the full shape and the State Field Values table. The
early-exit stub paths (missing profile TOML, disabled, missing credentials, and the
cold-start total-failure case where neither raw file exists) are unchanged — they still
write the flatter original envelope with no per-field sub-objects, matching aviation's
`write_status()`-vs-full-envelope split exactly.

**Verified live**, scratch cache root, three cases:

- **Both fields fresh** (`current`/`forecast` state `"ok"`, real mtimes) → envelope
  `"ok"`, empty `note`.
- **One field stale, its fetch forced to fail** (bogus API key against the real
  `api.openweathermap.org` host, real HTTP 401 returned) → envelope `"degraded"`,
  `note: "forecast fetch failing; serving cached data from <old raw_forecast.json
  mtime>"`, `raw_forecast.json`'s mtime confirmed unchanged after the run (old cache
  preserved, not clobbered).
- **Cold start, no raw files, bad key** → envelope `"error"`, `"weather fetch failed; no
  cache"`, no `current`/`forecast` keys — confirms the early-exit path is untouched by
  this change.

**Scope:** provider-side only, same as aviation's fix — no WXR/SitRep display logic
touched. See Remaining Work.

---

## Known Constraints

**Rate limiting** — not handled explicitly. `cache_ttl_sec` (default 300s) is the only
throttle; no OpenWeather quota/HTTP-429 handling exists in the script. OpenWeather's free
tier (60 calls/min, 1,000,000 calls/month) is far above what a 300s TTL against two
endpoints for one profile could hit, so this has not been an issue in practice, but a
misconfigured TTL or multiple profiles sharing one key could approach it with no warning
from this script.

**8-second HTTP timeout** (`curl --max-time 8`) — hardcoded, not TOML-configurable.
Shorter than aviation's fetch calls, which set no explicit `--max-time` at all.

**Single shared TTL for two independent endpoints** — `cache_ttl_sec` gates both the
current-conditions and forecast HTTP calls with the same value; there is no
`current_ttl_sec`/`forecast_ttl_sec` split the way aviation splits `metar_ttl_sec`/
`taf_ttl_sec`. Not a known problem today, just a structural difference worth knowing
before assuming per-endpoint tuning is possible.

---

## Remaining Work

- [x] No per-field / partial-failure staleness detection — fixed Aug 31, 2026 by porting
      aviation's per-field `state`/`last_ok`/`age_seconds` + degraded-envelope pattern
      directly (see Known Quirks / History above).
- [ ] **WXR-side staleness validation is a separate follow-up, not covered by this fix.**
      Same gap as aviation: even with the provider now correctly reporting `degraded`,
      nothing in `gtex62-sitrep`'s display layer reads `status.json`'s `current`/
      `forecast` sub-objects to surface staleness at render time — that's the next layer
      of defense, out of scope here.
- [ ] Confirm whether the `provider`/multi-source intent behind the
      `fetch_openweather.sh` naming (see Naming Convention Exception above) is real
      forward-planning or a naming accident — open question, not resolved by this doc.
- [ ] `[events]` block in the shipped profile template appears unused by this script —
      verify and either wire it up or remove it from the template (not investigated this
      session).
- [ ] No dedicated session/verification history exists for this domain predating this
      doc (see Session History below) — nothing to reconcile, just noting the gap is
      real, not an omission of this doc.

---

## Session History

Condensed; this domain had no prior dedicated doc, and CHANGELOG.md's pre-0.6.1 history
only ever covered the pfSense/AP/VPN/modem family (see [CHANGELOG.md](../CHANGELOG.md)'s
scope note), so `weather`'s baseline-era history below is reconstructed from `git log`,
not from prior prose. The Aug 31, 2026 fix itself does have a live CHANGELOG.md entry
(0.6.1), alongside aviation's.

- **Apr 25–29, 2026 — Initial engine baseline.** `fetch_openweather.sh` shipped as part
  of "Establish core runtime provider foundation" (`8c2b650`), alongside the other
  original-baseline providers.
- **Aug 31, 2026 — This doc written; first pass.** No code changes; backfills the
  documentation gap identified in this session's provider-doc coverage audit and records
  the no-partial-failure-state gap found while reading the script.
- **Aug 31, 2026 — Per-field staleness detection shipped, same session.** Ported
  aviation's `field_status_json()`/degraded-envelope pattern into
  `fetch_openweather.sh` — see Known Quirks / History above for the full before/after,
  the fix, and live verification (three cases: both-fresh `"ok"`, one-field-failing
  `"degraded"`, cold-start `"error"`). This doc's status.json schema, State Field Values
  table, and Remaining Work were updated in the same pass to match.
