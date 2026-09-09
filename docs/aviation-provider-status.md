# Aviation Provider Status

Current implementation state of the core `aviation` provider: split METAR/TAF fetch
architecture, output schemas, the per-field degraded-envelope convention, and known
quirks. Written retroactively (Aug 31, 2026) to close a provider-documentation coverage
gap identified across `docs/`, and to capture the same-day TAF stuck-data incident while
it's still fresh. Follows the same `-provider-status.md` structure used by
[pfSense Provider Status](pfsense-provider-status.md) and
[AP Provider Status](ap-provider-status.md).

**Disambiguation — "MTR" is not `providers/mtr/`.** This engine has a *separate*,
unrelated provider directory, `providers/mtr/` (`fetch_mtr.sh`), wrapping the Linux `mtr`
("My Traceroute") network-diagnostic tool for a Pi5-triggered overnight capture on
sustained gateway outages — nothing to do with aviation weather. Meanwhile, the WXR/AVT
display panel's "MTR" label refers to **METAR** (aviation routine weather report), the
field documented below. Anyone landing on either provider in isolation should not assume
the shared letters mean a shared codebase — they're coincidentally-overlapping
abbreviations for two unrelated domains. `providers/mtr/` has no dedicated doc yet as of
this writing (flagged, not addressed here — see Remaining Work).

Companion docs: [Architecture](architecture.md), [Weather Provider Status](weather-provider-status.md)
(sibling atmospheric-data domain, written the same session; its own per-field
staleness-detection gap — the same failure shape as this domain's TAF incident below —
was found while writing that doc and fixed the same day, ported directly from this
domain's fix, per its own Known Quirks / History entry).

---

## Implementation Status

### `providers/aviation/fetch_aviation.sh` ✓ COMPLETE (last touched Aug 31, 2026)

METAR + TAF text for the OSA/SitRep WXR/AVT panel family, sourced from
aviationweather.gov's public data API. No SSH, no gate — a plain `curl` against a public
REST API per field, same transport shape as the weather provider. Implements:

- Profile/site TOML resolution chain for METAR/TAF/station-model ICAO codes
  (`profiles/aviation/{profile}.toml`, falling back to `site.toml`'s `[aviation]`
  section, itself falling back further to a hardcoded `KMEM` default)
- **Two independent HTTP endpoints, each with its own TTL and its own success/failure
  tracking** — `fetch_metar()` and `fetch_taf()` are separate functions hitting separate
  aviationweather.gov paths, gated by separate `metar_ttl_sec`/`taf_ttl_sec` TOML keys
  (both default 600s). A failure in one does not touch the other's cache file or state.
- An optional third fetch for `station_model` (a separate ICAO used only for the
  station-model/cloud-layer display) — only issued when `station_model` differs from the
  METAR station; otherwise reuses the METAR fetch's own raw file, no extra HTTP call
- Response validation is presence-only (`[[ -s "$TMP_FILE" ]]`, non-empty) — no JSON/shape
  validation, since the raw response is plain text (`format=raw`), not JSON
- Per-field state tracking (`METAR_STATE`/`TAF_STATE`) feeding a **degraded envelope**
  convention — see Output Schemas below
- Log lines tagged `METAR:`/`TAF:` with a UTC timestamp (`fetch.log`), so a failure no
  longer requires correlating against file mtimes to tell which call produced it
- Output to `shared/aviation/{profile}/current.json` and
  `shared/aviation/{profile}/status.json`

---

## Output Schemas

### status.json

`shared/aviation/{profile}/status.json` — written by `fetch_aviation.sh`.

```json
{
  "state": "degraded",
  "profile": "home",
  "generated_at": "2026-08-31T14:23:00Z",
  "note": "taf fetch failing; serving cached data from 2026-08-13T14:02:51Z",
  "metar": {
    "state": "ok",
    "last_ok": "2026-08-31T14:20:00Z",
    "age_seconds": 180
  },
  "taf": {
    "state": "error",
    "last_ok": "2026-08-13T14:02:51Z",
    "age_seconds": 1555629
  }
}
```

**Per-field sub-objects (`metar`/`taf`)** — `state`/`last_ok`/`age_seconds`, matching
[astro-provider-status.md](astro-provider-status.md)'s recommended staleness-block shape. Each is derived
from that field's own raw cache file's mtime (`metar_raw.txt`/`taf_raw.txt`), not from a
separately tracked timestamp that could drift out of sync with what's actually on disk.
Two important subtleties:

- **`state` reflects only the outcome of *this run's* fetch attempt**, not whether the
  file being served is stale. If the field's own TTL hasn't expired, no fetch is
  attempted this run and `state` stays at its initialized `"ok"` regardless of how old
  the underlying data actually is — freshness is what `age_seconds` is for, not `state`.
- **`last_ok`/`age_seconds` always reflect the raw file's mtime**, whether or not a fetch
  was attempted this run. A field can show `state: "error"` (this run's fetch failed)
  while `last_ok` points at a much older successful fetch from days or weeks ago — that
  gap *is* `age_seconds`, and is the whole point of tracking it this way.
- When no raw file exists at all (true cold start, never once succeeded), both `last_ok`
  and `age_seconds` are `null`.

#### Envelope State Field Values

| Value | Meaning |
| --- | --- |
| `"ok"` | Both METAR and TAF fetches (or TTL-skips) succeeded/are fresh this run |
| `"degraded"` | Exactly one of METAR/TAF failed this run; the other is fine. `note` names which field and, when available, since when (`last_ok`) — matching the existing modem/vpn convention of degraded-for-partial-failure rather than masking it as `"ok"` |
| `"error"` | Both METAR and TAF failed this run **and** neither has any cache to fall back on (`METAR_TEXT`/`TAF_TEXT` both empty) — total failure, no `current.json` written this run |
| `"disabled"` | Profile has `enabled = false` in TOML |

The `"degraded"` state and the per-field sub-objects are both new as of the Aug 31, 2026
fix below — see Known Quirks / History. Before that, a stuck-but-present TAF cache
produced `state: "ok"` indefinitely, with no field-level signal at all.

### current.json

`shared/aviation/{profile}/current.json` — written by `fetch_aviation.sh`.

```json
{
  "generated_at": "2026-08-31T14:23:00Z",
  "stations": {
    "metar": "KMEM",
    "taf": "KMEM",
    "station_model": "KMEM"
  },
  "metar_raw": "KMEM 311420Z 21008KT 10SM SCT045 BKN250 33/22 A2995 RMK AO2 SLP138 T03330217",
  "taf_raw": "TAF KMEM 311420Z 3114/0114 21008KT P6SM SCT045\nFM311800 22012KT P6SM VCTS BKN035CB\n...",
  "station_model_raw": "KMEM 311420Z 21008KT 10SM SCT045 BKN250 33/22 A2995 RMK AO2 SLP138 T03330217"
}
```

`*_raw` fields are the literal raw-text API response, unparsed — `format=raw` on both
endpoints. `station_model_raw` equals `metar_raw` byte-for-byte whenever
`stations.station_model == stations.metar` (the common case; no second HTTP call is made
in that case — see Implementation Status). **Nothing downstream parses `taf_raw` today**
— confirmed by grep across both `gtex62-core` and `gtex62-sitrep` — so the TAF stuck-data
incident below went undetected on the display side for 18 days purely because nothing was
looking at the text's content, only `status.json`'s (then-nonexistent) staleness signal.
See Remaining Work.

---

## Configuration

`profiles/aviation/{profile}.toml`:

```toml
profile_id = "home"
enabled = true

[stations]
# Defaults come from site.toml [aviation].
# primary =
# metar =
# taf =
# station_model =
# advisories_center =

[cache]
metar_ttl_sec = 600
taf_ttl_sec = 600
advisories_ttl_sec = 600

[advisories]
enabled = false
radius_nm = 300
```

`site.toml [aviation]` fallback:

```toml
[aviation]
primary = "KMEM"
metar = "KMEM"
taf = "KMEM"
station_model = "KMEM"
advisories_center = "KMEM"
```

Resolution order per station role: profile TOML `[stations]` → `site.toml [aviation]`
same-named key → `site.toml [aviation] primary` (both `metar` and `taf` share this last
fallback) → hardcoded `KMEM`. **`[advisories]` and `advisories_center`/
`advisories_ttl_sec` are shipped config with no implementation** — `fetch_aviation.sh`
never reads or references `advisories` anywhere; this is SIGMET/AIRMET config staged
ahead of a feature that doesn't exist yet in this script (see
[legacy-suite-conversion-guide.md](legacy-suite-conversion-guide.md), which lists
`airsig_*.sh` as a legacy script this domain is meant to eventually replace). Not a bug —
just config with nothing behind it yet.

---

## Known Quirks / History

### Aug 31, 2026 — TAF stuck-data incident (root cause + fix)

**Symptom:** `taf_raw.txt` had been frozen at issue time `140251Z` for **18 days**, while
`metar_raw.txt` kept updating normally on its own cadence the entire time.
`status.json`'s `state` reported `"ok"` throughout — there was no field-level signal at
all before this fix, only the coarse both-empty check described in the pre-fix `"error"`
row above, which a stuck-but-present file never tripped.

**Root cause:** aviationweather.gov's `/api/data/taf` endpoint began hard-rejecting the
`hours=0&sep=true` query parameters this script had been sending, with HTTP 400
("Unexpected query parameter provided"). Confirmed against the endpoint's own published
OpenAPI spec (`/data/schema/openapi.yaml`): the TAF endpoint only ever documented
`ids`/`bbox`/`format`/`metar`/`time`/`date`. **`hours` was never a valid TAF parameter —
it's METAR-only** — and `sep` isn't in the spec at all. Both params had apparently been
silently accepted (or silently ignored) by the endpoint until some point in this 18-day
window, when the upstream service started enforcing its own documented contract and began
returning 400 for every TAF request. METAR's own request (`ids=...&format=raw&hours=1`,
`hours` being a real, documented METAR parameter) was unaffected — which is exactly why
only TAF went stale while METAR kept updating, and why the coarse "both empty" failure
check never caught it: METAR alone kept the *combined* condition `METAR_TEXT` and
`TAF_TEXT` both non-empty forever.

**Fix, two parts:**

1. **TAF fetch URL corrected** — now requests `?ids=${station}&format=raw` only, no
   `hours`/`sep`. Verified live: TAF updates to a current issue time again; confirmed
   dropping `sep=true` doesn't change `taf_raw`'s line-wrapping (still multi-line
   FM-group text) — moot regardless, since nothing downstream parses `taf_raw` (see
   current.json above).
2. **Per-field staleness detection added** — a failed TAF (or METAR) fetch was previously
   silently swallowed: the tmp file was discarded, the old cache left untouched, and
   `status.json` only went non-`"ok"` when *both* fields were empty, so a stuck TAF alone
   never surfaced anywhere. `status.json` now carries the per-field `metar`/`taf`
   sub-objects documented above, and the envelope `state` goes `"degraded"` when exactly
   one field is failing, with `note` naming which field and since when.

**Verified live:** simulated a forced TAF failure (old rejected params, aged cache past
TTL) and confirmed the cache file was left untouched, `status.json` showed
`state: "degraded"`, `taf.state: "error"` with the correct `last_ok`/`age_seconds`, and
the log line was tagged `TAF:`.

**Scope:** provider-side only — does not touch WXR/SitRep display logic. Nothing in
`gtex62-sitrep` reads aviation's `taf_raw`/`status.json` yet, so a display-side staleness
check (catching a stale-but-`"ok"`-looking TAF at render time too, as defense in depth)
remains a separate, later task — see Remaining Work.

**Why this belongs in a "known quirks" section, not just a changelog line:** the failure
mode — an upstream API silently tightening validation on an undocumented-but-previously-
accepted parameter combination, with the local script having no way to distinguish "API
is down" from "API now rejects a request it used to accept" — is exactly the kind of bug
that reads as instantly obvious in hindsight and take hours to find live, because the
symptom (`state: "ok"`, stale text) actively points away from the provider script. If a
different field on this or a sibling domain (weather, notably — see its Known
Constraints) ever goes stale-but-`"ok"` again, check for a silently-changed upstream
contract before assuming a local bug.

### May 6, 2026 — METAR source switched to aviationweather.gov raw API

`fetch_metar()` moved from a tgftp-decoded source to
`aviationweather.gov/api/data/metar?format=raw&hours=1`, used for all three METAR-shaped
fetches (primary METAR, TAF-station METAR if separately configured, station-model METAR).
Preserves the `$` maintenance indicator and surfaces SPECI observations when more recent
than the routine METAR — both lost under the prior decoded source.

### May 6, 2026 — station_model ICAO support added

`STATION_MODEL` resolution added (profile → `site.toml aviation.station_model` →
`aviation.metar` → `aviation.primary` chain). A separate METAR fetch for the
station-model ICAO is only issued when it differs from the primary METAR station,
stored as `station_model_raw` in `current.json` — this is what backs the WXR panel's
station-model/cloud-layer display independent of the primary conditions station.

---

## Remaining Work

- [ ] **Nothing downstream parses `taf_raw` yet** (core or SitRep) — confirmed by grep
      across both repos during the Aug 31, 2026 incident fix. The per-field staleness
      detection above is provider-side defense; a consumer that actually reads `taf_raw`
      still doesn't exist.
- [ ] **WXR-side staleness validation is a separate follow-up, not covered by this doc.**
      Even with the provider now correctly reporting `degraded`, nothing in
      `gtex62-sitrep`'s display layer currently reads `status.json`'s `metar`/`taf`
      sub-objects to surface staleness at render time — that's the next layer of defense
      against a repeat of the Aug 31 incident, and is out of scope here.
- [ ] `[advisories]` config (`advisories_center`, `advisories_ttl_sec`, `radius_nm`) is
      shipped but unimplemented — see Configuration above. SIGMET/AIRMET fetch is the
      likely intended feature; not started.
- [ ] `providers/mtr/` (the unrelated `mtr`-the-tool provider) has zero documentation
      coverage anywhere in `docs/` — deserves its own from-scratch `-status.md` doc the
      same way this one was just written. Flagged here (see Disambiguation above) but
      explicitly not this session's work.
