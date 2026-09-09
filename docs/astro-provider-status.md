# Astro Provider Status

Current implementation state of the core `astro` provider: script location, output
schema, configuration, refresh model, and known quirks. Promoted from `astro-schema.md`,
which documented this domain's schema in pre-implementation "recommended"/"should"
language even though `providers/astro/fetch_astro.sh` shipped with the initial engine
baseline (Apr 25–29, 2026) and has matched that recommended shape ever since — the schema
content was accurate, just voiced as a proposal for something already built, and missing
the fetch-mechanics/config/quirks writeup every other implemented domain gets. Follows the
same `-provider-status.md` structure used by
[Weather Provider Status](weather-provider-status.md) and
[System Provider Status](system-provider-status.md) (`system` was promoted out of its own
`system-schema.md` in the same pass, for the same reason).

Companion docs: [Architecture](architecture.md) (provider pattern, cache layout — its TTL
table's `astro` row is corrected by this doc, see Known Quirks), [Orb Provider
Reference](orb-provider-reference.md) (a *different* ephemeris domain — see Scope below,
this is the most important thing to get right about `astro`).

---

## Scope: `astro` Is Not `orb`

Two independent core domains compute planet/sun/moon positions, with different
libraries, different cache trees, and different suite consumers:

| Domain | Script | Cache | Consumed by (OSA) |
| --- | --- | --- | --- |
| `orb` | `providers/orb/fetch_orb.py` (pyephem) | `shared/orb/<profile>/ephemeris.vars` | `lua/suite/orb.lua` — the ORB panel |
| `astro` | `providers/astro/fetch_astro.sh` (embedded Python, pyephem) | `shared/astro/<profile>/current.json` | `lua/suite/tme.lua` — the TME (clock) panel, not ORB |

Both use `pyephem` and compute overlapping bodies, but they are not the same provider and
neither reads the other's cache. `astro-schema.md`'s old "Related OSA suite-cache note"
pointed at `osa-orb-cache.md` — that's wrong; `osa-orb-cache.md` documents the `orb`
domain's `ephemeris.vars`, which `tme.lua` never reads. There is no dedicated OSA-side
cache note for `astro` yet (see Suite Consumption, below, for what `tme.lua` actually
does with it).

---

## `providers/astro/fetch_astro.sh` ✓ COMPLETE

```text
providers/astro/fetch_astro.sh <profile>
```

Profile default: `home`

Computes sun, moon, and five planet positions via an embedded Python heredoc (`pyephem`),
normalized to a single flat body schema. Implements:

- Profile/site TOML resolution chain for lat/lon (`profiles/astro/{profile}.toml`
  `[location]`, falling back to `site.toml`'s `[location.home]`); `timezone` resolves from
  the profile's **root-level** `timezone` key (not `[location]`), then `site.toml`, then
  the host's own `date +%Z` as a last resort
- `enabled = false` and missing-profile-toml both short-circuit to a `status.json`-only
  write, no `current.json` touched
- No TTL/freshness gating inside the script itself — every invocation recomputes from
  scratch; TTL only controls how often the launcher *calls* it (see Refresh Model)
- Six bodies: sun, moon, mercury, venus, mars, jupiter, saturn — each reduced to the same
  `body_payload()` shape (altitude, azimuth, above-horizon flag, prev/next rise/set,
  heading, legacy theta)
- Rise/set events wrapped in `safe_event()`, which swallows pyephem's
  `AlwaysUpError`/`NeverUpError` and emits `null` for that timestamp rather than raising —
  correct for circumpolar/never-rising bodies at extreme latitudes, though not a practical
  concern at this deployment's latitude

---

## Cache Location

```text
~/.cache/gtex62-core/shared/astro/<profile>/current.json
~/.cache/gtex62-core/shared/astro/<profile>/status.json
```

## Profile

```text
~/.config/gtex62-core/profiles/astro/<profile>.toml
```

```toml
profile_id = "home"
enabled = true
source = "ephem"
# timezone =   # root-level key, not under [location] — defaults from site.toml

[location]
# lat / lon — defaults come from site.toml [location.home]

[fallback]
weather_profile = "home"

[cache]
refresh_sec = 60
```

The installed profile omits the `[cache]` block entirely (launcher default 60s applies).
`source = "ephem"` is recorded but never branched on — the script always uses pyephem
regardless of this value, the same recorded-but-unused-config pattern as `air`'s
`baseline_provider`/`overlay_provider` (see
[ENV Panel Provider Status](env-panel-provider-status.md)) and `solar`'s `source`. The
`[fallback] weather_profile` key is more than unused-but-recorded — `fetch_astro.sh` never
reads the `[fallback]` section at all, in code or in a fallback chain; it's dead
configuration, likely a placeholder for `astro-schema.md`'s original "core may populate
rise/set from a weather or solar provider" design note, never wired up.

Suite TOML binding:

```toml
[profiles]
astro = "home"
```

---

## `current.json`

```json
{
  "generated_at": "2026-09-09T16:18:40Z",
  "profile": "home",
  "observer": { "lat": 35.111649, "lon": -89.755973, "timezone": "America/Chicago" },
  "sun": {
    "id": "sun",
    "name": "Sun",
    "altitude_deg": 52.513,
    "azimuth_deg": 137.461,
    "is_above_horizon": true,
    "prev_rise_ts": 1788953839,
    "prev_set_ts": 1788912963,
    "next_rise_ts": 1789040283,
    "next_set_ts": 1788999278,
    "heading_deg": 227,
    "legacy_theta_deg": 47.461
  },
  "moon": { "...": "same shape" },
  "planets": {
    "mercury": { "...": "same shape, keyed by lowercase name" },
    "venus": {}, "mars": {}, "jupiter": {}, "saturn": {}
  },
  "status": { "state": "ok" }
}
```

| Key | Description |
| --- | --- |
| `<body>.altitude_deg` / `azimuth_deg` | Degrees; canonical position truth |
| `<body>.is_above_horizon` | `altitude_deg > 0` |
| `<body>.prev_rise_ts` / `prev_set_ts` / `next_rise_ts` / `next_set_ts` | Unix epoch; `null` for a circumpolar/never-rising body at this observer |
| `<body>.heading_deg` | `(azimuth + 90) % 360`, rounded to an integer — the human-facing heading OSA renders |
| `<body>.legacy_theta_deg` | `(azimuth - 90) % 360` — compatibility projection for legacy volvelle-style rendering |
| `status` | See Known Quirks — this embedded stub is not the domain's real health signal |

---

## `status.json`

```json
{
  "state": "ok",
  "profile": "home",
  "collector": "astro",
  "generated_at": "2026-09-09T16:18:40Z",
  "note": ""
}
```

`state` is one of `"ok"`, `"error"` (missing profile TOML, or missing/unresolvable
lat/lon), or `"disabled"`. No `"degraded"`/per-field state — a single Python process
computes all six bodies in one pass, so there's no partial-failure mode the way
multi-endpoint domains (weather, aviation, air) have.

---

## Refresh Model

Launcher schedules a loop every `ASTRO_TTL` seconds, read from `[cache] refresh_sec`,
default **60s**. No internal staleness gate — every cycle fully recomputes.

---

## Known Quirks

- **Duplicate, divergent "status" representations.** `current.json`'s own embedded
  `status` field is a bare `{"state": "ok"}` stub — it does not carry `profile`,
  `collector`, `generated_at`, or `note` the way the real `status.json` file does, and
  nothing in the codebase appears to read the embedded field at all (`tme.lua` reads
  `status.json` for health, not `current.json.status` — see Suite Consumption). The
  embedded field looks like a leftover from `astro-schema.md`'s original "Recommended
  Status Block" design sketch (which specified `provider`/`state`/`generated_at`/
  `age_seconds`) that was implemented properly as a sibling file instead, without the stub
  being removed from `current.json`'s own payload.
- **`rise_ts`/`set_ts` (current-interval fields) were never implemented.** The original
  schema doc's "Strongly Recommended Timing Fields" listed both plain `rise_ts`/`set_ts`
  *and* the `prev_*`/`next_*` variants. Only the `prev_*`/`next_*` pair shipped — there is
  no single "the rise/set time for the currently-displayed interval" field; a consumer
  would have to derive it from `prev_*`/`next_*` plus current time. Not a problem for
  `tme.lua`'s actual use (see Suite Consumption) — it only ever wants the *next* event,
  which `next_rise_ts`/`next_set_ts` already give it directly — but it means the field set
  the original doc called "strongly recommended" is only half-shipped.
- **`[fallback] weather_profile` is dead config** — see Profile, above.
- **Wrong OSA cross-link in the doc this replaces** — see Scope, above.
- **`architecture.md`'s TTL table listed `astro` as `"varies"`.** It doesn't — like
  `orb`/`solar`, it has one fixed `refresh_sec`-driven default (60s). Corrected in that
  doc's table alongside this one landing.

---

## Suite Consumption

OSA's **TME** panel (`lua/suite/tme.lua`), not ORB, reads `shared/astro/<profile>/`,
resolving the profile from `[profiles] astro` in the suite TOML (default `"home"`). The
consumption is narrow: `sun_event_status_line()` reads only `.sun.next_rise_ts` and
`.sun.next_set_ts` from `current.json` to build a single "next SUNRISE/SUNSET" countdown
status line alongside the clock rows TME otherwise builds from the `time` domain. `moon`
and the five planets are computed and cached by every run but have **no current OSA
consumer** — nothing reads them today. `status.json`'s health fields are also unread; a
missing/stale `current.json` just makes `sun_event_status_line()` return `nil` (line
suppressed), with no distinct stale-data indicator. No dedicated OSA-side cache note
exists yet for this consumption path (unlike `orb`'s `osa-orb-cache.md` or `net`'s
`osa-net-cache.md`) — writing one is a candidate follow-up, out of scope here.
