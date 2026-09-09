# System Provider Status

Current implementation state of the core `system` provider: script location, output
schemas, configuration, refresh model, and known quirks. Promoted from `system-schema.md`,
which documented this domain's schema in pre-implementation "recommended"/"should"
language even though `providers/system/fetch_system.sh` shipped with the initial engine
baseline (Apr 25–29, 2026) and has matched that recommended shape ever since — the schema
content was accurate, just voiced as a proposal for something already built, and missing
the fetch-mechanics/config/quirks writeup every other implemented domain gets. Follows the
same `-provider-status.md` structure used by
[Weather Provider Status](weather-provider-status.md) and
[Astro Provider Status](astro-provider-status.md) (`astro` was promoted out of its own
`astro-schema.md` in the same pass, for the same reason).

Companion docs: [Architecture](architecture.md) (provider pattern, cache layout, fast-lane
/ slow-lane split this domain established for OSA `SYS`), [osa-net-cache.md in
gtex62-osa](/home/gtex62/.config/conky/gtex62-osa/docs/osa-net-cache.md) (the `net`
domain's own cache-plus-live-values hybrid, cited here as the doc this domain's original
design note compared itself to, in spirit if not in exact terminology).

---

## `providers/system/fetch_system.sh` ✓ COMPLETE

```text
providers/system/fetch_system.sh <profile>
```

Profile default: `local`

Pure local-machine introspection — no network calls, no SSH, no upstream API. Reads
`/proc`, `/sys/class/dmi`, `/etc/os-release`, and shells out to `sensors`/`nvidia-smi`
when present. Implements:

- Profile TOML is optional — unlike every other domain in this repo, a missing
  `profiles/system/{profile}.toml` is **not** an error; the script just proceeds with
  `enabled` defaulting to `true` and no other config to resolve (no location, no
  credentials). Only an explicit `enabled = false` short-circuits to a `status.json`-only
  write.
- Four output files per run: `current.json` (machine snapshot), `processes.json`
  (top-CPU/top-memory tables), `storage.json` (fixed five-row filesystem table),
  `status.json` (collector health)
- CPU%, temperature, RAM%, GPU stats all read live every run — no internal TTL/freshness
  gate, matching `astro`'s pattern; the launcher's `refresh_sec` is the only cadence
  control (see Refresh Model)
- GPU stats via one `nvidia-smi --query-gpu=...` call; `num_or()` coerces any non-numeric
  field (`nvidia-smi` emits `[N/A]` when a value doesn't apply) to `0`/empty rather than
  erroring — on a machine with no GPU or no `nvidia-smi`, `gpu.model` is `""` and the
  numeric fields are all `0`, shape preserved
- CPU temperature via `sensors`, preferring a per-core average (`Core N:` lines) and
  falling back to a single package/Tctl/Tdie/CPU-Temp reading; `0` if `sensors` isn't
  installed or reports nothing matching either pattern

### CPU/Process Sampling (`sample_cpu_and_processes()`)

An embedded Python block computes both the overall CPU% and the top-CPU/top-memory
process tables from one shared `/proc` scan, interval-based against a small state file
(`$TMP_DIR/system_<profile>_cpu.state`):

- Reads `/proc/stat` totals and every `/proc/<pid>/stat`+`/proc/<pid>/statm` once, diffs
  against the previous run's saved jiffies-per-pid, normalizes to total capacity across
  all cores (same convention as Conky's `${top cpu}`)
- **Cold start / counter-reset handling**: if there's no saved state, or the saved
  `total` is >= the current `total` (state file missing, corrupted, or a rare `/proc/stat`
  counter anomaly), it takes a synchronous two-point sample instead — saves the current
  snapshot, blocks for `time.sleep(0.3)`, then re-reads `/proc/stat` and every `/proc/<pid>`
  a second time in the same run. This only happens on cold start or a genuine reset, not
  every cycle, but it does add a real 0.3s stall to that one run — worth knowing given
  `system`'s 1s default refresh interval leaves little slack.
- A process not present in the previous sample (a genuinely new PID this interval) gets
  `d = 0` jiffies delta by construction, so a brand-new CPU-heavy process always reports
  `cpu_percent: 0` for its first sampled interval regardless of actual load — it only
  shows real usage starting the *second* time it's sampled.

---

## Cache Location

```text
~/.cache/gtex62-core/shared/system/<profile>/current.json
~/.cache/gtex62-core/shared/system/<profile>/processes.json
~/.cache/gtex62-core/shared/system/<profile>/storage.json
~/.cache/gtex62-core/shared/system/<profile>/status.json
```

## Profile

```text
~/.config/gtex62-core/profiles/system/<profile>.toml
```

```toml
profile_id = "local"
enabled = true

[cache]
refresh_sec = 1
```

No location, credentials, or per-field config exists for this domain — the profile TOML
is effectively an on/off switch plus a refresh interval.

Suite TOML binding:

```toml
[profiles]
system = "local"
```

---

## `current.json`

```json
{
  "generated_at": "2026-09-09T16:18:46Z",
  "profile": "local",
  "hostname": "titan",
  "user": "gtex62",
  "os": { "name": "Linux Mint 22.3", "codename": "ZENA", "version_id": "22.3" },
  "kernel": { "release": "7.0.0-31-G", "release_full": "7.0.0-31-generic" },
  "uptime_seconds": 7722,
  "uptime_display": "02:08:42",
  "cpu": { "model": "Intel(R) Core(TM) i9-7940X CPU @ 3.10GHz", "usage_percent": 16.52, "temperature_c": 34.21 },
  "memory": { "used_bytes": 8061595648, "total_bytes": 67090481152, "usage_percent": 12.02 },
  "gpu": {
    "model": "NVIDIA GeForce RTX 3080 Ti",
    "driver_version": "580.173.02",
    "usage_percent": 10,
    "temperature_c": 46,
    "power_w": 39.34,
    "memory": { "used_mb": 1193, "total_mb": 12288 }
  },
  "motherboard": { "name": "PRIME X299-DELUXE II" },
  "bios": { "version": "4001" },
  "refs": { "processes": "processes.json", "storage": "storage.json", "status": "status.json" }
}
```

`kernel.release` abbreviates `-generic` to `-G` for OSA's compact display convention;
`kernel.release_full` (added 2026-07-19) carries the raw `uname -r` for consumers that
want it unabbreviated. `hostname`, `user`, and `kernel.release_full` were all added
2026-07-19 for clean-suite-e's `SYS` panel — see Known Quirks for their OSA consumption
status.

## `processes.json`

```json
{
  "generated_at": "2026-09-09T16:18:46Z",
  "top_cpu": [ { "name": "code", "cpu_percent": 92.9 } ],
  "top_mem": [ { "name": "thunderbird-bin", "rss_bytes": 914415616 } ]
}
```

`top_cpu` is required/original; `top_mem` was added 2026-07-19 for clean-suite-e — see
Known Quirks.

## `storage.json`

```json
{
  "generated_at": "2026-09-09T16:18:46Z",
  "filesystems": [
    { "label": "/ROOT", "kind": "fs", "mount": "/", "size_bytes": 502392610816, "used_bytes": 45625262080, "avail_bytes": 431171977216, "use_percent": 10 }
  ]
}
```

Always exactly five fixed rows, hardcoded in `write_storage_json()`: `/ROOT` (`/`),
`/SWAP` (swap, computed from `/proc/meminfo` rather than `df`), `/EFT` (`/boot/efi`),
`/NAS` (`/mnt/NAS_Data`), `/WD` (`$WD_BLACK_PATH` or `/mnt/WD_Black`). An unmounted target
still produces its row with all-zero values rather than being omitted — `df` returning
nothing just leaves `size`/`used`/`avail`/`pct` at their `0` defaults. These are
OSA-specific mount labels, not a generalized filesystem inventory.

## `status.json`

```json
{
  "state": "ok",
  "profile": "local",
  "collector": "system",
  "generated_at": "2026-09-09T16:18:46Z",
  "note": ""
}
```

`state` is `"ok"` or `"disabled"` (`enabled = false`) — there is no `"error"` state for
this domain; every read function degrades to an empty string/zero rather than failing the
whole run, so `fetch_system.sh` always reaches its final `write_status "ok" ""` once it
starts.

---

## Refresh Model

Launcher schedules a loop every `SYSTEM_TTL` seconds, read from `[cache] refresh_sec`,
default **1s** — this is one of the fast-track domains alongside `net`/`time` (see
[Architecture](architecture.md)'s TTL table). No internal staleness gate; every cycle
re-reads `/proc` and re-shells to `sensors`/`nvidia-smi` from scratch.

---

## Known Quirks

- **`top_mem`, `hostname`, `user`, and `kernel.release_full` (all added 2026-07-19 "for
  clean-suite-e `SYS`") have no OSA consumer.** Checked `lua/suite/sys.lua` directly —
  none of the four are referenced anywhere in it. OSA's `SYS` panel only ever reads
  `top_cpu`, `cpu`/`memory`/`gpu`/`motherboard`/`bios`, and `storage.json`'s rows. Not a
  bug — these fields were added for a different suite and are additive/optional by
  design — just worth knowing before assuming every field in `current.json` has an OSA
  reader.
- **Missing-profile-toml is not an error here**, unlike every other domain in this repo
  (`air`, `astro`, `weather`, etc. all write `state: "error"` and exit on a missing
  profile TOML). `system` has nothing that *requires* the profile TOML to exist, so it
  silently proceeds with defaults — correct behavior for this domain's minimal config
  surface, but a real behavioral difference from the rest of the codebase's convention.
- **The cold-start CPU sample blocks for 0.3s synchronously** — see CPU/Process Sampling,
  above. Only on cold start / a counter-reset run, but real when it happens, against a 1s
  default refresh interval.
- **A brand-new process always reports 0% CPU for its first sampled interval** — see
  CPU/Process Sampling, above.

---

## Suite Consumption

OSA's **SYS** panel (`lua/suite/sys.lua`) reads `shared/system/<profile>/`, resolving the
profile from `[profiles] system` in the suite TOML (default `"local"`). It uses a
fast-lane/slow-lane split:

- **Slow lane (core-owned, cache-backed)**: CPU/GPU box titles from `cpu.model`/
  `gpu.model`, footer lines from `motherboard.name`/`bios.version`, the storage table from
  `storage.json`, GPU driver/power detail rows from `gpu.driver_version`/`gpu.power_w`,
  and the CPU-side process table from `processes.json`'s `top_cpu` (read defensively —
  `decode_process_rows()`'s jq filter tries several possible key shapes before falling
  through to `.top_cpu`, the one that actually matches this schema).
- **Fast lane (suite-local, read at draw time, not from this cache)**: live CPU/RAM/GPU
  meter values, CPU/GPU temperatures, VRAM — OSA reads these directly rather than via the
  shared cache, for responsiveness independent of `refresh_sec`.

This mirrors the same hybrid pattern OSA's `net` panel documents for itself (cached
display-ready values from a shared cache, live values read directly via Conky
expressions) — see
[osa-net-cache.md](/home/gtex62/.config/conky/gtex62-osa/docs/osa-net-cache.md), though
that doc doesn't use the "fast-lane/slow-lane" terms this domain's own design notes
coined.
