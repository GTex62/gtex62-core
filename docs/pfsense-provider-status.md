# pfSense Provider Status

Current implementation state of the core `pfsense` provider: what's shipped, each domain's
schema, the gate-per-domain pattern, and what's left. Updated as domains land; session
prose is kept short and dated here — full narrative (bug investigations, live
cross-check output, decision rationale) lives in the dated archive snapshot.

Companion docs: [SitRep Architecture](sitrep-architecture.md) (design, stays stable),
[SitRep Relocation Plan](sitrep-relocation-plan.md) (moving the widget itself, currently
blocked on this provider's remaining work), [Network Providers Roadmap](network-providers-roadmap.md)
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
| Interfaces, CPU%, MEM%, gateway | `pf-fetch-basic.sh` (all modes) | `status.json` | 60s | ✓ Implemented |
| Router: uptime, load, firmware, hw model, BIOS | `pf-fetch-basic.sh medium`, `section=system` | `router.json` | 60s | ✓ Implemented (Aug 18, 2026) |
| pfBlockerNG: IP blocks, DNSBL hits, query total | `pf-fetch-basic.sh slow`, `section=pfblockerng` | `pfblockerng.json` | 5m | ✓ Implemented (Aug 18, 2026) |
| Pi-hole: active, totals, blocked, domains | `pf-fetch-basic.sh slow`, `section=pihole` (pi5 SSH) | `pihole.json` | 5m | ✓ Implemented (Aug 18, 2026) |
| ARP table | — | `arp.json` | 2–5m | Pending — new, not in any legacy script |
| DHCP leases | — | `leases.json` | 2–5m | Pending — new, not in any legacy script |
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
[SitRep Relocation Plan](sitrep-relocation-plan.md) § Provider Enable/Disable
— that section was the design source for this feature and still holds.
This section tracks implementation state only.

**Shipped (Aug 19, 2026):** `[providers]` / `[providers.pfsense]` added to
`~/.config/gtex62-core/core.toml` (and `examples/runtime/core.toml.example`).
`bin/gtex62-core-launch` reads `providers.pfsense.status` and skips both the
`initial_refresh` and `refresh_loop` calls for `fetch_pfsense.sh` entirely
when it's `false` (or the key/section/file is absent) — the domain is not
fetched at all, not fetched-and-discarded. `fetch_pfsense.sh` itself was not
touched; the gate is purely at the launcher's call site.

**Not yet wired (schema-only):** `vpn`, `ap`, `modem`, `router`, `pihole`,
`pfblockerng`. These flags exist in `core.toml` and are semantically
correct, but `gtex62-core-launch` currently only ever invokes
`fetch_pfsense.sh` — `fetch_router.sh`, `fetch_pfblockerng.sh`,
`fetch_pihole.sh`, `fetch_vpn.sh`, `fetch_modem.sh`, and `fetch_ap.sh` are
built and verified (see their own domain sections/session history) but were
never wired into the launcher in the first place. Flipping any of those six
flags to `true` does nothing today; wiring each script in (profile
resolution, TTL, stamp/pid files, gated `initial_refresh`/`refresh_loop`
calls — same shape as the `pfsense.status` change above) is a separate,
not-yet-scheduled task.

**SitRep display states** (Disabled / Unconfigured / existing degraded
states / Healthy) are a design note only — `lua/suite/pf.lua` doesn't exist
yet and the relocation is still blocked (see
[SitRep Relocation Plan](sitrep-relocation-plan.md), Part 0 Audit). The
design itself (four-state table, `UNCONFIGURED` reusing each provider's
existing missing-profile/placeholder-credential detection rather than new
per-provider logic in SitRep) is already fully specified there and doesn't
need re-deciding once `pf.lua` is written — just implementing.

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
    "ip": "203.0.113.1"
  },
  "interfaces": {
    "WAN": {
      "ifname": "igc0",
      "ibytes": 623456789012,
      "obytes": 54321098765,
      "fetched_at": 1754056980
    },
    "HOME": {
      "ifname": "igc1.10",
      "ibytes": 26432198765,
      "obytes": 263123456789,
      "fetched_at": 1754056980
    },
    "IOT":   { "ifname": "igc1.20", "ibytes": 0, "obytes": 0, "fetched_at": 0 },
    "GUEST": { "ifname": "igc1.30", "ibytes": 0, "obytes": 0, "fetched_at": 0 },
    "INFRA": { "ifname": "igc1.40", "ibytes": 0, "obytes": 0, "fetched_at": 0 },
    "CAM":   { "ifname": "igc1.50", "ibytes": 0, "obytes": 0, "fetched_at": 0 }
  }
}
```

#### State Field Values

| Value | Meaning |
| --- | --- |
| `"ok"` | SSH succeeded, all fields populated |
| `"degraded"` | SSH gate tripped or SSH failed; fields may be absent |
| `"disabled"` | Profile has `enabled = false` in TOML |
| `"error"` | Misconfiguration (missing profile, no ssh_target) |

This `state`/`ssh_gate` envelope shape is shared by every domain below.

**Interface rate computation** — `ibytes` and `obytes` are cumulative counters from
`netstat`. The Lua view model computes instantaneous rate by diffing two successive cache
reads:

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

---

## Planned Cache Files

All paths relative to `~/.cache/gtex62-core/`.

| Data | Cache File | Cadence | Status |
| --- | --- | --- | --- |
| Interfaces, CPU%, MEM%, gateway | `shared/pfsense/[profile]/status.json` | 60s | ✓ Implemented |
| Router uptime, load, firmware, hw model, BIOS | `shared/pfsense/[profile]/router.json` | 60s | ✓ Implemented |
| pfBlockerNG | `shared/pfsense/[profile]/pfblockerng.json` | 5m | ✓ Implemented |
| Pi-hole | `shared/pfsense/[profile]/pihole.json` | 5m | ✓ Implemented |
| ARP table | `shared/pfsense/[profile]/arp.json` | 2–5m | Pending |
| DHCP leases | `shared/pfsense/[profile]/leases.json` | 2–5m | Pending |
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

### ARP + DHCP Collection

Add to `fetch_pfsense.sh` medium-cadence SSH block. Collect both in one remote command:

```bash
# ARP table — one line per entry: MAC IP interface
arp -an | awk '/\(/{
  ip=$2; gsub(/[()]/,"",ip)
  mac=$4
  iface=$6
  printf "ARP\t%s\t%s\t%s\n", mac, ip, iface
}'

# DHCP leases — parse /var/dhcpd/var/db/dhcpd.leases for MAC + hostname
awk '
  /^lease /     { ip=$2 }
  /hardware ethernet/ { mac=$3; gsub(/;/,"",mac) }
  /client-hostname/   { host=$2; gsub(/[";]/,"",host) }
  /^}/ && ip    { printf "LEASE\t%s\t%s\t%s\n", mac, ip, host; ip=""; mac=""; host="" }
' /var/dhcpd/var/db/dhcpd.leases 2>/dev/null
```

Output written to `arp.json` and `leases.json` separately. The Python assembly block joins
them against `devices.toml` and writes the classified device list — see
[SitRep Architecture](sitrep-architecture.md) § Device Inventory for the target schema and
status classification.

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
- [ ] ARP table → `arp.json`
- [ ] DHCP leases → `leases.json`
- [ ] Verify pfBlockerNG sqlite3 paths on current pfSense version

### AP Provider

- [x] Create `providers/ap/fetch_ap.sh` — own directory, not `providers/pfsense/`
      (see [AP Provider Status](ap-provider-status.md) for why)
- [x] Collapse 3-session poll to 1 session per AP
- [x] Join client MAC+IP against `ap_ipmap.csv` (core-owned copy; `devices.toml` migration
      still pending below)
- [x] Output `ap_status.json` and `ap_clients.json`
- [x] Use `runtime/ap/ssh_state` gate

### Device Inventory

- [ ] Expand `ap_ipmap.csv` → `devices.toml` with MAC column
- [ ] Validate MAC entries against live pfSense ARP table
- [ ] Establish `devices.toml` path in `site.toml` or core config convention

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
