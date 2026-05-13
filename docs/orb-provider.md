# Core Orb Provider

## Purpose

The `orb` provider computes a shared ephemeris cache — planet, sun, and moon
positions, altitudes, and rise/set timestamps — for use by any suite that
displays celestial data.

It is distinct from the `astro` domain (normalized sun/moon/rise-set summary).
The `orb` provider uses the `pyephem` library to produce per-body azimuth,
altitude, theta projection, and full neighboring-event timestamps that suites use
for timeline rendering, arc fills, ring placement, and horizon visibility.

Multiple suites display this data in different forms (globe + ring, ring only,
horizontal line, arc). The provider is shared; the rendering is suite-specific.

---

## Provider

```
providers/orb/fetch_orb.sh <profile>
providers/orb/fetch_orb.py <profile>
```

Profile default: `home`

The shell script calls the Python script and writes its stdout to the cache file
atomically via a temp file.

---

## Cache Location

```
~/.cache/gtex62-core/shared/orb/<profile>/ephemeris.vars
```

---

## Profile

```
~/.config/gtex62-core/profiles/orb/<profile>.toml
```

Example (`profiles/orb/home.toml`):

```toml
[cache]
# How often to recompute planet/sun/moon positions (seconds)
ttl_sec = 60

# Which astro profile to use for lat/lon (defaults to "home")
# astro_profile = "home"
```

See `examples/runtime/profiles/orb/home.toml.example` for the installable
template.

Suite TOML binding:

```toml
[profiles]
orb = "home"
```

### Location Resolution

The provider resolves observer lat/lon in this order:

1. `$LAT` / `$LON` environment variables
2. `shared/astro/<astro_profile>/current.json` — `observer.lat` / `observer.lon`
3. `profiles/astro/<astro_profile>.toml` — `[location]` section
4. `profiles/weather/home.toml` — `[location]` section

`astro_profile` defaults to `"home"` unless overridden in the orb profile TOML.

---

## `ephemeris.vars`

### Format

Simple `KEY=value` text, one per line.

```text
LAT=35.0424
LON=-89.9767
TS=1776841117
SUN_AZ=19.521
SUN_ALT=-40.639
SUN_THETA=289.521
SUN_RISE_TS=1776856729
SUN_SET_TS=1776904709
...
JUPITER_AZ=303.238
JUPITER_ALT=-5.983
JUPITER_THETA=213.238
JUPITER_NEXT_RISE_TS=1776873803
JUPITER_NEXT_SET_TS=1776925412
```

### Top-Level Keys

| Key | Description |
|-----|-------------|
| `LAT` | Observer latitude |
| `LON` | Observer longitude |
| `TS` | Cache generation timestamp (Unix epoch) |

### Bodies

| Body key | Body |
|----------|------|
| `SUN` | Sun |
| `MOON` | Moon |
| `MERCURY` | Mercury |
| `VENUS` | Venus |
| `MARS` | Mars |
| `JUPITER` | Jupiter |
| `SATURN` | Saturn |

### Per-Body Keys

For each body `<BODY>`:

| Key | Description |
|-----|-------------|
| `<BODY>_AZ` | Azimuth in degrees |
| `<BODY>_ALT` | Altitude in degrees (negative = below horizon) |
| `<BODY>_THETA` | Projection angle for ring/arc placement (`azimuth − 90°`, wrapped 0–360) |
| `<BODY>_RISE_TS` | Selected rise timestamp for current display interval |
| `<BODY>_SET_TS` | Selected set timestamp for current display interval |
| `<BODY>_SET_PREV_TS` | Previous set; carryover helper for overnight intervals |
| `<BODY>_PREV_RISE_TS` | Previous rising event timestamp |
| `<BODY>_PREV_SET_TS` | Previous setting event timestamp |
| `<BODY>_NEXT_RISE_TS` | Next rising event timestamp |
| `<BODY>_NEXT_SET_TS` | Next setting event timestamp |

Not all keys are present for every body on every run. Bodies that never rise or
never set at the observer location will omit the corresponding timestamps.

---

## Refresh Model

The launcher schedules:

- initial background refresh at startup
- recurring background refresh every `ttl_sec` seconds (default 60)

A 60-second cadence is appropriate; sub-minute ephemeris recomputation does not
meaningfully improve displayed accuracy.

---

## Suite Consumption

Suites read from `shared/orb/<profile>/` and resolve the profile from their
suite TOML `[profiles] orb` key (default `"home"`).

OSA reads this cache via `lua/suite/orb.lua`, which derives CELESTIAL row data,
visible time-band start/end hours, above-horizon flags, and current marker
position from the raw ephemeris values.
