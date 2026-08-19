# SitRep Engine Migration

Migrating SitRep from a self-contained widget to an engine-driven operational console.

---

## Purpose

SitRep began as a network status display specific to the home infrastructure. It currently
performs data collection, device identification, status analysis, and rendering in a single
pass — running its own SSH sessions, maintaining its own IP-to-name map, and doing its own
join at draw time.

As the engine architecture matures, SitRep should become a pure presentation layer: it asks
the engine for information and displays what it receives. All collection, correlation, and
classification logic moves to the engine's `pfsense` provider.

This document captures the current script inventory, the migration plan, and the design
decisions made during the transition.

---

## Core Principle

> **The engine gathers knowledge. SitRep reports status.**

SitRep is not a desktop widget. It is a command-center utility whose purpose is to answer
one question: *"What is happening on my network right now?"*

It must remain independent of any suite. Whether Clean Suite, Tech HUD, Tri HUD, LCARS, or
OSA is active — or nothing is active — the command `sitrep` must work in any terminal.

---

## Current Architecture

SitRep currently acts as all four layers simultaneously:

```
Collector + Database + Analysis Engine + Display
```

### Scripts in Production (Legacy)

| Script | Role | SSH Target |
| --- | --- | --- |
| `pf-ssh-gate.sh` | Circuit breaker / backoff state machine | — |
| `pf-fetch-basic.sh` | pfSense system, interfaces, pfBlockerNG, Pi-hole | `pf` alias (key auth) |
| `ap_status_all_clients.sh` | AP model, CPU%, client count per AP | Zyxel WBE530 (password auth) |
| `ap_clients_named.sh` | AP client list with IP→Name resolution | Zyxel WBE530 (password auth) |
| `zyxel_cmd.sh` | SSH transport for Zyxel APs via sshpass | Zyxel WBE530 |
| `pf-rate-all-test.sh` | Dev/diagnostic: live rate sampling all VLANs | `pf` alias |
| `pf-rate-infra-test.sh` | Dev/diagnostic: live rate sampling INFRA only | `pf` alias |

### Device Identity Source

`config/ap_ipmap.csv` — static IP→Name map, VLAN-organized, comment-delimited.
Read at runtime by `ap_clients_named.sh` into a bash associative array for the join.

### Current Data Flow

```
ap_ipmap.csv  ─────────────────────────────────────┐
                                                    ▼
WBE530 SSH ──► zyxel_cmd.sh ──► ap_status_all_clients.sh ──► display
                             └► ap_clients_named.sh  ───────► display

pfSense SSH ──► pf-ssh-gate.sh (allow/trip/reset)
            └► pf-fetch-basic.sh (MODE=full|medium|slow) ──► display
```

---

## Future Architecture

```
devices.toml          ──► static identity registry (MAC → name, type, location, VLAN)
pfSense ARP table     ──► dynamic state (MAC → current IP, interface)
pfSense DHCP leases   ──► corroborating data (MAC → hostname, lease TTL)
                              │
                         engine join
                              │
                         ┌────┴──────────────┐
                         │  pfsense provider  │
                         │  (core)            │
                         └────┬──────────────┘
                              │
                    ┌─────────┴──────────┐
                    │   cache files       │
                    └─────────┬──────────┘
                              │
                           SitRep
                         (display only)
```

The engine owns all SSH sessions, all joins, and all status classification. SitRep reads
from cache and renders. If the engine is not running, SitRep reads from whatever cache
exists and displays a staleness indicator in the status slot.

---

## Implementation Status

### providers/pfsense/fetch_pfsense.sh ✓ IN PROGRESS

The core pfSense provider exists and is structurally correct. It implements:

- Profile/site TOML resolution chain for SSH target and interface names
- Cache TTL check before SSH (skips poll if cache is fresh)
- Single batched SSH session collecting interfaces, CPU%, MEM%, and gateway
- Gate integration (allow check, trip on failure, reset on success)
- Atomic JSON write via Python + `os.replace()`
- Output to `shared/pfsense/{profile}/status.json`

The following data domains from the legacy `pf-fetch-basic.sh` are **not yet ported**:

| Domain | Legacy Mode | Status |
| --- | --- | --- |
| System (uptime, load, version, BIOS, hw model) | `medium` | Not yet ported |
| pfBlockerNG (IP blocks, DNSBL hits, query total) | `slow` | Not yet ported |
| Pi-hole (active, totals, blocked, domains) | `slow` (pi5 SSH) | ✓ Implemented — `fetch_pihole.sh` (Aug 18, 2026) |
| ARP table | — | New — not in any legacy script |
| DHCP leases | — | New — not in any legacy script |

AP collection and device inventory are separate providers, not yet started.

### providers/pfsense/pf-ssh-gate.sh ✓ COMPLETE

Gate script is production-ready. Key improvements over legacy version:

- State directory derived from `GTEX62_CACHE_DIR` / `GTEX62_CONKY_CACHE_DIR` env vars
- No dependency on `conky-env.sh` — portable as a standalone core utility
- State path: `$CACHE_ROOT/runtime/pfsense/ssh_state`

**Resolved (Aug 18, 2026):** `fetch_pfsense.sh`'s inline `gate_status()` function, which
read the state file directly and duplicated `pf-ssh-gate.sh status`'s logic, has been
replaced with a direct call to `pf-ssh-gate.sh status`. `GATE_STATE_DIR` is left unset for
this call (same as the existing `trip`/`reset` calls), which resolves to `pf-ssh-gate.sh`'s
default state dir — identical to `fetch_pfsense.sh`'s own `$GATE_DIR`
(`${CACHE_ROOT}/runtime/pfsense`) — so behavior is unchanged. Verified directly: forced a
trip via `pf-ssh-gate.sh trip TEST_REASON`, confirmed `fetch_pfsense.sh` picked up
`state: "degraded"` / `ssh_gate.tripped: true` / correct `left_seconds` and `reason`, then
reset and confirmed a clean return to `state: "ok"`.

---

## status.json Schema (Current)

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

### state field values

| Value | Meaning |
| --- | --- |
| `"ok"` | SSH succeeded, all fields populated |
| `"degraded"` | SSH gate tripped or SSH failed; fields may be absent |
| `"disabled"` | Profile has `enabled = false` in TOML |
| `"error"` | Misconfiguration (missing profile, no ssh_target) |

### Interface rate computation

`ibytes` and `obytes` are cumulative counters from `netstat`. The Lua view model computes
instantaneous rate by diffing two successive cache reads:

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

Counter wraparound on 32-bit interfaces is handled by the `now_bytes >= prev[key].bytes`
guard — on wrap the delta is skipped for one cycle.

---

## Planned Cache Files

All paths relative to `~/.cache/gtex62-core/`.

| Data | Cache File | Cadence | Status |
| --- | --- | --- | --- |
| Interfaces, CPU%, MEM%, gateway | `shared/pfsense/[profile]/status.json` | 60s | ✓ Implemented |
| System (uptime, load, version, BIOS) | `shared/pfsense/[profile]/system.json` | 60s | Pending |
| pfBlockerNG | `shared/pfsense/[profile]/pfblockerng.json` | 5m | Pending |
| Pi-hole | `shared/pfsense/[profile]/pihole.json` | 5m | ✓ Implemented |
| ARP table | `shared/pfsense/[profile]/arp.json` | 2–5m | Pending |
| DHCP leases | `shared/pfsense/[profile]/leases.json` | 2–5m | Pending |
| AP status (model, CPU%, client count) | `shared/pfsense/[profile]/ap_status.json` | 2m | Pending |
| AP clients (named, per AP) | `shared/pfsense/[profile]/ap_clients.json` | 2m | Pending |

---

## Device Inventory

`ap_ipmap.csv` is the seed for a proper device registry. The engine model requires MAC
as the stable identity key — IP addresses are dynamic (DHCP), but MAC is permanent.

### Current CSV Format

```
# IP,Name
192.168.10.3,Titan
192.168.40.4,WBE530 (Closet)
```

### Target Format — `devices.toml`

```toml
[[device]]
mac      = "aa:bb:cc:dd:ee:ff"
name     = "Titan"
type     = "Workstation"
vlan     = 10
location = "Office"
owner    = "GTex62"
notes    = "RTX 3080 Ti, Linux Mint"

[[device]]
mac      = "11:22:33:44:55:66"
name     = "WBE530 (Closet)"
type     = "Access Point"
vlan     = 40
location = "Closet"
```

The engine joins `devices.toml` against the live ARP table from pfSense. Devices in the
ARP table with no matching MAC entry are flagged `UNKNOWN`. Devices in `devices.toml`
absent from the ARP table are flagged `OFFLINE` or `UNREACHABLE` depending on last-seen
data.

**MAC discovery procedure** — for any device not yet in `devices.toml`, boot the device,
let it acquire a DHCP lease, then check the pfSense ARP table: Diagnostics → ARP Table
in the web UI, or `arp -an` via SSH.

### Device Status Classification

The engine assigns one of the following before SitRep ever sees the data:

| Status | Meaning |
| --- | --- |
| `ONLINE` | Present in ARP table, IP matches expected VLAN |
| `OFFLINE` | Known device, absent from ARP table |
| `APIPA` | 169.254.x.x address — DHCP failure |
| `ROAMING` | Present in ARP table on unexpected VLAN |
| `UNREACHABLE` | ARP present but not responding to probe |
| `UNKNOWN` | MAC not in `devices.toml` |

SitRep only renders status. Classification belongs to the engine.

---

## SSH Architecture

### Two SSH Targets, Two Auth Methods

| Target | Alias | Auth | Gate State Path |
| --- | --- | --- | --- |
| pfSense (V1211) | `pf` | Key-based, `BatchMode=yes` | `runtime/pfsense/ssh_state` |
| Zyxel WBE530 (×3) | Direct IP | `sshpass` + password file | `runtime/ap/ssh_state` |

These use **separate gate state files**. A tripped pfSense connection must not block AP
polling and vice versa. The current `pf-ssh-gate.sh` derives its state path from
`CACHE_ROOT` — the AP gate will use the same script with a different `state_dir` export
or a `--state-dir` parameter.

### Circuit Breaker Backoff

| Fail Count | Cooldown |
| --- | --- |
| 1 | 3s |
| 2 | 10s |
| 3 | 30s |
| 4 | 120s |
| 5+ | 600s |

---

## Pending: system.json

Commands to add to `fetch_pfsense.sh` for the system domain. These were in `pf-fetch-basic.sh`
`medium` mode and should be batched into the existing SSH session:

```bash
uname -a
uptime
sysctl -n kern.boottime hw.model hw.ncpu hw.physmem
cat /etc/version
kenv smbios.bios.version smbios.bios.vendor smbios.bios.reldate 2>/dev/null
```

Output writes to `shared/pfsense/{profile}/system.json`. Suggested schema:

```json
{
  "generated_at": "2025-08-01T14:23:00Z",
  "version":      "2.8.1",
  "hw_model":     "Intel(R) Celeron(R) N5105",
  "ncpu":         4,
  "physmem_bytes": 8589934592,
  "bios_version": "0.9.3",
  "uptime_seconds": 1234567,
  "load": { "l1": 0.26, "l5": 0.18, "l15": 0.14 }
}
```

---

## Pending: ARP + DHCP Collection

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
them against `devices.toml` and writes the classified device list.

---

## Pending: AP Provider

### Session Optimization

Current `ap_status_all_clients.sh` opens 3 SSH sessions per AP (version, CPU, station
info) = 9 connections for 3 APs. Target is 1 session per AP:

```bash
zyxel_cmd.sh "$ip" $'show version\nshow cpu status\nshow wireless-hal station info\nexit'
```

### Output Schema — ap_status.json

```json
{
  "generated_at": "2025-08-01T14:23:00Z",
  "aps": [
    {
      "label":   "CLOSET",
      "ip":      "192.168.40.4",
      "model":   "WBE530",
      "cpu_pct": 5,
      "clients": 7
    },
    {
      "label":   "OFFICE",
      "ip":      "192.168.40.5",
      "model":   "WBE530",
      "cpu_pct": 4,
      "clients": 6
    },
    {
      "label":   "GREAT ROOM",
      "ip":      "192.168.40.6",
      "model":   "WBE530",
      "cpu_pct": 7,
      "clients": 15
    }
  ]
}
```

### Output Schema — ap_clients.json

```json
{
  "generated_at": "2025-08-01T14:23:00Z",
  "aps": [
    {
      "label": "CLOSET",
      "ip":    "192.168.40.4",
      "clients": [
        { "mac": "aa:bb:cc:dd:ee:ff", "ip": "192.168.20.12", "name": "Ka Nght Stnd" },
        { "mac": "11:22:33:44:55:66", "ip": "192.168.20.13", "name": "Ka Piano" }
      ],
      "unknown": []
    }
  ]
}
```

Clients with no matching entry in `devices.toml` appear in the `unknown` array as raw IPs.
The join happens in the provider, not in SitRep.

---

## SitRep as Cache Consumer

In the migrated model, SitRep's Lua view model reads from engine cache paths only.

```lua
-- lua/suite/pf.lua (SitRep view model)

local HOME  = os.getenv("HOME") or ""
local CACHE = os.getenv("GTEX62_CACHE_DIR") or (HOME .. "/.cache/gtex62-core")
local PF    = CACHE .. "/shared/pfsense/default/"

local function jq(path, filter)
  local cmd = string.format("jq -r %q %q 2>/dev/null", filter, path)
  local h = io.popen(cmd)
  if not h then return "" end
  local s = h:read("*a")
  h:close()
  return (s or ""):gsub("^%s*(.-)%s*$", "%1")
end

function M.gateway_online()
  return jq(PF .. "status.json", ".gateway.online // false")
end

function M.iface_ibytes(key)
  return tonumber(jq(PF .. "status.json", ".interfaces." .. key .. ".ibytes // 0"))
end

function M.ap_clients(ap_index)
  -- Returns array of {name, ip, mac} tables
  return jq(PF .. "ap_clients.json",
    ".aps[" .. ap_index .. "].clients[] | .name // .ip")
end

function M.cache_age_seconds()
  local h = io.popen("stat -c %Y " .. PF .. "status.json 2>/dev/null")
  if not h then return nil end
  local mtime = tonumber(h:read("*a"))
  h:close()
  if not mtime then return nil end
  return os.time() - mtime
end
```

### Staleness Indicator

The `ONLINE` status slot in the top-right of the widget becomes cache-aware:

| Condition | Display |
| --- | --- |
| Cache fresh, gateway online | `ONLINE` |
| Cache fresh, gateway offline | `OFFLINE` |
| Cache age > 120s (2× poll cadence) | `STALE · 4m ago` |
| `ssh_gate.tripped == true` in cache | `SSH DOWN` |
| `status.json` missing | `NO DATA` |

---

## sitrep.lua — File Split and Dead Code Removal

The current `sitrep.lua` contains three distinct Cairo widgets and a significant amount of
dead code from the original graphical SitRep design. Before relocation, the file must be
split and cleaned.

### Current File Contents

| Section | Lines (approx) | Status |
| --- | --- | --- |
| `conky_draw_sitrep()` and sitrep-specific helpers | ~40% of file | Keep — relocate to engine |
| `draw_system_impl()` / `conky_draw_system()` / `conky_draw_system_embed()` | ~25% of file | Move to tech-hud suite |
| `draw_network_impl()` / `conky_draw_network()` / `conky_draw_network_embed()` | ~25% of file | Move to tech-hud suite |
| Dead code from original graphical SitRep design | ~10% of file | Delete |

### Dead Code — Delete Entirely

These functions and variables are defined but never called in the `conky_draw_sitrep()`
draw path. They are remnants of the original gauge/arc-based SitRep design:

**Arc drawing infrastructure** — used only by system/network circle widgets, not SitRep:
- `draw_arc_meter()`
- `draw_text_arc()`
- `polar()`
- `arc_span_ccw()`
- `arc_span_cw()`

**Graphical meter functions** — defined, never called in sitrep draw path:
- `draw_meters()` — vertical bar meters for VRM/GPU/RAM/CPU
- `draw_pfsense_meters()` — paired in/out bar meters per VLAN; references a
  `conky_pf_rates()` function from the old pfSense arc widget era

**Network EMA smoothing** — belongs to `draw_network_impl`, not SitRep:
- `net_ema` table
- All EMA update logic inside `draw_network_impl`

**Unused summary function:**
- `pf_summary()` — defined, never called; superseded by `pf_data_full()`

**WAN IP helpers** — used only by `draw_network_impl`:
- `wan_ip_label_short()`
- `refresh_wan_ip()`

**OS version and age display** — used only by `draw_system_impl`:
- `os_label_text()`
- `get_root_birth_ts()`
- `OS_AGE_CACHE` table

**Seasonal tint system** — used only by system/network circle widgets:
- `current_season_label()`
- `read_seasonal_vars()`
- `day_of_year_for_date()`
- `SEASON_CACHE` table
- `blend_color()`

### Code to Move — System and Network Circle Widgets

`draw_system_impl()`, `conky_draw_system()`, and `conky_draw_system_embed()` are a
complete self-contained Cairo widget. Move to:

```
gtex62-tech-hud/lua/widgets/system.lua
```

`draw_network_impl()`, `conky_draw_network()`, and `conky_draw_network_embed()` are a
complete self-contained Cairo widget. Move to:

```
gtex62-tech-hud/lua/widgets/network.lua
```

The `_embed()` variants use `util.embedded_corner_offset()` from the suite's `util.lua`
and depend on `t.embedded_corners` from the suite theme — they are suite-coupled by
design and belong in the suite, not the engine.

### What Remains in sitrep.lua After Split

The cleaned engine-resident `widgets/sitrep/sitrep.lua` contains only:

**Utility functions** (keep as-is):
- `trim()`, `to_num()`, `clamp()`, `cparse()`
- `draw_text_right()`, `text_width()`, `draw_round_rect()`
- `fmt_bytes_iec()`, `fmt_int_commas()`, `fmt_uptime()`

**Theme loader** (keep, update path):
- `get_sitrep_theme()` — update to resolve from `GTEX62_CORE_DIR`, not `CONKY_SUITE_DIR`

**Data layer** (replace with engine cache reads):
- `parse_kv()` — remove once data source is JSON cache
- `pf_data_full()` — replace with `jq` reads from `status.json`, `system.json`
- `ap_cached_output()` — remove; engine provider writes cache directly
- `parse_ap_status()` — remove; engine provides structured `ap_status.json`
- `parse_ap_clients_named()` — remove; engine provides structured `ap_clients.json`
- `ap_blocks()` — replace with `jq` reads from `ap_status.json`, `ap_clients.json`

**Draw functions** (keep as-is — pure Cairo, no data coupling):
- `draw_pfsense_totals()`
- `draw_pfsense_status()`
- `draw_centered_segments()`
- `draw_hr_at()`
- AP block renderer inside `conky_draw_sitrep()`

**Main entrypoint** (keep, update data reads):
- `conky_draw_sitrep()` — update all data reads from `parse_kv/cparse/execi` pattern
  to `jq(cache_path, filter)` pattern

### Data Read Migration Map

Every data read in `conky_draw_sitrep()` maps to an engine cache file:

| Current Read | Pattern | Engine Cache | JSON Path |
| --- | --- | --- | --- |
| Gateway online | `pf-fetch-basic.sh medium` via execi | `status.json` | `.gateway.online` |
| pfSense version | `pf-fetch-basic.sh full` cached | `system.json` | `.version` |
| pfSense BIOS | same | `system.json` | `.bios_version` |
| Load average | same | `system.json` | `.load.l5` |
| CPU core count | same | `system.json` | `.ncpu` |
| Interface ibytes | same | `status.json` | `.interfaces.WAN.ibytes` |
| Interface obytes | same | `status.json` | `.interfaces.WAN.obytes` |
| pfBlockerNG IP count | same | `pfblockerng.json` | `.pfb_ip_total` |
| pfBlockerNG DNSBL count | same | `pfblockerng.json` | `.pfb_dnsbl_total` |
| pfBlockerNG hit pct | same | `pfblockerng.json` | `.pfb_dnsbl_pct` |
| Resolver total queries | same | `pfblockerng.json` | `.resolver_total` |
| Pi-hole active | same | `pihole.json` | `.active` |
| Pi-hole load | same | `pihole.json` | `.load15` |
| Pi-hole total queries | same | `pihole.json` | `.total` |
| Pi-hole blocked | same | `pihole.json` | `.blocked` |
| Pi-hole domains | same | `pihole.json` | `.domains` |
| AP CPU% | `ap_status_all_clients.sh` cached | `ap_status.json` | `.aps[n].cpu_pct` |
| AP client count | same | `ap_status.json` | `.aps[n].clients` |
| AP known client names | `ap_clients_named.sh` cached | `ap_clients.json` | `.aps[n].clients[].name` |
| AP unknown client IPs | same | `ap_clients.json` | `.aps[n].unknown[].ip` |

### Suite Dependency Removals

The following suite-coupled references must be removed or replaced in the engine-resident
file:

| Current Reference | Action |
| --- | --- |
| `SUITE_DIR` (all uses) | Replace with `CORE_DIR` from `GTEX62_CORE_DIR` env var |
| `CACHE_DIR` (legacy conky cache) | Replace with `GTEX62_CACHE_DIR` engine cache paths |
| `WD_BLACK_PATH` | Remove — disk label is a system widget concern, not SitRep |
| `util = dofile(SUITE_DIR .. "/lua/lib/util.lua")` | Replace with engine-resident util or inline the needed functions |
| `pcall(dofile, ... "/lua/widgets/widgets.lua")` | Remove — suite widget loader |
| `pcall(dofile, ... "/lua/widgets/pf_widget.lua")` | Remove — legacy pfSense widget |
| `CONKY_CACHE_DIR` / `PF_CACHE_DIR` / `AP_CACHE_DIR` | Replace with engine cache paths |

---



### Current Location and Problem

```
~/.config/conky/gtex62-tech-hud/widgets/sitrep.conky.conf
```

The current `.conky.conf` resolves all geometry and theming through `gtex62-tech-hud/theme.lua`:

```lua
local SUITE_DIR = os.getenv("CONKY_SUITE_DIR")
               or (os.getenv("HOME") .. "/.config/conky/gtex62-tech-hud")
local theme = dofile(SUITE_DIR .. "/theme.lua")
local pos   = theme.layout_pos("sitrep")
SITREP_THEME = SUITE_DIR .. "/theme-sitrep.lua"
```

This means SitRep cannot launch without the tech-hud environment. If `CONKY_SUITE_DIR` is
unset and the tech-hud directory is absent, the config fails at `dofile`. This directly
violates the core principle: SitRep must work regardless of which suite is active.

### Target Location

```
~/.config/conky/gtex62-conky-engine/widgets/sitrep/
├── sitrep.conky.conf       ← decoupled config
├── sitrep.lua              ← Cairo draw entrypoint
└── theme-sitrep.lua        ← minimal self-contained theme
```

SitRep lives in the engine, not in any suite. Each suite that previously carried a SitRep
panel retires it in favor of the `sitrep` command which launches this engine-resident widget.

### Decoupled conky.conf

The suite dependency is replaced with a core directory resolution:

```lua
-- widgets/sitrep/sitrep.conky.conf

local CORE_DIR = os.getenv("GTEX62_CORE_DIR")
              or (os.getenv("HOME") .. "/.config/conky/gtex62-conky-engine")
local THEME_FILE = CORE_DIR .. "/widgets/sitrep/theme-sitrep.lua"
local theme = dofile(THEME_FILE)

conky.config = {
  alignment              = 'top_left',
  xinerama_head          = theme.monitor_head or 0,
  background             = false,
  double_buffer          = true,
  update_interval        = 1,

  use_xft                = true,

  own_window             = true,
  own_window_type        = 'desktop',
  own_window_hints       = 'undecorated,sticky,skip_taskbar,skip_pager,below',
  own_window_argb_visual = true,
  own_window_argb_value  = 0,
  own_window_transparent = true,
  own_window_class       = 'Conky',

  minimum_width          = theme.min_w  or 460,
  maximum_width          = theme.max_w  or 560,
  minimum_height         = theme.min_h  or 800,

  gap_x                  = theme.gap_x  or 0,
  gap_y                  = theme.gap_y  or 0,

  draw_shades            = false,
  draw_borders           = false,
  default_color          = 'C0C0C0',
  color1                 = '808080',

  lua_load               = CORE_DIR .. "/widgets/sitrep/sitrep.lua",
  lua_draw_hook_pre      = 'draw_sitrep',
}

conky.text = [[]]
```

### Self-Contained theme-sitrep.lua

SitRep's theme is minimal and utilitarian — dark, monospace, no palette selection, no
suite color roles. It does not inherit from any suite theme file.

```lua
-- widgets/sitrep/theme-sitrep.lua

local theme = {}

-- Window geometry
theme.monitor_head = 0
theme.min_w  = 460
theme.max_w  = 560
theme.min_h  = 800
theme.gap_x  = 0
theme.gap_y  = 0

-- Colors (RGBA 0..1)
theme.bg          = { 0.05, 0.08, 0.05, 0.88 }   -- dark green-black
theme.fg          = { 0.75, 0.90, 0.65, 1.00 }   -- phosphor green
theme.ink         = { 0.45, 0.60, 0.40, 0.80 }   -- dimmed label
theme.accent      = { 0.85, 1.00, 0.70, 1.00 }   -- bright header
theme.ok          = { 0.40, 0.90, 0.40, 1.00 }   -- ONLINE
theme.warn        = { 1.00, 0.80, 0.20, 1.00 }   -- STALE / WARNING
theme.err         = { 1.00, 0.35, 0.35, 1.00 }   -- OFFLINE / SSH DOWN
theme.unknown     = { 0.80, 0.50, 0.20, 1.00 }   -- UNKNOWN device

-- Typography
theme.font_mono   = "JetBrainsMono Nerd Font"
theme.font_size   = 10
theme.font_small  = 9

-- Layout
theme.margin      = { top = 20, left = 16, right = 16, gap = 12 }

return theme
```

### Launch Script

The `sitrep` command is a thin shell wrapper in the engine's `bin/` directory:

```bash
#!/usr/bin/env bash
# bin/sitrep
# Launch the SitRep operational console.
# Works regardless of which suite is active.

CORE_DIR="${GTEX62_CORE_DIR:-${HOME}/.config/conky/gtex62-conky-engine}"
CONF="${CORE_DIR}/widgets/sitrep/sitrep.conky.conf"

if [[ ! -f "$CONF" ]]; then
  echo "SitRep config not found: $CONF" >&2
  exit 1
fi

# Kill any existing SitRep instance
pkill -f "sitrep.conky.conf" 2>/dev/null || true
sleep 0.3

export GTEX62_CORE_DIR="$CORE_DIR"
conky -c "$CONF" &
```

Symlink or add `bin/` to `$PATH` so `sitrep` works from any terminal context.

### Per-Suite Migration

Each suite that currently carries a SitRep panel handles it as follows during conversion:

| Suite | Action |
| --- | --- |
| `gtex62-tech-hud` | Remove `widgets/sitrep.conky.conf`; `sitrep` command replaces it |
| `gtex62-clean-suite` | Remove `apwbe` widget; `sitrep` command replaces it |
| `gtex62-tri-hud` | Audit for equivalent panel; retire in favor of `sitrep` |
| `gtex62-lcars` | Audit for equivalent panel; retire in favor of `sitrep` |
| `gtex62-osa` | No SitRep panel — `sitrep` available as standalone command only |

No suite carries a SitRep panel after migration. The widget lives in the engine and is
suite-agnostic by design.

---

## Rate Scripts — Dev Tools Only

`pf-rate-all-test.sh` and `pf-rate-infra-test.sh` do their own delta sampling with `sleep`
inline. They are diagnostic tools, not production data scripts. They do not migrate to core.

Production rate data comes from successive reads of `status.json`, with the Lua view model
computing the delta between `ibytes`/`obytes` values across draw cycles. These scripts
remain in `scripts/dev/` for manual testing.

---

## Migration Checklist

### Gate

- [x] Port `pf-ssh-gate.sh` to core — state path from env vars, no `conky-env.sh`
- [x] pfSense gate deployed: `runtime/pfsense/ssh_state`
- [ ] AP gate deployed: `runtime/ap/ssh_state` (separate state from pfSense gate)
- [ ] Resolve inline `gate_status()` duplication in `fetch_pfsense.sh` — replace with
      call to `pf-ssh-gate.sh status`

### pfSense Provider

- [x] `fetch_pfsense.sh` — profile/TOML resolution, cache TTL, batched SSH, atomic write
- [x] Interfaces (ibytes/obytes per VLAN) → `status.json`
- [x] CPU%, MEM% → `status.json`
- [x] Gateway online/IP → `status.json`
- [ ] System info (uptime, load, version, BIOS) → `system.json`
- [ ] pfBlockerNG (IP blocks, DNSBL, query total) → `pfblockerng.json`
- [x] Pi-hole (active, totals, blocked, domains) → `pihole.json` (separate `pi5` SSH,
      separate gate state — `fetch_pihole.sh`, Aug 18, 2026)
- [ ] ARP table → `arp.json`
- [ ] DHCP leases → `leases.json`
- [ ] Verify pfBlockerNG sqlite3 paths on current pfSense version

### AP Provider

- [ ] Create `providers/pfsense/fetch_ap.sh`
- [ ] Collapse 3-session poll to 1 session per AP
- [ ] Join client IPs against `devices.toml`
- [ ] Output `ap_status.json` and `ap_clients.json`
- [ ] Use `runtime/ap/ssh_state` gate

### Device Inventory

- [ ] Expand `ap_ipmap.csv` → `devices.toml` with MAC column
- [ ] Validate MAC entries against live pfSense ARP table
- [ ] Establish `devices.toml` path in `site.toml` or core config convention

### sitrep.lua File Split

- [ ] Extract `draw_system_impl` / `conky_draw_system` / `conky_draw_system_embed` →
      `gtex62-tech-hud/lua/widgets/system.lua`
- [ ] Extract `draw_network_impl` / `conky_draw_network` / `conky_draw_network_embed` →
      `gtex62-tech-hud/lua/widgets/network.lua`
- [ ] Delete all dead code from original graphical SitRep design (see dead code list above)
- [ ] Verify tech-hud suite still renders correctly after extraction
- [ ] Verify no remaining references to deleted functions in theme or other widget files

### Widget Relocation

- [ ] Create `widgets/sitrep/` directory in engine
- [ ] Write decoupled `sitrep.conky.conf` — resolves from `GTEX62_CORE_DIR`, no suite deps
- [ ] Write self-contained `theme-sitrep.lua` — no suite palette, no `theme.lua` dependency
- [ ] Move `sitrep.lua` Cairo draw entrypoint to `widgets/sitrep/sitrep.lua`
- [ ] Write `bin/sitrep` launch wrapper
- [ ] Verify `sitrep` launches cleanly with `CONKY_SUITE_DIR` unset
- [ ] Remove `sitrep.conky.conf` from `gtex62-tech-hud/widgets/`

### SitRep View Model

- [ ] Write `lua/suite/pf.lua` consuming `status.json`, `ap_status.json`, `ap_clients.json`
- [ ] Implement `cache_age_seconds()` helper
- [ ] Implement `iface_rate_mbps()` with counter delta across draw cycles
- [ ] Map status classes to display strings and color roles
- [ ] Add staleness indicator to status slot
- [ ] Remove all direct SSH calls from SitRep Lua/scripts

### Verification

- [ ] `sitrep` works with engine running — data is live
- [ ] `sitrep` works with engine stopped — stale cache renders with age indicator
- [ ] `sitrep` works with no cache — `NO DATA` displays cleanly, no Lua errors
- [ ] SSH gate trip reflected in status slot — degrades gracefully
- [ ] APIPA device appears in APIPA section, not as UNKNOWN
- [ ] Counter wraparound on 32-bit interfaces handled without spike

---

## VPN Provider (Proposed)

A new, simpler provider class — no SSH target, no gate. `piactl` and `wg` are local
commands; `fetch_vpn.sh` polls them directly and writes via the same atomic-write pattern
as `fetch_pfsense.sh`. Cadence can be tighter than the SSH-based providers since there's
no remote round-trip cost — 10–15s is reasonable.

### Output Schema — vpn.json

```json
{
  "generated_at": "2026-06-16T21:34:00Z",
  "connectionstate": "Connected",
  "region": "us-texas",
  "protocol": "wireguard",
  "interface": "wgpia0",
  "vpnip": "102.129.234.184",
  "endpoint": "102.129.234.184:1337",
  "latest_handshake_seconds": 55,
  "keepalive_interval_seconds": 25,
  "transfer": { "rx_bytes": 1593344, "tx_bytes": 454522 },
  "killswitch": true
}
```

All fields are collected regardless of whether SitRep surfaces all of them at any given
moment — handshake age and killswitch state are the two fields most likely to drive
display logic, but the rest (region, protocol, interface, IP) round out the picture for
future use without requiring a schema change later.

`vpnip` and `endpoint` are distinct and both worth keeping: `vpnip` is the tunnel-assigned
local address inside the VPN, while `endpoint` is the remote PIA server's public address
and port the tunnel connects to. They happen to share the same IP in the sample above —
coincidental to this particular server, not a general rule.

### Live Verification

Confirmed directly via `sudo wg show wgpia0` on Titan:

```
interface: wgpia0
  public key: 0+OxgStESDbxHpPLt0sxrIFOxQBq1oyH9DyddZA1jjA=
  listening port: 47871
  fwmark: 0x3213
peer: uRENeJ8Hn6f8eWCuesrPOeT088eqZZqoFuj/LiaaX3U=
  endpoint: 102.129.234.184:1337
  allowed ips: 0.0.0.0/0
  latest handshake: 55 seconds ago
  transfer: 1.52 MiB received, 443.87 KiB sent
  persistent keepalive: every 25 seconds
```

This confirms `fwmark: 0x3213` from a second, independent source — the same value cited
in the killswitch detection section below, now doubly verified rather than inferred from
one piece of evidence. It also confirms the raw byte counts behind the human-readable
transfer line; `wg show wgpia0 dump` returns these as machine-parseable raw bytes directly,
without needing to reverse the MiB/KiB formatting `wg show` applies for display.

The `persistent keepalive: every 25 seconds` line matters beyond confirming the field
exists — it changes how the handshake-age thresholds below should be set.

### Data Sources — Resolved

Each field's source is determined by what it actually is, not by branching the script on
"PIA vs. generic WireGuard." Protocol-level facts come from `wg`; PIA-application concepts
come from `piactl`:

| Field | Source | Command |
| --- | --- | --- |
| `connectionstate`, `region` | PIA app | `piactl get connectionstate` / `piactl get region` |
| `interface`, `vpnip` | WireGuard kernel module | `wg show wgpia0 dump` |
| `latest_handshake_seconds`, `transfer` | WireGuard kernel module | `wg show wgpia0 dump` |
| `killswitch` | PIA policy routing tables (see below) | `ip route show table piavpnFwdrt` |

`piactl get killswitch` and `piactl get publicip` were tested directly and confirmed
**not supported** — both return `Unknown type`. A third-party command reference claimed
otherwise; it was wrong. This rules out the documented CLI path entirely for killswitch
state — it has to come from inspecting PIA's routing, not piactl.

Because the wg-sourced fields are generic WireGuard facts rather than PIA-specific ones,
`fetch_vpn.sh` would extend cleanly to a second, unrelated WireGuard tunnel later without a
schema change — the piactl-sourced fields would simply be absent/null for that tunnel. No
fallback branch is needed; this resolves the original open question.

**New open item:** `wg show` requires root (confirmed directly — without `sudo` it returns
`Unable to access interface: Operation not permitted`). `fetch_vpn.sh` runs as the regular
user alongside the other providers, so this needs either a narrowly-scoped passwordless
sudoers rule for `wg show wgpia0 dump` specifically (read-only, interface-specific — much
safer than broad sudo access), or confirmation that PIA's daemon socket exposes equivalent
data without raw WireGuard access. To be resolved before the provider is built.

### Killswitch Detection — Verified Mechanism

PIA's Linux killswitch is implemented as policy routing, not firewall rules. Custom route
tables are registered in `/etc/iproute2/rt_tables`:

```
256  piavpnrt
257  piavpnOnlyrt
258  piavpnWgrt
259  piavpnFwdrt
```

Packets are steered into these tables by `fwmark` — confirmed via `wg show`'s
`fwmark: 0x3213` line, the same mark PIA's `ip rule` entries presumably match on. The
killswitch itself is a `blackhole default metric 32000` route inside `piavpnFwdrt` — lowest
priority, so it's only consulted when no better route exists.

This was verified empirically across controlled states on the live system:

| `ip route show table piavpnFwdrt` | State |
| --- | --- |
| `dev wgpia0` + `blackhole` | Connected, Kill Switch enabled |
| `dev wgpia0` only | Connected, Kill Switch disabled |
| `blackhole` only | Tunnel failed unexpectedly — Kill Switch enforcing, traffic dropped |
| Empty | Voluntary disconnect — PIA tears down routing entirely, not enforced by design |

The last row matters for interpretation: a deliberate disconnect (GUI or `piactl
disconnect`) clears this table regardless of the Kill Switch setting — by design, the
client doesn't block your traffic just because you asked to disconnect. This means an
empty table is **indistinguishable from "killswitch off"** by inspection alone.
`fetch_vpn.sh` should only read `killswitch` from this table while
`connectionstate == "Connected"`; outside that, hold the last-known value rather than
re-deriving it from an empty table.

The "failed unexpectedly" row was confirmed by forcing `sudo ip link set wgpia0 down`
without touching the PIA app — the `blackhole` route held and became the sole entry while
the `wgpia0` route vanished, confirming the killswitch enforces during a real failure, not
just at the configuration level.

**Not yet tested:** Kill Switch disabled + forced unexpected drop. This is the actual
unprotected-leak scenario and would show what real exposure looks like in this table —
worth testing before fully trusting the "unprotected" classification end to end.

### Health Classification

`latest_handshake_seconds` is the leading indicator of tunnel health — a stale handshake
often precedes `connectionstate` catching up to a dropped tunnel. The engine, not SitRep,
classifies this.

The original thresholds below (180s/600s) were a reasonable guess before the keepalive
interval was known. With `persistent keepalive: every 25 seconds` confirmed live, a
healthy tunnel should never miss more than one or two keepalive cycles — so the threshold
tightens considerably; waiting until 180s to flag `STALE` would mean tolerating roughly
seven missed keepalives before saying anything:

| Class | Condition |
| --- | --- |
| `HEALTHY` | `connectionstate == "Connected"` and handshake < 60s (≤ ~2 missed keepalives) |
| `STALE` | `connectionstate == "Connected"` and handshake 60–180s |
| `DEAD` | `connectionstate != "Connected"` or handshake > 180s or absent |

If the keepalive interval varies by server or region, `fetch_vpn.sh` should read
`keepalive_interval_seconds` from the live `wg show` output rather than hardcoding 25s,
and derive the thresholds as a multiple of it (e.g. `HEALTHY` ≤ 2× interval, `STALE` ≤
6–8× interval) so the classification stays correct if PIA changes the interval server-side.

### Proposed Display

A `PIA` status line, formatted consistently with the existing `SYSTEM PFSENSE` line:

```
PIA: HEALTHY
VPN: CONNECTED | REGION: US-TEXAS | PROTO: WG
LATENCY 25ms | HANDSHAKE 0:55 | KS ON
```

`PIA: HEALTHY` is the classified verdict (engine-derived from handshake freshness +
killswitch state). `VPN: CONNECTED` is the raw `connectionstate` passthrough — same
pattern as `ONLINE` (verdict) vs `gateway.online` (raw fact) elsewhere in the widget.
Handshake age renders as `m:ss`, consistent with load/uptime formatting conventions
already in use.

### Transfer Data Placement

Rather than a dedicated block, `transfer.rx_bytes`/`tx_bytes` fold into the existing
VLAN totals table as a `VPN` column after `CAM`, preserving the table's visual rhythm:

```
WAN    HOME    IoT   GUEST  INFRA  CAM    VPN
593G   24G    11G   105M   45G    1.6G   12.4G
51G   244G   345G   1.5G   32G    88M    3.2G
```

This keeps the PIA status line focused on connection health while the ambient transfer
volume sits alongside the rest of the network totals.

---

## WAN Health Monitoring (Proposed)

### Motivating Incident

Three to four consecutive nights (Aug 15–18, 2026) of intermittent overnight connectivity
degradation — pings cycling through partial values (e.g. `60/48/21/000`) roughly every
4–5 seconds, worsening to sustained multi-minute drops. Throughout, pfSense's WAN interface
continued reporting link-up/`ONLINE`, because that status reflects interface link state,
not actual throughput or loss. The existing `gateway.online` boolean in the pfSense
provider schema cannot detect this class of problem — the connection can be degraded to
the point of unusability while still reading "online."

Root cause confirmed as a Comcast-side plant/node issue, independently corroborated by:

- Comcast's own outage status page (100–200 subscribers impacted, resolution ETA 10:34am)
- Hand-run `mtr` logging from Titan and Pi5, captured overnight across two source machines
  and two different destination targets (8.8.8.8 and the pfSense WAN gateway), both
  showing the same signature: near-zero loss at the local gateway hop, then sustained
  20–95% loss beginning at the first Comcast-facing hop, tracking closely with a second
  hop downstream, and clearing to ~0% within the same hour as Comcast's reported fix time.

This is exactly the kind of event SitRep should have surfaced in real time instead of
requiring manual `mtr` diagnosis after the fact.

**Update (Aug 18, 2026):** CM1000 admin access from behind pfSense was solved (see
`cable-modem-admin-access.md`, "Confirmed Working Solution: NAT via Same-Subnet Virtual
IP"). Pulling the modem's own data independently corroborates the above from a third angle:

- The Event Log for the same morning shows a dense cluster of `T3 time-out` /
  `No Ranging Response received` / `UCD invalid or channel unusable` entries on the
  upstream, packed into roughly 07:55–08:22 — the modem's own view of losing sync with the
  CMTS repeatedly during the window the `mtr` logs show loss.
- The Cable Connection page's Downstream OFDM table showed channel 2 (957 MHz) running
  weak even hours after recovery: -2.0 dBmV power (vs. +4.2 dBmV on channel 1), 35.8 dB SNR
  (vs. 39.8 dB), and 3,460 uncorrectable codewords vs. 21 on channel 1 — consistent with a
  marginal RF path on the coax plant, not a modem or pfSense-side problem.

This changes the "Remaining option" note further down (see "Modem-Level Corroboration
Provider" below) — a scripted scrape is now feasible without a dedicated bridge device,
since the NAT-to-VIP path gives any host behind pfSense a routable path to
`192.168.100.1`.

### Observed Failure Modes of the `ONLINE`/`OFFLINE` Boolean

Directly observed during the incident, watching the existing `ONLINE`/`OFFLINE` display
against live ping behavior — two distinct failure modes, not one polling-speed problem:

1. **Boolean didn't drop to `OFFLINE` when pings were cycling to `000`.** Link state
   (carrier/interface up) and packet delivery are different things — the WAN interface
   never actually lost carrier during the degradation, so the boolean had nothing to flip
   on. This isn't fixable by polling faster; polling more often just re-samples the same
   wrong-but-stable `true` value, since the signal being measured is the wrong layer for
   this class of problem.

2. **Inverse case also observed: `OFFLINE` showing while pings were still getting positive
   values through.** A brief real link-state drop (carrier/lease loss) can recover fast
   enough that live traffic partially resumes before the cached `OFFLINE` verdict updates,
   producing a display that contradicts what's actually happening on the wire in the
   moment.

**Conclusion — this isn't "add loss% as a supplementary metric."** The link-state boolean
was measuring the wrong thing for this failure class the entire time. Loss%-based
classification (`HEALTHY`/`DEGRADED`/`CRITICAL`) should be the primary verdict driving the
`WAN` status line; `gateway.online` stays as a raw secondary fact (same relationship as
`connectionstate` vs. `PIA: HEALTHY` in the VPN section), not the thing decided first.

### Proposed Provider: `providers/network-health/fetch_wanhealth.sh`

Short, frequent `mtr` (or `ping`) sampling against the WAN gateway IP — not a full
overnight-style continuous log, just enough samples per cycle (e.g. 15–20 pings every
60–120s) to produce a live loss%/latency reading for the cache.

**Target selection — important, learned the hard way:** the probe target must not be a
known DNS-over-HTTPS resolver IP (e.g. 8.8.8.8, 1.1.1.1, 9.9.9.9). pfBlockerNG's
`pfB_DoH_IP_v4` auto-rule silently blocks ICMP to those addresses for the INFRA VLAN,
which caused an entire night's logging attempt from Pi5 to produce empty output with no
error. The **pfSense WAN gateway IP** is the correct target: it isolates whether
degradation is happening at the very first hop into Comcast's network (which is what
actually happened) without tripping that blocklist. Hardcode a comment in the script
noting why this target was chosen, so it doesn't get swapped back to a public DNS IP
later and silently break again.

Proposed schema, `shared/network-health/wan.json`:

```json
{
  "state": "ok",
  "collector": "wanhealth",
  "generated_at": "2026-08-18T02:35:07Z",
  "target": "gateway",
  "target_ip": "100.92.72.67",
  "loss_pct": 25.0,
  "avg_latency_ms": 20.4,
  "samples": 20
}
```

### Health Classification

Same pattern as the PIA `HEALTHY`/`STALE`/`DEAD` verdict — a classified field layered on
top of the raw `gateway.online` link-state boolean already in the pfSense provider, not a
replacement for it:

| Class | Condition |
| --- | --- |
| `HEALTHY` | `loss_pct` < 5% |
| `DEGRADED` | `loss_pct` 5–20% |
| `CRITICAL` | `loss_pct` > 20% |

### Display Layout — Resolved (Aug 18, 2026)

A `WAN` status line, formatted consistently with the existing `PIA` and `SYSTEM PFSENSE`
lines — raw link state and classified verdict shown side by side, same convention as
`VPN: CONNECTED` (raw) vs. `PIA: HEALTHY` (classified):

```
WAN: DEGRADED
GATEWAY LOSS 25% | AVG 20ms | ONLINE (link-up)
```

**Placement:** in the blank gap between the WBE530 access points section and the
`SYSTEM PFSENSE` line — this space already exists in the current layout and reads as
reserved room for exactly this kind of addition. `WAN` sits above `PIA` (network health
takes priority over VPN health), both above the existing `SYSTEM PFSENSE` divider.

**Modem line is conditional, not always-on.** Mocked up and settled on: the modem
corroboration line (`MODEM: T3x<n> (1H) | DS2 SNR <x>dB | US AVG <y>dBmV` — pulling from
`shared/modem/status.json`, proposed above) only renders when `WAN` is `DEGRADED` or
`CRITICAL`. When `WAN` is `HEALTHY` it's absent entirely, not shown blank — matches the
"corroborating detail for an active incident, not a standing metric" framing decided
earlier in this doc. It sits directly under the `WAN` line it corroborates, sharing the
same visual accent so the two read as one unit:

**Field meanings, and derivation still needed:** each of the three values is a compressed
summary, not a raw passthrough of the schema below — `fetch_modem.sh` (or a display-layer
step) needs to compute these, since the proposed `modem/status.json` schema only has raw
per-channel arrays today:
- `T3x<n> (1H)` — count of T3 ranging-timeout events in the trailing 1-hour window. This
  is `recent_t3_timeouts` as already defined in the schema below (summed from
  `docsDevEvCounts`, not a row count) — no new derivation needed here.
- `DS2 SNR <x>dB` — the downstream OFDM channel with the **worst** SNR, labeled by its
  channel number, not both channels shown. Requires a "pick the min-SNR entry from
  `downstream_ofdm_channels`" step not yet in the schema — a full channel-by-channel dump
  would be too dense for a single status line; the intent is "is anything bad," with the
  full breakdown still available by opening `DocsisStatus.asp` directly.
- `US AVG <y>dBmV` — mean upstream power across the locked SC-QAM channels (e.g. the four
  values in `upstream_channels` averaged). Also not yet in the schema — needs an averaging
  step over locked channels only, since `Not Locked` channels report `0 dBmV` and would
  skew a naive average.

```
WAN: DEGRADED
GATEWAY LOSS 25% | AVG 20ms | ONLINE (link-up)
MODEM: T3x24 (1H) | DS2 SNR 35.8dB | US AVG 39.8dBmV

PIA: HEALTHY
VPN: CONNECTED | REGION: US-TEXAS | PROTO: WG
LATENCY 25ms | HANDSHAKE 0:55 | KS ON
```

**VLAN totals table** gets a `VPN` column appended after `CAM` (see Transfer Data Placement
below) — no new table, same DN/UP row structure as the existing WAN/HOME/IoT/GUEST/INFRA/CAM
columns.

### Execution Model — Resolved (Conky's Own Loop Is Sufficient)

Nothing in the current architecture (this doc, `fetch_pfsense.sh`, `fetch_vpn.sh`) specifies
what actually invokes the fetch scripts on a schedule. `pf-ssh-gate.sh` is described as "no
dependency on `conky-env.sh` — portable as a standalone core utility," which means the fetch
scripts *can* run independent of Conky, but nothing shown confirms they currently *do*.

In practice this isn't a blocker: the OSA suite runs essentially anytime Titan is powered
on — the only gap is the window between boot and OSA launching. Conky's own update loop
calling into the engine on its normal cadence is therefore a reliable enough trigger for
the WAN health provider to work for its intended purpose (catching multi-hour overnight
degradation like the Aug 15–18 incident); a fresh-boot gap of a few minutes doesn't
meaningfully change the outcome for that use case.

A `systemd` timer or cron schedule independent of Conky remains a nice-to-have — it would
close the boot-to-launch gap and provide monitoring coverage on the rare occasion OSA isn't
running — but it is not required for the auto-trigger design below to function correctly
under normal usage.

### Auto-Triggered mtr Capture on Sustained CRITICAL

Extends the classification above: rather than requiring manual intervention (as happened
during the Aug 15–18 incident), the provider tracks how long `loss_pct` has remained in
`CRITICAL` and, past a configurable duration threshold, automatically shells out to start a
full diagnostic capture — the automated equivalent of `mtr_overnight_log.sh` — without
anyone needing to notice pings cycling in the widget first.

Proposed state additions to `wan.json` (or a sibling `wan_incident.json`):

```json
{
  "critical_since": "2026-08-18T02:35:07Z",
  "critical_duration_seconds": 780,
  "capture_triggered": true,
  "capture_log_path": "/home/gtex62/Documents/_Reports/auto_mtr_20260818_024755.log"
}
```

**Trigger logic:**

| Condition | Action |
| --- | --- |
| `loss_pct` enters `CRITICAL` | Start/continue `critical_since` timer |
| `critical_duration_seconds` ≥ threshold (e.g. 300–600s) AND `capture_triggered == false` | Launch mtr capture script, set `capture_triggered = true`, record `capture_log_path` |
| `loss_pct` returns to `HEALTHY` | Reset `critical_since` to null, reset `capture_triggered = false` (ready to fire again on a future episode) |

**Guard against re-trigger spam:** the `capture_triggered` flag must persist across poll
cycles while still `CRITICAL` — without it, every poll past the threshold would spawn a new
capture process. One capture process per continuous critical episode, not one per poll.

**Reuses existing tooling:** the auto-triggered capture is the same script logic as
`mtr_overnight_log.sh` (timestamped snapshots appended to a logfile), just started
programmatically by the provider instead of manually from a terminal, and scoped to run
until `loss_pct` recovers rather than for a fixed overnight window. Output path should stay
consistent with where manual captures already land (`/home/gtex62/Documents/_Reports/`) so
both manual and automatic runs are easy to find together.

**Threshold duration is a judgment call, not yet set** — long enough to avoid firing on a
brief transient blip (a single bad `mtr` cycle isn't an outage), short enough to still catch
the bulk of an episode rather than triggering near its end. The Aug 18 incident's own data
is a useful reference point: loss stayed elevated continuously for roughly 6 hours, so even
a conservative 10–15 minute sustained-critical threshold would have triggered well within
the first hour of onset.



### Modem-Level Corroboration Provider (Newly Feasible)

Previously deferred — `cable-modem-admin-access.md` originally concluded that modem-level
data (SNR, power, error counts) required a dedicated always-on bridge device wired directly
to the modem, since the modem only answers a same-subnet source. That constraint is
unchanged, but as of Aug 18, 2026 pfSense itself satisfies it: a WAN Virtual IP inside
`192.168.100.0/24`, combined with Outbound NAT translating to that VIP, gives any host
behind pfSense a routable path to `192.168.100.1`. A dedicated bridge device is no longer
required — the engine can poll the modem directly, the same way it polls pfSense.

**Proposed provider:** `providers/modem/fetch_modem.sh` — scrapes the CM1000 admin pages
(`Cable Connection` for signal stats, `Event Log` for ranging/timeout events) on a schedule,
via the pfSense NAT-to-VIP path. Cadence should be much lower than the WAN loss-based
provider (signal stats and event log entries change slowly outside an active incident) —
every few minutes is likely sufficient, versus the 60–120s loss-based sampling above.

**Reconnaissance complete (Aug 18, 2026)** — confirmed via view-source and HAR capture
against the live CM1000, so this is implementation-ready rather than speculative:

- **Page is server-rendered HTML, not JS-injected.** A plain HTTP GET returns fully
  populated `<table>` markup — no headless browser or JS execution needed. Older leftover
  JS (`InitDsTableTagValue()` etc.) suggests a prior firmware architecture; current
  firmware renders server-side despite that code still being present.
- **URL map**, extracted from the Genie menu HTML (`GenieIndex.asp`):

  | Page | Filename |
  | --- | --- |
  | Login | `GenieLogin.asp` (GET to view, `POST /goform/GenieLogin` to authenticate) |
  | Dashboard | `DashBoard.asp` |
  | Cable Connection (signal data) | `DocsisStatus.asp` |
  | Event Log | `EventLog.asp` |
  | Logout | `Logout.asp` |

- **Table `id` attributes on `DocsisStatus.asp`** — stable targets for parsing, no
  positional column-counting needed:

  | Table | `id` |
  | --- | --- |
  | Startup Procedure | `startup_procedure_table` |
  | Downstream Bonded Channels (SC-QAM) | `dsTable` |
  | Upstream Bonded Channels (SC-QAM) | `usTable` |
  | Downstream OFDM Channels | `d31dsTable` |
  | Upstream OFDMA Channels | `d31usTable` |

  Two standalone fields are also present: `#Current_systemtime` and `#SystemUpTime` —
  useful for confirming a fetch returned fresh data rather than something cached.

- **`EventLog.asp` uses a different pattern — worth handling separately from
  `DocsisStatus.asp`.** Its `<table id="eventlog_table">` contains only a header row in the
  raw HTML; the actual event data is embedded as an XML string inside an inline
  `InitTagValue()` JS function (same "server-templated into JS, not real AJAX" pattern as
  `DocsisStatus.asp`, but XML instead of pipe-delimited). Extract via regex
  (`InitTagValue\(\)\s*{\s*var xmlFormat = '(.+?)';`) then parse as XML — actually simpler
  than DOM-walking the table would have been. Root element `docsDevEventTable`, one `<tr>`
  per row, fields `docsDevEvIndex`, `docsDevEvFirstTime`, `docsDevEvLastTime`,
  `docsDevEvCounts`, `docsDevEvLevel`, `docsDevEvId`, `docsDevEvText` — these are the actual
  DOCSIS Device Event MIB field names (RFC 4639), suggesting this is close to a verbatim
  dump of what SNMP would have exposed if it were reachable.
  - **Important for the `recent_t3_timeouts` field:** the modem already de-duplicates
    repeated identical events into one row with a `docsDevEvCounts` repeat counter and a
    `docsDevEvFirstTime`/`docsDevEvLastTime` span — e.g. the Aug 18 log's first row
    represents 31 occurrences of the same T3-timeout message collapsed into one entry
    spanning 08:22:07–09:04:06, not 31 separate rows. `fetch_modem.sh` must **sum
    `docsDevEvCounts` across matching rows**, not count table rows, or it will
    undercount actual timeout occurrences by roughly an order of magnitude.

- **Auth flow, confirmed via HAR capture (not cookie-free as first suspected):**
  1. `GET /GenieLogin.asp` → extract the current `webToken` value (a hidden form field;
     confirmed to change per page load — must be fetched fresh each login, not hardcoded).
  2. `POST /goform/GenieLogin` — form-encoded body: `loginUsername`, `loginPassword`,
     `login=1`, `webToken`. Response is a `302` redirect to `/GenieIndex.asp`, with
     **no cookie set on this response.**
  3. Follow the redirect → `GET /GenieIndex.asp` — **this** response is where the session
     cookie (`SessionID=<value>`) actually gets set, one step after the login POST itself.
     A scraper checking for `Set-Cookie` immediately after the login POST would incorrectly
     conclude auth failed — the cookie only appears after following the redirect.
  4. Subsequent requests (`DocsisStatus.asp`, `EventLog.asp`, etc.) carry
     `Cookie: SessionID=<value>` and return authenticated data.
  - **Firmware quirk:** the modem's embedded server splits the cookie across two separate
    `Set-Cookie` headers (`SessionID=<value>` on one line, `HttpOnly; Secure` flags with no
    name/value on a second) instead of one conformant header. A `requests.Session()` in
    Python should handle this transparently (its cookie jar picks up the valid line and
    ignores the malformed one), but worth confirming empirically once code exists — embedded
    device HTTP servers occasionally have further surprises nearby.
  - **Credential handling:** the login POST body carries the admin password in plain text
    (normal for form auth over HTTP, not a bug) — store it in an environment variable or a
    permissions-locked secrets file for `fetch_modem.sh`, not hardcoded in the script or
    committed anywhere in this repo.

Proposed schema, `shared/modem/status.json`:

```json
{
  "state": "ok",
  "collector": "modem",
  "generated_at": "2026-08-18T11:22:10Z",
  "modem_ip": "192.168.100.1",
  "upstream_channels": [
    { "id": 17, "freq_hz": 16400000, "power_dbmv": 39.5, "locked": true },
    { "id": 18, "freq_hz": 22800000, "power_dbmv": 40.3, "locked": true },
    { "id": 19, "freq_hz": 29200000, "power_dbmv": 39.3, "locked": true },
    { "id": 20, "freq_hz": 35600000, "power_dbmv": 40.0, "locked": true }
  ],
  "downstream_ofdm_channels": [
    { "id": 193, "freq_hz": 690000000, "power_dbmv": 4.2, "snr_db": 39.8, "uncorrectables": 21 },
    { "id": 194, "freq_hz": 957000000, "power_dbmv": -2.0, "snr_db": 35.8, "uncorrectables": 3460 }
  ],
  "recent_t3_timeouts": 24,
  "event_log_window_minutes": 60
}
```

**Health classification:** SNR/power/uncorrectable thresholds should mirror the reference
ranges established from the Aug 18 read (upstream power ~35–49 dBmV nominal; downstream OFDM
SNR floor ~35 dB, power roughly ±7 dBmV) rather than inventing new ones — exact thresholds
still need tuning against a longer baseline before they're trustworthy enough to drive a
`HEALTHY`/`DEGRADED`/`CRITICAL` verdict the way `wan.json`'s loss% does.

**Relationship to WAN health:** this is corroborating detail, not a replacement for the
loss%-based verdict above — `wan.json` (or its successor) stays the primary signal for
"is the connection currently degraded," since it's what actually reflects usability. The
modem provider answers the follow-up question once degradation is flagged: *is this the
plant/CMTS, or something else*. Whether `recent_t3_timeouts` should factor into
`WAN`'s own classification (not just sit alongside it as reference data) is open — it's
tempting since T3 timeouts are a leading indicator, but conflating two providers'
classification logic repeats the mistake being fixed elsewhere in this doc (see the
inline-`gate_status()` duplication note under Known Constraints).

**Display:** resolved as a conditional line under `WAN`, shown only during
`DEGRADED`/`CRITICAL` — see "Display Layout — Resolved" under WAN Health Monitoring above.

### Open Items

- Sampling interval and packet count per cycle not yet tuned — needs to be frequent enough
  to catch onset quickly without adding meaningful load or SSH/probe overhead.
- Whether this lives as its own provider (`network-health`) or as an extension of the
  existing `pfsense` provider's schema is undecided; keeping it separate follows the same
  reasoning as keeping VPN health separate from pfSense health — different failure domains,
  different polling cadence.
- Historical retention (e.g. rolling last-N-hours buffer for a mini sparkline) not yet
  designed — the overnight incident data above was only reconstructable because a
  hand-run `mtr` log happened to be capturing at the time; the engine version should not
  depend on that being manually started.
- Sustained-critical trigger duration not yet set — see auto-trigger section above.
- Auto-triggered capture's own lifetime/stop condition needs a cap (e.g. max runtime even
  if `CRITICAL` never clears) so a truly prolonged outage doesn't grow an unbounded logfile.
- Modem provider (`fetch_modem.sh`) reconnaissance is complete for both `DocsisStatus.asp`
  and `EventLog.asp` (URL map, table/XML structure, auth flow — see above); the script
  itself is still unbuilt.
- Modem provider polling adds a second outbound NAT-translated path through pfSense
  (distinct from the existing SSH-based pfSense provider) — worth confirming this doesn't
  interact with the `pf-ssh-gate.sh` circuit breaker in an unexpected way, since it's a
  different transport (HTTP via NAT vs. SSH) hitting a different device.
- **Resolved (Aug 18, 2026):** PIA VPN policy routing was pulling traffic to
  `192.168.100.1` into the WireGuard tunnel (or the killswitch blackhole) instead of
  reaching pfSense's LAN gateway — found in practice on Titan. Fixed by adding
  `192.168.100.0/24` as a "bypass VPN" IP/subnet rule under PIA's Split Tunnel settings
  (Titan-specific config — see `cable-modem-admin-access.md` for the exact steps). If Pi5
  (the proposed always-on host for `fetch_modem.sh`) runs PIA, it needs the same split-tunnel
  rule added separately — Split Tunnel config is per-device, not account-wide.

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

**Inline gate_status() duplication** — `fetch_pfsense.sh` reads the gate state file
directly via an internal `gate_status()` function rather than calling `pf-ssh-gate.sh status`.
Both code paths must stay in sync until the duplication is resolved.

**Interface counter width** — `netstat` on FreeBSD/pfSense reports 64-bit counters on
modern interfaces, but some virtual or legacy interfaces may wrap at 32 bits (~4GB). The
Lua rate computation guards against this by skipping cycles where `now_bytes < prev_bytes`.

---

## Relocation Session — Part 0 Audit (Aug 18, 2026)

**Status: BLOCKED pending decision.** Read-only audit of `gtex62-tech-hud`'s live SitRep
completed; nothing modified there. Findings below split into (A) ordinary path-coupling
fixes expected by this doc, and (B) a premise-level discrepancy that stops Part 1 from
starting until resolved.

### Files audited (read-only, all in `gtex62-tech-hud`)

- `widgets/sitrep.conky.conf`
- `lua/widgets/sitrep.lua` (2046 lines)
- `theme-sitrep.lua` (261 lines)
- `lua/lib/util.lua`, `lua/lib/theme-core.lua` (dependencies of the above)
- `~/.local/bin/sitrep` (launcher)
- `scripts/pf-fetch-basic.sh`, `ap_status_all_clients.sh`, `ap_clients_named.sh` (confirmed present, confirmed still legacy SSH scripts)

### A. Path-coupling findings — as expected, ordinary relocation fixes

These match what this doc already anticipated and just need doing in Part 1:

1. `sitrep.conky.conf` resolves `SUITE_DIR` and `dofile`s tech-hud's monolithic
   `theme.lua` for `theme.layout_pos("sitrep")` / `theme.monitor_head`. Replace with the
   doc's decoupled `CORE_DIR`-based config (no suite theme dependency).
2. `sitrep.lua` resolves `SUITE_DIR` (`CONKY_SUITE_DIR` env, fallback
   `~/.config/conky/gtex62-tech-hud`) at the top — needs `GTEX62_CORE_DIR` per this doc's
   plan.
3. `sitrep.lua` does `local util = dofile(SUITE_DIR .. "/lua/lib/util.lua")` —
   **unconditional, not `pcall`'d**. This is a hard dependency on tech-hud's shared
   util module, not yet flagged explicitly in this doc's "Suite Dependency Removals"
   table. Needs either an inlined subset of the util functions actually used, or a small
   engine-local `util.lua` under `widgets/sitrep/`.
4. `sitrep.lua` also does `pcall(dofile, .../widgets.lua)` and
   `pcall(dofile, .../pf_widget.lua)` — confirmed present exactly as this doc's "Suite
   Dependency Removals" table already calls out for removal.
5. `theme-sitrep.lua` is **not self-contained** as this doc's target design assumes — it
   does `dofile(SUITE_DIR .. "/lua/lib/theme-core.lua")` and pulls all colors from
   `palette.pfsense.*` (tech-hud's shared suite palette), not flat inline RGBA. The
   doc's proposed `theme-sitrep.lua` (minimal, no palette selection, no suite theme
   inheritance) does not exist yet in the legacy file — it needs to be authored fresh
   during relocation, not copied.
6. `get_sitrep_theme()` in `sitrep.lua` falls back to `util.get_theme()` (tech-hud's
   shared theme function) if `SITREP_THEME` / `theme-sitrep.lua` can't be found — this
   fallback path itself depends on the util.lua dependency in (3) and needs to be
   dropped or replaced.
7. `~/.local/bin/sitrep` hardcodes tech-hud's config path and a `conky-sitrep.pid`
   PID file under `${XDG_RUNTIME_DIR:-$HOME/.cache}`. Per this session's plan, the new
   `sitrep-e` launcher targets the new config path and a distinct
   `conky-sitrep-e.pid`, leaving this script untouched.
8. `WD_BLACK_PATH` env var is read at the top of `sitrep.lua` — matches this doc's
   existing note to remove it (disk label is a system-widget concern; confirmed unused
   in the `conky_draw_sitrep()` path itself).

### B. Premise discrepancy — BLOCKING

This session's brief states SitRep's "data-sourcing is already correct: no direct
shell/execi/Conky-native reads, it's a pure cache consumer per the existing migration
doc." **This is not true of the live code, and it is not what this doc's own checklist
claims either.**

Confirmed directly in `lua/widgets/sitrep.lua`'s live `conky_draw_sitrep()` draw path:

- `get_pf_data()` → `pf_data_full()` (line 434) issues
  `${execi <poll> SUITE_DIR/scripts/pf-fetch-basic.sh full > <cache> &}` — a live shell-out
  to the legacy SSH-fetch script, not a cache read.
- `ap_blocks()` → `ap_cached_output()` (line 455) issues the same pattern against
  `scripts/ap_status_all_clients.sh` and `scripts/ap_clients_named.sh` — both legacy
  scripts that open their own SSH sessions per this doc's own "Scripts in Production
  (Legacy)" table above.
- Both write to a **suite-local flat-text file cache**
  (`~/.cache/conky/pfsense/sitrep_full.cache`, `~/.cache/conky/ap/*.cache`), parsed by a
  custom `parse_kv()` — not the engine's JSON cache at
  `~/.cache/gtex62-core/shared/pfsense/{profile}/status.json` at all.

This matches exactly the "Current Architecture" section above (SitRep as
collector+database+analysis+display all at once) — it is the **pre-migration** state,
not the migrated cache-consumer state. It also matches this doc's own **Migration
Checklist**, where every relevant box is still unchecked: "Write `lua/suite/pf.lua`
consuming `status.json`..." and "Remove all direct SSH calls from SitRep Lua/scripts"
are both `[ ]`, not `[x]`.

Separately, even a rewritten cache-consumer SitRep couldn't be fully served by the core
`pfsense` provider today: per the "Implementation Status" / "Planned Cache Files"
sections above, `status.json` (interfaces/CPU%/MEM%/gateway) is the only cache file
actually implemented. `system.json`, `pfblockerng.json`, `pihole.json`, `ap_status.json`,
`ap_clients.json` are all listed "Pending," and the AP provider itself hasn't been
started ("AP collection and device inventory are separate providers, not yet started").

**Why this blocks Part 1 as scoped:** a straight copy-and-repath of `sitrep.lua` into
`gtex62-core/widgets/sitrep/` would either (a) fail outright, since it depends on
tech-hud-local `scripts/`, `lua/lib/util.lua`, `lua/lib/theme-core.lua`,
`lua/widgets/pf_widget.lua` that won't exist at the new location, or (b) require
dragging the entire legacy direct-SSH fetch apparatus (`pf-fetch-basic.sh`,
`ap_status_all_clients.sh`, `ap_clients_named.sh`, `zyxel_cmd.sh`, `pf-ssh-gate.sh`) into
`gtex62-core` as new SitRep-owned files with their own private cache format — which is a
data-sourcing decision, not a relocation, and touches the exact "missing provider" case
the session guardrails say to stop and confirm on rather than resolve solo.

**Also flagged:** the doc's own "Widget Relocation" target layout (flat
`widgets/sitrep/{sitrep.conky.conf, sitrep.lua, theme-sitrep.lua}`, default
`GTEX62_CORE_DIR` fallback of `~/.config/conky/gtex62-conky-engine`) differs from this
session's brief, which asks for a `lua/suite/`, `lua/ui/`, palette-file internal shape
under `gtex62-core/widgets/sitrep/` (the actual repo name — `gtex62-conky-engine` does
not exist on disk). Noting this now; not blocking, since the session brief is the more
current instruction, but the doc's stale layout description should be reconciled once
Part 1's actual structure is settled.

**Decision (Aug 18, 2026):** Stop the relocation for tonight. Resume only once the core
`pfsense` provider is a genuine cache consumer's data source — i.e. once `system.json`,
`pfblockerng.json`, `pihole.json` are implemented (currently "Pending" above) and an AP
provider exists producing `ap_status.json` / `ap_clients.json` (currently not started).
No `gtex62-core/widgets/` files were created this session. `gtex62-tech-hud`'s legacy
SitRep is untouched and keeps running via `~/.local/bin/sitrep` as before.

**To resume this migration in a future session:**

1. Finish the core `pfsense` provider's remaining pending domains (system, pfBlockerNG,
   ARP, DHCP — see "Migration Checklist" → "pfSense Provider" above). Pi-hole is done
   (`fetch_pihole.sh`, Aug 18, 2026 — see below).
2. Build the AP provider (`providers/pfsense/fetch_ap.sh`) producing `ap_status.json`
   and `ap_clients.json` (see "Migration Checklist" → "AP Provider" above).
3. Only then re-run Part 0 of a relocation session — the Part 0 findings above (section
   A) are still accurate and don't need re-auditing, just re-confirm nothing has drifted
   in `gtex62-tech-hud`'s files since Aug 18, 2026.
4. At that point `sitrep.lua`'s data layer (`pf_data_full`, `ap_cached_output`,
   `ap_blocks`, `parse_kv`, `parse_ap_status`, `parse_ap_clients_named`) gets rewritten
   to `jq` reads against the engine's JSON caches per the "SitRep as Cache Consumer" /
   "Data Read Migration Map" sections above, **before** or **as part of** the relocation
   — not after it, so the relocated widget is a true cache consumer from the day it
   lands in `gtex62-core/widgets/sitrep/`.

---

## pfSense Provider Session — Pi-hole Domain (Aug 18, 2026)

First of the three remaining `pfsense` provider domains from item 1 of the resume
checklist above (Pi-hole → pfBlockerNG → system, easy to hard). Pi-hole only this
session; pfBlockerNG and system are separate future sessions.

### Gate architecture decision

`pf-ssh-gate.sh`'s state directory was hardcoded to `${CACHE_ROOT}/runtime/pfsense`,
which the "SSH Architecture" and "Known Constraints" sections above require Pi-hole
*not* share (separate host, separate failure domain — a tripped pfSense gate must not
block Pi-hole polling or vice versa). Rather than duplicate the trip/reset/status
circuit-breaker logic inline, `pf-ssh-gate.sh` gained a `GATE_STATE_DIR` env override
(default behavior unchanged when unset) so it can be reused for `runtime/pihole` as
well as any future non-pfSense target — the same parameterization this doc already
anticipated for the AP gate. `fetch_pfsense.sh` itself was not touched.

### fetch_pihole.sh

New script: `providers/pfsense/fetch_pihole.sh`. Reuses `fetch_pfsense.sh`'s TOML
parsing helpers, `SSH_OPTS`, and atomic-write (`python3` + `os.replace()`) conventions.
SSH target resolves from a new `[pihole]` section — `profiles/pfsense/{profile}.toml`
first, falling back to `site.toml`'s new `[pihole] ssh_target = "pi5"` (added this
session, parallel to the existing `[pfsense]` block). Gated via
`GATE_STATE_DIR=$CACHE_ROOT/runtime/pihole pf-ssh-gate.sh`. Cache TTL defaults to 300s
per this doc's "Planned Cache Files" cadence.

### pihole.json schema (proposed and implemented — no prior schema existed in this doc)

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
blocklist), matching the legacy script's `pihole_domains` field — not a count of
blocked queries. `blocked_pct` is derived (`queries_blocked / queries_total`), not a
raw Pi-hole field, kept for display convenience the same way `fetch_pfsense.sh` derives
nothing today but `pfblockerng.json`'s planned `pfb_dnsbl_pct` sets the precedent for
provider-side percentage derivation.

### Verification — Pi-hole Domain

- **Mechanical:** ran `fetch_pihole.sh main_router` directly; `jq .` parses the output
  cleanly; all fields above populated with live values, `state: "ok"`.
- **Cross-check:** ran `gtex62-tech-hud/scripts/pf-fetch-basic.sh slow` directly
  (read-only reference, untouched) for its `section=pihole` block against the same live
  Pi-hole host. `pihole_active`, `pihole_total`, `pihole_blocked`, and `pihole_domains`
  matched exactly. `pihole_load1` differed (0.02 legacy vs 0.03 new) — expected sampling
  noise between two independent `/proc/loadavg` reads taken a few seconds apart, not a
  query-logic discrepancy.

### Files touched

- `providers/pfsense/pf-ssh-gate.sh` — added `GATE_STATE_DIR` override (backward
  compatible)
- `providers/pfsense/fetch_pihole.sh` — new
- `~/.config/gtex62-core/site.toml` — added `[pihole]` section
- This doc — checklist/table updates above

pfBlockerNG and system domains remain pending; AP provider not started.
