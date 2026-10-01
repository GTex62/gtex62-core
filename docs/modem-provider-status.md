# Modem Provider Status

Current implementation state of the core `modem` provider: script location, output
schema, configuration, and known constraints. Written Oct 1, 2026, promoting `modem` out
of [Network Providers Roadmap](network-providers-roadmap.md) into the same
`-provider-status.md` structure used by [pfSense Provider
Status](pfsense-provider-status.md)/[Weather Provider Status](weather-provider-status.md).
This doc reflects the **current, final schema** — read it first for "what does
`modem/status.json` actually look like today."

**Network Providers Roadmap is not superseded.** This domain has the single longest,
most detailed investigation history of any provider in this codebase — ten-plus dated
sessions chasing a `recent_t3_timeouts` undercount down to a modem/host clock skew, then
building burst-vs-trickle alerting on top of it. [CHANGELOG.md](../CHANGELOG.md) cites
specific dated sessions in that doc by name throughout, and the roadmap doc remains the
only place that full narrative — the dead ends, the live captures, the exact wrong
hypotheses ruled out — lives. This doc distills the current state; it does not repeat
that history. Companion docs: [Architecture](architecture.md), [VPN Provider
Status](vpn-provider-status.md) (sibling domain, built the same session), [SitRep
Architecture](sitrep-architecture.md) (Alert Banner Watcher's `comcast-degraded-t3-*`
conditions, which read this domain's data via `fetch_alerts.sh`).

---

## Implementation Status

### `providers/modem/fetch_modem.py` + `fetch_modem.sh` ✓ COMPLETE (last touched Sept 17, 2026)

Netgear CM1000 cable modem admin UI, HTTP-scraped through pfSense's NAT-to-VIP path to
`192.168.100.1`. The engine's only HTTP-auth transport — not SSH (pfSense/AP family), not
a local CLI (`vpn`). `fetch_modem.sh` is a thin pass-through wrapper (same split as
`fetch_github.sh`/`fetch_github_traffic.py`); all logic lives in `fetch_modem.py`, which
owns TOML loading, auth, HTML/XML parsing, and the atomic-write envelope directly rather
than following the bash+awk TOML-helper style `fetch_pfsense.sh`/`fetch_vpn.sh` use.

**Does not touch `pf-ssh-gate.sh`** or its state at all — different transport (HTTP, not
SSH), independent as written. Whether sustained modem HTTP failures *should* influence
pfSense's SSH gating (both paths ultimately route through the same pfSense box) remains
an open question — see Remaining Work.

### Auth Flow

1. `GET /GenieLogin.asp` → extract the current `webToken` (a hidden form field, changes
   per page load — fetched fresh each login, never hardcoded).
2. `POST /goform/GenieLogin` (form-encoded: `loginUsername`, `loginPassword`, `login=1`,
   `webToken`) → `302` redirect to `/GenieIndex.asp`, with **no cookie set on this
   response**.
3. Follow the redirect → `GET /GenieIndex.asp` — the session cookie (`SessionID=<value>`)
   is actually set **here**, one step after the login POST. Checking for `Set-Cookie`
   immediately after the login POST would incorrectly read as auth failure.
4. Subsequent requests carry `Cookie: SessionID=<value>`.

**An expired/unauthenticated session returns HTTP 200**, not 401 — a JS redirect stub
(`window.top.location = "/GenieLogin.asp"`) in the response body. `is_auth_redirect()`
checks body content, not status code, with one automatic re-login retry before giving up.

### Page Parsing

`DocsisStatus.asp` is server-rendered HTML (a plain `GET` returns fully populated
`<table>` markup — no JS execution needed), with stable `id` attributes used for
targeting rather than positional column-counting:

| Data | Table `id` | Parsed? |
| --- | --- | --- |
| Downstream SC-QAM | `dsTable` | No — documented, not parsed |
| Upstream SC-QAM | `usTable` | Yes |
| Downstream OFDM | `d31dsTable` | Yes |
| Upstream OFDMA | `d31usTable` | No — documented, not parsed |
| Startup/registration state | `startup_procedure_table` | Yes (`connectivity_state`, `boot_state` rows only) |

Both parsed channel tables match columns **by header keyword** (`"lock"`, `"channel
id"`, `"frequency"`, `"power"`, `"snr"`, `"uncorrectable"`), not fixed position — several
real columns on the OFDM table (Modulation/Profile ID, Active Subcarrier Range,
Unerrored/Correctable Codewords) are deliberately unmapped and ignored rather than
misread. `startup_procedure_table` rows are matched by label text for the same reason —
it carries several other rows (Acquire Downstream Channel, Configuration File, Security,
IP Provisioning Mode) outside this schema's scope.

`EventLog.asp` is a different pattern: its `<table>` has only a header row in the raw
HTML — actual event data is embedded as an XML string inside an inline `InitTagValue()`
JS function, extracted via regex and parsed as real XML (root `docsDevEventTable`, DOCSIS
Device Event MIB field names per RFC 4639). **The modem de-duplicates repeated identical
events into one collapsed row** with a `docsDevEvCounts` repeat counter and a
`docsDevEvFirstTime`/`docsDevEvLastTime` span — `recent_t3_timeouts` sums
`docsDevEvCounts` across matching rows, not row count, or it undercounts by roughly an
order of magnitude.

---

## Output Schema

### status.json

`shared/modem/{profile}/status.json` — written by `fetch_modem.py`. **No `current.json`**
— unlike most domains, everything lives in the one status file.

```json
{
  "state": "ok",
  "profile": "local",
  "collector": "modem",
  "generated_at": "2026-10-01T14:23:00Z",
  "note": "",
  "modem_ip": "192.168.100.1",
  "upstream_channels": [
    { "locked": true, "id": 17, "freq_hz": 16400000, "power_dbmv": 39.5 }
  ],
  "downstream_ofdm_channels": [
    { "id": 194, "freq_hz": 957000000, "power_dbmv": -2.0, "snr_db": 35.8, "uncorrectables": 3460 }
  ],
  "connectivity_state": { "status": "OK", "comment": "Operational" },
  "boot_state": { "status": "OK", "comment": "Operational" },
  "recent_t3_timeouts": 93,
  "recent_t3_elapsed": "14:05",
  "recent_t3_since_epoch": 1759198760,
  "event_log_window_minutes": 60
}
```

A fully-unlocked upstream channel reports `id: 0, freq_hz: 0, power_dbmv: 0.0` — this is
genuinely what the modem reports for an unused channel slot, not a parsing bug; exclude
`locked == false` rows from any averaging.

#### `recent_t3_*` Fields

- **`recent_t3_timeouts`** — summed `docsDevEvCounts` across T3-matching rows (DOCSIS
  event IDs `82000200`/`82000500`, with a `"t3 time-out"` text-substring fallback for
  undiscovered variants) whose `LastTime` falls inside the trailing
  `event_log_window_minutes` window. **Reads the entire collapsed row's lifetime count
  the moment it re-enters the window** — not "+1" — which is why `fetch_alerts.sh`'s
  burst detection (below) tracks a separate delta rather than reading this field as a
  per-poll increment.
- **`recent_t3_elapsed`** — `"H:MM"` elapsed duration (hours uncapped past 24) since the
  earliest counted row's `FirstTime`, offset-corrected the same as `LastTime`. `null`
  when the count is 0.
- **`recent_t3_since_epoch`** — the same anchor as a raw epoch, for identity comparison
  (confirming a resurfacing count belongs to the *same* lineage as a prior poll, not a
  coincidentally-similar new one) — a formatted string can't be compared this way.
- When the total is `0` but a matching row exists just outside the window, `note` names
  how old it was (e.g. `"... a matching event row exists 62.8min old (outside the
  window)"`) — distinguishes "genuinely quiet" from "just missed the window," since the
  modem's own finite log buffer means the evidence for the latter can roll off before
  anyone investigates a zero reading.

#### Clock Offset Correction

Every modem timestamp (`docsDevEvFirstTime`/`docsDevEvLastTime`) is corrected by a
`clock_offset_sec` before comparison, because **this deployment's CM1000 clock runs
~60 minutes behind host time** (leading theory: the modem doesn't observe DST and stays
on Standard Time year-round). The offset is **self-calibrated every poll**: `fetch_modem.py`
reads `DocsisStatus.asp`'s own `#Current_systemtime` field (confirmed live, ticks forward
with real elapsed time between requests — distinct from `InitTagValue()`'s dead
placeholder-JS dummy value, which only a browser's JS engine would ever see) and computes
`now_dt - modem_reported_now` directly, sanity-bounded to under 6h. The configured
`[eventlog].clock_offset_sec` TOML key is consulted **only as a fallback** when the live
field is missing or fails that bound — a `note` surfaces either way so a broken live
reading isn't silently invisible.

#### State Field Values

| Value | Meaning |
| --- | --- |
| `"ok"` | No fetch-level or data-level problem this run |
| `"degraded"` | Modem unreachable/auth failed (network/credential problem), or one of three conditions closed Sept 17, 2026: `connectivity_state.status` present but not `"OK"` (registered-but-unhealthy — a *missing* row is a different, unflagged condition), a fully-unlocked `upstream_channels` array (can't transmit upstream at all), or a channel-table parse failure (table not found / no rows / header mapping incomplete) |
| `"error"` | Missing profile TOML, or placeholder password (`CHANGE_ME`) still in the runtime profile |
| `"disabled"` | Profile has `enabled = false` |

---

## Configuration

`profiles/modem/{profile}.toml`:

```toml
profile_id = "local"
enabled = true
cache_ttl_sec = 300   # signal stats/event log change slowly outside an active incident

[connection]
base_url = "http://192.168.100.1"
username = "admin"
# timeout_sec = 8

[credentials]
password = "CHANGE_ME"   # deliberate placeholder — a fresh bootstrap fails loudly
                          # (state=error) rather than silently never authenticating

[eventlog]
window_minutes = 60
clock_offset_sec = 3600   # FALLBACK ONLY — see Clock Offset Correction above;
                           # should be 0 for a fresh deployment unless you've
                           # independently confirmed your own modem is skewed
```

Password lives in the profile TOML itself (same place every other provider's credentials
live, outside both git repos) rather than a separate secrets mechanism.
`fetch_modem.py` emits a non-fatal warning if the runtime profile TOML is group/world-
readable (recommends `chmod 600`) without blocking the run.

---

## Known Quirks / History

Condensed; see [Network Providers Roadmap](network-providers-roadmap.md) for the full
investigation (ten-plus dated sessions, Aug 19 – Sept 17, 2026) behind these.

- **The CM1000's own web GUI hides recurring events.** Its rendered/exported event table
  shows a collapsed row's `FirstTime`, never `LastTime` or `docsDevEvCounts` — so a
  condition that's been actively recurring for a full day can look, in the modem's own
  UI, like a single static line from hours ago with no indication it's still live.
  `recent_t3_timeouts` (reading the raw XML directly) is the more trustworthy signal, the
  opposite of what seemed intuitive going into that investigation.
- **A `0` count historically masked real, currently-happening events three separate
  times** before the fixes below shipped: once from the clock skew above (events looked
  far older than the window when read against uncorrected host time), once from a
  dropped-row bug (`docsDevEvLastTime == "Time Not Established"`, the modem's own
  placeholder for a still-updating row, excluded any matching row outright regardless of
  `FirstTime`'s validity), and once from an ID/text matching gap that also, in the
  opposite direction, over-counted a non-T3 event (`85000200`, "UCD invalid or channel
  unusable") as if it were a T3 timeout. All three are fixed in the current code (DOCSIS
  event-ID-first matching with a text fallback; `FirstTime` fallback when `LastTime` is
  unparseable; self-calibrated clock offset).
- **Burst detection exists on the alerts side, not here** — `fetch_alerts.sh` tracks a
  separate poll-to-poll delta (`t3_last_seen_count`/`t3_last_seen_since_epoch`) rather
  than reading `recent_t3_timeouts` as an increment, specifically because a collapsed
  row's full lifetime count reappears whenever its `LastTime` re-enters the window — a
  naive diff against *that* number produced a real false-positive "+108 in one poll"
  alert the same day burst detection first shipped, fixed by only trusting a delta when
  `recent_t3_since_epoch` matches the prior baseline (provably the same row, not a
  coincidence). See [SitRep Architecture](sitrep-architecture.md) § Alert Banner Watcher
  for the live condition definition (`comcast-degraded-t3-burst`/`-total`).
- **Three silent "ok while actually broken" gaps closed Sept 17, 2026** (same six-domain
  Doctor audit as `vpn`, see [CHANGELOG.md](../CHANGELOG.md) 0.7.0) — see State Field
  Values above.
- **A genuinely new DOCSIS failure mode (T2/T4/SYNC timeouts) is seen but not
  alerted on.** First observed Sept 12, 2026 — `matches_t3()` only watches for T3-specific
  IDs/text, so these events parse cleanly but contribute nothing to
  `recent_t3_timeouts`, by design (not a bug). Discussed, explicitly deferred pending a
  second occurrence — see Remaining Work.

---

## Known Constraints

- **Modem's own Event Log buffer is finite** — a byte-for-byte recapture of a specific
  past episode isn't always possible once it's rolled off; `nearest_excluded_age_min`
  (see `recent_t3_*` Fields above) exists specifically to leave forensic evidence before
  that happens, not to prevent it.
- **`clock_offset_sec`'s fallback value (3600s) is deployment-specific**, sized off this
  host's observed skew — not a general constant, and self-calibration means it should
  rarely be consulted at all in normal operation.
- **No health classification on signal stats** — SNR/power/uncorrectable thresholds
  exist as reference ranges in commentary, not as a computed field; a longer baseline was
  judged necessary before trusting thresholds enough to classify.
- **Credential handling is plaintext-in-TOML**, same convention as every other provider
  here — acceptable because the runtime profile directory lives outside both git repos
  entirely, not because the password itself is protected in any special way.

---

## Remaining Work

- [ ] T2/T4/SYNC event detection and alerting — explicitly deferred after a single
      sighting (Sept 12, 2026); revisit on a second occurrence.
- [ ] Whether sustained modem HTTP failures should factor into `pf-ssh-gate.sh`'s SSH
      gating, given both paths route through the same pfSense box — open question, not
      attempted.
- [ ] No signal-stats (SNR/power/uncorrectable) health classification yet — needs a
      longer baseline than the one reference read this domain was built against.

---

## Session History

Heavily condensed — this is the single longest investigation trail of any provider here.
Full detail, including every live capture and ruled-out hypothesis, lives in
[Network Providers Roadmap](network-providers-roadmap.md) (its "Modem-Level Corroboration
Provider" section onward) and [CHANGELOG.md](../CHANGELOG.md).

- **Aug 18–19, 2026 (0.2.0) — Built and verified.** Reconnaissance (auth flow, table
  structure, URL map) done via view-source/HAR capture before writing code. Live
  cross-check against real authenticated pages caught and fixed two bugs the
  reconnaissance alone couldn't surface: `#Current_systemtime` initially judged dead
  placeholder JS (later revisited, see Sept 7 below), and real event timestamps using a
  `"YYYY-MM-DD, HH:MM:SS"` format that didn't match the originally-guessed formats.
- **Aug 24, 2026 (0.4.0) — `connectivity_state`/`boot_state` added**, parsed from
  `startup_procedure_table`.
- **Aug 31, 2026 — `recent_t3_timeouts` undercount fix #1**, the `LastTime`-unparseable
  dropped-row bug and the T3-vs-UCD ID matching gap, both described in Known Quirks /
  History above.
- **Sept 6–7, 2026 — Root-caused to modem/host clock skew**, after an intermediate
  session found the counting logic itself correct against live data but couldn't explain
  a reported zero during a real episode. A real, separate double-scheduler bug (two
  concurrent suites each running their own uncoordinated launcher loop) was found and
  fixed in the same investigation — worthwhile on its own, not the actual explanation for
  the reported miss.
- **Sept 7, 2026 — Self-calibrating clock offset.** Replaced the static
  `clock_offset_sec` fallback with live measurement via `#Current_systemtime` — see
  Clock Offset Correction above. Not in CHANGELOG.md as its own entry; see the roadmap
  doc's "Follow-up #2" session.
- **Sept 8–13, 2026 (0.6.2–0.6.5) — Alert-side work on top of the now-trustworthy
  count**: `SINCE <HH:MM>` → `FOR <H:MM>` elapsed anchor; stale-cache force-expire;
  burst-vs-trickle-vs-total three-tier model and its same-day false-positive fix (see
  Known Quirks / History above); per-breach `(T3)`/`(LOSS)`/`(T3+LOSS)` detail in
  `alert_log.txt`.
- **Sept 17, 2026 (0.7.0) — Three silent-gap closures**, part of the same six-domain
  Doctor audit as `vpn`. 13 scenarios verified against the real shipped code.
