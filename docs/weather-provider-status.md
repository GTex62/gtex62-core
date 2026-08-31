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
same `current.json`-plus-`status.json` cache shape, written the same session — see that
doc's Known Quirks / History section for a staleness-detection failure mode this domain
shares but has not yet hit).

---

## Implementation Status

### `providers/weather/fetch_openweather.sh` ✓ COMPLETE (unchanged since Apr 29, 2026)

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
  "state": "ok",
  "profile": "home",
  "provider": "openweather",
  "generated_at": "2026-08-31T14:23:00Z",
  "provider_updated_at": "2026-08-31T14:20:00Z",
  "note": ""
}
```

Flatter than the pfSense-family envelope (`profile`/`collector`/`generated_at` there vs.
`profile`/`provider`/`generated_at` here — no `collector` key, no `ssh_gate` object,
since there's no SSH/gate to report on). `provider_updated_at` is the upstream
observation timestamp (OpenWeather's own `dt` field, current-conditions payload only) —
distinct from `generated_at`, which is always this script's own wall-clock run time.

#### State Field Values

| Value | Meaning |
| --- | --- |
| `"ok"` | Both `current.json` and `forecast_daily.json` were written from a present raw cache file (freshly fetched or still-present-but-stale) |
| `"disabled"` | Profile has `enabled = false` in TOML |
| `"error"` | Missing profile TOML, missing credentials/coordinates, or **no raw cache file exists yet** for current and/or forecast (cold start with a failed first fetch) |

No `"degraded"` state exists for this domain — contrast with
[Aviation Provider Status](aviation-provider-status.md)'s per-field degraded envelope.
See Known Constraints below for what this means in practice.

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
gates both the current and forecast HTTP calls identically — see Known Constraints. The
shipped template also carries an `[events]` block (`cache_ttl_sec`,
`extra_events_file`) that this script never reads at all — likely copy-pasted from a
sibling profile template; flagged, not corrected here.

---

## Known Constraints

**No partial-failure ("degraded") state, and no per-field staleness tracking —
identified during this doc's Aug 31, 2026 audit, not yet fixed.** Unlike
[Aviation Provider Status](aviation-provider-status.md)'s post-incident `metar`/`taf`
per-field `state`/`last_ok`/`age_seconds` sub-objects, `status.json` here has no
equivalent. The end-of-script `write_status "ok" ...` call fires unconditionally once
both `RAW_CURRENT` and `RAW_FORECAST` exist on disk — it checks **presence, not
freshness**. A failed HTTP fetch only removes the *tmp* file; if a previous successful
fetch already populated `RAW_CURRENT`/`RAW_FORECAST`, the script re-derives
`current.json`/`forecast_daily.json` from that stale raw file on every subsequent run,
stamps a brand-new `generated_at`, and reports `state: "ok"` — indefinitely, for as long
as the API keeps failing. This is the same failure shape that produced the aviation TAF
incident (see that domain's Known Quirks / History) before its per-field fix shipped;
weather has not had an equivalent incident on record, but has no defense against one.
`provider_updated_at` (the upstream observation timestamp) is the one signal a consumer
could use to detect this independently today — nothing currently reads it for that
purpose.

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

- [ ] No per-field / partial-failure staleness detection (see Known Constraints) — the
      aviation fix (per-field `state`/`last_ok`/`age_seconds`, degraded envelope) is a
      direct template if this is ever prioritized for weather.
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

Condensed; this domain has no prior dedicated doc or CHANGELOG.md coverage —
CHANGELOG.md's own scope note only ever covered the pfSense/AP/VPN/modem family (see
[CHANGELOG.md](../CHANGELOG.md)), and `weather` predates that file entirely. History
below is reconstructed from `git log`, not from prior prose.

- **Apr 25–29, 2026 — Initial engine baseline.** `fetch_openweather.sh` shipped as part
  of "Establish core runtime provider foundation" (`8c2b650`), alongside the other
  original-baseline providers. No further commits to this script since — the only
  provider domain found in this audit to be completely unchanged since the engine's
  initial build-out.
- **Aug 31, 2026 — This doc written.** No code changes; backfills the documentation gap
  identified in this session's provider-doc coverage audit and records the
  no-partial-failure-state constraint found while reading the script (see Known
  Constraints above).
