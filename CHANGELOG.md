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

- **Remaining six providers wired into `gtex62-core-launch`** — closes the
  "never wired into the launcher" gap flagged in
  [docs/pfsense-provider-status.md § Provider Enable/Disable](docs/pfsense-provider-status.md#provider-enabledisable):
  `vpn`, `ap`, `modem`, `router`, `pihole`, `pfblockerng` now each get their
  own gated `initial_refresh`/`refresh_loop` call, same shape as the
  `providers.pfsense.status` wiring already in place. Each script itself was
  not touched — this session only added the launcher's call sites (profile
  resolution, cache-TTL read matching each script's own `cache_ttl_sec`
  convention, suite-scoped PID/stamp files, `core.toml`-gated enable check).
  `router`/`pihole`/`pfblockerng` reuse the existing `PFSENSE_PROFILE`/
  `PFSENSE_PROFILE_TOML` vars rather than adding new ones, since those three
  scripts already read `profiles/pfsense/{profile}.toml` same as `status`.
  `vpn`/`ap`/`modem` get their own profile vars (`local`/`main_router`/
  `local`, matching `suites/sitrep.toml [profiles]`). TTL defaults mirror
  each script's own fallback exactly: `router` 60s, `pihole`/`pfblockerng`/
  `modem` 300s, `vpn` 10s, `ap` 120s (with the same profile→`site.toml`
  fallback `fetch_ap.sh` itself uses). `core.toml`'s `[providers]`/
  `[providers.pfsense]` comments updated to drop the now-stale
  "schema-only"/"not yet wired" language for these six flags; `alerts`
  remains schema-only (out of scope — no launcher call site to gate yet).
  The six scripts' own build/verification is not re-litigated here — see
  their original dated entries below (VPN, modem, router, pfBlockerNG,
  Pi-hole, AP) and
  [docs/ap-provider-status.md](docs/ap-provider-status.md) for AP. Verified
  live: restarted the running SitRep launcher, confirmed all six now-wired
  cache files (`vpn.json`, `ap_status.json`/`ap_clients.json`, `status.json`
  under `shared/modem/`, `router.json`, `pihole.json`, `pfblockerng.json`)
  populate with `state: "ok"` on first fetch, then watched `generated_at`
  advance across multiple real cycles at each provider's configured
  interval (10s/60s/120s/300s) without disturbing the already-running
  `pfsense.status` domain or any other suite provider.
- **`alerts` wired into `gtex62-core-launch`** — closes the gap flagged in
  `gtex62-sitrep`'s "Wire header alert-banner column to real banner.json
  data" commit (`banner.json` only advanced on a manual `fetch_alerts.sh`
  run; SitRep's header would drift to `STALE` a couple minutes after). Same
  shape as the six above: its own `ALERTS_PROFILE` (`suites/sitrep.toml`'s
  `profiles.alerts`, default `main_router`, already declared from the prior
  SitRep-side session), a `profiles/alerts/{profile}.toml` `cache_ttl_sec`
  lookup, suite-scoped stamp/PID files, `core.toml`-gated
  `initial_refresh`/`refresh_loop` calls. Two things this domain doesn't
  share with the other six: no `profiles/alerts/*.toml` ships (the lookup
  is real, not skipped, so one just works if added later — but today it
  always falls through to the 60s default), and `fetch_alerts.sh` has no
  `cache_ttl_sec` concept of its own to mirror (it recomputes from scratch
  every invocation — "safe to re-run on any cadence" per its own header
  comment) — 60s was chosen to match the fallback already used on the
  SitRep display side (`pf.lua`'s `header_alert_lines()`, prior session),
  so the two stay in step rather than diverging. `core.toml`'s
  `[providers]` comment (both the tracked `examples/runtime/core.toml.example`
  and the live runtime copy) and `docs/pfsense-provider-status.md` updated
  to drop the "schema-only" language for this flag. `fetch_alerts.sh`
  itself was not touched. Verified: the real `run_locked`/`refresh_loop`
  functions (extracted verbatim from the edited launcher) run against an
  isolated scratch cache tree — `banner.json`'s `generated_at` advanced on
  every cycle at the configured interval, matching the write-stamp exactly
  each time. Not restarted against the live desktop launcher this session
  (that would have killed the running conky window) — the extracted-function
  test exercises the identical `refresh_loop` → `run_locked` →
  `fetch_alerts.sh` → `banner.json` path, just against a throwaway cache
  root instead of the live one.
- **PID-file scoping fix — `NET_LOOP_PID_FILE`/`ORB_LOOP_PID_FILE`
  (`bin/gtex62-core-launch`)** — every other domain's refresh-loop PID file
  is suite-scoped (`${SUITE_ID}-<domain>-refresh.pid`); `net` and `orb` were
  the only two named by profile instead (`net-${NET_PROFILE}-refresh.pid`,
  `orb-${ORB_PROFILE}-refresh.pid`), so two suites sharing a profile id
  (e.g. OSA and SitRep both defaulting to `net=local`/`orb=home`) shared the
  same PID file. Effect: launching the second suite silently killed and
  re-adopted the first suite's already-running net/orb loop via
  `cleanup_pidfile()` at startup, and closing whichever suite currently
  "owned" the file then killed that shared loop on its `EXIT` trap —
  staling out the other suite's net/orb widgets until something relaunched
  to re-adopt it. Fixed by folding `${SUITE_ID}` into both filenames
  (`${SUITE_ID}-net-refresh.pid`, `${SUITE_ID}-orb-refresh.pid`), matching
  every other domain's pattern exactly. The profile-scoped `name` passed
  into `refresh_loop`/`run_locked` (lock dir + stamp file) is unchanged —
  net/orb keep the same cross-suite cache-dedup behavior `pfsense` already
  has when two suites reference the same profile id. Verified live: with
  OSA already running, launched SitRep alongside it — SitRep got its own
  `sitrep-net-refresh.pid`/`sitrep-orb-refresh.pid`, OSA's
  `net-local-refresh.pid`/`orb-home-refresh.pid` and their live loop PIDs
  were untouched throughout, and quitting SitRep left OSA's net/orb loop
  running unaffected.
- **Alert banner watcher (`providers/alerts/fetch_alerts.sh`)** — new
  cross-cutting provider, no SSH/gate of its own: reads `status.json`,
  `pihole.json`, `ap_status.json`, `ap_clients.json` (all
  `shared/pfsense/{profile}/`), applies threshold/duration logic from
  `core.toml`'s new `[alerts]` section, writes a severity-sorted,
  parent/child-grouped queue to `shared/alerts/{profile}/banner.json` plus a
  transition-only text log at `shared/alerts/{profile}/alert_log.txt`. Five
  conditions: gateway offline (SEVERE, duration-gated — a boolean-duration
  proxy for the not-yet-built `network-health` provider's real loss-%),
  Pi-hole inactive (CAUTION, duration-gated), AP MAC/IP mismatch (CAUTION,
  instant, reuses `ap_clients.json`'s `mismatch_total`), unidentified IP
  (CAUTION, instant, summed from `unknown[]`), AP offline (SEVERE, instant,
  per AP). `providers.alerts` added to `[providers]` as schema-only (matches
  `vpn`/`ap`/`modem` — not wired into `gtex62-core-launch`). See
  [docs/sitrep-architecture.md § Alert Banner Watcher](docs/sitrep-architecture.md#alert-banner-watcher)
  for full schema and verification.
- **devices.toml device inventory** — new MAC-keyed device inventory at
  `~/.config/gtex62-core/devices.toml` (co-located with `core.toml`, outside
  both repos same as it). Covers all 5 VLANs (51 devices: 6 User, 25 IoT, 1
  Guest, 9 Infra, 10 Cameras). MAC/IP/VLAN/name/hostname sourced from the
  network design PDF, `display_name` from the legacy `ap_ipmap.csv`. Two
  known-offline WLEDs have no MAC — keyed `"ip:<addr>"` instead, with an
  explicit `mac = ""`. Validated against live `arp.json`/`leases.json`: 38
  of 49 MAC-bearing devices confirmed present with matching IP, 0
  mismatches; 11 documented devices not currently in ARP (flagged
  idle/aged-out, not confirmed offline). See
  [docs/pfsense-provider-status.md](docs/pfsense-provider-status.md) §
  Device Inventory.
- **devices.toml wired into fetch_ap.sh** — `fetch_ap.sh`'s AP-client join
  now keys on MAC against `devices.toml` (all 5 VLANs) instead of IP
  against the core-owned `ap_ipmap.csv` copy, which is now retired but left
  untouched on disk. The Python CSV `load_ipmap()` was replaced with
  `load_devicemap()` (stdlib `tomllib`), joined on `mac.lower()`.
  `ap_clients.json`'s schema and the `0.0.0.0`/`172.29.*` IP pre-filter are
  unchanged — only the lookup key changed. Live cross-check: pre- and
  post-change scripts run back-to-back against the real APs matched
  byte-for-byte on every known client's mac/ip/name across all 3 APs.
- **Bootstrap architecture fix** — `gtex62-core-bootstrap-runtime`
  previously installed `examples/runtime/suites/osa.toml.example`
  unconditionally, even for a core-only run with no suite dir present —
  silently writing an `enabled = true` `suites/osa.toml` pointing at a
  nonexistent path. The `suites/*` template install now skips when
  `SUITE_DIR` is empty or not a real directory. New
  `scripts/bootstrap-runtime-root.sh` — the canonical, directly-runnable
  core-only entrypoint (thin exec into `bin/gtex62-core-bootstrap-runtime`);
  only safe to add once the skip fix landed, since without it a bare
  core-only run would still fabricate the OSA suite entry. Confirmed
  `install_template()`'s existing skip-if-exists logic was already
  safe/idempotent — installing core-only then adding a suite later doesn't
  clobber anything already on disk.
- **README: core-only bootstrap path documented** — the "Bootstrap and
  Launch" section now documents `scripts/bootstrap-runtime-root.sh`
  alongside the existing suite-delegated bootstrap path; previously only
  the latter was documented.
- **devices.toml.example bootstrap template** — the real `devices.toml` is
  excluded from the repo and the template system (same convention as
  `core.toml`/`site.toml`), which meant a fresh clone + bootstrap produced
  no `devices.toml` at all, silently breaking AP client naming and MSMTCH
  detection for anyone not already running this exact setup. New
  `examples/runtime/devices.toml.example` matches the real schema: five
  `[vlan.*]` sections (user/iot/guest/infra/cameras), MAC-keyed devices with
  hostname/name/display_name/ip/mac fields, and the `ip:`-prefixed key
  pattern for no-MAC placeholder entries — populated with sanitized/fake
  placeholder data only. Picked up automatically by `install_template()`'s
  existing skip-if-exists logic. Verified: fresh bootstrap generates a
  `devices.toml` that parses cleanly (5 vlans, 8 placeholder devices);
  bootstrap against a directory with an existing `devices.toml` leaves it
  byte-for-byte unchanged.
- **MSMTCH — AP client MAC/IP mismatch detection** — `fetch_ap.sh` now
  flags AP clients whose MAC is known in `devices.toml` but whose live IP
  doesn't match the documented one. `load_devicemap()` was extended (not
  duplicated) to also return each device's documented IP. `ap_clients.json`
  gains a per-AP `mismatches[]` array (mirrors the existing `unknown[]`
  pattern, holding `{mac, ip, documented_ip, name}`) plus a network-wide
  `mismatch_total`. The two `ip:`-keyed no-MAC placeholder entries are
  skipped, same as the existing join. Verified live against all 3 APs:
  `mismatch_total` is 0 everywhere (current known-good state); confirmed
  the count increments correctly via a simulated mismatch against a
  scratch copy of `devices.toml` (real file untouched throughout). See
  [docs/ap-provider-status.md](docs/ap-provider-status.md) § MSMTCH.

## 0.3.0 — 2026-08-19

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
