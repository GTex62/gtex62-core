# pfSense Provider Status

Current implementation state of the core `pfsense` provider: what's shipped, each domain's
schema, the gate-per-domain pattern, and what's left. Updated as domains land; session
prose is kept short and dated here — full narrative (bug investigations, live
cross-check output, decision rationale) lives in the dated archive snapshot.

Companion docs: [SitRep Architecture](sitrep-architecture.md) (design, stays stable),
[SitRep Relocation Plan](archive/sitrep-relocation-plan.md) (superseded — SitRep was built
out as its own sibling repo, `gtex62-sitrep`, rather than relocated into this engine as
planned; kept as the historical record of the original engine-resident approach),
[Network Providers Roadmap](network-providers-roadmap.md)
(unrelated future providers — VPN, WAN health, modem — that happen to have been drafted
alongside this one), [AP Provider Status](ap-provider-status.md) (the Zyxel AP domain —
split into its own doc since Aug 19, 2026: different device class, different auth model,
own provider directory; only shares this doc's cache directory convention). Full prose
history predating this split:
[archive/sitrep-engine-migration-2026-08-18.md](archive/sitrep-engine-migration-2026-08-18.md).

---

## Implementation Status

### `providers/pfsense/fetch_pfsense.sh` ✓ IN PROGRESS

The core pfSense provider exists and is structurally correct. It implements:

- Profile/site TOML resolution chain for SSH target and interface names
- Cache TTL check before SSH (skips poll if cache is fresh)
- Single batched SSH session collecting interfaces, CPU%, MEM%, and gateway
- Gate integration (allow check, trip on failure, reset on success)
- Atomic JSON write via Python + `os.replace()`
- Output to `shared/pfsense/{profile}/status.json`

### `providers/pfsense/pf-ssh-gate.sh` ✓ COMPLETE

Gate script is production-ready. State directory derived from `GTEX62_CACHE_DIR` /
`GTEX62_CONKY_CACHE_DIR` env vars, no dependency on `conky-env.sh` — portable as a
standalone core utility. Default state path: `$CACHE_ROOT/runtime/pfsense/ssh_state`.
Accepts a `GATE_STATE_DIR` override so other domains can point it at their own state file
(see Gate-Per-Domain Pattern below).

- **Resolved (Aug 18, 2026):** `fetch_pfsense.sh`'s inline `gate_status()` function, which
  duplicated `pf-ssh-gate.sh status`'s logic by reading the state file directly, was
  replaced with a direct call to `pf-ssh-gate.sh status`. Behavior unchanged (same default
  state dir on both sides). Verified: forced a trip, confirmed `fetch_pfsense.sh` picked up
  `state: "degraded"` correctly, reset, confirmed clean return to `state: "ok"`.

### Domain Table

| Domain | Legacy Source | Cache File | Cadence | Status |
| --- | --- | --- | --- | --- |
| Interfaces, CPU%, MEM%, gateway (incl. live loss%/latency + per-VLAN rate) | `pf-fetch-basic.sh` (all modes) | `status.json` | 60s | ✓ Implemented |
| Gateway loss/latency history (dpinger RRD window) | — | `gateway_history.json` | 60s (independent TTL, matches RRD step) | ✓ Implemented (Aug 24, 2026) |
| Router: uptime, load, firmware, hw model, BIOS | `pf-fetch-basic.sh medium`, `section=system` | `router.json` | 60s | ✓ Implemented (Aug 18, 2026) |
| pfBlockerNG: IP blocks, DNSBL hits, query total | `pf-fetch-basic.sh slow`, `section=pfblockerng` | `pfblockerng.json` | 5m | ✓ Implemented (Aug 18, 2026) |
| Pi-hole: active, totals, blocked, domains | `pf-fetch-basic.sh slow`, `section=pihole` (pi5 SSH) | `pihole.json` | 5m | ✓ Implemented (Aug 18, 2026) |
| ARP table | — | `arp.json` | 180s (independent TTL) | ✓ Implemented (Aug 19, 2026) |
| DHCP leases | — | `leases.json` | 180s (independent TTL) | ✓ Implemented (Aug 19, 2026) |
| AP status (model, CPU%, client count) | `ap_status_all_clients.sh` | `ap_status.json` | 2m | ✓ Implemented (Aug 19, 2026) — see [AP Provider Status](ap-provider-status.md) |
| AP clients (named, per AP) | `ap_clients_named.sh` | `ap_clients.json` | 2m | ✓ Implemented (Aug 19, 2026) — see [AP Provider Status](ap-provider-status.md) |

---

## Gate-Per-Domain Pattern

Each domain that talks to a host over SSH gets its **own** circuit-breaker state, even
when it shares a host with another domain. A tripped/slow domain must never block or be
blocked by an unrelated one. All gates reuse the single `pf-ssh-gate.sh` script via its
`GATE_STATE_DIR` env override (default unset → `runtime/pfsense`).

| Domain | SSH Target | Gate State Dir |
| --- | --- | --- |
| `fetch_pfsense.sh` (interfaces/CPU/MEM/gateway) | `pf` | `runtime/pfsense` (default) |
| `fetch_router.sh` | `pf` (same host) | `runtime/router` |
| `fetch_pfblockerng.sh` | `pf` (same host) | `runtime/pfblockerng` |
| `fetch_pihole.sh` | `pi5` (separate host) | `runtime/pihole` |
| AP provider (planned) | Zyxel WBE530 ×3 (direct IP, password auth) | `runtime/ap` |

Same-host domains (`router`, `pfblockerng`) share nothing but the target IP — reasoning is
identical whether the host is shared or not: heavier/slower queries on one domain must not
trip the circuit breaker for a faster, unrelated poll on the same box.

### Circuit Breaker Backoff

| Fail Count | Cooldown |
| --- | --- |
| 1 | 3s |
| 2 | 10s |
| 3 | 30s |
| 4 | 120s |
| 5+ | 600s |

---

## Provider Enable/Disable

Full design (schema, missing-file behavior, SitRep display states) lives in
[SitRep Relocation Plan](archive/sitrep-relocation-plan.md) § Provider Enable/Disable
— that section was the design source for this feature and still holds, though the plan
doc itself is now archived/superseded (see the companion-docs line above).
This section tracks implementation state only.

**Shipped (Aug 19, 2026):** `[providers]` / `[providers.pfsense]` added to
`~/.config/gtex62-core/core.toml` (and `examples/runtime/core.toml.example`).
`bin/gtex62-core-launch` reads `providers.pfsense.status` and skips both the
`initial_refresh` and `refresh_loop` calls for `fetch_pfsense.sh` entirely
when it's `false` (or the key/section/file is absent) — the domain is not
fetched at all, not fetched-and-discarded. `fetch_pfsense.sh` itself was not
touched; the gate is purely at the launcher's call site.

**Wired (Aug 22, 2026):** `vpn`, `ap`, `modem`, `router`, `pihole`,
`pfblockerng` are now all gated into `gtex62-core-launch` the same shape as
`pfsense.status` — profile resolution, per-script `cache_ttl_sec`-matched
TTL, suite-scoped stamp/PID files, gated `initial_refresh`/`refresh_loop`
calls. `router`/`pihole`/`pfblockerng` reuse the existing `PFSENSE_PROFILE`
(same `profiles/pfsense/{profile}.toml` the pfsense-status domain already
reads); `vpn`/`ap`/`modem` get their own profile vars. See CHANGELOG.md's
Unreleased entry for the wiring details and live verification, and each
domain's own dated entry above for the scripts' original build/verification
(unchanged by this wiring pass — no script was touched).

**Wired (Aug 24, 2026):** `alerts` is now gated into `gtex62-core-launch`
the same shape as the six above — its own `ALERTS_PROFILE` (suite.toml's
`profiles.alerts`, default `main_router`), a `profiles/alerts/{profile}.toml`
`cache_ttl_sec` lookup (no such file ships yet, so this falls through to a
60s default every time today — kept as a real lookup, not skipped, so a
future profile file just works), suite-scoped stamp/PID files, gated
`initial_refresh`/`refresh_loop` calls. See CHANGELOG.md's Unreleased entry
for details and live verification.

**SitRep display states** (Disabled / Unconfigured / existing degraded
states / Healthy) were a design note only as of Aug 19, 2026, when
`lua/suite/pf.lua` didn't exist yet and this relocation was blocked here
(see [SitRep Relocation Plan](archive/sitrep-relocation-plan.md), Part 0
Audit — now archived/superseded). SitRep was since built out separately as
its own repo, `gtex62-sitrep`, where `lua/suite/pf.lua` does now exist and
is wired to live core cache data; whether these four display states
specifically ended up implemented there hasn't been checked from this repo.
The design itself (four-state table, `UNCONFIGURED` reusing each provider's
existing missing-profile/placeholder-credential detection rather than new
per-provider logic in SitRep) remains a reasonable reference regardless of
where it landed.

---

## Domain Schemas

### status.json

`shared/pfsense/{profile}/status.json` — written by `fetch_pfsense.sh`.

```json
{
  "state": "ok",
  "profile": "main_router",
  "collector": "pfsense",
  "generated_at": "2025-08-01T14:23:00Z",
  "ssh_target": "pf",
  "ssh_gate": {
    "status": "OK",
    "tripped": false,
    "left_seconds": 0,
    "reason": ""
  },
  "cpu_pct": 4,
  "mem_pct": 31,
  "gateway": {
    "online": true,
    "ip": "203.0.113.1",
    "loss_pct": 0.0,
    "latency_ms": 2.7,
    "latency_stddev_ms": 0.4
  },
  "interfaces": {
    "WAN": {
      "ifname": "igc0",
      "ibytes": 623456789012,
      "obytes": 54321098765,
      "fetched_at": 1754056980,
      "rate_ibytes_per_sec": 323287.8,
      "rate_obytes_per_sec": 33807.9,
      "prev_fetched_at": 1754056920
    },
    "HOME": {
      "ifname": "igc1.10",
      "ibytes": 26432198765,
      "obytes": 263123456789,
      "fetched_at": 1754056980,
      "rate_ibytes_per_sec": 1000.5,
      "rate_obytes_per_sec": 6660.0,
      "prev_fetched_at": 1754056920
    },
    "IOT":   { "ifname": "igc1.20", "ibytes": 0, "obytes": 0, "fetched_at": 0, "rate_ibytes_per_sec": null, "rate_obytes_per_sec": null, "prev_fetched_at": null },
    "GUEST": { "ifname": "igc1.30", "ibytes": 0, "obytes": 0, "fetched_at": 0, "rate_ibytes_per_sec": null, "rate_obytes_per_sec": null, "prev_fetched_at": null },
    "INFRA": { "ifname": "igc1.40", "ibytes": 0, "obytes": 0, "fetched_at": 0, "rate_ibytes_per_sec": null, "rate_obytes_per_sec": null, "prev_fetched_at": null },
    "CAM":   { "ifname": "igc1.50", "ibytes": 0, "obytes": 0, "fetched_at": 0, "rate_ibytes_per_sec": null, "rate_obytes_per_sec": null, "prev_fetched_at": null }
  }
}
```

`gateway.loss_pct`/`latency_ms`/`latency_stddev_ms` (0.4.0, Aug 24, 2026) are dpinger's own
rolling 60s average, read live off its polling socket (`/var/run/dpinger_WAN_DHCP~*.sock`) —
additive alongside the pre-existing `online`/`ip`, which are untouched. Absent (key not
present, not `null`) when the socket glob comes back empty (dpinger not running, `WAN_DHCP6`
matched instead — can't happen, see below) rather than a fabricated zero. A companion
duration-window history of the same dpinger quality data (`rrdtool fetch` against pfSense's
own `WAN_DHCP-quality.rrd`) is written separately to `gateway_history.json` — see its own
schema section below.

**Per-VLAN rate fields** — `rate_ibytes_per_sec`/`rate_obytes_per_sec` (bytes, not bits —
matches the existing `ibytes`/`obytes` naming) and `prev_fetched_at` are computed server-side
each cycle by `fetch_pfsense.sh` itself: before overwriting `status.json`, it reads the
*previous* file's `interfaces.<VLAN>.ibytes`/`obytes`/`fetched_at` and diffs against the
freshly-collected values (moving the "Interface rate computation" Lua reference below
server-side, since it's a fact, not a display choice). `prev_fetched_at` is the timestamp of
the sample the rate was diffed against, so a consumer can see the actual delta-t used rather
than assuming a fixed cadence. Both rate fields are `null` (never a fabricated 0) whenever
there's no valid previous sample to diff against — cold start, a previous cycle that landed on
a degraded/error/disabled stub (which omits `interfaces` entirely), or a 32-bit counter
wraparound on that direction (`now_bytes >= prev_bytes` guard, same convention as the Lua
reference below); a wraparound on only one direction leaves the other direction's rate valid
independently.

#### State Field Values

| Value | Meaning |
| --- | --- |
| `"ok"` | SSH succeeded, all fields populated |
| `"degraded"` | SSH gate tripped or SSH failed; fields may be absent |
| `"disabled"` | Profile has `enabled = false` in TOML |
| `"error"` | Misconfiguration (missing profile, no ssh_target) |

This `state`/`ssh_gate` envelope shape is shared by every domain below.

**Interface rate computation (historical reference — now done server-side, see the
per-VLAN rate fields above)** — `ibytes` and `obytes` are cumulative counters from
`netstat`. This sketch of a Lua view model computing instantaneous rate by diffing two
successive cache reads predates `rate_ibytes_per_sec`/`rate_obytes_per_sec` landing in
`status.json` itself; kept here as the reference the server-side computation above was
moved from (same diff/guard logic, same reasoning), not as a pattern a consumer still
needs to implement:

```lua
-- lua/suite/pf.lua
local prev = {}

function M.iface_rate_mbps(key)
  local now_bytes = tonumber(jq(PF .. "status.json",
    ".interfaces." .. key .. ".ibytes // 0"))
  local now_ts    = tonumber(jq(PF .. "status.json",
    ".interfaces." .. key .. ".fetched_at // 0"))
  local rate = 0
  if prev[key] and now_ts > prev[key].ts and now_bytes >= prev[key].bytes then
    local delta_bytes = now_bytes - prev[key].bytes
    local delta_t     = now_ts   - prev[key].ts
    rate = (delta_bytes * 8) / (delta_t * 1e6)   -- Mbps
  end
  prev[key] = { bytes = now_bytes, ts = now_ts }
  return rate
end
```

Counter wraparound on 32-bit interfaces (some virtual/legacy interfaces on FreeBSD wrap at
~4GB; modern interfaces report 64-bit) is handled by the `now_bytes >= prev[key].bytes`
guard — on wrap the delta is skipped for one cycle.

### gateway_history.json

`shared/pfsense/{profile}/gateway_history.json` — written by `fetch_pfsense.sh` (0.4.0, Aug
24, 2026), piggybacked on its existing SSH session same as `arp.json`/`leases.json` — no new
session, no new gate. A window of samples, not a point value, so it's kept apart from
`status.json`.

```json
{
  "state": "ok",
  "profile": "main_router",
  "collector": "gateway_history",
  "generated_at": "2026-08-24T03:00:00Z",
  "ssh_target": "pf",
  "ssh_gate": { "status": "OK", "tripped": false, "left_seconds": 0, "reason": "" },
  "gateway": "WAN_DHCP",
  "rrd_file": "WAN_DHCP-quality.rrd",
  "step_sec": 60,
  "window_sec": 1200,
  "samples": [
    { "ts": 1756004400, "loss_pct": 0.0, "latency_ms": 2.7, "latency_stddev_ms": 0.4 }
  ]
}
```

Source is `rrdtool fetch` against pfSense's own `WAN_DHCP-quality.rrd` (already written for
its Status > Monitoring graphs, not new tooling), at 1-min resolution. `window_sec` defaults
to 1200 (20min) — margin over the design notes' aspirational "≥25% for >15min" gateway
condition without hardcoding that 15min figure into collection. IPv4 (`WAN_DHCP`) only,
matching the single-WAN-link framing of that condition; `WAN_DHCP6` can be added the same way
later if ever needed. Own independent TTL (`gateway_history_cache_ttl_sec`, default 60s,
matching the RRD's native step) — same piggyback-cadence pattern as `arp_cache_ttl_sec`, not
rewritten when not due. Header/blank rows and not-yet-consolidated (`nan`) rows from `rrdtool
fetch` are dropped before building `samples`.

- Feeds the alert banner's future duration-based gateway condition — not a display meter.
  As of this writing no SitRep Lua reads it yet (`pf.lua`'s GATEWAY meter is still a static
  placeholder).
- **Verified (Aug 24, 2026):** live against the real box, alongside the live
  `gateway.loss_pct`/`latency_ms`/`latency_stddev_ms` dpinger-socket read added in the same
  session. Confirmed no existing consumer breaks: no SitRep Lua read `status.json`'s
  `gateway{}` object yet, and `fetch_alerts.sh`'s SEVERE gateway-offline trigger reads only
  `gateway.online`, unaffected.

### router.json

`shared/pfsense/{profile}/router.json` — written by `fetch_router.sh`.

```json
{
  "state": "ok",
  "profile": "main_router",
  "collector": "router",
  "generated_at": "2026-08-19T03:55:04Z",
  "ssh_target": "pf",
  "ssh_gate": { "status": "OK", "tripped": false, "left_seconds": 0, "reason": "" },
  "uptime_seconds": 5464088,
  "load": { "l1": 0.24, "l5": 0.23, "l15": 0.15 },
  "version": "2.8.1-RELEASE",
  "hw_model": "Intel(R) Celeron(R) N5105 @ 2.00GHz",
  "ncpu": 4,
  "physmem_bytes": 8406269952,
  "bios_version": "3mdeb Dasharo (coreboot+UEFI) v0.9.3 (09/06/2024)"
}
```

`uptime_seconds`/`physmem_bytes`/`ncpu` are `null` on parse failure (same sentinel
convention as `status.json`'s `cpu_pct`/`mem_pct`); `version`/`hw_model`/`bios_version`
default to `""`; `load` defaults to `{"l1":0.0,"l5":0.0,"l15":0.0}`.

- **Named `router.json`, not `system.json`** (Aug 18, 2026): `providers/system/` already
  owns `current.json` for the *host* machine. This is pfSense's own router-side data — a
  different machine, different cache directory — `router.json` avoids the naming
  collision entirely.
- CPU%/MEM% utilization deliberately **not** duplicated here — already in `status.json`
  from `fetch_pfsense.sh`'s own `top` sample.
- **Bug found and fixed during porting:** the legacy `pf-fetch-basic.sh`'s boot-time
  regex (`.*sec[[:space:]]*=...`) greedily matches `usec` instead of `sec` in
  `sysctl -n kern.boottime`'s output, producing a garbage uptime (~56 years). Fixed here
  with an anchored pattern (`^\{ sec = ([0-9]+),.*`); legacy script's copy of the bug is
  left undocumented-but-unpatched there (tech-hud is read-only, headed for replacement).
- **Verified (Aug 18, 2026):** live cross-check against `pf-fetch-basic.sh medium`.
  `physmem_bytes`, `ncpu`, `hw_model`, `version`, `bios_version` matched exactly.
  `load.l1/l5/l15` differed by ~0.01–0.02 (sampling drift, expected). `uptime_seconds`
  differed structurally — that's the bug above, not a porting error; the new value
  matches the router's own live `uptime` output.

### pfblockerng.json

`shared/pfsense/{profile}/pfblockerng.json` — written by `fetch_pfblockerng.sh`.

```json
{
  "state": "ok",
  "profile": "main_router",
  "collector": "pfblockerng",
  "generated_at": "2026-08-19T03:36:41Z",
  "ssh_target": "pf",
  "ssh_gate": { "status": "OK", "tripped": false, "left_seconds": 0, "reason": "" },
  "pfb_ip_total": 2335487,
  "pfb_dnsbl_total": 21120,
  "pfb_dnsbl_pct": 0.13,
  "resolver_total": 16083636
}
```

`pfb_ip_total` sums the `Packets:` evaluation count across all `USER_RULE: pfB_*` rules
excluding `pfB_DNSBL_*` (`pfctl -vvsr`). `pfb_dnsbl_total` is `SUM(counter)` from the
DNSBL sqlite table. `resolver_total` is `totalqueries + queries` from the resolver
sqlite's `row=0` entry. `pfb_dnsbl_pct` is derived provider-side
(`pfb_dnsbl_total / resolver_total * 100`).

- **Gated independently** (`runtime/pfblockerng`) even though same host as
  `fetch_pfsense.sh` — these queries (`pfctl` rule walk + two `sqlite3` reads) are
  heavier and slower-cadence than the fast interfaces/CPU/MEM poll.
- **Verified (Aug 18, 2026):** live cross-check against `pf-fetch-basic.sh slow`,
  `section=pfblockerng`. All four fields matched **exactly** (2335487 / 21120 / 16083636
  / 0.13 on both sides) — no drift, no structural mismatch.

### pihole.json

`shared/pfsense/{profile}/pihole.json` — written by `fetch_pihole.sh`.

```json
{
  "state": "ok",
  "profile": "main_router",
  "collector": "pihole",
  "generated_at": "2026-08-19T03:15:22Z",
  "ssh_target": "pi5",
  "ssh_gate": { "status": "OK", "tripped": false, "left_seconds": 0, "reason": "" },
  "active": true,
  "load": { "l1": 0.03, "l5": 0.03, "l15": 0.0 },
  "queries_total": 34681284,
  "queries_blocked": 16667741,
  "blocked_pct": 48.06,
  "domains_blocked": 282899
}
```

`domains_blocked` is the gravity DB's distinct-domain count (size of the active
blocklist), not a count of blocked queries. `blocked_pct` is derived
(`queries_blocked / queries_total`).

- **Separate host** (`pi5`, not `pf`) — own SSH session, own gate (`runtime/pihole`).
  Never routed through the pfSense SSH session or gate.
- `pf-ssh-gate.sh` gained its `GATE_STATE_DIR` override this session (backward
  compatible, default behavior unchanged when unset) specifically to support this.
- **Verified (Aug 18, 2026):** live cross-check against `pf-fetch-basic.sh slow`,
  `section=pihole`. `active`/`total`/`blocked`/`domains` matched exactly. `load1`
  differed by 0.01 (sampling noise between two independent `/proc/loadavg` reads).

### arp.json

`shared/pfsense/{profile}/arp.json` — written by `fetch_pfsense.sh` (not a separate script —
piggybacked on its existing SSH session, no new gate).

```json
{
  "state": "ok",
  "profile": "main_router",
  "collector": "arp",
  "generated_at": "2026-08-19T23:39:50Z",
  "ssh_target": "pf",
  "ssh_gate": { "status": "OK", "tripped": false, "left_seconds": 0, "reason": "" },
  "entries": [
    { "mac": "64:62:66:2f:2a:3e", "ip": "192.168.100.5", "iface": "igc0" }
  ]
}
```

`entries` is the ARP table (raw, unjoined — no `devices.toml` classification here; see
Remaining Work below). Parsed from `arp -an`, filtered to `$3=="at" && $4!="(incomplete)"`
— pfSense reports unresolved neighbors as `? (ip) at (incomplete) on iface expired
[ethernet]`, which the roadmap's original `/\(/` match let through as a garbage row (mac
became the interface name, ip became the literal string `"incomplete"`). Found via local
dry-run against synthetic fixtures, confirmed live: 1 of 47 raw lines on the live box was an
`(incomplete)` entry, correctly excluded, leaving 46 clean entries.

### leases.json

`shared/pfsense/{profile}/leases.json` — written by `fetch_pfsense.sh`, same session as
`arp.json`.

```json
{
  "state": "ok",
  "profile": "main_router",
  "collector": "leases",
  "generated_at": "2026-08-19T23:39:50Z",
  "ssh_target": "pf",
  "ssh_gate": { "status": "OK", "tripped": false, "left_seconds": 0, "reason": "" },
  "entries": [
    { "mac": "84:ea:ed:6e:18:b8", "ip": "192.168.1.100", "hostname": "RokuUltraLivingRoom" }
  ]
}
```

`entries` is parsed from `/var/dhcpd/var/db/dhcpd.leases`; `hostname` defaults to `""` when
a lease has no `client-hostname` line (common — many DHCP clients don't send one). Includes
leases in any `binding state` (not just `active`) — raw collection, no filtering; that
belongs to the future join/classify step.

**Independent write cadence, same SSH session** — `arp.json`/`leases.json` are gated by
their own mtime-based TTL (`arp_cache_ttl_sec`, default 180s; root key in profile TOML,
falls back to `[pfsense] arp_cache_ttl_sec` in `site.toml`), computed before the SSH call
and used to decide whether to append the ARP+DHCP awk block to `fetch_pfsense.sh`'s existing
remote command string — still exactly one SSH call, no new session, no new gate. When not
due, the files are left untouched rather than overwritten with an empty stub. Persistent
misconfiguration states (missing profile, disabled, no ssh_target) stub both files
unconditionally; transient states (gate tripped, ssh failed) only stub them if they were due
that round, so a shared-session hiccup doesn't clobber still-valid cached entries.

Known coupling, not fixed: the outer script's exit-early check is keyed to `status.json`'s
own `cache_ttl_sec` (30s in `main_router.toml`) — if that were ever raised past
`arp_cache_ttl_sec`, arp/leases would be starved of their turn to run. Non-issue at current
config values.

- **Verified (Aug 19, 2026):** mechanical — `jq .` valid on both files, `entries` populated,
  no empty mac/ip fields, degraded-path stubs (`entries: []`) confirmed via a forced
  missing-profile-toml run. Live cross-check against the pfSense box: `arp.json` — 46
  entries after the incomplete-entry fix, matching raw `arp -an` line count minus the 1
  incomplete entry exactly. `leases.json` — 18 entries, matching `grep -c '^lease '` on the
  live `dhcpd.leases` file exactly, no drift. Confirmed the three existing SSH-shared
  domains (`status.json`, `router.json`, `pfblockerng.json`) still return `state: "ok"`
  after this change. Confirmed the independent-TTL skip: re-running immediately left
  `arp.json`'s mtime unchanged.

---

## Planned Cache Files

All paths relative to `~/.cache/gtex62-core/`.

| Data | Cache File | Cadence | Status |
| --- | --- | --- | --- |
| Interfaces, CPU%, MEM%, gateway | `shared/pfsense/[profile]/status.json` | 60s | ✓ Implemented |
| Gateway loss/latency history | `shared/pfsense/[profile]/gateway_history.json` | 60s (independent TTL) | ✓ Implemented |
| Router uptime, load, firmware, hw model, BIOS | `shared/pfsense/[profile]/router.json` | 60s | ✓ Implemented |
| pfBlockerNG | `shared/pfsense/[profile]/pfblockerng.json` | 5m | ✓ Implemented |
| Pi-hole | `shared/pfsense/[profile]/pihole.json` | 5m | ✓ Implemented |
| ARP table | `shared/pfsense/[profile]/arp.json` | 180s (independent TTL) | ✓ Implemented |
| DHCP leases | `shared/pfsense/[profile]/leases.json` | 180s (independent TTL) | ✓ Implemented |
| AP status (model, CPU%, client count) | `shared/pfsense/[profile]/ap_status.json` | 2m | ✓ Implemented |
| AP clients (named, per AP) | `shared/pfsense/[profile]/ap_clients.json` | 2m | ✓ Implemented |

---

## Known Constraints

**Zyxel password auth** — WBE530 APs do not support key-based SSH. `sshpass` with a
password file at `~/.config/zyxel_ap/.pass` is required. This is a permanent hardware
constraint, not a TODO.

**pfBlockerNG sqlite3 paths** — Hardcoded to `/var/unbound/pfb_py_dnsbl.sqlite` and
`/var/unbound/pfb_py_resolver.sqlite`. Verify these paths after pfSense or pfBlockerNG
version upgrades.

**Pi-hole SSH target** — Pi-hole is queried via SSH alias `pi5`, not through pfSense.
The `pihole.json` provider must maintain a distinct SSH session. Do not route Pi-hole
queries through the pfSense SSH session or gate.

**Interface counter width** — `netstat` on FreeBSD/pfSense reports 64-bit counters on
modern interfaces, but some virtual or legacy interfaces may wrap at 32 bits (~4GB). The
Lua rate computation guards against this by skipping cycles where `now_bytes < prev_bytes`.

---

## Remaining Work

### ARP + DHCP Collection ✓ IMPLEMENTED (Aug 19, 2026)

Shipped as an addition to `fetch_pfsense.sh`'s existing SSH block — see `arp.json`/
`leases.json` schemas above for the full design (independent write-cadence TTL, escaping,
the `(incomplete)`-entry fix found during live cross-check).

Deliberately out of scope this session (held for its own): joining `arp.json`/`leases.json`
against `devices.toml` and writing a classified device list. `devices.toml` itself
(expanding `ap_ipmap.csv` with a MAC column) was not touched — see
[SitRep Architecture](sitrep-architecture.md) § Device Inventory for the target schema and
status classification this next session will build.

### AP Provider ✓ IMPLEMENTED (Aug 19, 2026)

Moved to its own doc — [AP Provider Status](ap-provider-status.md) — since it's a genuinely
separate provider (own `providers/ap/` directory, different device class, different auth
model), not a pfSense-host domain like the sections above it. The schemas and session-batching
sketch that used to live in this section are now out of date and have been superseded there;
see that doc for the shipped `ap_status.json`/`ap_clients.json` schemas, the MAC↔IP join
design, and full cross-check results against both legacy scripts. Uses the `runtime/ap` gate
(see Gate-Per-Domain Pattern above), reusing `pf-ssh-gate.sh` directly rather than duplicating
it.

---

## Remaining Work Checklist

### Gate

- [x] Port `pf-ssh-gate.sh` to core — state path from env vars, no `conky-env.sh`
- [x] pfSense gate deployed: `runtime/pfsense/ssh_state`
- [x] Per-domain gate pattern proven out: `runtime/pihole`, `runtime/pfblockerng`,
      `runtime/router` all live (Aug 18, 2026)
- [x] AP gate deployed: `runtime/ap/ssh_state` (Aug 19, 2026)
- [x] Resolve inline `gate_status()` duplication in `fetch_pfsense.sh` — replaced with
      call to `pf-ssh-gate.sh status` (Aug 18, 2026, see Implementation Status above)

### pfSense Provider

- [x] `fetch_pfsense.sh` — profile/TOML resolution, cache TTL, batched SSH, atomic write
- [x] Interfaces (ibytes/obytes per VLAN) → `status.json`
- [x] CPU%, MEM% → `status.json`
- [x] Gateway online/IP → `status.json`
- [x] System info (uptime, load, version, BIOS) → `router.json` (`fetch_router.sh`, Aug 18, 2026)
- [x] pfBlockerNG (IP blocks, DNSBL, query total) → `pfblockerng.json` (`fetch_pfblockerng.sh`, Aug 18, 2026)
- [x] Pi-hole (active, totals, blocked, domains) → `pihole.json` (`fetch_pihole.sh`, Aug 18, 2026)
- [x] ARP table → `arp.json` (Aug 19, 2026, piggybacked on `fetch_pfsense.sh`'s session)
- [x] DHCP leases → `leases.json` (Aug 19, 2026, same session)
- [x] Live gateway loss%/latency (dpinger socket) → `status.json`'s `gateway{}` (Aug 24, 2026)
- [x] Gateway loss/latency history (RRD window) → `gateway_history.json` (Aug 24, 2026)
- [x] Per-VLAN instantaneous rate (`rate_ibytes_per_sec`/`rate_obytes_per_sec`,
      `prev_fetched_at`) → `status.json`'s `interfaces.<VLAN>` (Aug 25, 2026 — see Session
      History)
- [ ] Verify pfBlockerNG sqlite3 paths on current pfSense version

### AP Provider

- [x] Create `providers/ap/fetch_ap.sh` — own directory, not `providers/pfsense/`
      (see [AP Provider Status](ap-provider-status.md) for why)
- [x] Collapse 3-session poll to 1 session per AP
- [x] Join client MAC+IP against `devices.toml` (Aug 20, 2026 — migrated from the
      core-owned `ap_ipmap.csv` copy; see Device Inventory checklist below)
- [x] Output `ap_status.json` and `ap_clients.json`
- [x] Use `runtime/ap/ssh_state` gate

### Device Inventory

- [x] Expand `ap_ipmap.csv` → `devices.toml` with MAC column (Aug 20, 2026 —
      see Session History)
- [x] Validate MAC entries against live pfSense ARP table (Aug 20, 2026)
- [x] Establish `devices.toml` path in core config convention — co-located
      with `core.toml` at `~/.config/gtex62-core/devices.toml` (Aug 20, 2026);
      not referenced from `site.toml` — no provider wiring this session
- [x] Wire `devices.toml` into `fetch_ap.sh`'s MAC↔IP client join, retiring
      the `ap_ipmap.csv` read (Aug 20, 2026 — see Session History)
- [x] Add `examples/runtime/devices.toml.example` bootstrap template — real
      `devices.toml` was excluded from the repo/template system same as
      `core.toml`/`site.toml`, leaving fresh installs with no seed file;
      `install_template()`'s skip-if-exists logic now generates a working
      starting file (5 sanitized `[vlan.*]` sections, fake MAC/IP placeholder
      entries, `ip:`-keyed no-MAC example) on first bootstrap (Aug 22, 2026)

---

## Session History

Condensed; full prose (verification transcripts, decision rationale, live cross-check
output) is in [archive/sitrep-engine-migration-2026-08-18.md](archive/sitrep-engine-migration-2026-08-18.md).

- **Aug 18, 2026 — Pi-hole domain.** `fetch_pihole.sh` shipped. `pf-ssh-gate.sh` gained
  `GATE_STATE_DIR` override (backward compatible). New `[pihole]` section in `site.toml`.
  Cross-checked exactly against `pf-fetch-basic.sh slow` except expected load-average
  sampling drift.
- **Aug 18, 2026 — pfBlockerNG domain.** `fetch_pfblockerng.sh` shipped, gated
  independently (`runtime/pfblockerng`) despite sharing the `pf` host with
  `fetch_pfsense.sh`. Cross-checked as an **exact** match against `pf-fetch-basic.sh slow`.
- **Aug 18, 2026 — Router (system) domain.** `fetch_router.sh` shipped as `router.json`
  (not `system.json` — naming collision avoidance, see schema section above). Found and
  fixed a real bug in the legacy reference script's uptime parsing (greedy regex matched
  `usec` instead of `sec`). Cross-checked exact match on all fields except the now-fixed
  uptime.
- **Aug 19, 2026 — AP provider.** `providers/ap/fetch_ap.sh` shipped in its own directory —
  new territory (new device class, password auth via `sshpass`, no existing core provider to
  extend). Full detail split to [AP Provider Status](ap-provider-status.md) rather than kept
  here (own auth model, own directory — not a pfSense-host domain like the three above).
  Collapsed the legacy 3-sessions-per-AP poll to 1. Cross-checked live against both legacy
  scripts: model/CPU%/client-count and all known-client names matched exactly across all 3
  APs, including a raw-vs-filtered client-count discrepancy that reproduced identically on
  both old and new code (not a porting bug — preserved as-is).

All three domains from the original resume checklist (Pi-hole, pfBlockerNG, router/system)
are done, and the AP provider that was next after them is now done too. ARP and DHCP
collection remain.

- **Aug 19, 2026 — Provider enable/disable.** `[providers]`/`[providers.pfsense]`
  schema shipped in `core.toml`; `gtex62-core-launch` gates the one call it
  already makes (`fetch_pfsense.sh`, on `providers.pfsense.status`). Scoped
  deliberately narrow: the other six flags are schema-only since the scripts
  they'd gate (`router`/`pfblockerng`/`pihole`/`vpn`/`modem`/`ap`) were never
  wired into the launcher to begin with — wiring them in is separate,
  larger-diff work against the shared launcher, left for its own session.
  Found and worked around a real parser limitation during verification (see
  § Provider Enable/Disable above and CHANGELOG.md): the shared TOML-section
  parser doesn't strip trailing comments, so the Pi-hole hosting note was
  placed on its own line rather than trailing `pihole = false`.
- **Aug 19, 2026 — ARP + DHCP collection.** `arp.json`/`leases.json` shipped as an addition
  to `fetch_pfsense.sh`'s existing SSH block — no new session, no new gate, per explicit
  scoping for this session. Added an independent mtime-based TTL (`arp_cache_ttl_sec`,
  default 180s) so the two outputs get their own slower write cadence despite sharing the
  30s-cadence session; the ARP+DHCP awk commands are only appended to the remote command
  string when due, and the two files are only rewritten when due (never clobbered with an
  empty stub on an off-cycle round). Persistent misconfiguration states stub both files
  unconditionally; transient gate-tripped/ssh-failed states only stub them if they were due
  that round. Found and fixed a real bug during live cross-check: the roadmap's `/\(/`
  ARP filter let pfSense's `? (ip) at (incomplete) on iface expired [ethernet]` lines
  through as garbage rows (mac field became the interface name) — a local dry-run against
  synthetic fixtures caught a naive version of this, but the live box's actual format
  (`at (incomplete)`, not a different field layout) needed a second live-verified fix
  (`$4!="(incomplete)"`). Cross-checked live: 46 clean ARP entries (47 raw lines minus 1
  incomplete, exact match) and 18 lease entries (exact match against
  `grep -c '^lease ' dhcpd.leases`). Confirmed the three domains already sharing this SSH
  session (`status.json`, `router.json`, `pfblockerng.json`) still return `state: "ok"`
  after the change. Deliberately did not touch `devices.toml`, `ap_ipmap.csv`, or any
  join/classification logic — held for its own session per scoping.
- **Aug 20, 2026 — `devices.toml` built and validated.** New MAC-keyed device inventory at
  `~/.config/gtex62-core/devices.toml` (co-located with `core.toml`), retiring the
  hand-maintained, IP-keyed `ap_ipmap.csv` (read-only reference this session, not edited).
  Covers all 5 VLANs (51 devices total: 6 User, 25 IoT, 1 Guest, 9 Infra, 10 Cameras), not
  just AP clients. MAC/IP/VLAN/name/hostname sourced from the network design PDF;
  `display_name` (short fixed-width labels) sourced from `ap_ipmap.csv`. Two known-offline
  WLEDs (192.168.20.4/.5) have no MAC — keyed `"ip:<addr>"` instead of by MAC, with an
  explicit `mac = ""` field, confirmed with the user before writing. The V1211 router's MAC
  (missing from the PDF) was resolved against live `arp.json` (`64:62:66:2f:2a:3f` at
  `igc1.40`/192.168.40.1). VLAN 30 (Guest) has no static-IP table in the PDF; its one entry
  (the "A14" phone, `display_name` from `ap_ipmap.csv`) got its real MAC
  (`e2:77:2c:da:18:09`) and full name directly from the user rather than a source document.
  Normalized one PDF typo (`WEB530` to `WBE530`, matching the device's own hostname and every
  other reference to it). Validated live against `arp.json`/`leases.json`: 38 of 49
  MAC-bearing devices confirmed present in ARP with matching IP, 0 IP mismatches. 11
  documented devices not currently in ARP (likely idle/ARP-aged-out — printers, a 3D
  printer, switches/APs — not confirmed offline, flagged not assumed). 2 MACs in ARP
  outside devices.toml, both WAN-side/ISP (igc0), correctly out of scope. `leases.json`
  cross-check found only stale pre-VLAN-migration `192.168.1.0/24` lease history (consistent
  MACs, different subnet) plus 2 unrecognized MACs (one hostnamed "iPad", likely Apple MAC
  randomization on a different network) — flagged, not added speculatively. Scoped
  deliberately narrow per this session's instructions: did not touch `fetch_ap.sh`'s
  MAC-to-IP join logic, did not wire `devices.toml` into any provider, did not build
  known-MAC-on-wrong-IP detection — all held for a later session.
- **Aug 20, 2026 — `fetch_ap.sh` wired to `devices.toml`.** Swapped the AP-client
  MAC↔IP join from the core-owned `ap_ipmap.csv` copy (IP-keyed) to `devices.toml`
  (MAC-keyed, all 5 VLANs) — `devices.toml`'s content was not touched this session, only
  wired in as the new lookup source. The embedded Python's CSV `load_ipmap()` was
  replaced with `load_devicemap()` using stdlib `tomllib`, joined on `mac.lower()`
  instead of `ip`; the two `ip:`-keyed offline-WLED entries (no MAC) are skipped by
  design, matching their existing absence from AP client lists. `ap_clients.json`'s
  schema, the `0.0.0.0`/`172.29.*` IP pre-filter, and the unknown-IP fallback behavior
  were left byte-for-byte unchanged — only the lookup key changed. Verified: `jq .`
  valid on the live output; spot-checked 4 known MACs resolve to their exact
  `devices.toml` `display_name`. Live cross-check: ran the pre-change script (old
  `ap_ipmap.csv` path) and the new script back-to-back against the real APs, each into
  its own scratch cache root, to hold the live station population constant between the
  two — every known client's `mac`/`ip`/`name` row matched byte-for-byte across all 3
  APs, `unknown` counts identical (0 on both, all APs). `fetch_ap.sh` no longer reads
  `ap_ipmap.csv` at all; neither copy of the file (the read-only `gtex62-tech-hud`
  original or the core-owned copy) was edited or deleted, per guardrail — the
  core-owned copy is now unread by any provider, cleanup left for later. `[ap]
  ipmap_path` in `site.toml` is now unused config, left in place — not part of this
  session's scope.
- **Aug 25, 2026 — Per-VLAN instantaneous rate.** Closed the one open question from
  `gtex62-osa/design/osa-design-notes.md`'s NET-panel-redesign scoping first: checked live
  via SSH whether pfSense tracks per-VLAN sub-interface traffic in its own RRD. It does —
  `/var/db/rrd/{wan,lan,opt1..opt5}-traffic.rrd` exist and are live-updating (confirmed
  `opt1`–`opt5` map to `HOME`/`IOT`/`GUEST`/`INFRA`/`CAM` via `config.xml`'s `<interfaces>`
  block), so the rolling-window RRD option was viable infrastructure-wise after all — but
  per the scoping conclusion this doesn't reopen the decision, since the diff approach still
  wins on the recorded tradeoffs (no new SSH round-trip, no new gate). Implemented the diff
  approach in `fetch_pfsense.sh`: before overwriting `status.json` each due cycle, the
  Python block now reads the *previous* file's `interfaces.<VLAN>.ibytes`/`obytes`/
  `fetched_at` (falling back to an empty dict on a missing file, unparsable JSON, or a prior
  degraded/error/disabled stub with no `interfaces` key — all treated as cold start) and
  diffs against the freshly-collected values, writing `rate_ibytes_per_sec`/
  `rate_obytes_per_sec`/`prev_fetched_at` alongside the raw counters — no new SSH call, no
  new gate, no new cache file. Also fixed the doc drift flagged in the design notes: the
  `0.4.0` (Aug 24, 2026) `gateway.loss_pct`/`latency_ms`/`latency_stddev_ms` fields and the
  `gateway_history.json` domain had shipped and were in `CHANGELOG.md` but not yet in this
  doc's schema block or Domain Table — both now folded in, plus a new `gateway_history.json`
  schema section. Verified live against the real box: two poll cycles ~44s apart produced
  sane, differing per-VLAN rates (spot-checked against the raw counter deltas by hand); a
  forced missing-`status.json` cold start produced `null`/`null`/`null` for all six VLANs; a
  forced prior degraded-stub (no `interfaces` key) produced the same null result on the next
  real cycle without error; a forged prior sample with one direction's counter set above the
  current value (simulated wrap) produced `null` for only that direction while the other
  direction's rate computed normally, with `prev_fetched_at` still populated. `gtex62-osa`
  not touched this session, per scoping — the NET panel build against this field is a
  separate follow-up session.
