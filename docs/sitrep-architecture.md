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
