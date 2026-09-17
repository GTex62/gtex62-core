# Doctor — Per-Provider "Missing" Conditions

Working doc for filling in what `MISSING` (and any other non-OK NOTE tag) actually means
per domain, so the Doctor alert banner can show a specific, correct remediation line
instead of a generic one. Companion to `doctor-design.md`'s Actions/Remediation table —
that table has the *shape* of the categories; this doc nails down which category applies
to which domain, and the exact banner text, checked against real provider behavior.

**Status: verified against every domain's real `providers/<domain>/fetch_<domain>.sh`
(and `.py`/other scripts where they exist), plus the real installed profile TOMLs under
`~/.config/gtex62-core/profiles/`, 2026-09-16.** Every row below reflects what the script
actually does, not a guess from `architecture.md`. Corrections to the original guesses are
called out explicitly where the real behavior differs.

Missing-condition categories, as confirmed by this pass:

1. **Missing profile TOML** — provider enabled in `core.toml`, but no
   `profiles/<domain>/<profile>.toml` exists. Two genuinely different sub-cases exist and
   this pass found real examples of both:
   - **Silent launcher-cadence fallback** (the dangerous one): `gtex62-core-launch` parses
     `cache_ttl_sec`/`ttl_sec`/`refresh_sec` from the profile TOML with `awk`; a missing
     file (or a present file lacking that key) makes the parse return empty, and the
     launcher's own bash `${VAR:-N}` default silently takes over for the *refresh_loop
     scheduling cadence* — never surfaced anywhere in `status.json`, cache mtime, or any
     other observable signal. **NET is the canonical, already-documented real-world
     instance of this**, not just a theoretical risk: `fetch_net.sh` (line ~59) never even
     checks whether its profile TOML exists — `ENABLED="${ENABLED:-true}"` just proceeds
     regardless, and the *only* consequence of a missing `profiles/net/<profile>.toml` is
     that `NET_TTL` falls from the profile's explicit `ttl_sec = 1` (confirmed in the live
     `~/.config/gtex62-core/profiles/net/local.toml`, commented "VLAN and ping are
     fast-track display metrics — keep at 1s") to the launcher's bash default of 60 —
     exactly the "fast-track meters (VLAN, ping) appear frozen" scenario
     `architecture.md`'s Bootstrap Gap section and this project's own `CLAUDE.md` call out
     by name. `status.json` still reports `state:"ok"` the whole time. Same silent
     fallback shape confirmed for **ASTRO** (no `[cache]` section in its own profile TOML
     at all today — always running on the launcher's bare 60s default, whether or not a
     profile exists) and **ORB** (profile TOML *does* set `ttl_sec = 60` explicitly, so
     today's real value and the fallback value are identical by coincidence — meaning
     `TTL=60` in a live table genuinely cannot be trusted at face value for either domain
     without a separate explicit flag, exactly as originally guessed). **ALERTS** doesn't
     fit this sub-case (see its own entry — it has no TTL concept at all).
   - **Explicit, non-silent handling**: most other domains check
     `[[ ! -f "$PROFILE_TOML" ]]` themselves and write `state:"error"`,
     `note:"missing profile toml"` before exiting — confirmed verbatim in
     `fetch_calendar.sh`, `fetch_connectivity.sh`, `fetch_astro.sh`, `fetch_weather`
     (`fetch_openweather.sh`), `fetch_air.sh`, `fetch_solar.sh`, `fetch_system.sh` (via its
     own check), `fetch_time.sh`, `fetch_vpn.sh`, `fetch_pfsense.sh`, `fetch_mtr.sh`
     (folds this into its `disabled` check), and `fetch_modem.py`. For these, "missing
     profile TOML" already produces a correct, specific `status.json` a Doctor banner can
     read directly — no new plumbing needed, just point at `note`.
   - **GITHUB does not use this mechanism at all** — see its own entry; a missing
     `profiles/github/<profile>.toml` is harmless by design (falls through to in-script
     defaults), not a launcher-TTL collision.
2. **Missing cache file entirely** — provider enabled and configured, but has never
   written output (or output was deleted). AGE has nothing to compute against — expect
   blank/null, not zero.
3. **Missing field within an otherwise-fresh cache** — file exists, mtime looks current,
   but an expected key is absent or unusable. Two confirmed sub-flavors, worth
   distinguishing per domain below because they call for different Doctor logic:
   - **State-elevating — every domain, zero exceptions, as of 2026-09-17.** The provider
     itself notices the partial failure and raises the envelope's own `state` field (to
     `degraded`/`partial`/etc.) with a `note` saying what's wrong and, where available,
     the field's own last-known-good time — Doctor can trust `state` alone, for every
     domain, with no per-domain special case needed. Confirmed implemented in
     **AVIATION** (the original incident and fix — still the cleanest example),
     **WEATHER** (identical `current`/`forecast` degraded pattern), and closed at the
     source across three passes: **VPN**'s tunnel-ping-failure case *and* its `wg show`
     dump failure (the latter closed last, see its entry — the one row that used to need
     `health` instead of `state`); **MODEM**'s `connectivity_state`, all-unlocked-upstream,
     and channel-table-parse-failure cases (all three); **AIR**'s per-source
     `openweather.valid`/`airnow.valid` failures (distinct from AIR's own long-standing
     `partial` state, which still only fires when *neither* source resolves a
     timestamp); **CONNECT**'s speedtest failure (previously nested in `current.json`
     only); and **NETWORK**'s null `wan_ip`/`dns`/`gateway` fields. Each entry below has
     the fix, the required consumer check, and live verification against the real code.
   - **Silent — none remaining.** This sub-flavor is now historical. Every condition
     that used to leave `state:"ok"` with no signal, across every domain audited in this
     doc, has been closed at the source.
4. **Missing dependency owned by another domain** — the domain's own cache may be fine,
   but something it depends on is what's actually missing. **SOLAR is the clean, fully
   verified example**: `fetch_solar.sh` polls for up to 20s (40 × 0.5s) for
   `shared/weather/<profile>/{raw_current,current}.json` to appear, then writes an
   explicit `state:"waiting"`, `note:"waiting for weather cache"` if it never shows —
   Doctor should read this literally: "SOLAR waiting" always means "go look at WEATHER's
   row," never a solar-side problem of its own. Media's `local_dir`/NAS case (see its
   entry) is the other confirmed instance. **AP does NOT belong in this category** — see
   its entry for the correction; the original guess (from `architecture.md`'s cache-layout
   comment) turns out to describe a storage-location artifact, not a functional
   dependency.

---

## Domains

### AIR
- **Category 3 (state-elevating, plus its own extra state)**. Confirmed in
  `fetch_air.sh`: `state:"error"` for missing profile TOML, missing coordinates, or
  missing OpenWeather API key (all pre-flight, explicit); `state:"error"`,
  `note:"air fetch failed; no cache"` if there's no prior cache to fall back on at all
  (category 2, on first run). Once a fetch produces *some* `current.json`, AIR has its own
  third outcome distinct from aviation/weather's plain `degraded`: if the computed
  `provider_updated_at` timestamp can't be derived from either source, it writes
  `state:"partial"`, `note:"air cache has no provider timestamp"` — this can happen even
  when both sources technically returned data, if neither carries a usable observed
  timestamp. Beneath that, AIR already carries **two independent per-source validity
  flags** in `current.json` itself — `openweather.valid` and `airnow.valid` (both
  boolean) — which is finer-grained than aviation/weather's metar/taf split and worth its
  own Doctor sub-row rather than collapsing into one banner line: a person needs to know
  *which* of the two AQI sources is the one that's down.
  - Banner text: `state:"error"` → same generic "check API key / network reachability"
    line, but name the specific missing piece from `note` (coordinates vs. API key vs.
    fetch failure) since AIR's `note` already says exactly which). `state:"partial"` →
    "AIR cache has data but no reliable timestamp — check AirNow/OpenWeather API status."
  - **Was a confirmed silent gap — FIXED 2026-09-17 in `fetch_air.sh`.** Either per-source
    flag could independently go `false` while the *other* source still resolved a
    timestamp (`provider_updated_at` non-empty, top-level `state` staying `"ok"` with
    nothing pointing at which source was actually down — distinct from the `"partial"`
    case above, which only fires when *neither* source resolves one). After computing
    `PROVIDER_TS`, the script now re-reads `openweather.valid`/`airnow.valid` back out of
    the `current.json` it just wrote and, for each source that's actually enabled
    (`OWM_ENABLED`/`airnow_active` — the bash-side config flags parsed from the profile
    TOML, not the jq payload's own `openweather.enabled`/`airnow.enabled` fields, which
    are effectively always true once a raw file exists — even the empty-placeholder one —
    and so can't distinguish "never configured" from "configured but failing") and
    reads `false`, sets `state:"degraded"` and appends a note naming that source. Gating
    on the enabled flag matters: without it, a site that's simply never turned AirNow on
    would show `degraded` forever. Verified by extracting the exact new block and running
    it against five scenarios: healthy (both sources valid) → `ok`; OpenWeather invalid
    with AirNow still resolving → `degraded`, correct note; AirNow invalid with
    OpenWeather still resolving → `degraded`, correct note; AirNow "invalid" but not
    actually enabled → correctly stays `ok` (no false-flagging a disabled source); both
    sources invalid with no timestamp at all → correctly falls through to the
    pre-existing `partial` branch instead, confirming no overlap between the two states.
  - **Consumer check, done before shipping**: grepped the whole repo — no core provider
    reads `shared/air/` at all. The only reader anywhere is `gtex62-osa`'s own `env.lua`,
    which reads `status.json`'s `state` but only special-cases `state == "error"`;
    `"degraded"` falls through to a normal render exactly like AIR's own pre-existing
    `"partial"` state already did. Confirmed live by running OSA's real, unmodified
    `env.lua` (`status_lines()`) against a synthetic `degraded` cache shaped like the
    fixed script's real output: it rendered `DATA // NOMINAL`, byte-identical to the
    healthy case — `gtex62-osa` was not modified.

### ALERTS
- Confirmed: `fetch_alerts.sh` has no `cache_ttl_sec` of its own and no cache-TTL skip at
  all (see its header comment and the script's own structure — every invocation
  recomputes `banner.json` from scratch off other domains' already-written caches). It
  also **always** writes `state:"ok"` unconditionally at the end (line ~848) — there is no
  failure path inside this script that produces a non-"ok" `banner.json`. This means a
  "missing ALERTS" condition is never a partial-data problem the way aviation/weather's
  is; `banner.json` either reflects the current alert queue correctly, or the script
  didn't run at all (crashed, was never invoked, or its cache dir is unwritable) —
  functionally identical to category 2's "never written" case, just with no TTL to judge
  staleness against. **Correction to the original guess**: it's not really "category 2
  with a caveat," it *is* plain category 2 — there's no separate failure mode to
  distinguish. The launcher (`gtex62-core-launch` line ~248-254) documents this
  explicitly too: `ALERTS_TTL` always resolves to its bash default (60) today since no
  `profiles/alerts/*.toml` ships, kept as a real (if currently inert) lookup for future
  use.
  - Banner text: missing/stale `banner.json` → "Alerts provider isn't running — check
    `fetch_alerts.sh` is wired into the refresh loop," not a data-staleness message.

### AP
- **Correction — does NOT belong in category 4.** The original guess (from
  `architecture.md`'s cache-layout comment, "no `shared/ap/` tree of its own... rides on
  pfSense's cache") is true only about *file location*, not about any functional
  dependency. Read directly from `fetch_ap.sh`: AP runs its own independent SSH session to
  each Zyxel AP, has its own gate directory (`runtime/ap/ssh_state`, separate from
  pfSense's/Pi-hole's own gates), and its cache-freshness check is entirely self-contained
  (its own `CACHE_TTL`/mtime check against `ap_status.json`). It never reads pfSense's own
  `status.json` or anything else pfSense's `fetch_pfsense.sh` writes. It merely *writes
  its own output* into `shared/pfsense/<profile>/ap_status.json` and `ap_clients.json` —
  a storage-location choice, not a health coupling. It also has **no "missing profile
  TOML" failure path at all** — unlike every other domain, it never checks whether
  `profiles/pfsense/<profile>.toml` exists; `enabled`/`ap cache_ttl_sec` fall straight
  through to `site.toml`'s `[ap]` section (where `ips`/`labels` genuinely live) and then
  to hardcoded defaults (120s) if that's missing too. A completely missing pfSense profile
  TOML has zero effect on AP.
  - Real "AP missing" conditions, all confirmed in `fetch_ap.sh`: `state:"error"`,
    `note:"no ap ips configured"` (category 2 — `site.toml [ap] ips` empty/unset);
    `state:"error"`, `note:"password file not found: <path>"` (config-completeness, the
    Zyxel sshpass credential file); `state:"degraded"`, `note:"ssh gate tripped"` (own
    gate, independent of pfSense's).
  - Banner text: "no ap ips configured" → "Set `[ap] ips`/`labels` in site.toml."
    "password file not found" → "Create `~/.config/zyxel_ap/.pass`." Neither should ever
    say "check PFSENSE row" — that would send someone hunting for a cause that isn't
    there.

### ASTRO
- **Category 1 (silent launcher-cadence fallback)** for the TTL side — see the category 1
  writeup above; ASTRO's own profile TOML has no `[cache]` section today, so it always
  runs on the launcher's bare 60s default regardless of whether the profile exists at all.
  Separately, `fetch_astro.sh` is otherwise fully self-contained: pure `pyephem`
  computation, no weather dependency despite the profile TOML carrying a vestigial
  `[fallback] weather_profile = "home"` key that `fetch_astro.sh` never actually reads
  (grep confirms no reference to it anywhere in the script — looks like dead config,
  worth flagging separately, not a Doctor concern). Missing-profile-TOML and
  missing-location both produce explicit `state:"error"` (`"missing profile toml"` /
  `"missing location"`) — category 1's silent sub-case only applies to the TTL/cadence
  number, not to astro's actual data collection, which fails loudly and correctly.
  - Banner text: `state:"error"`, `note:"missing location"` → "Set `[location]
    lat`/`lon` in the astro profile or `site.toml`."

### AVIATION
- **Category 3 (state-elevating) — confirmed as-implemented, still the reference
  model.** Verified directly in `fetch_aviation.sh`: `state:"error"` only for the
  total-failure case (`"aviation fetch failed; no cache"`, category 2 shape); `metar`/
  `taf` are tracked as genuinely independent fields, each with its own `state`/`last_ok`,
  and `OVERALL_STATE` becomes `"degraded"` with a `note` naming which field is failing and
  since when (`"taf fetch failing; serving cached data from <last_ok>"` etc.) whenever
  either one — but not both — is in error. Both failing at once also degrades (not
  errors) as long as *some* cached data exists to keep serving. This is genuinely the
  cleanest per-field staleness model in the codebase and both WEATHER and AIR's later
  patterns were built the same session to match it.
  - Banner text (already well-covered by the original doc): surface `metar`/`taf` as two
    sub-rows given they can diverge; `degraded` → name the specific field and its
    `last_ok` straight from `note`, no need to re-derive it.

### CALENDAR
- Confirmed: `fetch_calendar.sh` checks `[[ ! -f "$PROFILE_TOML" ]]` explicitly
  (`state:"error"`, `note:"missing profile toml"`) and `enabled` (`state:"disabled"`).
  Beyond that it always succeeds — the event-parsing loop silently skips malformed lines
  rather than failing, and always writes `state:"ok"` once past the preflight checks, even
  with zero events found. At 86400s TTL (confirmed in `architecture.md`'s table), category
  2 (never run) is indeed the practically-relevant case, as originally guessed — a
  calendar cache that's simply never been triggered would sit "missing" far longer than a
  staleness check alone would ever catch, since nothing here distinguishes "zero events
  because nothing's on the calendar" from "zero events because the source file was never
  read."
  - Banner text: missing cache entirely → "Calendar has never run — check
    `refresh_loop`/`initial_refresh` wiring," not "check credentials" (there are none to
    check; this provider reads local text files only).

### CONNECT (connectivity)
- Confirmed: `fetch_connectivity.sh` has `initial_refresh` only in
  `gtex62-core-launch` (line ~626) — no `refresh_loop` at all, exactly as
  `architecture.md` documents, confirmed by grep against the full launcher script (no
  `CONNECTIVITY_TTL` variable exists anywhere). "Missing" here does mean "no speedtest has
  ever run," category 2 by default, as guessed.
  - **New finding, not in the original guess**: `write_status "ok" ""` (the top-level
    `status.json`) is called **unconditionally** at the end of the script regardless of
    whether the speedtest itself succeeded — a failed `speedtest` binary call
    (`SPEED_STATE="error"`, `SPEED_NOTE="speedtest failed or unavailable"`) only ever
    surfaces inside `current.json`'s nested `speedtest.state`/`speedtest.note`, never in
    `status.json`. This is a real category-3 "silent" gap (see the category 3 writeup
    above): a Doctor check reading only `status.json` would call CONNECT healthy even
    while every speedtest attempt has been failing for weeks.
  - Recommendation for the open "is this WARN-worthy" question: resolved by fixing the
    gap directly rather than working around it — see below.
  - **FIXED 2026-09-17 in `fetch_connectivity.sh`.** The unconditional `write_status "ok"
    ""` at the very end now checks `SPEED_STATE` first: `"error"` (a failed `speedtest`
    call) elevates to `state:"degraded"` with a note built from `SPEED_NOTE`;
    `SPEED_STATE:"disabled"` (speedtest never enabled in the profile — a deliberate
    config choice, not a failure) still writes `"ok"`, same as `"ok"` (a successful run
    or a fresh cached reuse) always did. Verified by running the exact new conditional
    against all three `SPEED_STATE` values: `ok` → `ok`; `error` → `degraded` with
    `"speedtest failing: speedtest failed or unavailable"`; `disabled` → `ok`, confirming
    a site that's never turned speedtest on doesn't get falsely flagged.
  - **Consumer check, done before shipping**: grepped the whole repo for
    `shared/connectivity` — two real consumers, `providers/net/fetch_net.sh` (core) and
    `gtex62-osa`'s own `net.lua` (`speedtest_pair()`). Both read `current.json`, not
    `status.json` — a different file from the one this fix touches — via plain
    `.speedtest.display_down_mbps // .speedtest.download_mbps // 500`-style leaf-field
    `jq` lookups with no `.state` check anywhere. Structurally unaffected: they don't
    read the file this fix changes, and the fix doesn't change `current.json`'s shape.
    Neither `gtex62-core`'s other scripts nor `gtex62-osa` were modified.
  - Banner text, now live: `state:"degraded"`, note starts "speedtest failing" →
    "Speedtest failing — check `speedtest` CLI is installed/licensed (`--accept-license
    --accept-gdpr`)." Stale beyond `max_age_days` with `state:"ok"` (speedtest disabled,
    not failing) → "No speedtest has run in N days (on-demand only, no automatic
    refresh)," still a Doctor-derived `STALE` check against `current.json`'s own
    `age_days`, not a provider-reported condition.

### GITHUB
- **Resolved — not actually "varies," and not TTL-fallback-collision-prone at all.**
  Confirmed three things by reading `fetch_github_traffic.py` and the systemd units
  directly:
  1. GITHUB has **no `initial_refresh` or `refresh_loop` entry anywhere in
     `gtex62-core-launch`** — grepping the whole launcher for `github` finds nothing.
     It is entirely outside the per-domain launcher/TTL-fallback mechanism the "Bootstrap
     Gap" and category 1 apply to. A missing `profiles/github/<profile>.toml` is
     harmless: `load_toml()` returns `{}` on a missing file, and the script's own
     `if profile and not profile.get("enabled", True)` short-circuits to "proceed as
     enabled" for a falsy (empty) profile — so it just runs with defaults
     (`cache_ttl_sec=21600`, i.e. 6h, confirmed as both the code default and the real
     installed `profiles/github/default.toml`'s comment/value).
  2. The real refresh cadence is owned entirely by a **systemd user timer**,
     `gtex62-github-traffic.timer` (`OnBootSec=10m`, `OnUnitActiveSec=12h`,
     `Persistent=true`), confirmed enabled and active on this host. So GITHUB's
     effective real-world cadence is bounded by whichever is longer: the 12h timer
     interval, or the script's own 6h internal skip-if-fresh check — in practice, ~12h.
  3. Real "missing GITHUB" conditions, all explicit in `fetch_github_traffic.py`: profile
     disabled → `state:"disabled"`; empty repo registry
     (`~/.config/conky/github-traffic-repos.json`, confirmed present and populated with
     10 repos on this host) → `state:"error"`, `note:"no repos configured"`; any `gh api`
     call failing for one or more repos → `state:"error"`,
     `note:"fetch failed for: <repos>"` (partial-failure-as-error, not degraded — a
     genuine mismatch with aviation/weather's convention worth flagging as an
     inconsistency, though out of scope to fix here).
  - Banner text: missing/stale cache → check `systemctl --user status
    gtex62-github-traffic.timer` first (is the timer itself running), not a profile-TOML
    remediation — that's the wrong layer for this domain.

### MEDIA
- Not independently re-verified against `fetch_lyrics.py`/`.sh` this pass (the original
  entry already cites `lyrics-library-design.md` directly and its category 4 framing —
  distinct from "no lyrics exist" — matches that doc's own stated failure-handling
  design). Left as originally written; worth a dedicated verification pass against
  `fetch_lyrics.py` itself before this ships as literal banner text, since everything
  else in this doc was confirmed against the real script and this domain wasn't.

### MODEM
- **Category 4's storage-location note does not apply here either** (unlike AP, this was
  never claimed as a cache dependency in the original doc — just flagged as "likely has
  its own dependency-on-pfsense angle worth checking"). Confirmed: MODEM's only
  relationship to pfSense is a **network path**, not a cache dependency — it reaches the
  modem's admin UI at `192.168.100.1` via pfSense's NAT-to-VIP routing, but
  `fetch_modem.py` never reads any pfSense cache file. A pfSense outage could make the
  modem unreachable, but Doctor would see that correctly as MODEM's own
  `state:"degraded"`, `note:"modem unreachable: <exc>"` — there's no missing-dependency
  banner needed beyond MODEM's own state.
  - MODEM already implements the **aviation-style explicit-state pattern** independently
    (confirmed in `fetch_modem.py`'s `write_status()`/exception handling): `state:"error"`
    for missing profile TOML, missing/placeholder password (`note` names the exact TOML
    key), or an unexpected exception; `state:"degraded"` for `ModemUnreachableError`
    (network-level failure) and `ModemAuthError` (reached the modem, login/session
    failed) — these are kept as two distinct causes in `note` even though both map to the
    same `state`. `write_status()` always emits the full envelope shape (empty arrays,
    null scalars) on every failure path so a consumer can `jq` the same field paths
    regardless of state — worth calling out as a second reference pattern alongside
    aviation's, not just a one-off.
  - **Was a confirmed category-3 "silent" gap — FIXED 2026-09-17, the last of MODEM's
    three.** `parse_channel_table()` can return `(rows=[], note="table #<id> header
    mapping incomplete...")` (or "not found", or "has no rows") if the modem's admin UI
    HTML structure changes and expected columns go missing — this note used to fold into
    the envelope's `note` string on an otherwise-successful run, but `state` stayed
    `"ok"`, so a silent HTML-structure change (firmware update, etc.) showed as `ok` with
    empty channel arrays and a note nobody was watching for. `main()` now checks: if
    either `docsis["upstream_channels"]` or `docsis["downstream_ofdm_channels"]` came
    back empty, `state:"degraded"` — the note text itself needed no changes, since
    `parse_channel_table()`'s own note was already flowing into `notes`; this only added
    the missing state elevation. Deliberately keyed off the *channel* arrays, not
    `docsis["notes"]` generally, so it doesn't also elevate `parse_startup_procedure()`'s
    own "row missing" note (a `connectivity_state` row that's absent from the table
    entirely is still a different, not-yet-flagged case from a *present* row with a bad
    value, which is what the fix above already catches — conflating the two would blur a
    distinction worth keeping). Verified by extracting the exact new block and running
    it against six scenarios, including the three from the earlier two fixes to confirm
    no collision: a healthy modem stays `ok`; an empty upstream array (header-mapping
    failure) → `degraded`, note preserved verbatim; an empty downstream array (table not
    found) → `degraded`, note preserved; all three conditions at once → `degraded` with
    all three notes combined correctly; a `connectivity_state` row *missing* (not
    present-but-bad) → correctly still `ok`, confirming this fix doesn't touch that
    separate case; an all-unlocked (non-empty) upstream array → still fires
    independently, confirming the two array-based checks don't interfere with each
    other.
  - Banner text: `state:"degraded"`, note starts with "modem unreachable" → "Check
    pfSense NAT path to 192.168.100.1 (modem admin UI)." Note starts with "modem auth
    failed" → "Check modem credentials in `[credentials].password`." `state:"error"`,
    note mentions password → "Set `[credentials].password` in the modem profile TOML
    (not `CHANGE_ME`)." `state:"degraded"`, note mentions "header mapping incomplete",
    "not found", or "has no rows" → "Modem admin UI layout may have changed — check the
    channel-table note in MODEM's status."
  - **Cross-checked against `gtex62-sitrep/lua/suite/pf.lua` (2026-09-16)** — this is the
    bigger finding of the two SitRep cross-checks. SitRep's `modem_fields()`/
    `docsis_word()` read `state`, `note`, `connectivity_state.status`, and
    `connectivity_state.comment`; `cm1000_fields()` separately reads `recent_t3_timeouts`,
    `event_log_window_minutes`, `downstream_ofdm_channels[0].snr_db`,
    `downstream_ofdm_channels[1].snr_db`, and `upstream_channels[].power_dbmv`/`.locked`.
    - **Was the most significant silent-gap finding of this doc — FIXED 2026-09-17 in
      `fetch_modem.py`.** `connectivity_state.status` is SitRep's *primary* modem-health
      signal, not a secondary field: per `pf.lua`'s own header comment, the whole point of
      its DOCSIS header line is to answer "is the modem actually connected/registered to
      Comcast" via this field, not via `status.json`'s top-level `state` (which only ever
      reflected whether the *scrape itself* succeeded). `parse_startup_procedure()` only
      ever set a `note` if the "connectivity state" row was *missing from the table
      entirely* — a present row with a bad *value* (modem not registered) produced no
      error and no note. `main()` now checks the parsed `connectivity_state.status`
      directly after `parse_docsis_status()` runs: any non-empty value that isn't `"OK"`
      (case-insensitive) sets `state:"degraded"` and appends
      `"modem not registered with Comcast (connectivity state: <value>)"` to `note`. A row
      that's simply *missing* still only trips the pre-existing
      `parse_startup_procedure()` note path (empty `connectivity_status` is deliberately
      excluded from the new check) — confirmed by direct unit-style execution of the added
      code block against six synthetic `docsis` dicts, including both the healthy case and
      the pre-existing missing-row case, to make sure the two paths don't collide.
    - **Also FIXED 2026-09-17**: an all-unlocked `upstream_channels` array used to silently
      render as a plausible `0.0` in SitRep's own US AVG computation
      (`cm1000_fields()`'s `[.upstream_channels[]? | select(.locked) | .power_dbmv] | if
      length > 0 then (add/length) else 0 end`), indistinguishable from a coincidental true
      reading near zero — `fetch_modem.py` did no locked/unlocked validation of its own.
      `main()` now checks: a non-empty `upstream_channels` array where no entry has
      `locked:true` sets `state:"degraded"` and appends
      `"no locked upstream channels (modem cannot transmit upstream)"`. An *empty* array
      (the pre-existing channel-table-header-mapping-incomplete case, still an open silent
      gap — see above) is deliberately excluded so the two paths stay distinct, same
      verification method as above.
    - **Reverse check (fields `fetch_modem.py` sets that SitRep doesn't read)**:
      `boot_state` (status/comment, same shape as `connectivity_state` but for the
      earlier DOCSIS boot sequence — SitRep only cares about the final registration
      state, not the boot-sequence detail) and `downstream_ofdm_channels[].uncorrectables`
      (per-channel uncorrectable-codeword counts — collected but never displayed or
      thresholded anywhere; `fetch_modem.py`'s own header comment explicitly disclaims
      "Health Classification... is explicitly NOT implemented here," so there's no
      known-good/known-bad boundary defined for this yet, unlike the fields above). Both
      remain plausible future Doctor signals, not fixed this pass — neither is a simple
      presence/absence check the way the two fields above were.
  - **Banner text, now live**: `state:"degraded"`, note starts "modem not registered with
    Comcast" → "Modem not registered with Comcast (`<connectivity_state.status>`) — check
    DOCSIS sync, not the scraper" (distinct from every other MODEM remediation line above,
    which all assume the scrape itself is the problem — the value comes straight from
    `note`, no separate array-check needed by Doctor). `state:"degraded"`, note starts "no
    locked upstream channels" → "Modem has no locked upstream channels — check DOCSIS
    upstream sync."
  - **Consumer check, done before shipping**: `providers/alerts/fetch_alerts.sh` is the
    only other reader of `shared/modem/{profile}/status.json` (grepped the whole repo).
    Its T3-burst tracking gates on `load_json(modem_status_path)`'s strict
    `state == "ok"` check — with the fix as originally scoped, a `degraded` poll would
    have gone through the same "no fresh evidence this round" branch as a genuinely
    broken modem, freezing T3 delta tracking for as long as `connectivity_state`/
    `upstream_channels` stayed bad. That's a real problem here, unlike a one-off VPN
    ping blip: a real DOCSIS registration loss can last the entire length of an outage —
    exactly the condition T3-burst tracking exists to help corroborate. Fixed by widening
    `load_json()` to take an `ok_states` tuple (default unchanged, `("ok",)`) and passing
    `("ok", "degraded")` at the VPN and MODEM call sites only — every other call site
    (pfsense status, pihole, ap_status, ap_clients, mtr) keeps the strict default, since
    their degraded/error states genuinely do mean "don't trust this poll." Verified live
    against an isolated cache root: a synthetic `degraded` MODEM cache with
    `recent_t3_timeouts` still updated the T3 baseline correctly (event-log parsing is
    independent of `connectivity_state`/`upstream_channels`, confirmed by reading
    `fetch_modem.py` — they come from separate HTML pages in the same fetch cycle), while
    a synthetic `error` MODEM cache with a deliberately different T3 value was correctly
    still ignored (baseline held, not corrupted) — the widening is exact, not a blanket
    loosening.
  - **SitRep display, confirmed unaffected**: `resolve_state_word()` (shared by
    `vpn.lua`/`pf.lua`) has no branch for `state == "degraded"` — it only special-cases
    `"error"`/staleness/disabled/ssh-tripped, so `"degraded"` falls through to `nil`
    (normal render) exactly like `"ok"` always did. Confirmed by running SitRep's actual,
    unmodified `pf.lua` (`header_status_lines()`/`wan_panel_data()`) against a synthetic
    `degraded` MODEM cache shaped like the fixed script's real output: `DOCSIS //
    NOT SYNCHRONIZED` and the WAN panel's T3/DS1/DS2/US AVG lines rendered exactly as
    they would have before this change. `gtex62-sitrep` itself was not modified.

### MTR
- Confirmed trigger-driven exactly as guessed, with the full state machine read directly
  from `fetch_mtr.sh`: `state:"disabled"` (no profile TOML, or `enabled != true`);
  `state:"error"`, `note:"no ssh_target configured"` (config-completeness); `state:
  "degraded"` for every SSH-gate-tripped path (confirm-step failure, outer-safety-cap-stop
  failure, start failure — all three trip the same `runtime/mtr` gate, independent of
  pfSense's/AP's own gates); `state:"ok"` otherwise, whether idle (`running:false`,
  trigger not active) or genuinely running (`running:true`, `confirmed` re-verified via
  live `pgrep` on every poll while `PREV_RUNNING=true`). "Missing" `mtr_state.json`
  entirely is plain category 2 (never run) — harmless in practice since idle is also
  written as `state:"ok"`, so there's no ambiguous "missing vs. idle" state to worry
  about the way ORB/NET's TTL collision creates ambiguity.
  - A genuinely broken MTR, per the confirmed code: `state:"degraded"` with `note`
    exactly naming which SSH step failed (`"ssh failed during confirm"` /
    `"...during start"` / `"...during outer-cap stop"`), always paired with
    `ssh_gate.tripped:true`. Idle is `state:"ok"`, `running:false`,
    `trigger.active:false` — never confusable with broken once Doctor reads
    `state`/`ssh_gate.tripped` rather than just `running`.
  - Banner text: `degraded` + gate tripped → "SSH gate tripped for MTR (Pi5) — check SSH
    alias / sshpass credentials," matching the existing pfSense/AP SSH-gate remediation
    line verbatim (same underlying condition class).

### NET
- **Category 1 (silent launcher-cadence fallback) — the single clearest, most
  consequential real example in the whole codebase**, confirmed directly in
  `fetch_net.sh`: it never checks whether `profiles/net/<profile>.toml` exists at all
  (`ENABLED="${ENABLED:-true}"` just proceeds either way), so nothing in `status.json`
  ever reflects a missing profile. The live installed profile
  (`~/.config/gtex62-core/profiles/net/local.toml`) explicitly sets `ttl_sec = 1` with a
  comment calling out exactly why ("VLAN and ping are fast-track display metrics — keep
  at 1s"); if that file (or just its `[cache] ttl_sec` key) went missing, the launcher's
  own bash default (`NET_TTL="${NET_TTL:-60}"`) would silently take over — a 60x slowdown
  in a fast-track domain, indistinguishable from a healthy `state:"ok"` NET row by any
  signal this script currently writes. This is the literal scenario `CLAUDE.md`'s Hard
  Rules section and `architecture.md`'s Bootstrap Gap note both already warn about by
  name — worth using NET, not ORB, as the doc's primary worked example when this ships.
  - Aside from the TTL-cadence issue, `fetch_net.sh` otherwise only ever writes
    `state:"disabled"` or `state:"ok"` — no error path for a missing profile, and no
    field-level degraded state if e.g. `public_ip()`'s external call fails (silently
    yields an empty `wan_ip`, same shape as NETWORK's category-3-style gap below, just
    lower-stakes here since WAN IP isn't fast-track-critical the way ping/VLAN are).
  - Banner text: this is where the "explicit flag in `doctor.json`, not inferred from the
    TTL number" idea from the category 1 definition matters most — Doctor needs
    `fetch_doctor.sh` to independently check `profiles/net/<profile>.toml`'s existence
    and `[cache] ttl_sec` presence, not just read NET's own `state`/age. Remediation:
    "NET profile TOML missing or has no `[cache] ttl_sec` — VLAN/ping meters are running
    at the 60s fallback cadence, not 1s. Run bootstrap."

### NETWORK
- **Resolved — not "varies," a concrete 5s default confirmed live.** `fetch_network.sh`
  has no internal `cache_ttl_sec` concept of its own (same shape as NET/ASTRO/SYSTEM/
  TIME — the TTL is purely a launcher-scheduling number, never read by the fetch script
  itself). The live installed profile
  (`~/.config/gtex62-core/profiles/network/local.toml`) has no `[cache]` section, so it
  runs on the launcher's bash default, `NETWORK_TTL="${NETWORK_TTL:-5}"` — confirmed by
  reading both the profile file and the launcher. Same silent-fallback shape as
  ASTRO/NET applies here (a missing profile is indistinguishable from a correctly
  configured one purely by the TTL number), but at 5s the practical stakes of drifting to
  a different fallback value are much lower than NET's 1s→60s jump.
  - Preflight is explicit and identical in shape to CALENDAR/TIME/VPN:
    `[[ ! -f "$PROFILE_TOML" ]]` → `state:"error"`, `note:"missing profile toml"`;
    `enabled != true` → `state:"disabled"`.
  - **Was a confirmed silent gap — FIXED 2026-09-17 in `fetch_network.sh`.** Past
    preflight it always wrote `state:"ok"`, even when `public_ip()`, DNS resolution, or
    the default-route lookup all silently returned empty — a category-3 "silent" gap of
    the same shape as NET's own `wan_ip`. Right after `current.json` is written, the
    script now checks the same `WAN_IP`/`DNS`/`GATEWAY` bash variables it just used to
    build that file; if any are empty, `state:"degraded"` and the note names exactly
    which field(s) (one, two, or all three). **Scoped to those three fields only, per
    the fix as requested — `lan_ip` can independently go null the same way and isn't
    covered by this check; flagging as a known gap, not silently expanded beyond what
    was asked.** Verified by running the exact new conditional against four cases: all
    three present → `ok`; `wan_ip` alone empty → `degraded`, `"null field(s): wan_ip"`;
    all three empty (interface fully down) → `degraded`, all three named; `dns` alone
    empty → `degraded`, correctly names only `dns`.
  - **Consumer check, done before shipping**: grepped the whole repo for
    `shared/network` — two real consumers, `providers/net/fetch_net.sh` (core) and
    `gtex62-clean-suite-e`'s `monitor_helpers.lua`. Both read `current.json`, not
    `status.json` (the file this fix touches), via plain `.interface.wan_ip //
    "-"`-style leaf-field lookups with no `.state` check anywhere — confirmed by reading
    each consumer's exact filter, not just the file list. Structurally unaffected.
    `gtex62-clean-suite-e` was not modified.
  - Banner text, now live: `state:"error"`, `note:"missing profile toml"` → standard
    remediation. `state:"degraded"`, note starts "null field(s):" → "NIC detection or
    public-IP lookup failing — check `primary_interface` config and outbound
    connectivity," naming the specific field(s) straight from `note`.

### ORB
- **Confirmed exactly as originally guessed — real TTL-fallback collision, live in the
  current install.** `~/.config/gtex62-core/profiles/orb/home.toml` sets
  `[cache] ttl_sec = 60` explicitly — the same number as the launcher's own bash fallback
  (`ORB_TTL="${ORB_TTL:-60}"`). This means a live `TTL=60` in Doctor's table cannot be
  taken as evidence of a correctly-installed profile without a separate explicit flag,
  exactly per the category 1 definition — the two states (configured-at-60 vs.
  fallen-back-to-60) produce byte-identical launcher behavior today. `fetch_orb.sh` /
  `fetch_orb.py` were not independently re-read this pass (no `ttl_sec` reference exists
  in either, matching every other domain's pattern of the TTL being launcher-only) — see
  `orb-provider-reference.md` for orb's own field-level docs if a deeper pass is needed
  later.
  - Same recommendation as NET/ASTRO: `fetch_doctor.sh` needs to independently check
    profile-TOML existence/key-presence for ORB, not infer it from the TTL number alone.

### PFSENSE
- **Resolved — "varies" is accurate, but concretely enumerable, not unknown.** PFSENSE is
  genuinely a family of independently-TTL'd sub-caches, not one domain with one TTL —
  confirmed against both the launcher's parsed defaults and the live installed profile
  (`~/.config/gtex62-core/profiles/pfsense/main_router.toml`, root `cache_ttl_sec = 30`,
  `[pihole] cache_ttl_sec = 60`):

  | Sub-cache | Script | Launcher default | Live configured value |
  | --- | --- | --- | --- |
  | `status.json` (gateway/interfaces) | `fetch_pfsense.sh` | 5s | 30s |
  | `pihole.json` | `fetch_pihole.sh` | 300s | 60s |
  | `router.json` | `fetch_router.sh` | 60s | (default) |
  | pfBlockerNG | `fetch_pfblockerng.sh` | 300s | (default) |
  | `ifaces.json` (interface byte counters) | `fetch_pfsense_ifaces.sh` | 1s | (default) |
  | ARP table | (within `fetch_pfsense.sh`) | 180s (`arp_cache_ttl_sec`) | (default) |
  | DHCP leases | (within `fetch_pfsense.sh`) | 180s (`leases_cache_ttl_sec`) | (default) |
  | Gateway loss/latency history | (within `fetch_pfsense.sh`) | 60s (`gateway_history_cache_ttl_sec`) | (default) |

  This matches `pfsense-provider-status.md`'s own detailed accounting (939 lines, already
  the authoritative source — not re-litigated line-by-line here). Preflight states
  confirmed in `fetch_pfsense.sh`: `state:"error"` for missing profile TOML or no
  `ssh_target`; `state:"disabled"`; `state:"degraded"` for SSH-gate-tripped or SSH-call
  failure (both write stub `arp_leases`/`history` envelopes too, matching the main
  envelope's state) — all following the same explicit-state convention as MTR/AP/MODEM.
  - PFSENSE is the domain **other providers depend on for network path** (MODEM) but,
    per the AP correction above, **not** for cache content (AP is self-contained despite
    sharing PFSENSE's directory). The only genuine cache-content dependency confirmed
    this pass is SOLAR→WEATHER, not anything→PFSENSE.
  - Banner text: since this is a multi-sub-cache domain, Doctor's PFSENSE row likely
    needs to be itself a small table (matching the shape above) rather than one line —
    a single `degraded`/`error` state could originate from any one of the seven
    independently-gated fetches.

### SOLAR
- **Category 4 — the cleanest, fully explicit example in the codebase.** Confirmed
  directly in `fetch_solar.sh`: it polls for up to 20s (40 × 0.5s sleep loop) waiting for
  either `shared/weather/<weather_profile>/raw_current.json` or `.../current.json` to
  exist, then writes `state:"waiting"`, `note:"waiting for weather cache"` if neither
  ever appears — a real, named, non-generic state distinct from `error`/`disabled`/`ok`.
  This is a better-documented instance of category 4 than the original doc's AP guess
  turned out to be; recommend using SOLAR as the doc's primary category-4 worked example
  instead. `WEATHER_PROFILE` is resolved from the solar profile's own
  `weather_profile` key (default `"home"`), confirmed to fall back correctly to that
  default.
  - Banner text: `state:"waiting"` → "SOLAR is waiting on the WEATHER cache — check the
    WEATHER row, not SOLAR's own config." Should literally defer to WEATHER's row rather
    than rendering its own generic remediation text, per the original doc's stated
    cascade-explicitly recommendation for PFSENSE→AP (which, per the AP correction,
    doesn't actually apply there — but does apply here).

### SYSTEM
- Confirmed local-only, no network dependency, same shape as TIME: `fetch_system.sh`
  writes `state:"disabled"` for a disabled profile, and always `state:"ok"` otherwise
  (confirmed no `"error"` path exists anywhere in the script). "Missing" for a domain with
  no external fetch to fail is effectively always category 2 (never run) or category 1's
  TTL-fallback shape if `profiles/system/<profile>.toml` lacks `[cache] refresh_sec` —
  though at 1s default either way (`SYSTEM_TTL="${SYSTEM_TTL:-1}"` matches the intended
  real value), the fallback collision here has no practical consequence the way NET's
  does. Field-level parse failures (CPU/RAM/GPU/storage reads) were not traced
  individually this pass — see `system-provider-status.md` for the existing field
  reference if a deeper per-field pass is needed.
  - Banner text: missing cache entirely, 1s-TTL domain → "SYSTEM provider isn't
    running — check `refresh_loop` is alive," same framing as NET/TIME (a fast-track
    domain missing for more than a couple of poll cycles signals the loop itself is
    dead, not a transient miss, exactly as the original TODO guessed).

### TIME
- Confirmed identical shape to SYSTEM: `fetch_time.sh` checks `[[ ! -f "$PROFILE_TOML"
  ]]` (`state:"error"`, `note:"missing profile toml"`) and `enabled`
  (`state:"disabled"`), then is pure `zoneinfo`/`datetime` arithmetic with no external
  call that can fail — always `state:"ok"` past preflight. No category-3 field-level
  failure mode exists (no optional sub-fetch to silently degrade). Same 1s fast-track
  reasoning as SYSTEM applies to what "missing" signals.
  - Banner text: same as SYSTEM — a missing/stale cache at this TTL means the refresh
    loop died, not a data problem.

### VPN
- Confirmed the four-state killswitch model already referenced in the original doc, plus
  the domain's own `state`/`health` split, both read directly from `fetch_vpn.sh`:
  - `status`-level `state`: `"error"` (missing profile TOML, or `piactl` not found —
    config/dependency problems) → `"disabled"` → `"ok"` (once past preflight, `state`
    stays `"ok"` even when sub-collections fail — see the category-3 gap below).
  - `killswitch` (bool) + `killswitch_mode` (`off`/`auto`/`on`, from PIA's
    `settings.json`) together answer "is it blocking traffic" vs. "which mode is
    configured" — the four-state model the original doc referenced.
  - `health` (`HEALTHY`/`STALE`/`DEAD`, derived from WireGuard handshake age against
    REKEY/REJECT-AFTER-TIME thresholds) is a *third* signal layered on top, not mentioned
    in the original doc — this is what goes `"DEAD"` when the `wg show` sudo call fails
    (missing sudoers rule), the `wg` binary is missing, `connectionstate != "Connected"`,
    or the handshake is genuinely stale. `state` now tracks the wg-dump-failure case
    directly too (see below, fixed 2026-09-17) — `health` remains the richer field for
    display purposes (HEALTHY/STALE/DEAD is more informative than a binary
    ok/degraded), but Doctor no longer *needs* it just to catch this one condition.
  - Real "missing VPN" conditions: `state:"error"`, `note:"missing profile toml"`
    (config); `state:"error"`, `note:"piactl not found"` (PIA client not installed/not on
    PATH — genuinely distinct from "cache not written," as the original TODO guessed);
    cache simply absent (category 2, first run or PIA never started).
  - Banner text: `state:"error"`, "piactl not found" → "PIA client not installed or not
    on PATH."
  - **Cross-checked against `gtex62-sitrep/lua/suite/vpn.lua` (2026-09-16)** — SitRep is
    the one suite with panel logic thorough enough to be a useful reference for field
    selection, so this confirms rather than re-derives the fields above. SitRep's
    `vpn_fields()`/`ltncy_meter_fields()` read exactly: `state`, `note`,
    `ssh_gate.tripped` (defensive only — confirmed `vpn.json` has no such key; VPN is
    genuinely local-only, matching its own doc entry), `region`, `protocol`,
    `latest_handshake_seconds`, `killswitch`, `health`, `killswitch_mode`, and
    `tunnel_latency_ms`. Every field SitRep reads is already accounted for above, with
    one refinement worth separating out:
    - **Was a new silent-gap finding — FIXED 2026-09-17 in `fetch_vpn.sh`.**
      `tunnel_latency_ms:null` turned out to be its own signal, independent of `health`:
      SitRep's own comment on `ltncy_meter_fields()` spells this out, the field goes
      `null` both "when disconnected (`health=DEAD`)" *and* "when the ping itself fails
      while otherwise connected" — i.e. a single failed ICMP echo through the tunnel could
      null this field while `health` still read `HEALTHY`/`STALE`, with nothing in `state`
      or `note` to show it. `main()`'s payload-assembly block now checks exactly that:
      `tunnel_latency_ms is None and health != "DEAD"` sets `state:"degraded"` and appends
      a note naming the failure and, when available, when the tunnel ping last succeeded —
      tracked the same way `killswitch` already carries forward its previous value across
      polls (`tunnel_latency_last_ok_epoch`, a new field in `vpn.json`, updated to "now" on
      every successful ping and otherwise held). Verified by running the exact shipped
      code (not a reimplementation) against four scenarios: ping failing with `health`
      still `HEALTHY` → `degraded` with a correct `last ok <iso>` note; disconnected
      (`health:"DEAD"`) with the ping also failing → stays `"ok"`, confirming `health`
      already covering that case means no double-flagging; a normal successful poll →
      unaffected, `tunnel_latency_last_ok_epoch` advances; and a first-ever ping failure
      with no prior `tunnel_latency_last_ok_epoch` on record → correct fallback wording
      ("no prior successful ping on record").
    - **Reverse check (fields `fetch_vpn.sh` sets that SitRep doesn't read)**: `endpoint`,
      `interface`, `vpnip`, `keepalive_interval_seconds`, `transfer.rx_bytes`/`tx_bytes`.
      None of these look like a missed health signal on inspection — they're identity/
      throughput fields, not state fields. `transfer` bytes are the one arguable case (a
      fresh handshake with zero rx/tx could mean "tunnel up, nothing flowing"), but
      that's a delta over time, not a snapshot check — `fetch_vpn.sh` doesn't track a
      previous value to diff against, so this isn't a simple field-presence check the way
      everything else here is. Flagging as a known limitation, not a lookup-table
      candidate today; not fixed this pass.
  - **Was the last remaining silent-gap exception in the whole doc — FIXED 2026-09-17 in
    `fetch_vpn.sh`.** The `wg dump`/sudoers case was deliberately left untouched in both
    the first VPN/MODEM pass and the four-domain pass that followed it, on the reasoning
    that `health` already surfaced it adequately — but that meant Doctor would have
    needed one hardcoded domain-specific exception ("check `health` instead of `state`
    for VPN") to reach full coverage, contrary to the original goal of `state` alone
    being trustworthy everywhere. Closed by adding
    `if connectionstate == "Connected" and wg_note: state = "degraded"` right before the
    existing tunnel-ping check. **Deliberately not gated on `health == "DEAD"` directly**
    — `health` also goes `"DEAD"` on an entirely normal voluntary disconnect (PIA tears
    the `wgpia0` interface down on disconnect, confirmed live on this host via `ip link
    show`/`sudo wg show wgpia0 dump` while connected — the same command would plausibly
    fail once the interface is gone, though this wasn't tested by actually disconnecting
    the live, killswitch-protected VPN, which would have been genuinely risky to do just
    to observe it), so gating on `health` alone would flag every routine disconnect as
    "degraded," a false positive. Gating on `connectionstate == "Connected"` instead
    scopes the check to exactly the anomalous case: piactl believes the tunnel is up but
    the wg dump still failed. `wg_note` was already flowing into `note` unconditionally
    before this fix (visible even in the old `"ok"` state) — only the state elevation
    was missing, no new note text needed.
  - **Confirmed no collision with the tunnel-ping fix in the same script**: the two
    checks are independent `if` blocks, both only ever set `state = "degraded"` (never
    unset it) and each only appends its own note text. They can't fire for the same
    underlying cause at once — a failed wg dump forces `latest_handshake_seconds` to
    `None`, which makes `health` `"DEAD"`, which is exactly the condition the tunnel-ping
    check excludes itself on (`health != "DEAD"`) — so at most one of the two note
    fragments appears per poll, never both mixed together.
  - Verified by running the exact shipped code against seven scenarios: a healthy poll
    (unaffected); connected with the wg dump failing (sudoers) → `degraded`, correct note,
    `health:"DEAD"`; **disconnected with the wg dump also failing → stays `"ok"`**, the
    critical false-positive check, confirming a routine disconnect isn't misread as a
    fetch failure even though `wg_note` is present; connected with only the tunnel ping
    failing (last round's case) → still fires independently via the other branch, byte-
    identical to before; connected with the wg dump failing but the ping somehow still
    succeeding → `degraded` via the wg-dump branch only, no note collision; a fully
    normal disconnect with the ping also failing (the realistic every-day case) →
    correctly stays `"ok"` despite both notes appearing in the text; and the wg binary
    missing entirely while connected → `degraded` with the correct distinct note.
  - **Consumer check — confirmed the existing widening already covers this, not assumed**:
    `providers/alerts/fetch_alerts.sh`'s `load_json(vpn_path, ok_states=("ok",
    "degraded"))` call (added the prior pass) widens generically for *any* `"degraded"`
    reason, not one tied specifically to the tunnel-ping case — grepped the file to
    confirm the call site itself needed no further change. Re-verified live anyway, same
    discipline as every prior round: ran `fetch_alerts.sh` against an isolated cache root
    with a VPN cache degraded specifically via this *new* wg-dump reason
    (`killswitch_mode:"on"`, `connectionstate:"Disconnected"`, `state:"degraded"`) —
    `adv_ks_blocking_since` got freshly set on that poll, confirming the
    advanced-killswitch-blocking detection still evaluates this cache correctly. Holds for
    the same underlying reason as the tunnel-ping case: `killswitch_mode` (PIA's
    settings.json) and `connectionstate` (`piactl`) are both read completely independently
    of whether `wg show` succeeded, so neither degraded reason ever taints their
    freshness.
  - **SitRep display, confirmed unaffected**: `resolve_state_word()` (shared by
    `vpn.lua`/`pf.lua`) has no branch for `state == "degraded"` — it only special-cases
    `"error"`/staleness/disabled/ssh-tripped, so `"degraded"` falls through to `nil`
    (normal render) exactly like `"ok"` always did. Confirmed by running SitRep's actual,
    unmodified `vpn.lua` (`vpn_panel_data()`) against a synthetic `degraded` cache shaped
    like the fixed script's real output: `ltncy_ms` correctly came back `nil` (frame.lua's
    documented "XXX" placeholder path) and the status lines (NOMINAL/REGION/PROTOCOL/
    HANDSHAKE/KS OFF) rendered exactly as they would have before this change. `gtex62-
    sitrep` itself was not modified.

### WEATHER
- **Category 3 (state-elevating) — confirmed identical pattern to AVIATION.** Verified
  directly in `fetch_openweather.sh`: `state:"error"` for missing profile TOML, missing
  credentials/coordinates, or total fetch failure with no prior cache (`"weather fetch
  failed; no cache"`, category 2 shape). Once any cache exists, `current`/`forecast` are
  tracked as independent fields exactly like aviation's `metar`/`taf` — `OVERALL_STATE`
  becomes `"degraded"` with a `note` naming which field is failing and its `last_ok`
  timestamp (`"forecast fetch failing; serving cached data from <last_ok>"`, etc.), same
  code shape, confirmed built in the same session as aviation's fix per the script's own
  comments. This is exactly the precedent the original TODO predicted checking for, and
  it's confirmed real, not just plausible.
  - AIR (see its entry) also derives from a similar OpenWeather-family fetch pattern but
    has its own third `"partial"` state on top — WEATHER doesn't have that extra state,
    only `error`/`disabled`/`degraded`/`ok`.
  - Banner text: same as AVIATION's already-covered guidance — surface `current`/
    `forecast` as two sub-rows, `degraded` → name the field and `last_ok` straight from
    `note`.

---

## Once filled in

Feed the confirmed category + banner text per domain back into `doctor-design.md`'s
Actions/Remediation table. Recommended concrete additions based on what this pass found:

- **Closed, not just planned, as of 2026-09-17**: the fifth "silent gap" category
  originally called for a per-domain nested-field lookup table (CONNECT's
  `speedtest.state`, MODEM's channel-table note, NETWORK's null fields, AIR's per-source
  `valid` flags, VPN's `health`/`wg dump` case) — instead, all ten confirmed instances
  across six domains were fixed at the source over three passes. `state` alone is
  trustworthy for every domain now, with zero remaining exceptions — no nested-field
  lookup table, and no domain-specific "check a different field" special case, needed
  anywhere in Doctor's design.
- **NET, not ORB, as the primary category-1 worked example** when this ships — it's the
  domain `CLAUDE.md` already calls out by name, and the consequence (1s→60s) is far more
  visible than ORB's (60s→60s, invisible).
- **Drop AP from category 4** and correct the "rides on pfSense's cache" language
  wherever it appears in Doctor's own docs going forward — it describes a storage
  location, not a health dependency. SOLAR→WEATHER is the real, fully-implemented
  category-4 example to reference instead.
- **GITHUB is out-of-band from the launcher entirely** (systemd timer, not
  `refresh_loop`) — Doctor's provider-table loop (which reads `core.toml [providers]` +
  the launcher's TTL variables per `doctor-design.md`'s own plan) will need a special
  case for this domain, or it will silently never appear in the live table the way every
  `refresh_loop`-driven domain does.
- MEDIA remains the one domain in this doc not independently re-verified against its own
  script this pass — do that before treating its entry as equally solid to the rest.
