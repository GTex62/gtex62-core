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

## 0.6.0 — 2026-08-28

- **Lyrics-library provider (`providers/media/fetch_lyrics`)** — promotes
  `gtex62-tech-hud`'s `music.lua` lyrics logic (local-check → online-fetch →
  write-through → publish) to a shared core provider. Config is global
  (`site.toml [media.lyrics]`), not per-profile, unlike every other current
  provider. Implements the design doc's Write-Through Safety section:
  create-only writes, per-writer temp files, rename-time re-check, no-replace
  hardlink rename with check-then-rename fallback, empty-payload rejection,
  close-error detection, and orphaned-temp sweep, plus persistent
  cross-invocation fetch/miss throttling. Wired into `gtex62-core-launch` the
  same way as `vpn`/`ap`/`modem`/`alerts` (`core.toml [providers] media`,
  default off in the example template). Verified live against the real
  NAS-backed library and real tracks.
- **`killswitch_mode` added to `vpn.json` (`providers/vpn/fetch_vpn.sh`)** —
  distinguishes PIA's Advanced Kill Switch from the regular VPN Kill Switch,
  which the existing `piavpnFwdrt`-sourced killswitch field can't do since it
  renders identically for both modes while Connected (and `piactl` has no
  killswitch get/set type at all). Read instead from PIA's own
  `/opt/piavpn/etc/settings.json` tri-state string (`off`/`auto`/`on`),
  world-readable — no sudoers rule needed. See
  `docs/network-providers-roadmap.md` § Killswitch Mode Detection — Advanced
  vs. Regular for the full investigation.
- **New SEVERE alert: Advanced Kill Switch blocking traffic
  (`providers/alerts/fetch_alerts.sh`)** — fires "KS BLOCKING TRAFFIC" when
  `vpn.json`'s new `killswitch_mode == "on"` and `connectionstate !=
  "Connected"`, sustained ≥ `advanced_killswitch_duration_sec` (default 10s).
  Same watcher-framework pattern as every other condition (duration-tracked
  `since`/`alerted` `state.json` fields, BREACH/CLEAR logging,
  severity-sorted queue entry); same visible symptom as `gateway-offline`
  but a distinct cause, so it gets its own message rather than blending into
  a Comcast-outage read. Message text measured via real cairo
  `text_extents` against the actual render font and alert-banner column
  width to confirm it fits. Reads `vpn.json` via a new `VPN_PROFILE_ID` arg,
  no new SSH/gate. Live-tested against a real Advanced-mode PIA install: no
  false trigger while Connected, fires at the 10s gate on a real
  disconnect, clears immediately on reconnect.
- Minor housekeeping in this same undocumented window, not independently
  bump-worthy: the pihole example TTL lowered to 60s to match the live
  config change, and doc notes on pfSense-conversion completion.
  (The fast pfSense interface poller that landed alongside the 0.5.0 bump
  is already fully described in the entry below and isn't repeated here.)
- **(2026-08-31) `recent_t3_timeouts` undercount fix
  (`providers/modem/fetch_modem.py`)** — not independently bump-worthy (bugfix,
  no schema change). `recent_t3_timeouts` was observed stuck at `0` across
  three real T3 sync-loss episodes despite genuine events well inside the
  trailing window. Root cause: `compute_recent_t3()` dropped any matching row
  outright when `docsDevEvLastTime` was unparseable (the modem's own "Time
  Not Established" placeholder on a still-updating row) — no fallback, even
  when `docsDevEvFirstTime` was valid. Live cross-check ruled out the
  originally-suspected cause (a `docsDevEvId`/text matching gap for
  `82000200`) — the old text-substring pattern already matched that event's
  real text correctly. Fixed by: (1) `matches_t3()` now matches by DOCSIS
  event ID first (`82000200`, `82000500`, both confirmed live) with a
  `"t3 time-out"` text-substring fallback for undiscovered future variants,
  dropping the old bare `"ucd invalid or channel unusable"` pattern that was
  actually a *different*, non-T3 event (`85000200`) inflating the count; (2)
  `compute_recent_t3()` now falls back to `docsDevEvFirstTime` when
  `docsDevEvLastTime` is unparseable, before excluding the row — safe
  because `FirstTime` <= real `LastTime` always, so it can only recover a
  true positive. Verified against a live modem capture plus synthetic
  regression cases. See `docs/network-providers-roadmap.md` § Modem-Level
  Corroboration Provider, Session Log — Aug 31, 2026.

## 0.5.0 — 2026-08-25

- **Per-VLAN instantaneous traffic rate (`providers/pfsense/fetch_pfsense.sh`)** — closes
  the one open question from `gtex62-osa/design/osa-design-notes.md`'s NET-panel-redesign
  scoping: checked live via SSH whether pfSense tracks per-VLAN sub-interface traffic in
  its own RRD. It does — `/var/db/rrd/{wan,lan,opt1..opt5}-traffic.rrd` exist and are
  live-updating (`opt1`–`opt5` confirmed mapping to `HOME`/`IOT`/`GUEST`/`INFRA`/`CAM` via
  `config.xml`'s `<interfaces>` block) — but per the scoping conclusion this doesn't reopen
  the decision: the instantaneous-diff approach still wins on the recorded tradeoffs (no
  new SSH round-trip, no new gate, no unverified dependency). `status.json`'s
  `interfaces.<VLAN>` objects gain `rate_ibytes_per_sec`/`rate_obytes_per_sec` (bytes, not
  bits — matches the existing `ibytes`/`obytes` naming) and `prev_fetched_at`, computed by
  diffing each cycle's freshly-collected counters against the *previous* `status.json`'s
  values before that file is overwritten — no new SSH call, gate, or cache file. 32-bit-wrap
  guard per direction (`now_bytes >= prev_bytes`, else `null` for that direction only, not a
  garbage negative); both rate fields `null` whenever there's no usable previous sample
  (cold start, or a prior cycle that landed on a degraded/error/disabled stub, which omits
  `interfaces` entirely) — same convention as `wg`/handshake fields elsewhere. Verified
  live: two real poll cycles ~44s apart produced sane, differing rates (hand-checked against
  raw counter deltas); a forced missing-`status.json` cold start produced `null`/`null`/`null`
  for all six VLANs; a forced prior degraded stub (no `interfaces` key) produced the same
  clean null result on the next real cycle; a forged one-direction counter regression
  (simulated wrap) nulled only that direction while the other computed correctly, with
  `prev_fetched_at` still populated. Also folds the already-stale `0.4.0` `gateway.loss_pct`/
  `latency_ms`/`latency_stddev_ms` fields and the `gateway_history.json` domain into
  `docs/pfsense-provider-status.md`'s schema block and Domain Table, which had drifted from
  this changelog. `gtex62-osa` untouched this session — the NET panel build against this
  field is a separate follow-up.
- **`docs/sitrep-relocation-plan.md` archived as superseded** — SitRep was built out as its
  own sibling repo, `gtex62-sitrep`, rather than relocated into `gtex62-core/widgets/` as
  that plan described. Moved to `docs/archive/sitrep-relocation-plan.md` with a superseded
  notice at the top; every cross-reference to it across this changelog and `docs/` updated
  to the new path, and prose asserting something the archival now falsifies (e.g.
  `docs/pfsense-provider-status.md` claiming `lua/suite/pf.lua` doesn't exist yet and the
  relocation is still blocked) corrected in place. Documentation-only, no schema/provider
  change on its own.
- **Fast interface byte-counter poller split out
  (`providers/pfsense/fetch_pfsense_ifaces.sh`)** — new sibling script to
  `fetch_pfsense.sh`, collecting only the 6 VLAN `netstat -I` byte counters
  on an independent ~1s TTL (`ifaces_cache_ttl_sec`) into a new
  `shared/pfsense/{profile}/ifaces.json`, gated independently
  (`runtime/pfsense_ifaces`) so a fast-poll SSH failure can't trip the
  shared `runtime/pfsense` gate that `status.json`'s CPU/MEM/gateway/ARP/
  leases/history depend on, and vice versa. `fetch_pfsense.sh`'s own
  `status.json` interfaces collection is unchanged — still 60s, untouched.
  Rate computation (diff, 32-bit-wrap guard, null-on-cold-start) duplicated
  from `fetch_pfsense.sh` into the new script, diffed against
  `ifaces.json`'s own previous sample. Investigated how
  `gtex62-tech-hud`'s `pf_widget.lua` sustains its own 1s interface poll
  before choosing an approach: no ControlMaster/multiplexing anywhere in
  its scripts or `~/.ssh/config` — a fresh SSH connection every poll.
  Live-measured against the real box: 5 fresh handshakes averaged ~0.12s
  each (vs ~0.01–0.02s with ControlMaster tested the same way); the full
  new script's end-to-end cycle averaged ~0.38s over 5 runs — both
  comfortably inside the 1s budget, so the simpler tech-hud-matching
  approach was kept over adding a persistent control socket. Wired into
  `bin/gtex62-core-launch` and `core.toml` (`[providers.pfsense] ifaces`)
  the same shape as the other pfSense-family flags. Verified live:
  cold-start nulls, a ~2s-later run's rates matching the raw counter delta
  by hand, same-second re-run TTL skip, and gate independence in both
  directions (forced trip on the new gate left `runtime/pfsense`
  untouched and `fetch_pfsense.sh` still returned `state: "ok"`).
  Reviewed before commit; two fixes applied: `fetched_at` changed from
  `int(time.time())` to a float in this script only (cold-start guard's
  `isinstance()` widened to `(int, float)` to match) — at 60s cadence
  integer-second rounding is noise, but at ~1s cadence it could round a
  real ~1.05s gap to a 1s or 2s `delta_t`, up to a ~2x rate error;
  `fetch_pfsense.sh`'s own int copy is deliberately left unchanged, not
  re-synced. And `bin/gtex62-core-launch`'s `refresh_loop` gained a
  name-keyed 0.5s minimum inter-cycle sleep for `pfsense-ifaces-*`
  (its generic 0.05s floor otherwise risked back-to-back SSH attempts
  during a slow-but-succeeding 2-4s stretch) — every other provider's
  0.05s floor is unchanged. `gtex62-osa`'s `M.vlan_bidir_rows()` now reads
  `ifaces.json` instead of `status.json` (that repo's own change, tracked
  independently) — without it the fast poller would have shipped unused.
  See `docs/pfsense-provider-status.md`'s Aug 25, 2026 "Review pass"
  entry for full detail.

## 0.4.0 — 2026-08-24

- **Modem `connectivity_state`/`boot_state` (`providers/modem/fetch_modem.py`)**
  — parses two more rows out of the CM1000's `startup_procedure_table`
  (already-scraped alongside the upstream/downstream channel tables),
  matched by row label (case-insensitive), not position/count — the table
  carries other rows (Acquire Downstream Channel, Configuration File,
  Security, IP Provisioning Mode) that aren't part of this schema and are
  deliberately ignored rather than misread. Both new fields land in
  `status.json` as `{status, comment}` objects, additive alongside the
  existing channel/`recent_t3_timeouts` fields. Verified live against the
  real modem: a fresh run succeeds (`state: "ok"`, no note), both fields
  populate (`status: "OK"`, `comment: "Operational"` for each).
- **Real VPN tunnel latency (`providers/vpn/fetch_vpn.sh`)** — new
  `tunnel_latency_ms` field in `vpn.json`, sourced from a single ICMP echo
  (`ping -I <iface> -c1 -W1 1.1.1.1`) sent through the tunnel interface
  itself, sampled once per the existing 10s `cache_ttl_sec` cycle alongside
  the rest of the payload. No pre-computed source exists for this: `piactl`
  has no latency/ping subcommand, and PIA's own per-region `LatencyTracker`
  is internal daemon RPC state used for its GUI region picker only, not
  reachable via `piactl` or a readable file (confirmed live). Pings a
  public target, not the VPN endpoint IP — confirmed live that PIA excludes
  the endpoint's own IP from the tunnel's routes, so pinging it via `-I`
  would silently take the same physical path as an untunneled ping and just
  re-measure the WAN link instead of the tunnel. `1.1.1.1` matches the
  standing ping targets already used elsewhere in this codebase
  (`fetch_net.sh`, `fetch_connectivity.sh`); no sudo needed (`ping` carries
  `cap_net_raw=ep`). Degrades to `null` with a note on failure, same
  pattern as the existing `wg show` dump block; reuses the profile's
  already-resolved `$IFACE`, no second hardcoded interface name
  introduced. Verified live: a normal sample (~22-24ms across several
  runs), a fake-interface probe, and a real `piactl` disconnect/reconnect
  cycle (confirming `wgpia0` is fully torn down on disconnect, not left
  idle) — all three degrade/recover cleanly.
- **Live dpinger loss%/latency + RRD gateway-loss history
  (`providers/pfsense/fetch_pfsense.sh`)** — two net-new, additive outputs
  piggybacked on the existing pfSense SSH session (same pattern as the
  ARP/DHCP-lease piggyback already there), per this session's live
  investigation of what's actually available on the box for real WAN
  loss%/latency data. (1) Live loss/latency for the GATEWAY panel's
  real-time bar: globs `/var/run/dpinger_WAN_DHCP~*.sock` (survives the
  bound WAN IP changing on DHCP renewal — the literal `~` after
  `WAN_DHCP` can't match `WAN_DHCP6`'s socket, so no separate v6 exclusion
  is needed) and reads dpinger's own rolling 60s average off the socket
  (~2-3ms, confirmed live). Adds `gateway.loss_pct`/`gateway.latency_ms`/
  `gateway.latency_stddev_ms` to `status.json`, additive alongside the
  existing `gateway.online`/`ip` — neither touched nor renamed. (2)
  Duration-window history for the alert banner's future percentage-based
  gateway condition: `rrdtool fetch` against pfSense's own
  `WAN_DHCP-quality.rrd` (already written for its Status > Monitoring
  graphs, not new tooling) at 1-min resolution, default 1200s/20min window
  — margin over the design notes' aspirational "≥25% for >15min" condition
  without hardcoding that 15min figure into collection. Own TTL-gated
  piggyback (default 60s, matching the RRD's native step) writes a
  separate `gateway_history.json`, kept apart from `status.json` since
  it's a window of samples, not a point value. IPv4 (`WAN_DHCP`) only,
  matching the single-WAN-link framing of the design notes' gateway
  condition; `WAN_DHCP6` can be added the same way later if ever needed.
  Both tested live against the real box. Verified no existing consumer
  breaks: no SitRep Lua reads `status.json`'s `gateway{}` object yet (only
  a static placeholder in `pf.lua`'s GATEWAY meter, untouched), and
  `fetch_alerts.sh`'s SEVERE gateway-offline trigger reads only
  `gateway.online`, unaffected — SitRep-side Lua and alert-banner logic
  are untouched, collection only.
- **WAN gateway reachability check now pings public resolvers, not the WAN
  gateway IP (`providers/pfsense/fetch_pfsense.sh`)** — `status.json`'s
  `gateway.online` check was pinging the ISP-side WAN gateway IP directly.
  On this Comcast link that address never answers ICMP as standing ISP
  policy (confirmed: 100% loss across repeated manual pings while actual
  internet access was fully healthy), making it a false-positive-prone
  target regardless of real link health. Now pings `8.8.8.8`/`1.1.1.1`
  instead, same defaults already used by
  `providers/connectivity/fetch_connectivity.sh`, with a fallback target
  so one dropped packet doesn't read as an outage. The WAN gateway IP is
  kept only for the informational `status.json` `ip` field, not as the
  reachability target.
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
  [docs/archive/sitrep-relocation-plan.md](docs/archive/sitrep-relocation-plan.md) § Provider
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
