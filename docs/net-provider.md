# Core Net Provider

## Purpose

The `net` provider is a fast-refresh shared cache for local network display data:
NIC identity, online status, speedtest summary, node table values, ping results,
and VLAN latency rows.

It is distinct from the `network` domain (normalized interface state from the
network provider) and the `connectivity` domain (speedtest snapshots). The `net`
provider acts as a display-ready projection layer on top of those shared sources,
refreshed at a faster cadence than either.

---

## Provider

```
providers/net/fetch_net.sh <profile>
```

Profile default: `local`

---

## Cache Location

```
~/.cache/gtex62-core/shared/net/<profile>/state.vars
~/.cache/gtex62-core/shared/net/<profile>/vlan.tsv
```

---

## Profile

```
~/.config/gtex62-core/profiles/net/<profile>.toml
```

Example (`profiles/net/local.toml`):

```toml
[cache]
# How often to refresh pings, WAN IP, and VLAN latency (seconds)
ttl_sec = 60
```

See `examples/runtime/profiles/net/local.toml.example` for the installable
template.

Suite TOML binding:

```toml
[profiles]
net = "local"
```

---

## `state.vars`

### Format

Simple `KEY=value` text, one per line.

```text
GENERATED_AT=2026-04-22T06:58:41Z
IFACE=eno1
TITLE=Intel I219-V
STATUS=ONLINE
LIVE_PERCENT=100
SPEEDTEST_DOWN=594
SPEEDTEST_AGE=06:42
SPEEDTEST_DELTA=+094
WAN_IP=73.177.9.62
LAN_IP=192.168.10.3
DNS=192.168.40.7
SUBNET=255.255.255.0
GATEWAY=192.168.10.1
CF_1111_MS=14.4
GOOGLE_8888_MS=20.2
SSH_TRIPPED=0
SSH_STATUS=OK
SSH_REASON=
SSH_LEFT=0
```

### Key Reference

| Key | Description |
|-----|-------------|
| `GENERATED_AT` | ISO 8601 UTC generation timestamp |
| `IFACE` | Primary network interface name |
| `TITLE` | User-facing NIC label (model name or alias) |
| `STATUS` | `ONLINE` or `OFFLINE` |
| `LIVE_PERCENT` | Online meter value; currently `100` or `0` |
| `SPEEDTEST_DOWN` | Cached download Mbps from speedtest snapshot |
| `SPEEDTEST_AGE` | Elapsed time since snapshot; `HH:MM` under 24h, `NNd` after, `--:--` if unavailable |
| `SPEEDTEST_DELTA` | Signed Mbps delta from baseline, e.g. `+094`; `---` if unavailable |
| `WAN_IP` | Public/WAN IP address (or VPN IP when VPN is active) |
| `VPN_STATE` | `ON`, `OFF`, or `UNKNOWN` |
| `LAN_IP` | LAN IPv4 address on the primary interface |
| `DNS` | Primary DNS server |
| `SUBNET` | Dotted-decimal subnet mask |
| `GATEWAY` | Default gateway |
| `CF_1111_MS` | Ping result for `1.1.1.1` in ms |
| `GOOGLE_8888_MS` | Ping result for `8.8.8.8` in ms |
| `SSH_TRIPPED` | `1` when pfSense SSH gate is in cooldown, otherwise `0` |
| `SSH_STATUS` | Raw SSH gate status |
| `SSH_REASON` | Trip reason, e.g. `PF_SSH_FAIL` |
| `SSH_LEFT` | Remaining cooldown seconds when tripped |

---

## `vlan.tsv`

### Format

Tab-separated, one row per VLAN gateway.

```text
192.168.10.1	0.546000	0.23
192.168.20.1	0.524000	0.24
192.168.30.1	0.526000	0.24
192.168.40.1	0.538000	0.23
192.168.50.1	0.518000	0.24
```

### Column Order

| Col | Key | Description |
|-----|-----|-------------|
| 1 | `gateway` | VLAN gateway address |
| 2 | `speed_ratio` | Normalized bar-fill value (0.0–1.0) |
| 3 | `ms` | Ping text shown in the latency column |

VLAN hosts are read from the `network` provider cache (`vlan_hosts[].host`),
falling back to `site.toml`, then to hardcoded defaults.

---

## Refresh Model

The launcher schedules:

- initial background refresh at startup
- recurring background refresh every `ttl_sec` seconds (default 60)

VLAN pings and external pings (`1.1.1.1`, `8.8.8.8`) run in parallel so one
slow target does not stretch the full refresh interval.

---

## Suite Consumption

Suites read from `shared/net/<profile>/` and resolve the profile from their
suite TOML `[profiles] net` key (default `"local"`).

OSA reads this cache via `lua/suite/net.lua`.
