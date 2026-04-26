# Core V1 Astro Schema For OSA

## Purpose

This note defines a practical normalized `astro` schema for core v1, with `gtex62-osa` as the immediate target.

Related OSA suite-cache note:

- [osa-orb-cache.md](/home/gtex62/.config/conky/gtex62-osa/docs/osa-orb-cache.md)

The goal is:

- make the core own astronomical truth
- let suites choose their own projection and rendering language
- avoid forcing future suites to inherit the legacy volvelle `theta` model as the canonical representation

This follows the existing rule:

- core defines how things work
- suite defines how things look and where they go

---

## Core Position

For core v1, the canonical astro truth should be:

- altitude
- azimuth
- rise time
- set time
- above/below horizon state

Optional compatibility values such as legacy `theta` may still be exposed, but they should not be the primary shared truth.

Why:

- `altitude` directly answers visible vs not visible
- `azimuth` is human-meaningful and suite-agnostic
- `rise_ts` and `set_ts` support schedule-style displays
- `theta` is useful for legacy suite rendering, but it is a projection artifact rather than the source truth

---

## Recommended Shared Layers

### Layer 1: Raw

Provider-native fetch or computed ephemeris data.

Examples:

- PyEphem / Skyfield calculations
- OWM sunrise/sunset for sun fallback
- station latitude / longitude

This layer remains core-internal.

### Layer 2: Normalized Shared Astro

Core should publish a normalized model that any suite can consume directly.

Suggested path:

- `shared/astro/<profile>/current.json`

Optional supporting files:

- `shared/astro/<profile>/bodies.json`
- `shared/astro/<profile>/status.json`

### Layer 3: Suite-Derived View Model

Suite-local projection data for a particular visual language.

Examples:

- OSA CELESTIAL time-band rows
- Tri-HUD flattened volvelle line
- LCARS orbital/globe placement

This layer belongs to the suite, not the core.

For OSA’s current implementation, the immediate suite-cache layer is documented separately in:

- [osa-orb-cache.md](/home/gtex62/.config/conky/gtex62-osa/docs/osa-orb-cache.md)

---

## Recommended Canonical Schema

## Top-Level

```json
{
  "generated_at": "2026-04-21T17:31:38Z",
  "observer": {
    "lat": 35.033333,
    "lon": -89.983333,
    "timezone": "America/Chicago"
  },
  "sun": {},
  "moon": {},
  "planets": {},
  "status": {}
}
```

## Observer

```json
{
  "lat": 35.033333,
  "lon": -89.983333,
  "timezone": "America/Chicago"
}
```

Required:

- `lat`
- `lon`
- `timezone`

---

## Body Schema

Each body should use the same normalized shape where possible.

```json
{
  "name": "Jupiter",
  "id": "jupiter",
  "altitude_deg": 17.4,
  "azimuth_deg": 348.2,
  "is_above_horizon": true,
  "rise_ts": 1776787605,
  "set_ts": 1776839220,
  "next_rise_ts": 1776873803,
  "next_set_ts": 1776839220,
  "prev_rise_ts": 1776701407,
  "prev_set_ts": 1776753028,
  "heading_deg": 78,
  "legacy_theta_deg": 348.2
}
```

### Required Canonical Fields

- `name`
- `id`
- `altitude_deg`
- `azimuth_deg`
- `is_above_horizon`

### Strongly Recommended Timing Fields

- `rise_ts`
- `set_ts`
- `prev_rise_ts`
- `prev_set_ts`
- `next_rise_ts`
- `next_set_ts`

These support:

- current visibility
- wrapped overnight visibility windows
- schedule projections like OSA CELESTIAL

### Optional Compatibility Fields

- `heading_deg`
- `legacy_theta_deg`

Definitions:

- `heading_deg` is the human-facing heading OSA displays after rotating the legacy convention into a more intuitive value
- `legacy_theta_deg` preserves compatibility for suites that already use the old flattened volvelle cycle

Canonical truth should still remain:

- `altitude_deg`
- `azimuth_deg`
- `is_above_horizon`

---

## Sun-Specific Notes

The sun should use the same body schema, but core may populate rise/set from a weather or solar provider if that is the current authoritative source.

Example:

```json
{
  "name": "Sun",
  "id": "sun",
  "altitude_deg": 66.8,
  "azimuth_deg": 163.3,
  "is_above_horizon": true,
  "rise_ts": 1776770401,
  "set_ts": 1776818260,
  "heading_deg": 73,
  "legacy_theta_deg": 343
}
```

If a better solar provider exists in the core later, the schema does not need to change.

---

## Moon-Specific Notes

The moon especially needs:

- cross-midnight rise/set support
- `prev_*` and `next_*` timing fields

Without those, schedule-style suite displays often break on days where rise and set fall on different calendar dates.

OSA already demonstrated why these fields matter.

---

## OSA Consumption Model

OSA ORB does not need the core to render anything. It only needs consistent truth fields.

OSA may also keep a suite-local cache or projection layer between shared `astro` truth and panel rendering, as long as that cache is treated as OSA-specific derived data rather than canonical core astronomy truth.

### CELESTIAL Box

OSA should derive:

- body label
- visible band start/end from rise/set
- current marker from current local time
- visibility correction from `is_above_horizon` or `altitude_deg > 0`
- DATA column from:
  - `rise_ts/set_ts` for sun and moon
  - `heading_deg` plus signed altitude for planets

### TERMINATOR Box

OSA should derive:

- flat map terminator window from UTC and solar geometry
- optional night/day overlays

No special core projection output is required for this.

---

## Legacy Compatibility Model

Legacy suites can continue to use a compatibility field:

- `legacy_theta_deg`

That allows:

- Tri-HUD flattened volvelle behavior
- LCARS legacy orbital placements
- smoother migration without rewriting every astro widget at once

But this field should be documented as:

- compatibility / suite-projection support
- not canonical astro truth

---

## Recommended Status Block

Optional but useful:

```json
{
  "provider": "pyephem",
  "state": "ok",
  "generated_at": "2026-04-21T17:31:38Z",
  "age_seconds": 12
}
```

Suggested fields:

- `provider`
- `state`
- `generated_at`
- `age_seconds`

This helps suites display:

- `EPHEMERIS // ACTIVE`
- stale-data warnings later if needed

---

## Suggested Core Output Example

```json
{
  "generated_at": "2026-04-21T17:31:38Z",
  "observer": {
    "lat": 35.033333,
    "lon": -89.983333,
    "timezone": "America/Chicago"
  },
  "sun": {
    "name": "Sun",
    "id": "sun",
    "altitude_deg": 66.8,
    "azimuth_deg": 163.3,
    "is_above_horizon": true,
    "rise_ts": 1776770401,
    "set_ts": 1776818260,
    "prev_rise_ts": 1776770401,
    "prev_set_ts": 1776731811,
    "next_rise_ts": 1776856729,
    "next_set_ts": 1776818260,
    "heading_deg": 73,
    "legacy_theta_deg": 343
  },
  "moon": {
    "name": "Moon",
    "id": "moon",
    "altitude_deg": 34.0,
    "azimuth_deg": 256.4,
    "is_above_horizon": true,
    "rise_ts": 1776781591,
    "set_ts": 1776837561,
    "prev_rise_ts": 1776781591,
    "prev_set_ts": 1776747424,
    "next_rise_ts": 1776872116,
    "next_set_ts": 1776837561,
    "heading_deg": 76,
    "legacy_theta_deg": 346
  },
  "planets": {
    "jupiter": {
      "name": "Jupiter",
      "id": "jupiter",
      "altitude_deg": 24.0,
      "azimuth_deg": 348.0,
      "is_above_horizon": true,
      "rise_ts": 1776787605,
      "set_ts": 1776839220,
      "prev_rise_ts": 1776787605,
      "prev_set_ts": 1776753028,
      "next_rise_ts": 1776873803,
      "next_set_ts": 1776839220,
      "heading_deg": 78,
      "legacy_theta_deg": 348
    }
  },
  "status": {
    "provider": "pyephem",
    "state": "ok",
    "generated_at": "2026-04-21T17:31:38Z",
    "age_seconds": 12
  }
}
```

---

## Recommendation Summary

- Canonical core astro truth should be `altitude`, `azimuth`, `is_above_horizon`, and rise/set timing.
- `legacy_theta` should remain optional compatibility output only.
- OSA should consume the canonical truth and derive its own CELESTIAL and TERMINATOR views.
- Legacy suites can continue to consume `legacy_theta` during migration.
- Core should normalize astronomy once, but never enforce one suite's projection as the only representation.
