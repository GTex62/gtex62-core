# ENV Panel Provider Status

Current implementation state of the two core provider domains behind the ENV panel —
`air` (AQI + pollution) and `solar` (UV + radiation): script locations, output schemas,
configuration, refresh model, and known quirks. Written to close a documentation gap —
`docs/atmos_meters.md` in the OSA suite repo covers panel *layout* (meter geometry, color
bands, theme knobs) but predates and does not track the underlying core cache, and no
core doc existed for either domain. Follows the same `-provider-status.md` structure used
by [Weather Provider Status](weather-provider-status.md) and
[Aviation Provider Status](aviation-provider-status.md), covering both domains in one
doc because they are consumed together as a single suite panel (see Suite Consumption).

Companion docs: [Architecture](architecture.md) (provider pattern, cache layout — its TTL
table's `air`/`solar` rows are corrected by this doc, see Known Quirks), [AirGradient
Engine Integration](airgradient-engine-integration.md) (planned third ENV input — indoor
AQI — not yet implemented; no `providers/airgradient/` exists yet).

---

## Scope: What "ENV Panel" Means

OSA's ENV panel (module `lua/suite/env.lua`, box title "ATMOS") merges three inputs:

| Input | Core provider? | Domain |
| --- | --- | --- |
| Outdoor air quality (AQI, PM2.5, O3, PM10, NO2, SO2, CO, NH3) | Yes | `air` |
| UV index + solar radiation | Yes | `solar` |
| Pollen (tree/grass/weed/mold) | **No** | static CSV in `gtex62-shared-assets`, day-of-year lookup, no fetch/provider involved |

This doc covers `air` and `solar` only. Pollen has no TTL, no cache staleness, and no
`status.json` — `env.lua`'s `read_pollen()` reads
`<shared-assets>/data/pollen/pollen_mem_v2.csv` directly by day-of-year and reports
`"POLLEN CSV MISSING"` if the file isn't found. If pollen ever needs live data, it would
be a new core provider domain, not part of `air`/`solar`.

---

## `air` Provider

### `providers/air/fetch_air.sh` ✓ COMPLETE

```text
providers/air/fetch_air.sh <profile>
```

Profile default: `home`

Merges two upstream sources into one cache:

- **OpenWeather** Air Pollution API (`/data/2.5/air_pollution`) — baseline. Always
  fetched when `[openweather] enabled = true`. Provides AQI (1–5 category) and raw
  pollutant components in µg/m³ directly.
- **AirNow** — optional overlay when `[airnow] enabled = true` *and* an API key is
  configured. Two separate endpoints, fetched independently:
  - `aq/data` (`AIRNOW_DATA_URL`) — per-pollutant raw concentrations in a bounding box
    around the profile's lat/lon (`distance_miles`), converted to µg/m³.
  - `aq/observation/current/ziplatlong` (`AIRNOW_OBS_URL`) — AirNow's own computed AQI
    for the nearest monitor.

Selection logic (`selected` object in `current.json`): OpenWeather components are the
base; any AirNow `aq/data` value present for a pollutant (after the `window_hours` /
`airnow_max_age` filters) overlays it. AQI is chosen independently in the *suite* layer
(`env.lua`), not by this script — see Suite Consumption.

#### Cache Location

```text
~/.cache/gtex62-core/shared/air/<profile>/current.json
~/.cache/gtex62-core/shared/air/<profile>/status.json
~/.cache/gtex62-core/shared/air/<profile>/raw_openweather.json
~/.cache/gtex62-core/shared/air/<profile>/raw_airnow_data.json
~/.cache/gtex62-core/shared/air/<profile>/raw_airnow_observation.json
~/.cache/gtex62-core/shared/air/<profile>/fetch.log
```

The three `raw_*.json` files are per-source freshness-gated snapshots (see Refresh
Model) — `current.json` is derived from whichever raw files exist on each run, not
re-fetched every time.

#### Profile

```text
~/.config/gtex62-core/profiles/air/<profile>.toml
```

```toml
profile_id = "home"
baseline_provider = "openweather"
overlay_provider = "airnow"
enabled = true

[location]
# lat / lon / timezone — defaults come from site.toml [location.home]

[cache]
ttl_sec = 900

[openweather]
enabled = true
# api_key — defaults come from site.toml [credentials].openweather_api_key

[airnow]
enabled = true
# api_key — defaults come from site.toml [credentials].airnow_api_key
distance_miles = 25
window_hours = 6
owm_tolerance_sec = 3600
```

`baseline_provider` / `overlay_provider` are recorded but not currently branched on by
the script — OpenWeather is always the base and AirNow is always the overlay regardless
of these values. `max_age_sec` (AirNow per-pollutant staleness ceiling) defaults to
`3600` and has no example key shown in the installed profile above; add
`[airnow] max_age_sec = <seconds>` to override.

Suite TOML binding:

```toml
[profiles]
air = "home"
```

#### `current.json`

```json
{
  "profile": "home",
  "generated_at": "2026-09-09T15:26:39Z",
  "provider_updated_at": "2026-09-09T14:00:00Z",
  "location": { "lat": 35.111649, "lon": -89.755973, "timezone": "America/Chicago" },
  "openweather": {
    "enabled": true,
    "valid": true,
    "observed_ts": 1788967599,
    "observed_at": "2026-09-09T15:26:39Z",
    "aqi": 1,
    "components": { "co": 153.14, "no": 0.59, "no2": 2.25, "o3": 51.99, "so2": 0.5, "pm2_5": 5.86, "pm10": 6.53, "nh3": 0.44 }
  },
  "airnow": {
    "enabled": true,
    "valid": true,
    "observed_ts": null,
    "observed_at": "",
    "latest_ts": 1788962400,
    "latest_at": "2026-09-09T14:00:00Z",
    "aqi": 32,
    "aqi_ts": 1788962400,
    "aqi_at": "2026-09-09T14:00:00Z",
    "values": {},
    "timestamps": {}
  },
  "selected": { "co": 153.14, "no": 0.59, "no2": 2.25, "o3": 51.99, "so2": 0.5, "pm2_5": 5.86, "pm10": 6.53, "nh3": 0.44 }
}
```

The sample above is a real capture showing a common divergence: `airnow.aqi` is present
(from `aq/observation`) while `airnow.values`/`timestamps` are empty (`aq/data` returned
nothing inside the tolerance window) — so `selected` falls back entirely to OpenWeather
even though AirNow AQI is being shown elsewhere. Don't assume a non-null `airnow.aqi`
implies any AirNow-sourced pollutant concentration is in `selected`.

| Key | Description |
| --- | --- |
| `provider_updated_at` | Newest of AirNow AQI ts, AirNow observed ts, AirNow data ts, or OpenWeather observed ts |
| `openweather.aqi` | OpenWeather's own 1–5 AQI category (not AirNow's 0–500 scale) |
| `airnow.aqi` | AirNow AQI (0–500 scale), from `aq/observation`, independent of `airnow.values` |
| `airnow.values` / `airnow.timestamps` | Per-pollutant AirNow concentrations (µg/m³) and their source timestamps, from `aq/data`, filtered to freshest-per-pollutant within `airnow_max_age` |
| `selected` | OpenWeather components overlaid with any available `airnow.values` — the pollutant set the ENV panel actually renders |

#### Unit Conversion

AirNow `aq/data` can report ppb/ppm for some gases; the script converts to µg/m³ before
overlay:

```text
O3  1 ppb  ≈ 1.96  µg/m³
NO2 1 ppb  ≈ 1.88  µg/m³
SO2 1 ppb  ≈ 2.62  µg/m³
CO  1 ppm  ≈ 1145  µg/m³ (1.145 mg/m³)
```

#### Refresh Model

Launcher schedules (`bin/gtex62-core-launch`): initial background refresh at startup,
then a loop every `AIR_TTL` seconds (from `[cache] ttl_sec`, default **900**).

Inside the script, `AIR_TTL` does double duty — it also gates each raw-source fetch
independently via `is_fresh` (mtime of `raw_openweather.json` / `raw_airnow_data.json` /
`raw_airnow_observation.json` against the same TTL), so a launcher cycle that fires
before a raw file has gone stale skips that source's HTTP call and reuses the cached raw
file. All three raw sources share one TTL; there's no way to give AirNow and OpenWeather
independent cadences.

A missing/empty response for a source deletes its temp file rather than caching a bad
response (`jq -e` shape check gates the `mv`); if *all three* raw files are absent (fresh
install, or all three failed), `status.json` is written `"error"` / `"air fetch failed;
no cache"` and the script exits 0 without writing `current.json`.

---

## `solar` Provider

### `providers/solar/fetch_solar.sh` ✓ COMPLETE

```text
providers/solar/fetch_solar.sh <profile>
```

Profile default: `home`

Not an independent upstream fetch — it's derived from the `weather` domain's cache plus
one live call to Open-Meteo for real UV/radiation when coordinates are available. This is
why `status.json`'s `provider` field reads `"weather-derived"` (see Known Quirks) and why
the profile's `[cache]` section has no equivalent of `air`'s per-source freshness gating:
every run either gets a real reading from Open-Meteo or falls back to a synthetic model,
there's no "reuse yesterday's raw file" path.

On each run:

1. Waits up to 20s (`40 × 0.5s`) for `shared/weather/<weather_profile>/raw_current.json`
   or `current.json` to exist — `status.json` is `"waiting"` if neither ever appears.
2. Calls Open-Meteo (`/v1/forecast?current=uv_index,shortwave_radiation`) with the
   profile's lat/lon, best-effort (`curl -fsS --max-time 8`; failure just leaves the
   synthetic model in place, it does not error the whole run).
3. Computes a synthetic solar model (sun-angle factor from sunrise/sunset in the weather
   cache, cloud factor from `clouds.all`, a day-of-year solar-declination zenith
   calculation) as the fallback for any value Open-Meteo didn't return.

#### Cache Location

```text
~/.cache/gtex62-core/shared/solar/<profile>/current.json
~/.cache/gtex62-core/shared/solar/<profile>/status.json
~/.cache/gtex62-core/shared/solar/<profile>/fetch.log
```

No raw file — Open-Meteo's response is used inline and discarded, not cached to disk.

#### Profile

```text
~/.config/gtex62-core/profiles/solar/<profile>.toml
```

```toml
profile_id = "home"
enabled = true
source = "weather-derived"
weather_profile = "home"

[location]
# lat / lon / timezone — defaults come from site.toml [location.home]
```

The installed `profiles/solar/home.toml` (and the installable
`examples/runtime/profiles/solar/home.toml.example`) have **no `[cache]` section at
all** — see Known Quirks for what that means for the refresh interval.

Suite TOML binding:

```toml
[profiles]
solar = "home"
```

#### `current.json`

```json
{
  "profile": "home",
  "provider": "weather-derived",
  "source": "openweather-derived",
  "timestamp": 1788967599,
  "generated_at": "2026-09-09T15:31:40Z",
  "provider_updated_at": "2026-09-09T15:26:39Z",
  "weather_profile": "home",
  "location": { "lat": 35.111649, "lon": -89.755973, "timezone": "America/Chicago" },
  "labels": ["UV", "VI", "IR", "CL", "RAD"],
  "values": { "UV": 4.75, "VI": 30.09, "IR": 43.1, "CL": 63, "RAD": 646 },
  "norm": { "UV": 0.43, "VI": 0.3, "IR": 0.43, "CL": 0.63, "RAD": 0.65 },
  "meta": {
    "source_weather_profile": "home",
    "timestamp": 1788967599,
    "sunrise": 1788953857,
    "sunset": 1788999326,
    "clouds": 63,
    "temp_f": 86.18,
    "temp_c": 30.1,
    "uv_source": "open-meteo"
  }
}
```

| Key | Description |
| --- | --- |
| `values.UV` / `values.RAD` | Real Open-Meteo reading when `meta.uv_source == "open-meteo"`, else the synthetic model's estimate |
| `values.VI` / `values.IR` | Always synthetic (visible/infrared factors) — Open-Meteo has no equivalent field, no real-data path exists for these |
| `values.CL` | Cloud cover %, passed through from the weather cache, not solar-derived at all |
| `norm.*` | Same five values normalized 0–1 (UV divided by 11, RAD by 1000, others already 0–1 factors) |
| `meta.uv_source` | `"open-meteo"` or `"synthetic"` — the only field that tells you whether `values.UV`/`RAD` are real or modeled |

#### Refresh Model

Launcher schedules a loop every `SOLAR_TTL` seconds, read from `[cache] refresh_sec`
(**not** `ttl_sec`), default **300**. Every cycle does a live Open-Meteo call when
lat/lon resolve — there is no internal staleness check to skip it, unlike `air`.

---

## Known Quirks

- **`architecture.md`'s TTL table is wrong for `air`.** It lists both `air` and `solar`
  at 300s. `solar`'s 300s is correct (launcher default); `air`'s real default is **900s**
  (`[cache] ttl_sec`), confirmed by the script's own fallback, the launcher's fallback,
  and the installed `profiles/air/home.toml`. Corrected in that doc's table alongside
  this one landing.
- **`air` and `solar` use different TOML keys for the same concept.** `air` reads
  `[cache] ttl_sec`; `solar` reads `[cache] refresh_sec`. Copying an `air`-style
  `ttl_sec = N` into a solar profile silently does nothing — the launcher falls back to
  300s regardless.
- **The installable solar template has no `[cache]` section**, so there's no
  discoverable example of the `refresh_sec` key anywhere in `examples/runtime/`. Anyone
  wanting a faster/slower solar cadence has to know the key name and add it manually.
- **`solar`'s `status.json.provider` is hardcoded to `"weather-derived"`**, ignoring the
  profile's actual `source` value — `write_status()` in `fetch_solar.sh` passes the
  literal string, not `$SOURCE`. `current.json.provider` uses the real `$SOURCE` value
  correctly; only the status file's copy is wrong. If `source` is ever changed away from
  `"weather-derived"` in a profile, `status.json` will misreport it.
- **AirNow AQI and AirNow pollutant concentrations can diverge** (see the `current.json`
  sample above) because they come from two independent AirNow endpoints
  (`aq/observation` vs `aq/data`) with their own coverage/latency. A present
  `airnow.aqi` does not guarantee any pollutant in `selected` is AirNow-sourced rather
  than OpenWeather baseline.
- **`solar` has no error state for a failed Open-Meteo call** — only `curl` success
  toggles `meta.uv_source` between `"open-meteo"` and `"synthetic"`; `status.json` still
  reports `"ok"` either way, since the synthetic fallback always produces a value. A
  suite reading `status.json.state` alone cannot detect "running on the synthetic model
  because Open-Meteo has been down for days."

---

## Suite Consumption

OSA reads both caches via `lua/suite/env.lua`, resolving profiles from `[profiles] air`
/ `[profiles] solar` in the suite TOML (both default `"home"`). Its `refresh()` is
minute-cadenced (`math.floor(os.time() / 60)`), independent of either provider's own TTL
— it just re-reads whatever `current.json`/`status.json` currently hold, once a minute.

`env.lua` layers additional suite-side logic on top of the raw caches:

- **AQI source selection**: prefers `airnow.aqi` when present, with an OpenWeather
  1–5-to-AirNow-band mapping (`owm_aqi_to_airnow`) as a display fallback — this
  selection is suite-side, not written into `air`'s `current.json`.
- **Panel status line** (`DATA // ...`): `"FAULT"` on `air` `status.json.state ==
  "error"`, `"PARTIAL"` if `air`/pollen cache is missing, `"STALE"` if `air`'s
  `provider_updated_at` is older than 7200s — solar staleness is not checked here.
- **Pollen** is merged in from the static CSV (see Scope, above) — no core provider
  involved.

Panel layout, meter geometry, color bands, and theme knobs are OSA-suite concerns
documented in `gtex62-osa/docs/atmos_meters.md`, not here.
