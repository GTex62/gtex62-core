# Engine V1 System Schema For OSA

## Purpose

This note defines the practical normalized `system` schema for engine v1, with `gtex62-osa` `SYS` as the immediate target.

Related OSA suite-cache note:

- [osa-net-cache.md](/home/gtex62/.config/conky/gtex62-osa/docs/osa-net-cache.md)

The goal is:

- make the engine own machine and OS truth
- let OSA keep its own compact projection and panel formatting
- avoid widget-local probing of `/proc`, `df`, `nvidia-smi`, and DMI data inside the suite

This follows the existing contract:

- engine defines how things work
- suite defines how things look and where they go

---

## Core Position

For engine v1, the canonical shared `system` truth should be split into:

- `current.json`
- `processes.json`
- `storage.json`
- `status.json`

Why:

- `current.json` carries the machine snapshot OSA needs every refresh
- `processes.json` isolates fast-moving top-process rows from the rest of the machine metadata
- `storage.json` isolates filesystem and swap tables cleanly
- `status.json` provides collector health without mixing operational state into panel data

OSA should consume these normalized files and build its own `SYS` display rows from them.

For OSA specifically, `SYS` now uses a fast-lane/slow-lane split:

- slow lane stays engine-owned and cache-backed
- fast lane stays suite-local and read directly at draw time

This keeps the shared contract for machine identity and inventory without degrading the usability of live telemetry.

That pattern is similar in spirit to OSA `NET`, where panel-oriented cached values live in a suite-local cache contract instead of being forced into a shared engine schema.

---

## Recommended Shared Paths

For a given profile:

- `shared/system/<profile>/current.json`
- `shared/system/<profile>/processes.json`
- `shared/system/<profile>/storage.json`
- `shared/system/<profile>/status.json`

For the current OSA binding, that is:

- `shared/system/local/current.json`
- `shared/system/local/processes.json`
- `shared/system/local/storage.json`
- `shared/system/local/status.json`

---

## `current.json`

## Top-Level Shape

```json
{
  "generated_at": "2026-04-22T03:34:14Z",
  "profile": "local",
  "os": {},
  "kernel": {},
  "uptime_seconds": 38043,
  "uptime_display": "10:34:03",
  "cpu": {},
  "memory": {},
  "gpu": {},
  "motherboard": {},
  "bios": {},
  "refs": {}
}
```

## Required Fields

- `generated_at`
- `profile`
- `os`
- `kernel`
- `uptime_seconds`
- `uptime_display`
- `cpu`
- `memory`
- `gpu`
- `motherboard`
- `bios`

## `os`

```json
{
  "name": "Linux Mint 22.3",
  "codename": "ZENA",
  "version_id": "22.3"
}
```

Required:

- `name`
- `codename`
- `version_id`

## `kernel`

```json
{
  "release": "6.17.0-22-G"
}
```

Required:

- `release`

## `cpu`

```json
{
  "model": "Intel(R) Core(TM) i9-7940X CPU @ 3.10GHz",
  "usage_percent": 8.10,
  "temperature_c": 37.43
}
```

Required:

- `model`
- `usage_percent`
- `temperature_c`

## `memory`

```json
{
  "used_bytes": 7253843968,
  "total_bytes": 67093901312,
  "usage_percent": 10.81
}
```

Required:

- `used_bytes`
- `total_bytes`
- `usage_percent`

## `gpu`

```json
{
  "model": "NVIDIA GeForce RTX 3080 Ti",
  "usage_percent": 3,
  "temperature_c": 50,
  "driver_version": "580.126.09",
  "power_w": 77.94,
  "memory": {
    "used_mb": 1041,
    "total_mb": 12288
  }
}
```

Required for engine schema:

- `model`
- `usage_percent`
- `temperature_c`
- `driver_version`
- `power_w`
- `memory.used_mb`
- `memory.total_mb`

If no GPU is present, engine may emit zero-like numeric values and an empty `model`, but the shape should remain stable.

## `motherboard`

```json
{
  "name": "PRIME X299-DELUXE II"
}
```

Required:

- `name`

## `bios`

```json
{
  "version": "4001"
}
```

Required:

- `version`

## `refs`

```json
{
  "processes": "processes.json",
  "storage": "storage.json",
  "status": "status.json"
}
```

This is optional convenience metadata for suites and debug tools.

---

## `processes.json`

## Shape

```json
{
  "generated_at": "2026-04-22T03:34:14Z",
  "top_cpu": [
    {
      "name": "code",
      "cpu_percent": 92.9
    }
  ]
}
```

Required:

- `generated_at`
- `top_cpu`

Each `top_cpu` row should include:

- `name`
- `cpu_percent`

OSA currently consumes this as the source for the CPU-side process table in `SYS`.

---

## `storage.json`

## Shape

```json
{
  "generated_at": "2026-04-22T03:34:14Z",
  "filesystems": [
    {
      "label": "/ROOT",
      "kind": "fs",
      "mount": "/",
      "size_bytes": 502392610816,
      "used_bytes": 45625262080,
      "avail_bytes": 431171977216,
      "use_percent": 10
    }
  ]
}
```

Required:

- `generated_at`
- `filesystems`

Each row should include:

- `label`
- `kind`
- `mount`
- `size_bytes`
- `used_bytes`
- `avail_bytes`
- `use_percent`

For OSA v1, the current expected rows are:

- `/ROOT`
- `/SWAP`
- `/EFT`
- `/NAS`
- `/WD`

These are OSA-facing labels, not necessarily universal engine labels for every future suite. Future engine evolution may add a more generic filesystem inventory while still allowing suite-local label binding.

---

## `status.json`

## Shape

```json
{
  "state": "ok",
  "profile": "local",
  "collector": "system",
  "generated_at": "2026-04-22T03:34:14Z",
  "note": ""
}
```

Required:

- `state`
- `profile`
- `collector`
- `generated_at`
- `note`

This file is operational metadata for the collector, not display truth.

---

## OSA Consumption Model

OSA `SYS` should derive:

- slow lane:
  - CPU box title from `cpu.model`
  - GPU box title from `gpu.model`
  - footer lines from `motherboard.name` and `bios.version`
  - storage table from `storage.json`
  - optional GPU component rows from `gpu.driver_version` and `gpu.power_w`
- fast lane:
  - status lines from local OS/kernel/uptime reads
  - CPU meter values from direct Conky/local telemetry
  - RAM meter values from direct Conky/local telemetry
  - CPU temp from direct local telemetry
  - GPU meter values from direct local telemetry
  - VRAM meter from direct local telemetry
  - GPU temp from direct local telemetry
  - process table from direct live process sampling

The engine should not render panel rows, abbreviate labels for OSA typography, or decide how the `SYS` panel allocates space.

---

## Compatibility Rule

This split is not just migration fallback.

It is the intended steady state for OSA `SYS`:

- engine publishes normalized slow-lane `system` truth
- OSA reads slow-lane shared truth for stable machine metadata
- OSA keeps high-churn telemetry local so the panel remains responsive

---

## Current Engine V1 Implementation

The current collector now writes:

- `shared/system/local/current.json`
- `shared/system/local/processes.json`
- `shared/system/local/storage.json`
- `shared/system/local/status.json`

And the launcher now refreshes `system` alongside:

- `weather`
- `aviation`

That makes `SYS` the first OSA panel after `WXR` to consume an engine-owned shared domain directly, while still preserving a suite-local fast lane for live telemetry.
