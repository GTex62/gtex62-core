# Network Providers Roadmap

Proposed engine providers unrelated to pfSense's SSH-gated domains: `vpn` (local
`piactl`/`wg` polling, no SSH), `network-health` (WAN loss/latency sampling), and `modem`
(HTTP scrape of the cable modem's admin UI via a pfSense NAT path). `vpn` was built and
verified Aug 19, 2026 (see its Session Log below); `modem` was built and verified Aug 19,
2026, including a live credential cross-check (see its Session Log below); `network-health`
is not started. They're grouped here because they were drafted in the same
investigation session, not because they share a transport, host, or gate with each other or
with the `pfsense` provider — see [pfSense Provider Status](pfsense-provider-status.md) for
that.

Full prose history predating this split:
[archive/sitrep-engine-migration-2026-08-18.md](archive/sitrep-engine-migration-2026-08-18.md).

---

## VPN Provider (Built — Aug 19, 2026)

A new, simpler provider class — no SSH target, no gate. `piactl` and `wg` are local
commands; `fetch_vpn.sh` polls them directly and writes via the same atomic-write pattern
as `fetch_pfsense.sh`. Cadence can be tighter than the SSH-based providers since there's
no remote round-trip cost — 10–15s is reasonable.

### Session Log — Aug 19, 2026 (Build + Verification)

- Built `providers/vpn/fetch_vpn.sh` — no SSH gate, reusing `fetch_pfsense.sh`/
  `fetch_pihole.sh`'s TOML-parsing helpers, atomic-write pattern, and envelope
  (`state`/`profile`/`collector`/`generated_at`/`note`), per the "Data Sources — Resolved"
  and "Killswitch Detection" sections above.
- Added `health` field to the schema (see correction on the schema block above).
- Installed the sudoers rule (see "Resolved" note under "Data Sources — Resolved" above),
  confirmed working live.
- Bootstrapped the new profile TOML (`profiles/vpn/local.toml.example` →
  `~/.config/gtex62-core/profiles/vpn/local.toml`) via
  `gtex62-core-bootstrap-runtime` — no bootstrap gap left behind.
- Mechanical verification: `jq .` valid, all fields populated in the Connected state;
  wg-sourced fields correctly go `null` (with a `note`) when `wg dump` is denied, without
  failing the whole fetch — tested via an unauthorized interface name, not by touching the
  real sudoers rule.
- Cross-check verification: manually diffed `fetch_vpn.sh`'s output against raw
  `sudo wg show wgpia0 dump` and `ip route show table piavpnFwdrt` — structurally matched;
  only sampling drift (handshake age, transfer counters) between runs, as expected.
  TTL gating (`cache_ttl_sec`) confirmed to skip back-to-back calls and refresh once stale.
- Killswitch-enabled + forced-drop re-confirmed live (already-documented row), plus a new
  detail: PIA's reconnect fully tears down and recreates the `wgpia0` netdev rather than
  just re-establishing the link — see "Killswitch Detection" above.
- **Killswitch-disabled + forced-drop — previously untested — verified this session.**
  See "Resolved" note under "Killswitch Detection — Verified Mechanism" above. Classification
  logic in `fetch_vpn.sh` holds correctly.
- Not done this session: wiring `vpn.json` into OSA's display/layout (`PIA` status line,
  VLAN table `VPN` column) — out of scope per this session's guardrails
  (`gtex62-osa`/`gtex62-tech-hud` stayed read-only throughout). Still a later task.

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
  "killswitch": true,
  "health": "HEALTHY"
}
```

(Envelope fields `state`, `profile`, `collector`, `generated_at`, `note` — same precedent
as `status.json`/`pihole.json` — are omitted from this sample for brevity but are present
in the real output; see the actual `vpn.json` samples in the build session log below.)

**Schema update (Aug 28, 2026):** added `killswitch_mode` (`"off"`/`"auto"`/`"on"`, or
`null`) alongside `killswitch` — a second, independent field answering "which mode is
configured" rather than "is it enforcing right now". See "Killswitch Mode Detection —
Advanced vs. Regular" below for why a second field was needed at all.

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

```text
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
| `connectionstate`, `region`, `protocol`, `vpnip` | PIA app | `piactl get connectionstate` / `region` / `protocol` / `vpnip` |
| `interface`, `latest_handshake_seconds`, `transfer`, `endpoint` | WireGuard kernel module | `wg show wgpia0 dump` |
| `killswitch` | PIA policy routing tables (see below) | `ip route show table piavpnFwdrt` |

**Correction (build session, Aug 19, 2026):** `vpnip` was originally assumed to come from
`wg show dump`, but that command doesn't actually carry the interface's local tunnel
address — only peer/handshake/transfer data. `piactl get vpnip` returns it directly and is
what `fetch_vpn.sh` actually uses (same source `fetch_net.sh` already relies on for its own
VPN-aware WAN IP lookup). `protocol` also turned out to be directly available via
`piactl get protocol` (confirmed live, returns `wireguard`) rather than needing to be
hardcoded as originally planned.

`piactl get killswitch` and `piactl get publicip` were tested directly and confirmed
**not supported** — both return `Unknown type`. A third-party command reference claimed
otherwise; it was wrong. This rules out the documented CLI path entirely for killswitch
state — it has to come from inspecting PIA's routing, not piactl.

Because the wg-sourced fields are generic WireGuard facts rather than PIA-specific ones,
`fetch_vpn.sh` would extend cleanly to a second, unrelated WireGuard tunnel later without a
schema change — the piactl-sourced fields would simply be absent/null for that tunnel. No
fallback branch is needed; this resolves the original open question.

**Resolved (build session, Aug 19, 2026):** `wg show` requires root (confirmed directly —
without `sudo` it returns `Unable to access interface: Operation not permitted`). A
narrowly-scoped passwordless sudoers rule was installed at
`/etc/sudoers.d/gtex62-core-vpn`:

```text
gtex62 ALL=(root) NOPASSWD: /usr/bin/wg show wgpia0 dump
```

Exact-string match — sudoers has no wildcards here, so only this literal command with
these literal arguments is authorized; changing the interface name in the profile TOML
away from `wgpia0` will make this sudo call start failing until the rule is updated to
match. Confirmed working end-to-end against the live tunnel.

### Killswitch Detection — Verified Mechanism

PIA's Linux killswitch is implemented as policy routing, not firewall rules. Custom route
tables are registered in `/etc/iproute2/rt_tables`:

```text
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
| `blackhole` only | Tunnel failed unexpectedly, Kill Switch **enabled** — enforcing, traffic dropped |
| Empty | Voluntary disconnect, **or** tunnel failed unexpectedly with Kill Switch **disabled** — not enforced either way |

The last row matters for interpretation: a deliberate disconnect (GUI or `piactl
disconnect`) clears this table regardless of the Kill Switch setting — by design, the
client doesn't block your traffic just because you asked to disconnect. This means an
empty table is **indistinguishable from "killswitch off"** by inspection alone.
`fetch_vpn.sh` should only read `killswitch` from this table while
`connectionstate == "Connected"`; outside that, hold the last-known value rather than
re-deriving it from an empty table. `fetch_vpn.sh` additionally holds the last-known value
whenever the table reads empty even while `connectionstate == "Connected"` — an empty read
during that state is treated as a transient race, not a fact worth trusting on its own.

The "failed unexpectedly, KS enabled" row was confirmed by forcing `sudo ip link set
wgpia0 down` without touching the PIA app — the `blackhole` route held and became the sole
entry while the `wgpia0` route vanished, confirming the killswitch enforces during a real
failure, not just at the configuration level. Re-confirmed a second time in the build
session below, with the added detail that PIA's reconnect fully tears down and recreates
the `wgpia0` netdev (new ifindex, new keypair) rather than just bringing the link back up —
`wg show` correctly errors `No such device` for the few seconds the interface doesn't exist
at all, independent of killswitch state.

**Resolved (build session, Aug 19, 2026):** Kill Switch disabled + forced unexpected drop —
previously untested. Verified via `sudo ip link set wgpia0 down` with Kill Switch confirmed
off beforehand (table read as `dev wgpia0` only, no `blackhole`, immediately prior). Result:
`piavpnFwdrt` went completely **empty** the instant the link dropped and stayed empty for
the entire outage (including through the interface teardown/recreate window) — `blackhole`
never appeared at any point. This confirms the killswitch genuinely does not enforce when
disabled (no leak-blocking route ever gets installed), and also confirms the row above:
"disabled + failed" is empirically indistinguishable from "voluntary disconnect" by table
inspection alone, same as the doc predicted for the disconnect case specifically. Raw log
of the full sampled sequence (1s cadence, `ip link show` / `ip route show` / `ip route show
table piavpnFwdrt` / `wg show wgpia0 dump`) is not retained past the session — the pattern
above is the durable finding. `fetch_vpn.sh`'s carry-forward logic handles this correctly:
since the table reads empty throughout, it never attempts to derive `killswitch` from
content and instead holds the last-known value the whole time, which was already `false` —
the correct answer, arrived at safely rather than by reading (and getting lucky with) an
empty table.

### Killswitch Mode Detection — Advanced vs. Regular (Aug 28, 2026)

PIA ships two distinct Kill Switch modes — regular "VPN Kill Switch" and "Advanced Kill
Switch" — and `KS ON` alone couldn't tell the user which was active. Investigated whether
`piavpnFwdrt` (the table `killswitch` above is derived from) can distinguish them at all,
or whether that requires a separate source.

**Config representation, verified live, not from docs:** `piactl get`/`set` have no
`killswitch` type at all — confirmed via `piactl --help`'s own enumerated type lists
(`allowlan`, `connectionstate`, `debuglogging`, `portforward`, `protocol`, `pubip`,
`region`, `regions`, `requestportforward`, `vpnip` for `get`; a similarly short list for
`set` — `killswitch` is in neither), a cleaner confirmation than the prior session's
trial-and-error `Unknown type` result for the same conclusion. The daemon instead persists
the setting as a plain string field in `/opt/piavpn/etc/settings.json`:
`"killswitch": "on"`. That file is **world-readable** (mode `644`, `root:piavpn`, under
`755` dirs) — no sudoers rule needed, unlike the `wg show` path.

The three values and their meaning were pulled from the QML strings embedded in the
`pia-client` binary itself (`strings /opt/piavpn/bin/pia-client | grep -i killswitch`),
not assumed:

| `settings.killswitch` | UI label | Notes |
| --- | --- | --- |
| `"off"` | (unchecked) | Kill Switch off |
| `"auto"` | "VPN Kill Switch" | regular mode |
| `"on"` | "Advanced Kill Switch" | client's own warning string: *"VPN Kill Switch is always enabled when Advanced Kill Switch is enabled."* — `"on"` implies regular KS too, not an independent toggle |

**Live test:** this machine's live `settings.json` already had `killswitch: "on"`
(Advanced) at investigation time, which doubled as the test case — no GUI driver was
available to flip it via `piactl` (unsupported, per above), so the test rode the existing
live setting rather than toggling it. Sampled `piactl get connectionstate` + `ip route
show table piavpnFwdrt` at 0.5s cadence through a real `piactl disconnect` /
`piactl connect` cycle:

- **While Connected:** table read `dev wgpia0` + `blackhole` — **identical** to the
  regular-mode "Connected, enabled" row already documented above. No distinguishing
  signal at the source while connected, under either mode.
- **Immediately after voluntary disconnect:** table read `blackhole` **only** — it did
  **not** empty. This contradicts the regular-mode behavior documented above (Aug 19
  session: voluntary disconnect clears the table completely, verified for `"auto"`/off).
  Advanced Kill Switch keeps blocking traffic even once the tunnel is intentionally down,
  which is the entire point of the mode — and the route table reflects that.

**Verdict:** genuinely split, not cleanly either "easy display fix" or "hard detection
limit". `piavpnFwdrt` alone **cannot** distinguish the two modes while Connected — the
table renders identically either way, so no amount of smarter parsing of that table fixes
it in that state. It *can* distinguish them at/after disconnect, but `fetch_vpn.sh`
deliberately doesn't re-derive `killswitch` outside `connectionstate == "Connected"` (the
carry-forward logic above), so that signal was structurally unreachable anyway. The fix
that shipped instead: read `/opt/piavpn/etc/settings.json`'s `killswitch` field directly
as a second, independent source — trivially readable, no privilege escalation, and
authoritative about configured mode in a way route-table inspection never can be. Added
as `killswitch_mode` on `vpn.json` (see schema update above); `vpn.lua`'s `KS` line now
reads `KS ON (ADV)` when `killswitch_mode == "on"`, `KS ON` for regular, unchanged `KS
OFF` otherwise (mode doesn't matter once nothing's being enforced).

### Health Classification (VPN)

`latest_handshake_seconds` is the leading indicator of tunnel health — a stale handshake
often precedes `connectionstate` catching up to a dropped tunnel. The engine, not SitRep,
classifies this.

Handshake age reflects WireGuard's own **REKEY-AFTER-TIME**: a session renegotiates a
fresh handshake once it's 120s old, on the next outbound send. **This is independent of
`PersistentKeepalive`** — the keepalive interval (25s, confirmed live) governs how often
an empty packet goes out to hold a NAT mapping open, not how often the cryptographic
handshake itself renews. The two mechanisms don't interact; a "healthy tunnel should
never miss more than one or two keepalive cycles" framing (this doc's original wording)
was a false premise — it assumed handshake age tracks keepalive cadence, which it
doesn't. `REJECT-AFTER-TIME` (180s: no successful handshake within this and the session
is protocol-dead) is the other bound here and is unrelated to keepalive either way.

| Class | Condition |
| --- | --- |
| `HEALTHY` | `connectionstate == "Connected"` and handshake < 130s (covers a full normal REKEY-AFTER-TIME cycle, ~10s margin) |
| `STALE` | `connectionstate == "Connected"` and handshake 130–180s (past normal rekey, not yet REJECT-AFTER-TIME) |
| `DEAD` | `connectionstate != "Connected"` or handshake > 180s (REJECT-AFTER-TIME) or absent |

**Implementation note (build session, Aug 19, 2026):** `fetch_vpn.sh` originally
implemented this table with 60s/180s thresholds, sized off the now-corrected
keepalive-cycles premise above. `keepalive_interval_seconds` is still read live and
included in `vpn.json`, but classification was never actually scaled by it — that idea
(scaling thresholds as a multiple of the keepalive interval) is dropped, not just
deferred: it was built on the same false premise and doesn't apply once handshake
renewal is understood to be a REKEY-AFTER-TIME event, not a keepalive-cycle count.

**Correction (verification session, Aug 24, 2026):** live capture — 72 samples over 6
minutes, 5s poll of `wg show wgpia0 dump` — showed `latest_handshake_ts` advancing
exactly three times, each at precisely +120s, while `persistent-keepalive` stayed on its
own unrelated 25s cadence throughout. This confirmed REKEY-AFTER-TIME (not keepalive
cycles) as the actual driver and reproduced the reported symptom: with the old 60s/180s
split, every ~120s cycle spent its second half (60–120s) reading `STALE` on an otherwise
fully healthy, low-latency, actively-passing-traffic tunnel. Thresholds were rebased to
130s/180s per the table above — 130s keeps `HEALTHY` covering the entire observed cycle
(max age recorded just before rollover was 118–120s) with a small margin, verified
against a fresh 2-cycle live capture showing `HEALTHY` held throughout and `STALE` never
fired on healthy behavior. `health` (`HEALTHY`/`STALE`/`DEAD`) remains a field on
`vpn.json` itself, computed in `fetch_vpn.sh` per this table — see the schema block
above.

### Proposed Display

A `PIA` status line, formatted consistently with the existing `SYSTEM PFSENSE` line:

```text
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

```text
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

### Health Classification (WAN Loss)

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

```text
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
earlier. It sits directly under the `WAN` line it corroborates, sharing the
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

```text
WAN: DEGRADED
GATEWAY LOSS 25% | AVG 20ms | ONLINE (link-up)
MODEM: T3x24 (1H) | DS2 SNR 35.8dB | US AVG 39.8dBmV

PIA: HEALTHY
VPN: CONNECTED | REGION: US-TEXAS | PROTO: WG
LATENCY 25ms | HANDSHAKE 0:55 | KS ON
```

**VLAN totals table** gets a `VPN` column appended after `CAM` (see Transfer Data Placement
above) — no new table, same DN/UP row structure as the existing WAN/HOME/IoT/GUEST/INFRA/CAM
columns.

### Execution Model — Resolved (Conky's Own Loop Is Sufficient)

Nothing in the current architecture (this doc, `fetch_pfsense.sh`, `fetch_vpn.sh`) specifies
what actually invokes the fetch scripts on a schedule. `pf-ssh-gate.sh` is portable as a
standalone core utility, which means the fetch scripts *can* run independent of Conky, but
nothing confirms they currently *do*.

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
classification logic repeats the mistake fixed in `fetch_pfsense.sh`'s inline
`gate_status()` duplication (see [pfSense Provider Status](pfsense-provider-status.md)).

**Display:** resolved as a conditional line under `WAN`, shown only during
`DEGRADED`/`CRITICAL` — see "Display Layout — Resolved" above.

### Session Log — Aug 19, 2026 (Build + Live Cross-Check)

- Built `providers/modem/fetch_modem.py` + a thin `providers/modem/fetch_modem.sh` wrapper
  (same split as `fetch_github.sh`/`fetch_github_traffic.py` — the auth/HTML/XML parsing
  here didn't fit the bash+awk TOML-helper style `fetch_pfsense.sh`/`fetch_vpn.sh` use, so
  the Python side owns TOML loading, atomic-write, and the envelope directly, mirroring
  `fetch_github_traffic.py`'s shape rather than reimplementing a bash variant of it).
- Schema shipped exactly as proposed above — `modem_ip`, `upstream_channels[]`,
  `downstream_ofdm_channels[]`, `recent_t3_timeouts`, `event_log_window_minutes`, plus the
  standard envelope. No health classification field, per this doc's own note that the
  SNR/power/uncorrectable thresholds aren't trustworthy yet.
- **Credential storage — decided this session:** password lives in the profile TOML itself
  (`[credentials].password` in `profiles/modem/local.toml`), not a separate env var or
  secrets file — the runtime copy is outside both git repos entirely (same as
  `openweather_api_key` and every other credential in this project), so "commit it" was
  never actually a risk; the real ask was avoiding a second credentials mechanism alongside
  the one every other provider already uses. The committed `local.toml.example` template
  ships `password = "CHANGE_ME"` as a deliberate placeholder (not an empty string) so a
  fresh bootstrap fails loudly (`state=error`, clear note) instead of silently never
  authenticating. `fetch_modem.py` also emits a non-fatal warning note if the runtime
  profile TOML is group/world-readable, recommending `chmod 600` — doesn't block a run.
- **Parsing approach — column headers matched by keyword, not fixed position.** `usTable`
  and `d31dsTable` parsing matches columns by header text (`"lock"`, `"channel id"`,
  `"frequency"`, `"power"`, `"snr"`, `"uncorrectable"`) rather than a hardcoded column
  order. Confirmed correct against the real authenticated page (see cross-check below) —
  the real headers are `Channel | Lock Status | Modulation | Channel ID | Frequency |
  Power` (`usTable`) and `Channel | Lock Status | Modulation / Profile ID | Channel ID |
  Frequency | Power | SNR / MER | Active Subcarrier Number Range | Unerrored Codewords |
  Correctable Codewords | Uncorrectable Codewords` (`d31dsTable`) — several unmapped
  columns on the OFDM table (Modulation/Profile ID, Active Subcarrier Range, Unerrored/
  Correctable Codewords) are correctly ignored rather than misread, which is exactly what
  the keyword-match approach was for. `dsTable`, `d31usTable`, and
  `startup_procedure_table` are documented stable ids but intentionally not parsed — out
  of scope for this session's schema, per the roadmap's own field list.
- **EventLog.asp row detection is tag-name-agnostic.** `parse_event_log()` finds row
  elements by structure (any element carrying a `docsDevEvIndex`/`docsDevEvId` child)
  rather than assuming a tag name. Confirmed live: the real wrapper tag genuinely is
  `<tr>`, exactly as the doc described, so this was defensive rather than
  strictly necessary — left as-is since it costs nothing and survives a firmware change
  that isn't `<tr>`.
- **`recent_t3_timeouts` window filtering — two real bugs found and fixed via the live
  cross-check, not caught by mechanical verification alone:**
  1. The original plan compared `docsDevEvLastTime` against `DocsisStatus.asp`'s
     `#Current_systemtime`, reasoning both were modem-sourced and so self-consistent
     regardless of host/modem clock skew. Live capture showed this was wrong:
     `#Current_systemtime` is populated by **leftover placeholder JS** —
     `DocsisStatus.asp`'s own `InitTagValue()` function returns a hardcoded dummy string
     ending in a literal `"Mon Jun 11 15:30:50 2012"`, dead code never wired to anything
     live on this firmware. `parse_docsis_status()` no longer reads this field at all;
     `fetch_modem.py` now uses local host time (naive `datetime.now()`) as the window
     reference instead, which empirically matches the timezone convention real
     `docsDevEvLastTime` values use (no tz marker, reads as local wall clock — confirmed
     by a live T3 event landing at a plausible ~84-minute age relative to host local time,
     not off by a timezone-sized offset).
  2. The originally-guessed timestamp formats (`MM/DD/YYYY HH:MM:SS` and similar) didn't
     match the real format at all: live data reads `docsDevEvFirstTime`/
     `docsDevEvLastTime` as `"2026-08-18, 08:22:07"` — **comma-space** between date and
     time, `YYYY-MM-DD` order. Every matching row failed to parse on the first live run as
     a result (masked correctly — excluded-with-a-note, not miscounted — but still wrong).
     `TIME_FORMATS` now lists the confirmed real format first; the original guesses are
     kept as fallbacks in case firmware/locale varies it, not because they've been seen.
  - Post-fix, sums `docsDevEvCounts` (not rows) across T3-pattern-matching events, per the
    roadmap's de-duplication warning, filtered to the trailing `event_log_window_minutes`.
    Rows that still fail to parse are excluded from the sum and surfaced via a `note`
    (undercounting-with-a-flag, never silent overcounting).
- **Mechanical verification — done:**
  - `jq .` valid and all envelope fields present (never just omitted) across every state:
    `ok`/`error`/`disabled`/`degraded`.
  - Missing profile toml → `state=error`, clear note.
  - Disabled profile → `state=disabled`.
  - Placeholder password (`CHANGE_ME`) → `state=error`, clear note, no auth attempt made.
  - Cache TTL → back-to-back calls skip correctly (mtime unchanged).
  - Bad password against the real live modem → full login flow exercised for real
    (`GET /GenieLogin.asp`, live `webToken` extraction confirmed working — the real page
    was captured and the token regex matched an unquoted numeric `value=1786514987` exactly
    as the doc described — POST to `/goform/GenieLogin`, cookie-jar check) → correctly
    resolved to `state=degraded` with an accurate note, no crash, ~0.4s.
  - Unreachable host (bogus IP + short timeout) → `state=degraded`, accurate note, no hang
    past the configured timeout.
  - Confirmed live (unauthenticated `GET` of both `DocsisStatus.asp` and `EventLog.asp`):
    an unauthenticated/expired-session request to either protected page returns
    **HTTP 200** with a JS redirect stub (`window.top.location = "/GenieLogin.asp"`) — not
    a 401 or an HTTP-level redirect. This wasn't spelled out in the doc's auth-flow notes
    (which cover login, not what a lapsed session looks like on a subsequent page fetch)
    and would have been missed by a status-code-only check; `is_auth_redirect()` checks
    response body content instead, with one automatic re-login retry before giving up.
- **Live cross-check — done, real credentials, real modem.** The admin password was set
  directly in the runtime `~/.config/gtex62-core/profiles/modem/local.toml` outside the
  assistant's input (never pasted into this conversation), then that file was `chmod 600`.
  A real authenticated fetch was run and its raw `DocsisStatus.asp`/`EventLog.asp` HTML was
  captured and diffed line-by-line against `fetch_modem.py`'s parsed output:
  - `upstream_channels`: 8 rows, 4 locked (channels 17–20, freq/power essentially matching
    the Aug 18 reference read) + 4 correctly-parsed `Not Locked` placeholder rows reading
    `id:0, freq_hz:0, power_dbmv:0.0` — this is genuinely what the modem reports for unused
    channel slots (confirmed from raw HTML), not a parsing bug; matches the roadmap's own
    note that unlocked channels report `0 dBmV` and need excluding from any future
    averaging step.
  - `downstream_ofdm_channels`: 2 rows, values essentially matching the Aug 18 reference
    read (small deltas — 4.1 vs 4.2 dBmV, 35.5 vs 35.8 dB — are real sampling drift between
    polls a day apart, not a parsing error).
  - `recent_t3_timeouts`: the two bugs above were caught and fixed via this exact diffing
    process — first live run showed `0` with a suspicious "all rows unparseable" note;
    after the fix, the same live data parses cleanly and the trailing-window math checks
    out against manual inspection of the raw XML (a currently-recurring T3 event, 40
    repeats, landing at ~84 minutes old — correctly excluded from the default 60-minute
    window, correctly included when tested against a 120-minute window).
  - No structural mismatches remain open; the fixes above are the structural mismatches
    this step was for.
- **Flagged, not fixed, per this session's guardrails:** whether this new HTTP/NAT path
  interacts with the `pf-ssh-gate.sh` circuit breaker. `fetch_modem.py` does not touch
  `pf-ssh-gate.sh` or its state directory at all — no gate, no trip/reset calls, same as
  `vpn`'s local-only design has no gate either. The two are independent as written; the
  open question (noted below, unchanged from before this session) is whether they *should*
  interact — e.g. should sustained modem HTTP failures ever influence pfSense SSH gating,
  given both paths ultimately route through the same pfSense box — not whether the code
  currently does anything surprising, since it doesn't touch that gate at all.
- `gtex62-osa`/`gtex62-tech-hud` stayed read-only throughout, as with prior domains.
- Not committed yet — awaiting confirmation per this project's guardrails.

### Session Log — Aug 31, 2026 (`recent_t3_timeouts` Undercount Fix)

- **Reported symptom:** `recent_t3_timeouts` observed stuck at `0` across three independent
  real-world checks the same day, despite the modem's own Event Log recording genuine T3
  timeout events (`docsDevEvId=82000200`, "No Ranging Response received - T3 time-out")
  well inside the default 60-minute window each time. Original hypothesis going in: an
  `82000200`/text matching gap in `matches_t3()`.
- **Investigated before implementing, per this project's guardrails — hypothesis did not
  survive contact with live data.** A fresh real T3 episode was captured live from the
  modem during this session (two-event burst, 11:21–11:29 CDT) and run through the
  then-current `matches_t3()`/`compute_recent_t3()` unmodified. Result: the existing
  `"no ranging response received"` substring pattern already matched `82000200`'s real
  text correctly, and the window math was also correct (60-minute window correctly
  excluded the episode once it aged past 60 minutes; a 180-minute window correctly summed
  it). So the originally-suspected ID/text matching gap was not actually present in the
  shipped code.
- **Real root cause found instead:** at least one real Event Log row had a valid
  `docsDevEvFirstTime` but `docsDevEvLastTime="Time Not Established"` (the modem's own
  placeholder, most likely for a row still being updated) and a large `docsDevEvCounts`
  (2416). `compute_recent_t3()` had no fallback for this — any matching row with an
  unparseable `docsDevEvLastTime` was dropped outright (`unparsed += 1; continue`),
  regardless of `docsDevEvFirstTime`'s validity or the row's repeat count. This is the
  mechanism that best explains the reported symptom: an in-progress T3 burst — the one
  case where the count matters most — landing on this placeholder and getting silently
  zeroed rather than counted.
- **Adjacent bug found in the same investigation:** the old `T3_PATTERNS` also bare-matched
  `"ucd invalid or channel unusable"` with no "T3" qualifier required. Live data confirmed
  this text belongs to `docsDevEvId=85000200`, a distinct DOCSIS event that occurs adjacent
  to real T3 bursts but is not itself a T3 timeout — this was inflating
  `recent_t3_timeouts`, the opposite direction from the reported symptom, but wrong either
  way.
- **Fix (`providers/modem/fetch_modem.py`):**
  1. `matches_t3()` now matches by DOCSIS event ID first — `T3_EVENT_IDS = {"82000200",
     "82000500"}`, both confirmed live (`82000500`, "Started Unicast Maintenance Ranging -
     No Response received - T3 time-out", was seen once earlier the same day and had since
     aged off the log by the time of this session's live capture) — falling back to a
     `"t3 time-out"` text substring so an undiscovered future ID variant doesn't silently
     repeat this same failure. The old bare `"ucd invalid or channel unusable"` /
     `"no ranging response received"` patterns were dropped; text carrying either phrase
     alongside "T3 time-out" still matches via the substring fallback, so no real coverage
     was lost.
  2. `compute_recent_t3()` now falls back to `docsDevEvFirstTime` when
     `docsDevEvLastTime` is unparseable, before excluding the row. `FirstTime` <= the real
     `LastTime` always, so this can only recover a true positive (a row whose `FirstTime`
     alone lands inside the window is *at least* that recent) — it can't manufacture a
     false include, since a genuinely stale leftover row's `FirstTime` would fall outside
     the window too. A row with both timestamps unparseable is still excluded and still
     surfaced via the existing `note` field.
- **Verified:** live modem capture (real `82000200` rows still match; real `85000200` rows
  no longer counted — window=180 total dropped from 75, which included the non-T3 UCD
  events, to 2, the genuine T3 rows only) plus synthetic regression cases — a row shaped
  exactly like the reported malformed one (valid `FirstTime`, `LastTime="Time Not
  Established"`, `counts=2416`) now correctly contributes `2416`; a row with both
  timestamps genuinely unparseable is still excluded with an accurate note; the
  `82000500` variant still matches via the text-substring fallback.
- **No `modem/status.json` schema change** — same fields, same types throughout. No
  `gtex62-sitrep`-side change required (confirmed against `docs/reading-the-widget.md`'s
  CM1000 column section and `design/sitrep-design-notes.md`'s CM1000/WAN panel section —
  both describe `recent_t3_timeouts`/`event_log_window_minutes` at the field-semantics
  level, which is unchanged).

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
- **Updated (Aug 19, 2026):** Modem provider (`fetch_modem.py` + `fetch_modem.sh`) is built
  and verified, including a live credential cross-check against the real modem — see its
  Session Log above (two real bugs found and fixed there: the `#Current_systemtime`
  reference field turned out to be dead placeholder JS, and the guessed event-timestamp
  format didn't match the real `"YYYY-MM-DD, HH:MM:SS"` format). Still open: committing the
  change.
- Modem provider polling adds a second outbound NAT-translated path through pfSense
  (distinct from the existing SSH-based pfSense provider). Confirmed this session:
  `fetch_modem.py` doesn't touch `pf-ssh-gate.sh` or its state at all, so there's no
  code-level interaction today. Still open: whether there *should* be one — e.g. whether
  sustained modem HTTP failures ought to factor into pfSense SSH gating, given both paths
  route through the same pfSense box — not attempted this session, per guardrails.
- **Resolved (Aug 18, 2026):** PIA VPN policy routing was pulling traffic to
  `192.168.100.1` into the WireGuard tunnel (or the killswitch blackhole) instead of
  reaching pfSense's LAN gateway — found in practice on Titan. Fixed by adding
  `192.168.100.0/24` as a "bypass VPN" IP/subnet rule under PIA's Split Tunnel settings
  (Titan-specific config — see `cable-modem-admin-access.md` for the exact steps). If Pi5
  (the proposed always-on host for `fetch_modem.sh`) runs PIA, it needs the same split-tunnel
  rule added separately — Split Tunnel config is per-device, not account-wide.
