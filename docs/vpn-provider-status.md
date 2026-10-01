# VPN Provider Status

Current implementation state of the core `vpn` provider: script location, output schema,
configuration, and known constraints. Written Oct 1, 2026, promoting `vpn` out of
[Network Providers Roadmap](network-providers-roadmap.md) into the same
`-provider-status.md` structure used by [pfSense Provider
Status](pfsense-provider-status.md)/[Weather Provider Status](weather-provider-status.md),
the way `astro`/`system` were previously promoted out of their own former `*-schema.md`
docs. This doc reflects the **current, final schema** after every fix described below —
read it first for "what does `vpn.json` actually look like today."

**Network Providers Roadmap is not superseded** — it stays as the full chronological
investigation log (the reasoning, dead ends, and live-verification detail behind every
fix summarized here) and as the only built-out home for the still-not-built
`network-health` proposal. [CHANGELOG.md](../CHANGELOG.md) cites specific dated sessions
in that doc by name throughout; this doc doesn't repeat that narrative, it distills the
current state from it. Companion docs: [Architecture](architecture.md) (provider pattern,
cache layout, TTL table), [Modem Provider Status](modem-provider-status.md) (sibling
domain, built the same session, corroborates `vpn` on the WAN panel), [SitRep
Architecture](sitrep-architecture.md) (Alert Banner Watcher's `killswitch-blocking`/
`advanced-killswitch` conditions, which read `vpn.json`).

---

## Implementation Status

### `providers/vpn/fetch_vpn.sh` ✓ COMPLETE (last touched Sept 17, 2026)

PIA WireGuard tunnel status. A structurally different provider class from the SSH-gated
pfSense family — **local-only, no SSH target, no gate**: `piactl` and `wg` are local
commands, polled directly on-host. Cadence can run tighter than SSH-based providers since
there's no remote round-trip (10s TTL in the shipped profile).

Three independent data sources, chosen by what each fact actually *is*, not by a single
"PIA vs. generic WireGuard" branch:

| Fields | Source |
| --- | --- |
| `connectionstate`, `region`, `protocol`, `vpnip` | `piactl get <key>` (PIA application-level) |
| `interface`, `latest_handshake_seconds`, `transfer`, `endpoint` | `sudo wg show <iface> dump` (WireGuard kernel module — generic, not PIA-specific) |
| `killswitch` | `ip route show table piavpnFwdrt` (PIA policy routing — `blackhole` route present/absent) |
| `killswitch_mode` | `/opt/piavpn/etc/settings.json`'s `killswitch` string (world-readable, no sudoers rule needed) |
| `tunnel_latency_ms` | A single ICMP echo (`ping -I <iface> -c1 -W1 1.1.1.1`) sent through the tunnel interface itself |

Because the `wg`-sourced fields are generic WireGuard facts, `fetch_vpn.sh` would extend
cleanly to a second, unrelated tunnel without a schema change — the `piactl`-sourced
fields would simply be absent/null for that tunnel.

**`wg show` requires root.** A narrowly-scoped passwordless sudoers rule is installed at
`/etc/sudoers.d/gtex62-core-vpn`:

```text
gtex62 ALL=(root) NOPASSWD: /usr/bin/wg show wgpia0 dump
```

Exact-string match, no wildcards — changing `[interface].name` in the profile TOML away
from `wgpia0` makes this sudo call start failing until the rule is updated to match.

---

## Output Schema

### vpn.json

`shared/vpn/{profile}/vpn.json` — written by `fetch_vpn.sh`.

```json
{
  "state": "ok",
  "profile": "local",
  "collector": "vpn",
  "generated_at": "2026-10-01T14:23:00Z",
  "note": "",
  "connectionstate": "Connected",
  "region": "us-texas",
  "protocol": "wireguard",
  "interface": "wgpia0",
  "vpnip": "102.129.234.184",
  "endpoint": "102.129.234.184:1337",
  "latest_handshake_seconds": 55,
  "keepalive_interval_seconds": 25,
  "transfer": { "rx_bytes": 1593344, "tx_bytes": 454522 },
  "tunnel_latency_ms": 23.4,
  "tunnel_latency_last_ok_epoch": 1759327380,
  "killswitch": true,
  "killswitch_mode": "on",
  "health": "HEALTHY"
}
```

`vpnip` (tunnel-assigned local address) and `endpoint` (remote PIA server's public
address) are distinct and both kept even though they often match the same IP
coincidentally for a given server.

#### Health Classification

`health` is engine-derived from handshake freshness, independent of `connectionstate`
(the raw PIA-reported state) — same "verdict vs. raw fact" split as `PIA: HEALTHY` vs.
`VPN: CONNECTED` on the display side.

| Class | Condition |
| --- | --- |
| `HEALTHY` | `connectionstate == "Connected"` and handshake age < 130s |
| `STALE` | `connectionstate == "Connected"` and handshake age 130–180s |
| `DEAD` | `connectionstate != "Connected"`, or handshake age > 180s, or absent |

Thresholds are rebased off WireGuard's own protocol constants — **REKEY-AFTER-TIME**
(a session renegotiates once its handshake is 120s old) and **REJECT-AFTER-TIME** (180s:
no successful handshake within this and the session is protocol-dead) — not off
`PersistentKeepalive` (25s). The two mechanisms are independent: keepalive sends happen
on their own 25s schedule regardless of when the handshake itself renews. An earlier
60s/180s split assumed handshake age tracked keepalive cadence; live capture (72 samples
over 6 minutes) showed the handshake timestamp only ever advancing every 120s exactly,
which is what the 130s `HEALTHY` ceiling is sized against (10s margin over the observed
max).

#### Killswitch Fields — Two Independent Questions

`killswitch` (is it enforcing *right now*) and `killswitch_mode` (which mode is
*configured*) answer different questions and can't be derived from each other:

- **`killswitch`** — derived from `piavpnFwdrt`'s `blackhole` route, **only while
  `connectionstate == "Connected"`**. A voluntary disconnect clears this table by design
  regardless of the configured mode, making an empty table indistinguishable from
  "killswitch off" by inspection alone — so outside `Connected`, and on any
  Connected-but-empty read (treated as a transient race), the field holds its last-known
  value rather than re-deriving from an empty table.
- **`killswitch_mode`** (`"off"` / `"auto"` / `"on"`, added Aug 28, 2026) — `piactl`
  has no `killswitch` get/set type at all (confirmed via its own enumerated type list);
  PIA's regular "VPN Kill Switch" and "Advanced Kill Switch" render **identically** in
  `piavpnFwdrt` while Connected, so the route table alone can't distinguish them. Read
  instead from `/opt/piavpn/etc/settings.json`'s own tri-state string. `"on"` implies
  regular KS is also active (per the client's own warning string) — not an independent
  third toggle.

#### State Field Values

| Value | Meaning |
| --- | --- |
| `"ok"` | No fetch-level problem this run |
| `"degraded"` | One of two conditions closed Sept 17, 2026 (see Known Quirks / History): a failed `wg show` dump while `connectionstate == "Connected"` (sudoers misconfigured, or `wg` missing — **not** fired on an ordinary disconnect, where `wg` failing is expected), or `tunnel_latency_ms == null` while `health != "DEAD"` (ping failing but the tunnel itself is otherwise up) |
| `"disabled"` | Profile has `enabled = false` |
| `"error"` | Missing profile TOML, or `piactl` not found |

---

## Configuration

`profiles/vpn/{profile}.toml`:

```toml
profile_id = "local"
enabled = true
cache_ttl_sec = 10   # tighter than SSH-based providers — no remote round-trip

[interface]
name = "wgpia0"   # must exactly match the sudoers rule's authorized command
```

No `[credentials]` section — nothing here authenticates to anything; `piactl`/`wg`/`ping`
all run as the local user (`wg` via the sudoers rule above).

---

## Known Quirks / History

Condensed; see [Network Providers Roadmap](network-providers-roadmap.md) for the full
investigation behind each of these.

- **`piactl get killswitch`/`publicip` are not supported**, despite third-party
  documentation claiming otherwise — confirmed live (`Unknown type`) and again later via
  `piactl --help`'s own enumerated type list, which omits `killswitch` entirely. This is
  why killswitch state has to come from routing-table inspection rather than a direct API
  call.
- **Advanced Kill Switch blocks traffic even after a voluntary disconnect** — the one
  place `killswitch` (not just `killswitch_mode`) *can* distinguish the two modes:
  regular mode clears `piavpnFwdrt` completely on disconnect, Advanced mode leaves the
  `blackhole` route in place. Structurally unreachable by `fetch_vpn.sh` itself (it
  doesn't re-derive `killswitch` outside `Connected`), but is exactly the condition the
  Sept 2026 `advanced-killswitch` SEVERE alert (`fetch_alerts.sh`) exists to catch from
  the alerts side.
- **No pre-computed tunnel-latency source exists.** `piactl` has no latency/ping
  subcommand; PIA's own per-region `LatencyTracker` is internal daemon RPC state (its GUI
  region picker), not reachable via `piactl` or a readable file. `tunnel_latency_ms`
  (Aug 24, 2026) pings a public target (`1.1.1.1`) through the tunnel interface
  (`ping -I wgpia0`) rather than the VPN endpoint IP — PIA excludes the endpoint's own IP
  from the tunnel's routes, so pinging it via `-I` would silently take the untunneled
  path and re-measure the WAN link instead.
- **Two silent "ok while actually broken" gaps closed Sept 17, 2026** (part of a
  six-domain Doctor-driven audit, see [CHANGELOG.md](../CHANGELOG.md) 0.7.0): a failed
  `wg show` dump previously only surfaced via `health` going `"DEAD"`, which Doctor would
  have needed a VPN-specific exception to treat as a real fetch failure (since `health`
  also reads `"DEAD"` on an ordinary disconnect, a non-alarming case). A lone failed
  tunnel ping while otherwise healthy had no signal anywhere at all. Both now elevate
  `state` to `"degraded"`, confirmed never to collide (a failed wg dump already forces
  `health:"DEAD"`, which is what excludes the ping-failure check from also firing).
- **Titan-specific PIA Split Tunnel requirement:** PIA's policy routing was found pulling
  traffic to `192.168.100.1` (the modem's NAT-to-VIP address, see [Modem Provider
  Status](modem-provider-status.md)) into the tunnel/killswitch instead of reaching
  pfSense's LAN gateway. Fixed by adding `192.168.100.0/24` as a bypass-VPN rule under
  PIA's Split Tunnel settings — per-device config, so any other host running both PIA and
  `fetch_modem.py` needs the same rule added separately.

---

## Known Constraints

- **Single ICMP sample per poll** for `tunnel_latency_ms` — no averaging/jitter tracking,
  just the one echo per `cache_ttl_sec` cycle (10s).
- **`health`'s 130s/180s thresholds are not configurable** — hardcoded against
  WireGuard's own REKEY-AFTER-TIME/REJECT-AFTER-TIME constants, not read from TOML.
- **No rate limiting of any kind** — `piactl`/`wg`/`ping` are all local/kernel calls with
  no external quota to respect.

---

## Remaining Work

- [ ] Wiring into OSA's display/layout (`PIA` status line, VLAN table `VPN` transfer
      column) — out of scope for the provider itself; a later suite-side task.
- [ ] Whether `fetch_modem.py`'s HTTP path and `fetch_vpn.sh`/`pf-ssh-gate.sh`'s SSH gate
      should interact (e.g. sustained modem failures influencing pfSense SSH gating,
      given both ultimately route through the same pfSense box) — open question, not
      attempted.

---

## Session History

Condensed from [CHANGELOG.md](../CHANGELOG.md) and [Network Providers
Roadmap](network-providers-roadmap.md); see either for full verification detail.

- **Aug 19, 2026 (0.2.0) — Built and verified.** `fetch_vpn.sh` shipped: `piactl`/`wg`/
  routing-table sourced fields, `killswitch` carry-forward logic, `health` classification
  (60s/180s thresholds at this point). Live cross-check against real `wg show` output and
  controlled killswitch-on/off + forced-drop states across all four combinations.
- **Aug 24, 2026 (0.4.0) — `tunnel_latency_ms` added.** Real ICMP-sourced tunnel latency;
  no pre-computed source existed. Verified live across a normal sample, a fake-interface
  probe, and a real disconnect/reconnect cycle.
- **Aug 24, 2026 — `health` thresholds rebased to 130s/180s.** REKEY-AFTER-TIME, not
  keepalive cadence, is what actually drives handshake renewal — see Health
  Classification above.
- **Aug 28, 2026 (0.6.0) — `killswitch_mode` added**, plus the new `advanced-killswitch`
  SEVERE alert in `fetch_alerts.sh` for Advanced KS blocking traffic post-disconnect.
- **Sept 17, 2026 (0.7.0) — Two silent-gap closures**, part of a six-domain Doctor audit:
  `state` now goes `"degraded"` for a failed `wg` dump (gated on `Connected`, so routine
  disconnects don't false-positive) and for a failing tunnel ping while otherwise
  healthy. 11 scenarios verified against the real shipped code.
