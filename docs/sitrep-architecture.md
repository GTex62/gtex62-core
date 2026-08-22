# SitRep Architecture

Migrating SitRep from a self-contained widget to an engine-driven operational console.
This is the stable design reference — what SitRep is, the principle it's held to, and
the before/after data-flow shape. It changes rarely.

For current implementation state of the data source, see
[pfSense Provider Status](pfsense-provider-status.md). For the mechanics of relocating
the widget itself out of `gtex62-tech-hud`, see
[SitRep Relocation Plan](sitrep-relocation-plan.md). Full prose session history predating
this split lives in [archive/sitrep-engine-migration-2026-08-18.md](archive/sitrep-engine-migration-2026-08-18.md).

---

## Purpose

SitRep began as a network status display specific to the home infrastructure. It currently
performs data collection, device identification, status analysis, and rendering in a single
pass — running its own SSH sessions, maintaining its own IP-to-name map, and doing its own
join at draw time.

As the engine architecture matures, SitRep should become a pure presentation layer: it asks
the engine for information and displays what it receives. All collection, correlation, and
classification logic moves to the engine's `pfsense` provider.

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

```text
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

### Rate Scripts — Dev Tools Only

`pf-rate-all-test.sh` and `pf-rate-infra-test.sh` do their own delta sampling with `sleep`
inline. They are diagnostic tools, not production data scripts. They do not migrate to core.

Production rate data comes from successive reads of `status.json`, with the Lua view model
computing the delta between `ibytes`/`obytes` values across draw cycles (see
[pfSense Provider Status](pfsense-provider-status.md) § status.json Schema). These scripts
remain in `scripts/dev/` for manual testing.

### Device Identity Source

`config/ap_ipmap.csv` — static IP→Name map, VLAN-organized, comment-delimited.
Read at runtime by `ap_clients_named.sh` into a bash associative array for the join.

### Current Data Flow

```text
ap_ipmap.csv  ─────────────────────────────────────┐
                                                    ▼
WBE530 SSH ──► zyxel_cmd.sh ──► ap_status_all_clients.sh ──► display
                             └► ap_clients_named.sh  ───────► display

pfSense SSH ──► pf-ssh-gate.sh (allow/trip/reset)
            └► pf-fetch-basic.sh (MODE=full|medium|slow) ──► display
```

---

## Future Architecture

```text
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

## Device Inventory

`ap_ipmap.csv` is the seed for a proper device registry. The engine model requires MAC
as the stable identity key — IP addresses are dynamic (DHCP), but MAC is permanent.

### Current CSV Format

```text
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

SitRep only renders status. Classification belongs to the engine. Building this join is
tracked as remaining work in [pfSense Provider Status](pfsense-provider-status.md) § ARP +
DHCP Collection.

---

## Alert Banner Watcher

Implemented Aug 22, 2026. Cross-cutting engine behavior, not one provider domain —
`providers/alerts/fetch_alerts.sh` reads *other* providers' already-written cache files
(`status.json`, `pihole.json`, `ap_status.json`, `ap_clients.json` under
`shared/pfsense/{profile}/`), applies threshold/duration logic, and writes one shared,
severity-sorted, parent/child-grouped alert queue. Same "engine gathers knowledge, SitRep
reports status" principle as the rest of this doc — SitRep's own Lua build (reading
`banner.json` and rendering the widget) has not started; design record and the full
condition table live in
[SitRep Design Notes § Alert banner / outage detection](../../gtex62-sitrep/design/sitrep-design-notes.md).

**Not a fetch-family provider.** No SSH, no gate, no remote target — pure computation over
cache files other providers already wrote. Safe to re-run on any cadence; every invocation
recomputes from scratch (no cache-TTL skip).

### Configuration

`core.toml`:

```toml
[providers]
alerts = false   # schema-only, matches vpn/ap/modem — not wired into
                 # gtex62-core-launch this session

[alerts]
gateway_offline_duration_sec = 900   # gateway.online continuously false -> SEVERE
pihole_inactive_duration_sec = 600   # pihole.json active continuously false -> CAUTION
```

MSMTCH and unidentified-IP have no threshold key — any count > 0 is an alert, not
configurable (confirmed with user Aug 22, 2026).

### Cache Output

`shared/alerts/{profile}/banner.json` — written by `fetch_alerts.sh`:

```json
{
  "state": "ok",
  "profile": "main_router",
  "collector": "alerts",
  "generated_at": "2026-08-22T19:54:11Z",
  "alert_count": 0,
  "queue": []
}
```

A breached condition is a queue entry:

```json
{
  "id": "gateway-offline",
  "severity": "SEVERE",
  "message": "COMCAST OUTAGE DETECTED",
  "since": "2026-08-22T19:37:53Z",
  "duration_seconds": 1000,
  "children": [
    { "id": "gateway-offline-detail", "severity": "INFORMATIONAL",
      "message": "GATEWAY OFFLINE >=15MIN", "since": "2026-08-22T19:37:53Z" }
  ]
}
```

`children` is always present (empty array when there are none) so a consumer never has to
check for key existence. Array order in `queue` **is** display order — severity-sorted
(SEVERE before CAUTION; top-level entries are never INFORMATIONAL, only children are),
stable within a tier in the watcher's fixed evaluation order (gateway, then each offline
AP, then MSMTCH, unidentified-IP, Pi-hole). Parent/child grouping is inherent to the
structure — children never get flattened into the top-level sort.

### State and Log

`runtime/alerts/{profile}/state.json` — the watcher's own duration-tracking state (first-
breach timestamps + already-alerted flags per condition, `ap_offline_since`/
`ap_offline_alerted` keyed per AP label). Deliberately **not** the `ssh_state` key=value
gate format used elsewhere under `runtime/` — this domain has no gate, and its state shape
(nested per-AP dict) doesn't fit that flat format. Only the `runtime/{domain}/` directory
convention is shared.

`shared/alerts/{profile}/alert_log.txt` — plain text, one line per breach/clear
**transition** (not per poll, so a steady-state alert doesn't spam the log):

```text
2026-08-22T19:54:33Z BREACH SEVERE gateway-offline COMCAST OUTAGE DETECTED
2026-08-22T19:54:49Z CLEAR SEVERE gateway-offline COMCAST OUTAGE DETECTED
```

### Degraded-Source Handling

If an upstream cache file is missing, unparseable, or its own envelope `state` isn't
`"ok"`, the watcher treats that round as "no fresh evidence" for that condition: it does
**not** derive a breach or a clear from stale/absent data, but it also does **not** hide an
already-active alert just because of a transient hiccup (e.g. a tripped SSH gate on
`pihole.json`) — the last known state carries forward untouched until a fresh `"ok"` read
says otherwise. Verified (Aug 22, 2026): forced `status.json` to `state: "degraded"` mid-
alert in a scratch cache tree; `gateway-offline` correctly stayed in the queue rather than
vanishing.

### Gateway Condition Is a Boolean-Duration Proxy

`status.json`'s `gateway.online` is a single ping (boolean), not a loss-%/latency sample —
the `network-health` provider that would supply real loss % was sketched in
[Network Providers Roadmap](network-providers-roadmap.md) but never started. Confirmed with
user (Aug 22, 2026): this watcher approximates the design notes' original ">=25% loss for
>15min" idea as "`gateway.online` continuously `false` for `gateway_offline_duration_sec`"
— same duration-threshold shape, no percentage. Upgrade path once a real loss-% provider
exists: swap this condition's data source, keep the rest of the watcher unchanged.

### Verification (Aug 22, 2026)

**Mechanical:** `jq .` valid on `banner.json`/`state.json`. Simulated all five conditions
simultaneously active via scratch copies of upstream JSON (temp `GTEX62_CONFIG_DIR`/
`GTEX62_CACHE_DIR`, real cache files never touched) — confirmed correct severity ordering
(both SEVERE entries before all three CAUTION entries), correct parent/child grouping
(gateway-offline's INFO detail child, MSMTCH's and unidentified-IP's per-entry INFO
children all nested correctly), correct log lines (5 `BREACH` lines, one per condition).
Re-ran unchanged — confirmed no duplicate `BREACH` log lines (already-alerted state
suppresses re-logging). Cleared all five conditions — confirmed queue emptied
(`alert_count: 0`) and 5 matching `CLEAR` log lines appended.

**Live:** ran `fetch_pfsense.sh`/`fetch_pihole.sh`/`fetch_ap.sh` fresh, then
`fetch_alerts.sh main_router` against the real cache — Pi-hole active, 0 MSMTCH, 0
unidentified IPs, all 3 APs online; gateway ping to the WAN gateway is currently failing
live (`gateway.online: false`) but the 15-minute duration threshold hadn't been crossed at
verification time, so `banner.json` correctly reported `alert_count: 0`, all-clear.

### Deferred

- The mtr_overnight_log.sh SSH trigger to Pi5 — self-terminating runtime, cooldown-window
  logic. `gateway-offline`'s `children` array is structured to accept an "MTR SCRIPT ON PI5
  BEGAN..." entry once this exists; not populated yet.
- Any SitRep-side Lua reading/rendering `banner.json` — the actual widget build, not
  started.
- Wiring `providers.alerts` into `gtex62-core-launch`'s `initial_refresh`/`refresh_loop` —
  schema-only for now, same as `vpn`/`ap`/`modem`/`router`/`pihole`/`pfblockerng`.
