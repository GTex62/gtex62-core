# Changelog

All notable changes to `gtex62-core` are documented here. Dates are per-entry
(when that piece of work landed), not per-release — several 0.1.0 entries
predate this file and are backfilled from existing docs.

**Scope note:** this file currently covers the network/pfSense-family
provider domains (`pfsense`, `ap`, `vpn`, `modem`) — backfilled from
[docs/network-providers-roadmap.md](docs/network-providers-roadmap.md),
[docs/pfsense-provider-status.md](docs/pfsense-provider-status.md), and
[docs/ap-provider-status.md](docs/ap-provider-status.md). Other engine
providers (weather, solar, astro, aviation, etc.) predate this file and are
not yet backfilled here.

---

## Unreleased

- **Provider enable/disable schema** — `[providers]` / `[providers.pfsense]`
  added to `core.toml` (and `examples/runtime/core.toml.example`): top-level
  `vpn`/`ap`/`modem` flags, nested `status`/`router`/`pihole`/`pfblockerng`
  flags for the pfSense sub-domains. All default `false`; a missing
  `core.toml` behaves identically to all-false. Portability feature — most
  users of this widget won't own all four device classes, and even within
  pfSense, Pi-hole/pfBlockerNG are optional packages some won't have.
  Only `providers.pfsense.status` is actually wired up yet: `bin/gtex62-core-
  launch` now reads it and skips both the `initial_refresh` and
  `refresh_loop` calls for `fetch_pfsense.sh` entirely when `false` — not
  fetched-and-discarded, not invoked at all. `fetch_pfsense.sh` itself is
  unchanged; the gate lives solely at the launcher's call site. The other
  six flags (`vpn`/`ap`/`modem`/`router`/`pihole`/`pfblockerng`) are schema-
  only for now — `fetch_router.sh`, `fetch_pfblockerng.sh`, `fetch_pihole.sh`,
  `fetch_vpn.sh`, `fetch_modem.sh`, and `fetch_ap.sh` are built and verified
  (see their own sessions above) but were never wired into
  `gtex62-core-launch` in the first place, so there's nothing yet for those
  flags to gate — a separate task. See
  [docs/pfsense-provider-status.md](docs/pfsense-provider-status.md) §
  Provider Enable/Disable for detail and
  [docs/sitrep-relocation-plan.md](docs/sitrep-relocation-plan.md) § Provider
  Enable/Disable for the SitRep-side display-state design (four states —
  Disabled/Unconfigured/degraded-states/Healthy — not yet implementable in
  code since `lua/suite/pf.lua` doesn't exist and the relocation is still
  blocked on ARP/DHCP collection).
- **Parser note found during verification:** the shared `parse_toml_section_
  value` awk helper (used by `gtex62-core-launch` and others) does not strip
  trailing `#` comments — `key = false # comment` parses as
  `"false       # comment"`, not a clean `false`. Not a problem for anything
  wired up today (only the comment-free `status` key is read), but worth
  knowing before wiring the `pihole` flag later: the comment noting Pi-hole's
  Pi5 hosting was placed on its own line above `pihole = false` in both
  `core.toml` files specifically to avoid this, rather than trailing the
  line as first drafted.
- **ARP + DHCP lease collection** — `arp.json`/`leases.json` added to
  `providers/pfsense/fetch_pfsense.sh`, piggybacked on its existing SSH
  session and gate (no new session, no new gate) but written on their own
  independent, slower cadence via a new `arp_cache_ttl_sec` TTL (default
  180s) checked before the SSH call — the ARP+DHCP awk commands are only
  appended to the remote command, and the two files only rewritten, when
  due, so an off-cycle round never clobbers still-valid cached entries with
  an empty stub. Raw data only — no `devices.toml` join/classification yet,
  deliberately held for its own session. Found and fixed a real bug during
  live cross-check: pfSense reports unresolved ARP neighbors as
  `? (ip) at (incomplete) on iface expired [ethernet]`, which the original
  `/\(/` filter let through as a garbage row (mac field became the
  interface name); fixed with `$3=="at" && $4!="(incomplete)"`. Verified
  live: 46 clean ARP entries and 18 lease entries, both exact matches
  against raw SSH output; confirmed the three domains already sharing this
  session (`status.json`, `router.json`, `pfblockerng.json`) unaffected.
  See [docs/pfsense-provider-status.md](docs/pfsense-provider-status.md) §
  arp.json / § leases.json.

## 0.2.0 — 2026-08-19

New provider domains: VPN and modem. Minor bump — new functionality, no
breaking changes to existing providers or schemas.

- **VPN provider** — `providers/vpn/fetch_vpn.sh` → `shared/vpn/{profile}/vpn.json`.
  PIA WireGuard, local-only (no SSH target, no gate — `piactl`/`wg` polled
  directly on-host). Fields split by actual source: `piactl` for
  `connectionstate`/`region`/`protocol`/`vpnip`; `wg show <iface> dump` for
  `interface`/handshake/`transfer` (requires a narrowly-scoped passwordless
  sudoers rule, `/etc/sudoers.d/gtex62-core-vpn`, exact-string-matched to one
  command); PIA's policy routing table (`ip route show table piavpnFwdrt`)
  for `killswitch`, independent of both — `piactl get killswitch`/`publicip`
  were tested and confirmed **not supported** despite third-party docs
  claiming otherwise. `killswitch` is only re-derived while `Connected` and
  held at its last-known value otherwise, since a voluntary disconnect
  clears the routing table by design (making an empty table indistinguishable
  from "killswitch off" by inspection alone) — verified live across all four
  states, including both forced-drop scenarios (killswitch on and off).
  `health` (`HEALTHY`/`STALE`/`DEAD`) classified from handshake age against
  the confirmed 25s keepalive interval (60s/180s thresholds, hardcoded and
  verified — not yet scaled by `keepalive_interval_seconds` pending a
  reason to).
- **Modem provider** — `providers/modem/fetch_modem.py` + thin
  `fetch_modem.sh` wrapper → `shared/modem/{profile}/status.json`. First
  HTTP-auth transport in the engine (Netgear CM1000 admin UI, scraped
  through pfSense's NAT-to-VIP path to `192.168.100.1` — not SSH, not a
  local CLI). Schema: `modem_ip`, `upstream_channels[]`,
  `downstream_ofdm_channels[]`, `recent_t3_timeouts`,
  `event_log_window_minutes`. `recent_t3_timeouts` sums `docsDevEvCounts`
  across matching event rows, not a row count — the modem de-duplicates
  repeated identical events into one row with a repeat counter, so counting
  rows undercounts by roughly 10x. No health classification field yet — a
  one-day reference read isn't a long enough baseline to trust SNR/power/
  uncorrectable thresholds against. Credentials live in
  `[credentials].password` in the profile TOML, same place every other
  provider's credentials already live (outside both git repos); the
  committed template ships `password = "CHANGE_ME"` so a fresh bootstrap
  fails loudly instead of silently never authenticating. Live cross-check
  against the real modem caught and fixed two bugs the docs alone couldn't
  surface: `DocsisStatus.asp`'s `#Current_systemtime` field is dead
  placeholder JS (never wired to live data on this firmware), and real
  event timestamps read `"YYYY-MM-DD, HH:MM:SS"` — comma-separated, not any
  of the originally-guessed formats. Does not touch `pf-ssh-gate.sh` or its
  state at all (different transport, different device); whether it should
  is an open question, not resolved this round.

## 0.1.0 — 2026-04-25 through 2026-08-19

Initial engine baseline through the pfSense-family and AP provider domains.

- **pfSense base domain** (2026-05-12) — `providers/pfsense/fetch_pfsense.sh`
  → `shared/pfsense/{profile}/status.json`. VLAN interface counters, CPU%,
  MEM%, and gateway reachability via a single batched SSH session.
  `pf-ssh-gate.sh` circuit breaker shipped alongside it — portable
  (state dir from env vars, no `conky-env.sh` dependency), 5-tier backoff
  (3s → 10s → 30s → 120s → 600s), `GATE_STATE_DIR` override so other
  domains can run independent gates against the same script.
- **Router/system domain** (2026-08-18) — `fetch_router.sh` → `router.json`
  (named to avoid colliding with `providers/system/`'s own `current.json`
  for the *host* machine). Uptime, load, pfSense version, hw model, BIOS.
  Found and fixed a real bug while porting the legacy reference script: its
  boot-time regex greedily matched `usec` instead of `sec` in
  `sysctl -n kern.boottime`, producing ~56 years of garbage uptime. Live
  cross-check matched exactly on every other field.
- **pfBlockerNG domain** (2026-08-18) — `fetch_pfblockerng.sh` →
  `pfblockerng.json`. IP block total, DNSBL hits/pct, resolver query total.
  Gated independently (`runtime/pfblockerng`) despite sharing the `pf` host
  with the base domain — heavier/slower queries must not trip the breaker
  for the faster poll. Live cross-check: exact match, no drift.
- **Pi-hole domain** (2026-08-18) — `fetch_pihole.sh` → `pihole.json`.
  Active state, load, query/blocked totals, distinct domains blocked.
  Separate SSH target (`pi5`, not `pf`) and separate gate
  (`runtime/pihole`) — `pf-ssh-gate.sh` gained its `GATE_STATE_DIR`
  override specifically to support this, backward compatible. Live
  cross-check matched exactly except expected load-average sampling drift.
- **AP provider** (2026-08-19) — `providers/ap/fetch_ap.sh` →
  `ap_status.json` / `ap_clients.json`. Zyxel WBE530 fleet; password auth
  via `sshpass` (permanent hardware constraint — no key-based SSH on this
  hardware), own gate (`runtime/ap`). Collapsed the legacy 3-sessions-per-AP
  poll to one session per AP. Live cross-check against both legacy scripts:
  model/CPU%/client-count and all known-client names matched exactly across
  all 3 APs, including a raw-vs-filtered client-count discrepancy that
  reproduced identically on old and new code (preserved as-is, not a
  porting bug).
