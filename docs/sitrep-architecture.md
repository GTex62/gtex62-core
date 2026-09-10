# SitRep Architecture

Migrating SitRep from a self-contained widget to an engine-driven operational console.
This is the stable design reference — what SitRep is, the principle it's held to, and
the before/after data-flow shape. It changes rarely.

For current implementation state of the data source, see
[pfSense Provider Status](pfsense-provider-status.md). For the original (now archived/superseded — SitRep was built out separately as its own
repo, `gtex62-sitrep`, instead) plan for relocating the widget itself out of
`gtex62-tech-hud`, see [SitRep Relocation Plan](archive/sitrep-relocation-plan.md). Full
prose session history predating
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

Implemented Aug 22, 2026, and now fully built end-to-end (last extended Sept 7, 2026, adding
the `comcast-degraded` condition below). Cross-cutting engine behavior, not one provider
domain — `providers/alerts/fetch_alerts.sh` reads *other* providers' already-written cache
files (`status.json`, `pihole.json`, `ap_status.json`, `ap_clients.json` under
`shared/pfsense/{profile}/`, `status.json` under `shared/modem/{modem_profile}/`, `vpn.json`
under `shared/vpn/{vpn_profile}/`, `mtr_state.json` under `shared/mtr/{mtr_profile}/`), applies
threshold/duration logic, and writes one shared, severity-sorted, parent/child-grouped alert
queue. Same "engine gathers knowledge, SitRep reports status" principle as the rest of this
doc — SitRep's own Lua build reading `banner.json` and rendering the widget is also built
(`lua/suite/pf.lua`'s `alert_banner_lines()`/`M.header_alert_lines()`, drawn by
`lua/ui/frame.lua`'s `draw_header_alert_banner()` in the header's right-hand column; original
design record predating both builds lives in
[SitRep Design Notes § Alert banner / outage detection](../../gtex62-sitrep/design/sitrep-design-notes.md),
now superseded by this section for implementation state).

**Not a fetch-family provider.** No SSH, no gate, no remote target — pure computation over
cache files other providers already wrote. Safe to re-run on any cadence; every invocation
recomputes from scratch (no cache-TTL skip).

### Configuration

`core.toml`:

```toml
[providers]
alerts = true   # wired into gtex62-core-launch's initial_refresh/refresh_loop,
                # same as vpn/ap/modem

[alerts]
gateway_offline_duration_sec = 900         # gateway.online continuously false -> SEVERE
pihole_inactive_duration_sec = 600         # pihole.json active continuously false -> CAUTION
advanced_killswitch_duration_sec = 10      # PIA Advanced KS blocking traffic -> SEVERE
comcast_degraded_t3_burst_count = 5        # this many NEW T3s within...
comcast_degraded_t3_burst_window_min = 5   # ...this many minutes -> CAUTION (half of OR); a rate
                                            # (events/hour), not recent_t3_timeouts's raw total
comcast_degraded_t3_stale_sec = 900        # ...unless modem/status.json's mtime is older than
                                            # this (15min) -> force-expired instead, see below
comcast_degraded_loss_pct_threshold = 25   # gateway.loss_pct >= this percent...
comcast_degraded_loss_duration_sec = 300   # ...sustained this long -> CAUTION (other half of OR)
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
stable within a tier in the watcher's fixed evaluation order (gateway, comcast-degraded,
advanced-killswitch-blocking, pihole, msmtch, unidentified-IP, ap-offline(s)). Parent/child
grouping is inherent to the structure — children never get flattened into the top-level sort.

### Condition Table

Full, current set of conditions the watcher evaluates, folded in from SitRep Design Notes'
original design record now that all seven are core-side implemented and verified:

| Condition | Threshold | Duration | Severity | Message |
| --- | --- | --- | --- | --- |
| Gateway offline | n/a — `status.json`'s boolean `gateway.online` | >=15min default (`gateway_offline_duration_sec`) | SEVERE (root) + INFO (detail, + MTR-began child once `fetch_mtr.sh` confirms Pi5's overnight log started) | COMCAST OUTAGE DETECTED / GATEWAY OFFLINE >=15MIN |
| Comcast degraded | `status.json`'s `gateway.loss_pct` >= 25% (`comcast_degraded_loss_pct_threshold`) OR a T3 burst — `modem/status.json`'s `recent_t3_timeouts` delta since the last poll, normalized to a rate, >= `comcast_degraded_t3_burst_count`/`..._window_min`'s equivalent rate (default 5 within 5min = 60/hr) | loss_pct sustained >=5min default (`comcast_degraded_loss_duration_sec`); T3 burst is itself instantaneous (a rate crossing, not a sustained condition) | CAUTION (root) + INFO child(ren) per sub-condition that actually fired — T3 side gives 2 (burst + running total) | COMCAST DEGRADED / T3: +\<n\> IN \<M\>MIN, T3: \<n\> TOTAL FOR \<H:MM\>, and/or GATEWAY: \<pct\>% FOR \<duration\> |
| Advanced Kill Switch blocking | n/a — `vpn.json`'s `killswitch_mode == "on"` AND `connectionstate != "Connected"` | >=10s default (`advanced_killswitch_duration_sec`) | SEVERE | KS BLOCKING TRAFFIC |
| Pi-hole inactive | n/a | >=10min default (`pihole_inactive_duration_sec`) | CAUTION | PI-HOLE INACTIVE |
| AP client MAC/IP mismatch | n/a (count > 0) — core-computed, `ap_clients.json`'s `mismatch_total` | instant | CAUTION (root) + INFO child(ren) — 2 per mismatch (location + IP), each `.upper()`'d for the render font | MAC/IP MISMATCH (n) / \<NAME\> AT \<LABEL\>, \<IP\> <- \<DOCUMENTED IP\> |
| Unidentified IP | n/a (count > 0) — summed from `ap_clients.json`'s per-AP `unknown[]` | instant | CAUTION | UNIDENTIFIED IP ON NETWORK (n) + INFO child per IP |
| AP offline | n/a — `ap_status.json`'s per-AP `online` | instant | SEVERE | `AP OFFLINE: {label}`, one entry per offline AP |

Gateway offline and Comcast degraded are independent conditions, deliberately evaluated
separately rather than as one condition with two severities — a degraded episode escalating
into a full outage doesn't clear the CAUTION entry, and the CAUTION entry clearing doesn't
imply the outage has too. See § Gateway Conditions below for why they use different data
sources despite both watching WAN health.

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

### Gateway Conditions: Boolean-Duration Proxy (SEVERE) vs. Real Loss % (CAUTION)

`gateway-offline` (SEVERE) is unchanged since Aug 22, 2026: `status.json`'s `gateway.online`
is a single ping (boolean), and the condition stays a boolean-duration proxy —
`gateway.online` continuously `false` for `gateway_offline_duration_sec` — a deliberately
simple, binary signal for "is there a full outage," not a percentage. This was **not**
upgraded when real loss-% data landed (next paragraph); it stays as-is by design, distinct
from `comcast-degraded` below.

Real loss-%/latency data does now exist, though — `fetch_pfsense.sh` (`c7c3f37`,
2026-08-23) added a live dpinger read straight off pfSense's own dpinger polling socket,
writing `gateway.loss_pct`/`latency_ms`/`latency_stddev_ms` (dpinger's own rolling 60s
average, not a single ping) into `status.json`, plus a 20-minute rolling window of 1-min
RRD samples into a new `gateway_history.json`. Both are consumed by SitRep's WAN panel
GATEWAY meter (`lua/suite/pf.lua`'s `gateway_meter_fields()`), and `gateway.loss_pct` is now
also consumed by the alert watcher's `comcast-degraded` (CAUTION) condition (Condition Table
above): `gateway.loss_pct >= comcast_degraded_loss_pct_threshold` (default 25%, matching the
original design notes' aspirational ">=25% loss" target) sustained for
`>= comcast_degraded_loss_duration_sec` (default 300s/5min — deliberately much shorter than
`gateway-offline`'s 900s/15min, since this is meant as an earlier warning, not a duplicate of
the full-outage condition on a longer fuse), OR'd with a T3-timeout burst from
`modem/status.json`'s `recent_t3_timeouts`. The `network-health` provider sketched in
[Network Providers Roadmap](network-providers-roadmap.md) that this data was originally
expected to come from was never built — the dpinger read landed directly inside
`fetch_pfsense.sh` instead, superseding that plan (see that doc's own superseded-note).

`gateway-offline` and `comcast-degraded` are independent conditions, evaluated and cleared
separately — a degraded episode escalating into a full outage doesn't clear the CAUTION
entry, and the CAUTION entry clearing doesn't imply the outage has too.

**What clears `comcast-degraded`:** both sub-conditions are recomputed fresh on every poll
where their source data is current — `t3_burst` and `loss_breached` are each just booleans
re-derived from live numbers, not sticky flags that need an explicit reset. The parent clears
the instant *neither* is true in the same poll. In practice:

- **T3 side (rewritten 2026-09-10, delta baseline fixed same day after a real false-positive —
  see `docs/network-providers-roadmap.md`'s Sept 8-10 session logs for the full
  investigation):** `recent_t3_timeouts` on its own does *not* naturally clear the way it looks
  like it should — it's a whole collapsed row's lifetime count, and stays elevated for as long
  as the same condition recurs at all, however mildly (a trickle averaging ~2.5/hr was observed
  staying continuously above the old flat threshold for 40+ hours). What actually clears the T3
  side now is the *burst* signal: `fetch_alerts.sh` tracks `t3_last_seen_count`/`t3_last_seen_at`/
  `t3_last_seen_since_epoch` (state.json) across polls and computes `rate = delta ÷
  hours_since_last_poll` each time — but only trusts that delta when the current reading's
  lineage anchor (`recent_t3_since_epoch`) matches the baseline's, i.e. it's provably the same
  row reappearing rather than a different/new one. A poll that reads `0` never touches the
  baseline (a quiet gap of any length doesn't erase what's known about a lineage that might
  reappear) — added after a real live false positive where the baseline's own reset-to-0
  behavior made a resurfacing chronic row's entire history look like a fresh burst. The T3 side
  breaches only when the (correctly-attributed) rate crosses `comcast_degraded_t3_burst_count`/
  `..._window_min`'s equivalent (default 60/hr), and clears the very next poll where it doesn't
  — typically within one poll cycle of the burst actually subsiding, not an hour later. A pure
  trickle (nonzero total, rate below the burst
  floor) never breaches this condition at all anymore; that context lives only on the WAN
  panel's always-visible `T3 X N TOTAL` line, not the banner.
- **Loss side:** clears as soon as a single fresh `gateway.loss_pct` sample reads below
  `comcast_degraded_loss_pct_threshold` — not sustained-to-clear the way it's sustained-to-
  breach; `comcast_loss_since` resets to `None` immediately.
- **Stale-data safety net (T3 side only, added 2026-09-09):** the above assumes
  `modem/status.json` keeps getting refreshed. If `fetch_modem.py` stops running entirely
  (crash, dead loop, expired credential) rather than writing a fresh error state, the file
  just sits there saying `"ok"` with whatever `recent_t3_timeouts` it last saw —
  indistinguishable from "still genuinely breached" by `state` alone. `fetch_alerts.sh`
  checks the file's mtime and force-expires the T3 sub-condition if it's older than
  `comcast_degraded_t3_stale_sec` (default 900s/15min), so a dead provider can't pin the
  banner open indefinitely — and deliberately does *not* advance the burst baseline off stale
  data, so the next genuinely fresh poll computes its delta/rate against the last real
  reading, however long ago that was. This is distinct from the *same-poll* `ok_modem=False`
  case (provider itself reports "degraded"/"error" fresh this poll), which is deliberately
  persisted rather than treated as a clear.

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

### Verification — `comcast-degraded` (Sept 7, 2026)

Against real cache files, backed up first and restored after (never left forced/fake):
forced `modem/status.json`'s `recent_t3_timeouts` to 9 (>= threshold 5) with real
`gateway.loss_pct` untouched — confirmed T3-only breach, single `comcast-degraded-t3` child,
correct `T3: 9 IN 60M` message. Restored modem, confirmed `CLEAR` logged. Forced
`gateway.loss_pct` to 40.0 (>= threshold 25) — confirmed no immediate breach on the first
poll (duration-sustain gate correctly withholding it), then backdated `comcast_loss_since` in
`state.json` past `comcast_degraded_loss_duration_sec` — confirmed loss-only breach, single
`comcast-degraded-loss` child, correct `GATEWAY: 40% FOR 6MIN` message. Forced both
simultaneously — confirmed both children present together under one `comcast-degraded`
parent, and no duplicate `BREACH` log line for the still-ongoing episode (already-alerted
state correctly suppressed it). Cleared both — confirmed `CLEAR` logged and queue emptied.
Loaded `lua/suite/pf.lua` standalone (`lua -e 'dofile(...)'`) and called
`M.header_alert_lines()` directly against the forced cache — confirmed the exact SitRep
header rendering path shows `COMCAST DEGRADED` / `T3: 9 IN 60M` / `GATEWAY: 40% FOR 6MIN` on
three lines (fits the 3-line non-scrolling window). Final state: all forced files restored
byte-identical to their real originals (`diff` confirmed), `banner.json` back to
`alert_count: 0`, header back to `NO ACTIVE ALERTS`.

### Deferred

- pfSense update-available indicator: pfSense's own dashboard shows this; unconfirmed
  whether it's accessible outside the web UI (SSH/CLI via pfSense-utils.inc, XML config,
  pkg version-style) or is web-UI-only, in which case it gets left off or becomes a
  manual-check-only item.
