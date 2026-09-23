# gtex62-doctor — Core Domain Design

Design for a new standalone suite, `gtex62-doctor`, that reports on the health of every
`gtex62-core` provider domain in one place. Scaffolded the same way `gtex62-sitrep` was —
own repo, mirrors the standard suite structure, runs alongside another suite rather than
replacing it. Split out as its own repo rather than a shared "suite doctor" pattern,
because suites are pure display — they have nothing of their own to diagnose that isn't
already core state.

**Status (2026-09-23): provider built, suite content in progress.** The core-side
provider exists: `providers/doctor/fetch_doctor.sh` writes the `status.json` this doc
specifies (schema in that script's header comment), and its launcher wiring,
`[doctor]` toggle and `suites/doctor.toml.example` are in place. The `gtex62-doctor` suite
has its chassis and launcher; box content (RUNTIME, CONFIG, PROVIDERS, DCM) is being
built against that schema. DCM and the config-completeness alerts below still specify
what the suite will render, not behavior that exists today. See Resolved Decisions for
what the provider pass settled, and Open Questions for what remains.

Reference implementations: `gtex62-tech-hud`'s Doctor script (`TECH HUD DOCTOR`),
`gtex62-tri-hud`'s Doctor script (`TRI HUD DOCTOR`, built after tech-hud's and closer to
the target state vocabulary), `architecture.md`'s provider/TTL table.

---

## Core Distinction: Suite Doctors vs. Core Doctor

Tech-hud and tri-hud each hand-maintain their own Doctor script. Both cover overlapping
ground — weather deps/cache, fonts, config vars, infrastructure/pfSense — organized
differently, drifting independently, and duplicating checks that describe core state
(cache freshness, screen-size detection, derived caches) rather than anything specific to
that suite's own display logic.

| | Suite-local Doctor (tech-hud, tri-hud) | Core Doctor (`gtex62-doctor`) |
| --- | --- | --- |
| Scope | That suite's own config/cache/fonts/deps | Every core provider domain, suite-agnostic |
| Source of truth | Hand-written per-widget checks | Loop over provider metadata (TTL, cache mtime, `core.toml` flags, profile `enabled`) |
| Duplication | Each suite reimplements the same checks slightly differently | One script, one schema, every suite benefits |
| Maintenance | Drifts as suites are added/converted | Grows automatically as core gains providers |

This promotes the *idea* of tech-hud/tri-hud's Doctor to core, the same way the lyrics
library design promoted tech-hud's lyrics handling — existing working logic generalized,
not redesigned from scratch.

---

## State Vocabulary

Tech-hud's Doctor used a two-state model (OK/WARN). Tri-hud's, built later, used four —
adopted here as the baseline, since it already distinguishes "broken" from "off by
design":

| State | Color | Meaning |
| --- | --- | --- |
| NOMINAL | green | Present, fresh, within TTL |
| WARN | yellow, highlighted | Missing, stale, or misconfigured — needs attention |
| DISABLED | unhighlighted | Administratively off, by design, not broken — by either mechanism: its `core.toml [providers]` flag is false, or its profile `enabled` key is not `true` (the fetch script then writes `state:"disabled"`). Not the same as "flag on, but the launching suite omits the domain" — see below |
| PRIVATE | unhighlighted | GITHUB's state — maintainer-only and hardcoded: never computed from its `enabled` key, `status.json` or any live signal, a fixed fact about which domain this is. No one but the maintainer can meaningfully enable it (`gthb_format.py`, which it depends on, lives outside both repos in a private directory), so it is structurally not-applicable to any other install, not a setting someone turned off. PRIVATE does not mean nothing to watch — GITHUB can still carry a `REFRESH` NOTE (see NOTE Column) that highlights independently of STATE |
| HYBRID | purple | One or more, but not all, of a multi-sub-flag domain's sub-caches are enabled — informational, not a problem |
| OPTIONAL | blue | Present and working, but not required (tri-hud's pfSense-enabled row is the model) |

**The STATE column says NOMINAL, not OK**, for suite-family visual consistency with
OSA/SitRep, which deliberately avoid "OK" for the same reason. "OK" survives only where
it quotes something literal — a provider's own `state:"ok"` JSON value, or tech-hud's
original two-state model above.

**STATE is derived, not set independently.** Whenever a domain's AGE exceeds its TTL, its
STATE is WARN — regardless of what caused it (missing cache, fetch failure, stale data).
Two columns disagreeing about the same row (AGE showing stale while STATE still shows NOMINAL)
defeats the point of scanning STATE as the fast path. The one exception is GITHUB, whose
STATE is hardcoded PRIVATE (see the table).

**STATE's inputs — and what it never reads.** STATE derives from two things: freshness (AGE
against TTL) and the provider's own reported non-ok state (`error`/`degraded`/`partial`/
`waiting` — a MODEM row whose provider reports `degraded` reads WARN even with AGE under TTL).
It takes no input from a Doctor-derived NOTE flag: `MISSING` (the TTL-fallback flag) and
`REFRESH` are raised independently and never move STATE. So a NOMINAL row carrying a
highlighted `MISSING` NOTE is a valid, expected combination, not a contradiction — ORB or
ASTRO on the fallback, where the real TTL and the fallback are both 60s and AGE stays under
TTL. It is the same STATE/NOTE divergence GITHUB already has, and the row highlights off the
NOTE alone (see Highlight rule). The rule above protects against AGE and STATE disagreeing;
it does not require STATE to mirror a NOTE. NET on the fallback reads WARN for a different
reason: its AGE, climbing toward 60, exceeds the 1s TTL the row reports — not the flag. A
flagged row reports its *intended* `ttl_sec` (NET's 1), never the launcher's effective
fallback, with `ttl_fallback:true` alongside it; reporting the effective 60s would make NET's
fallback read NOMINAL and defeat the point of flagging it.

**OPTIONAL is narrower than it first looked.** It does not mean "provider toggle is off" —
that's DISABLED. AP/PFSENSE being off should show DISABLED like VPN, not OPTIONAL.
OPTIONAL is reserved for a domain that's genuinely present and functioning but not a
requirement either way.

**DISABLED means administratively off — and only that.** Two situations both leave a
domain with no fresh cache, and they are not the same state:

| Situation | What is true | STATE |
| --- | --- | --- |
| Administratively off | Flag false in `core.toml`, or profile `enabled` not `true` — someone turned it off | DISABLED |
| Flag on, suite omits it | Dual-gated domain (vpn/ap/modem/alerts/mtr/pihole) with its `core.toml` flag `true`, but absent from the launching suite's `[domains]` — nobody turned it off, the launcher just never started it | Not DISABLED. Derived like any other row: WARN (`MISSING`, or `STALE` past TTL) if no fresh cache exists, NOMINAL if another suite's launcher is keeping the shared cache fresh |

The second row is a misconfiguration, not a choice, so it must not borrow DISABLED's
"by design" treatment — and it does not get a special exemption from the derivation rule
above either. What changes is the *remediation*, not the state: see Config-Completeness
Alerts.

**MTR needs its own word**, not OPTIONAL or DISABLED — it's trigger-armed, not off and not
merely optional. Settled: `idle` (`running:false`, trigger inactive), `armed` (trigger active,
capture not yet confirmed running — transitional) and `running` (overnight capture in
progress) rather than borrowing a state that means something else. None carries a NOTE or
highlights a row.

**HYBRID is for domains with multiple independent `core.toml` sub-flags** — written
generally, not hardcoded to one domain, though PFSENSE is currently its only user: four
independent `[providers.pfsense]` sub-flags (`status`/`router`/`pfblockerng`/`ifaces`,
post Pi-hole promotion). The "six sub-caches" named elsewhere in this doc counts cache
families, not flags — arp/leases ride on `status`'s fetch and have no flag of their own,
so HYBRID counts the four flags. Precedence, in order: DISABLED (zero sub-caches enabled)
→ HYBRID (some but not all enabled, and everything that is enabled is otherwise healthy)
→ NOMINAL/WARN by cache freshness once all sub-caches are enabled, same derivation rule as any
other row. WARN always overrides HYBRID — if any enabled sub-cache is genuinely stale or
unhealthy, the row shows WARN regardless of how many sub-caches are enabled; HYBRID never
masks a real freshness problem, it only applies when hybrid-but-healthy is the actual
situation. Only enabled sub-caches count toward that freshness check — a disabled
sub-flag's leftover cache file must not drag the row to WARN.

### Highlight rule — actionable NOTE only

Row highlight (see the STATE table above) marks **triggered/transient conditions only,
never category, and it is keyed on the NOTE column, not on STATE.** A row is highlighted
whenever its NOTE cell carries an actionable tag, regardless of what STATE shows — a
highlight represents an event, not a resting condition. The same condition —
an actionable NOTE present — is DCM's takeover trigger (see DCM — Digital Core Monitor).

- **Highlighted: any row whose NOTE carries an actionable tag** (`ERROR`, `DEGRADED`,
  `PARTIAL`, `WAITING`, `STALE`, `MISSING`, `REFRESH` — see NOTE Column). Each is
  something that actively changed: a threshold crossed, a fetch failed, a condition
  activated. An informational entry is not actionable and does not highlight — MEDIA's
  `OPTIONAL` genius-token note is the example.
- **STATE alone never highlights.** NOMINAL, DISABLED, PRIVATE, HYBRID, IDLE and RUNNING
  are what a row simply *is* — working, administratively off, structurally
  not-applicable, hybrid-but-healthy, armed-and-waiting, capturing-as-designed — a condition a row settles into and stays in,
  regardless of whether the underlying fact is "working" or "off by design." OPTIONAL
  follows the same way. WARN is not an exception: it highlights only because a NOTE is
  always populated alongside it.

**Why NOTE, not STATE.** For freshness-derived domains WARN and a populated NOTE always
co-occur, which made this look like a STATE-level rule ("highlight when STATE is WARN").
For every domain except GITHUB and the TTL-fallback `MISSING` case (see "STATE's inputs")
the two wordings behave identically. GITHUB is the case that needs the distinction: its
STATE is permanently PRIVATE, never WARN, yet it can carry a real, time-sensitive NOTE
(`REFRESH`) that must highlight independently of STATE. The fallback flag on ORB or ASTRO is
the narrower second instance: STATE reads NOMINAL from AGE against TTL while `MISSING`
highlights the row.

**Deliberate reversal — don't flip this back without reading why.** An earlier draft did
the opposite: DISABLED and PRIVATE were highlighted and WARN was not. It was reversed on
purpose. Highlight should draw the eye toward what needs attention right now, not toward
stable category facts. Under the earlier draft a fresh install — where the ship-disabled
defaults leave several domains DISABLED — would light up rows that need nothing from the
reader, while WARN, the row that does, would not stand out. That defeats scanning STATE
as the fast path (see "STATE is derived" above).

---

## Provider Table — Layout

**Settled: alphabetical, all 21 domains, one flat table.** (Was 20 until PIHOLE was
promoted out of the PFSENSE row into its own — it runs on Pi5 with its own script, SSH
gate and TTL, same as MTR, so worst-state-wins under PFSENSE would have blamed the
firewall for a Pi5 failure.) Bucketing by refresh behavior
(TTL-cadence / manual / conditional / event-driven, as originally proposed) turned out
more confusing in practice than useful — dropped in favor of a single alphabetical list
where STATE and per-row column content carry the distinction instead of table position.
Columns: `DOMAIN | STATE | TTL | AGE | NOTE`. No separate refresh-countdown column — see
below.

**AGE column, duration vs. timestamp split.** TTL-vs-AGE already implies how close a row
is to its next refresh, so a dedicated countdown column was dropped as redundant. AGE
itself switches representation depending on the domain's TTL:

- **Duration** (plain seconds) for domains with TTL under roughly the 900s line — net,
  time, system, vpn, orb, alerts, astro, ap, pihole (60s in the shipped pfsense profile,
  300s script fallback), weather, solar, modem, aviation, air,
  network (5s default — resolved below, no longer "varies"). A duration reads faster
  than a clock-time diff at these scales. **NET, SYSTEM and TIME (1s TTL) show a blank AGE
  by design:** at a 1s TTL the value would only flicker between 0 and 1 on each redraw —
  the same fast-track reasoning that excludes them from DCM's gauges (see Gauge
  eligibility). NETWORK's AGE is **not** blank — settled: it is a real duration (5s TTL, so the value stays
readable), `fast_track` false. Its DCM gauge exclusion is a separate matter (see Gauge
eligibility).
  **NET's blank is the normal-operation state, and it is not a contradiction that its AGE
  can appear.** Blank (or near-zero) describes NET refreshing at its real 1s TTL. When the
  TTL-fallback condition holds (see TTL-fallback collision, below) NET is no longer
  refreshing at 1s but roughly every 60s, so its AGE no longer flickers between 0 and 1 —
  it becomes a populated value that climbs toward 60 before each refresh resets it (an AGE
  of 47, say). Two different operating states, one
  column; the climbing AGE is how the fallback is confirmed when the TTL cell still reads
  `1` (see `NET FALLBACK TTL` in `doctor-qrh.md`).
  **Implementation constraint:** NET's blank AGE must be conditional on the fallback flag
  (the same `MISSING` condition `fetch_doctor.sh` derives from the profile's existence and
  `[cache] ttl_sec` key), not hardcoded per domain. A NET row that always renders a blank AGE
  would hide the one signal that confirms the fallback, and the TTL cell can't be trusted
  to substitute for it. The rendering logic has to treat NET's AGE as blank *only while the
  flag is clear*. SYSTEM and TIME have no such divergence (their launcher fallback is also
  1s), so for them a fixed blank is safe.
- **Absolute timestamp** (`HH:MM:SSZ`) once a duration would stop being legible at a
  glance — calendar (86400s TTL), github (12h systemd-timer cadence, no TTL — well past the line; date-only, see below),
  and the domains that don't have a real countdown story
  at all: connect (last manual run), media (last write-through), mtr (last triggered —
  see below), pfsense (not unresolved — a genuine multi-sub-cache family with no single
  TTL number to count down, see "Varies" TTL — resolved below). The threshold is "past
  the point a human can eyeball the duration," not an arbitrary cutoff — 900s already
  exists as a real TTL value in the table (air), so it's a natural line rather than an
  invented one.

**GITHUB's AGE timestamp is its continuous, always-visible signal; `REFRESH` is the
escalation, not the only way to notice a problem.** GITHUB sits in the timestamp group,
showing the last successful fetch (read from `history_days`, see `REFRESH` under NOTE
Column). A dead timer is visible the moment someone looks at the table — the timestamp
simply stops advancing, exactly as it would for CALENDAR — so no tag is needed for that.
It also handles a powered-off machine with no reconciliation logic: the timestamp is the
real last-successful-pull time regardless of uptime, so AGE reads correctly the instant
the widget is next checked.

**The timestamp is date-level — settled.** GITHUB shows `YYYY-MM-DD`, the newest
`history_days` day (it trails the pull by about a day), not the `HH:MM:SSZ` wall-clock
time other members of the group show. No other field in this doc is date-only
(CALENDAR's AGE is `HH:MM:SSZ` too), so plain `YYYY-MM-DD` is the format, not a truncated
`HH:MM:SSZ`. The reasoning: this domain's detection goal is "noticeable within a day or
two, well ahead of a two-week deadline," which a date already satisfies — the same
"doesn't need the rigor applied elsewhere" reasoning that justifies `REFRESH` as an
instruction rather than a condition. No change to `fetch_github_traffic.py` is needed to
record an exact last-success time this domain wouldn't use.

Once `REFRESH` fires, AGE switches to whole days elapsed over the 14-day window — e.g.
`10/14`. That replaces the timestamp because at that point remaining-days-until-loss is
more urgent than the raw timestamp, not because the timestamp was hiding anything
before then.

**MTR's timestamp should be read, not recomputed.** SitRep's widget already tracks when
MTR last triggered (gated on a SEVERE gateway-offline alert). Doctor's row should read
that same published value rather than deriving its own — two independent computations of
"when did MTR last fire" could drift out of sync with each other.

**TTL-fallback collision — NET, not ORB, is the real worked example.** Verified against
`fetch_net.sh`: it never checks whether its profile TOML exists at all, so a missing
`profiles/net/<profile>.toml` silently drops NET from its real 1s TTL to the launcher's
bash-default 60s, with `status.json` still reporting `state:"ok"` throughout — exactly
the "fast-track meters appear frozen" case `architecture.md`'s Bootstrap Gap section and
this project's own `CLAUDE.md` already call out by name. ORB and ASTRO have the same
underlying risk but a far less visible consequence (ORB's real TTL happens to equal the
60s fallback; ASTRO has no `[cache]` section at all today, same effect). Doctor cannot
trust a TTL number at face value for any of these three without an explicit flag —
`ttl_fallback` in `status.json` — distinguishing "profile confirmed present" from "running
on fallback"; see `doctor-missing-conditions.md` for the full verification.

**The flag is general, not NET/ORB/ASTRO only.** `fetch_doctor.sh` evaluates `ttl_fallback`
for every launcher-loop domain whose profile TOML carries a TTL key: `true` when that key is
absent from a present file — the shape where the launcher's awk parse returns empty and its
bash default takes over. Verified against the shipped examples and the live profiles: on this
host ASTRO, NETWORK and SOLAR are flagged; SYSTEM and TIME are not (their `[cache]
refresh_sec` is present), and CALENDAR is not (the key it is evaluated on, `[events]
cache_ttl_sec`, is present). A domain whose fetch script explicitly checks for its profile
reports a missing *file* as its own `state:"error"`, `note:"missing profile toml"` (PROC:
PROFILE TOML MISSING) — a different failure mode, never conflated with the flag. Only NET
and ORB never check, so for them a missing file also sets it. `ttl_fallback` is `null` (not
evaluated) for ALERTS (no profile ships), AP (TTL in `site.toml [ap]`), MEDIA (`site.toml`),
CONNECT (on-demand), GITHUB (systemd timer), and PFSENSE's router/pfblockerng/ifaces
sub-caches (their keys are not in the shipped example either). Domains without a
procedure of their own use PROC: FALLBACK TTL.

**Media domain detail.** Beyond state/age, media's row is a snapshot of library/config
state, drawing from fields already defined elsewhere — no new collection needed except
the file count:

| Field | Source |
| --- | --- |
| Lyrics file count in `local_dir` | New — directory listing, not currently in `status.json`/`lyrics.json` |
| Last song played | Already published as current-track state each cycle |
| Sites checked, in order | `[media.lyrics]` `providers_noapi` (`lrclib`, `lyrics_ovh`) + `providers_api` (`genius`) |
| Paid/API site configured | `genius_token` set vs. empty — presence only, never the token itself |

`genius_token` presence is a config-completeness check, not a runtime health check —
belongs with DCM (see below), not the live table. **Not independently
re-verified against `fetch_lyrics.sh`/`fetch_lyrics.py` yet** — treat as provisional
until it gets the same script-level pass the other domains got.

**"Varies" TTL — resolved.** Checked against the real fetch scripts and installed
profile TOMLs:

- **NETWORK** defaults to 5s (no profile override currently installed).
- **PFSENSE** is a genuine multi-sub-cache family, not one TTL — status/router/
  pfblockerng/ifaces/arp/leases (six) each gate independently, ranging 5s-300s. A single
  `degraded` on PFSENSE's row needs to name which sub-cache, not just "PFSENSE." Which
  sub-caches are enabled at all is a three-tier question, not a boolean — see State
  Vocabulary (HYBRID). Pi-hole is **not** one of them: it has its own PIHOLE row (see Provider Table —
  Layout), its own script (`fetch_pihole.sh`), SSH gate (`runtime/pihole`) and TTL. It
  only shares PFSENSE's cache directory (`shared/pfsense/{profile}/pihole.json`) and
  the pfsense profile TOML's `[pihole]` section, so Doctor's PIHOLE row reads that same
  path.
- **GITHUB runs entirely outside the launcher** — a systemd timer, not `refresh_loop`/TTL
  at all. Doctor's provider-table loop (which reads `core.toml [providers]`, each
  domain's profile `enabled`/`state`, and the launcher's TTL variables) needs an
  explicit special case for GITHUB or it will silently never appear in the live table
  the way every other domain does. Its STATE is likewise hardcoded PRIVATE (see State Vocabulary) — one underlying fact,
  that GITHUB is structurally special-cased in Doctor, not two. It also has a NOTE condition no other domain has —
  `REFRESH`, a 14-day data-loss deadline (see NOTE Column) — which PRIVATE STATE does not
  suppress. **Special-case handling — settled:** `fetch_doctor.sh` reads GITHUB's own cache
  directly (`shared/github/{profile}/status.json` and `current.json`) rather than through the
  launcher/TTL loop, with `ttl_sec` null and `ttl_label` `"TIMER"`. Its NOTEs are raised only
  where the profile file exists and is enabled, so a fresh install (which ships `enabled =
  false`) stays silent instead of highlighting `MISSING` forever.

---

## Disabled Domains

**Settled: inline, not pulled out.** Originally planned as a separate section below the
table; instead disabled domains (e.g. VPN) appear inline, alphabetically in
place, STATE = DISABLED unhighlighted (see State Vocabulary — Highlight rule), TTL still shown for reference. Simpler
to scan as one continuous alphabetical list than splitting attention between a table and
a separate call-out.

**Footer — a pointer, not an instruction.** The fix for a disabled domain differs by
domain *and* by mechanism (see below), so the footer does not try to encode it — neither
one generic `core.toml` line (wrong for most rows) nor per-domain file paths in the
remediation table (too much for a table cell). Doctor's job is showing that something is
off, not spelling out how to fix it. One fixed line, shown once in the widget footer:

```text
TO ENABLE PROVIDERS, SEE README § Provider Toggles
```

The literal text after `§` is the heading in `gtex62-core`'s README
(`## Provider Toggles`) — the heading, not a section number, since numbers break
silently on reorder. If that heading is ever renamed, this line, the Provider Toggles
heading and the README's table-of-contents entry change together.

Every "Domain disabled" case collapses to that same pointer. No DISABLED row gets its own
file path or remediation text, in the table or DCM.

**Two disable mechanisms — DISABLED must be derived from both.** Verified against
`bin/gtex62-core-launch` and every fetch script (2026-09-19):

- **`core.toml [providers]` flag** — `vpn`/`ap`/`modem`/`alerts`/`mtr`/`pihole` (dual-gated:
  the flag *and* the launching suite's `[domains]` list), `media`, and the
  `[providers.pfsense]` sub-flags `status`/`router`/`pfblockerng`/`ifaces` (flag-only).
  A false flag means the loop never starts, so there is no `status.json` to read — Doctor
  reads the flag itself.
- **Profile `enabled` key** — everything else: air/astro/aviation/calendar/connectivity/
  net/network/solar/system/time/weather. The loop always runs; the fetch script sees
  `enabled` is not `true`, writes `state:"disabled"` and exits. Doctor reads that state.

`core.toml [providers]` is partial by design — it deliberately does not list the eleven
profile-gated domains, because they are universal infrastructure with no suite-relevance
question to gate on, and a second copy of their on/off state would be able to disagree
with the profile. README § Provider Toggles states the rationale.

One consequence for the dual-gated six: a `true` flag does not by itself mean the domain
is running — if the launching suite's `[domains]` list omits it, the launcher skips it and
that suite starts no fetch loop for it. That is **not** DISABLED (see State Vocabulary):
Doctor derives the row from cache freshness like any other, and surfaces the cause in
DCM's config-completeness entries. Doctor can only check its own launching suite's list
(`suites/doctor.toml`, per its `GTEX62_SUITE_ID`) — it has no view of which other suite
launched what.

The pfSense split is still real: the PFSENSE row is four flag-only sub-flags under
`[providers.pfsense]` (`status`/`router`/`pfblockerng`/`ifaces`) and Pi-hole is no longer
one of them — it moved to top-level `[providers]` as `pihole`, with its own row. Those
four give the row three tiers, not two: none enabled → DISABLED, some enabled → HYBRID
(unless an enabled one is unhealthy, then WARN), all four enabled → NOMINAL/WARN by freshness.
See State Vocabulary.

**Ship-disabled defaults — verified against `examples/runtime/core.toml.example`,
`examples/runtime/profiles/`, and `bin/gtex62-core-launch` directly, not assumed from the
flag names alone:**

- **AP, MODEM, VPN, PIHOLE**: confirmed `= false` in the example template, matching the
  launcher's own `${..._ENABLED:-false}` bash fallback.
- **PFSENSE is not one flag.** It's four independent sub-flags under
  `[providers.pfsense]` — `status`/`router`/`pfblockerng`/`ifaces` — each gating its own
  `initial_refresh`/`refresh_loop` call separately. All four ship `= false`, so
  "PFSENSE defaults to false" is true in aggregate, but Doctor's own PFSENSE row (see the
  multi-sub-cache note in Provider Table — Layout) needs to treat this the same
  four-way way, not as a single boolean: all four false ships as DISABLED, and flipping
  any one (but not all) on moves the row to HYBRID rather than straight to NOMINAL.
- **MTR** ships disabled at both layers: `= false` in `core.toml.example`, and
  `profiles/mtr/pi5.toml.example` (added 2026-09-19 — previously no MTR profile example
  shipped at all, and `fetch_mtr.sh` treats a missing profile file as disabled, so a fresh
  bootstrap could not enable MTR from `core.toml` alone) ships `enabled = false`.
- **MEDIA** ships disabled: `media = false` in `core.toml.example`, matching the launcher's own
  `MEDIA_ENABLED="${MEDIA_ENABLED:-false}"` fallback. It is gated by that flag alone — its config is
  global (`site.toml [media.lyrics]`), not a profile TOML. The reason, per
  `media-event-driven-design.md`: once a player runs, each track triggers online lookups
  (lrclib, lyrics.ovh) that send listening metadata to third parties, and a hit writes a file
  into the real NAS lyrics library. That holds regardless of polling or events, so neither the
  idle fast-path already shipped nor the event-driven redesign changes the default. Polling
  cost is not the reason: that doc measures polling and finds its main cost while a track
  plays, not idle.
- **SYSTEM** ships enabled: `profiles/system/local.toml.example` (also added 2026-09-19,
  previously missing) has `enabled = true` — universal infrastructure, needed by every
  suite. Absence was harmless (`fetch_system.sh` only honors `enabled` when the profile
  file exists), but it left SYSTEM with no shipped way to be disabled.
- **ORB has no disable mechanism at all** — no `core.toml` flag, and `fetch_orb.sh`/
  `fetch_orb.py` never read a profile `enabled` key, so it always runs. Doctor cannot
  represent ORB as DISABLED. See Open Questions.

---

## Config-Completeness Alerts

A different class of condition from the existing alerts provider, worth keeping
separate rather than folding into its machinery. The alerts provider's banner already
handles *runtime* conditions — gateway-offline, Pi-hole inactive, MSMTCH, unknown IP, AP
offline — each with a severity tier and fixed message text, recomputed from other
providers' caches on a cadence.

Doctor's DCM alerts are *config-completeness* at startup: unset lat/lon, placeholder API keys,
unset timezone — closer to tech-hud's static `config/owm.vars LAT=` check than to a
polled runtime condition. Different enough in shape (checked once at file-read time, not
recomputed against a threshold/duration) that it wants its own small model rather than
reusing alerts' severity-queue design.

**Enabled in `core.toml` but absent from the suite's `[domains]`.** For a dual-gated domain
(vpn/ap/modem/alerts/mtr/pihole) whose flag is `true`, whose cache is missing or stale,
and which is not listed in Doctor's own launching suite (`suites/doctor.toml`), DCM
names that as the cause in place of the generic "provider isn't running" text.
Fixed text: "`<DOMAIN>` is enabled in `core.toml` but not listed in `[domains]` of
`suites/doctor.toml` — add it, or the launcher never starts it." The row's own
STATE/NOTE stay whatever the cache says (WARN, `MISSING`/`STALE`); if another suite's
launcher is keeping the cache fresh, the row is NOMINAL and no DCM entry is raised.

**Unset TZ — verified 2026-09-17, and the obvious framing is wrong.** There is no
system-TZ fallback mechanism anywhere in `gtex62-core` for an unset
`site.toml [location.home] timezone`. Checked every domain that reads it directly:

| Domain | Reads `[location.home] timezone`? | Falls back to system TZ if unset? | Used computationally? |
| --- | --- | --- | --- |
| ASTRO | Yes, via `site.toml` then `date +%Z` | Yes — the only domain with a real fallback chain | **No** — stored as `observer.timezone` metadata only; `ephem.Observer()` only ever uses lat/lon |
| CALENDAR | Yes, via `site.toml [calendar]` then `[location.home]` | **No** — ends at an empty string | No — stored as a `timezone` label only, events parse as plain text |
| WEATHER | Yes | No | No — forecast day-bucketing uses `$root.city.timezone`, a UTC offset from OpenWeather's own API response, not this value |
| SOLAR | Yes | No | No — pure metadata, UV/radiation math uses lat + raw epoch only |
| AIR | Yes | No | No — pure metadata |
| TIME | **Never reads `site.toml` at all** | N/A | The "local" row always uses the OS's own timezone (`datetime.now().astimezone()`) — unconditionally, regardless of what `site.toml` says |
| NET, NETWORK, ORB, everything else | No timezone concept | N/A | N/A |

No suite (checked OSA, SitRep) displays any of these `timezone`/`observer.timezone`
fields anywhere either — they're fully inert outside TIME's own local-clock row, which
was never wired to `site.toml` to begin with. The intuition behind "falls back to system
TZ, informational only" is directionally right about the *outcome* (nothing breaks
today), but wrong about the *mechanism* — it isn't that unset TZ triggers a fallback,
it's that TZ is vestigial config almost everywhere it's read. Doctor's DCM copy
should say that, not imply a fallback that doesn't exist: **"TZ NOT SET (UNUSED)"**, not
"USING SYSTEM TZ" — the latter would misrepresent ASTRO/CALENDAR/WEATHER/SOLAR/AIR as
silently doing the right thing when they're actually just not using the value at all.
This is a bootstrap edge case only, not a live concern — both the shipped
`examples/runtime/site.toml.example` and the live `site.toml` already set
`[location.home] timezone` explicitly.

---

## NOTE Column vs. DCM — Division of Labor

**Settled.** Two places on the widget carry non-NOMINAL information, deliberately not
duplicating each other:

- **NOTE column** (in the table, per row) — a short tag only, drawn from a fixed
  vocabulary: `ERROR`, `DEGRADED`, `PARTIAL`, `WAITING`, `STALE`, `MISSING`, `REFRESH`. The first
  four mirror a provider's own `state` field directly (`error`/`degraded`/`partial`/
  `waiting` — `partial` is AIR-only today, `waiting` is SOLAR-only today); `STALE` and
  `MISSING` are Doctor-derived, not read from any provider's own state (`STALE` = age
  past TTL with the provider still claiming `state:"ok"`; `MISSING` = the TTL-fallback
  collision flag — see Provider Table — Layout — a row can show `MISSING` even when AGE
  is well under TTL, exactly ORB's and ASTRO's case, where the real TTL and the fallback are
  both 60s; see "STATE's inputs"). `REFRESH` is GITHUB-only and
  Doctor-derived too, not mirrored from any GitHub-side JSON state (the fetch script has
  no concept of it). It fires once the age of GITHUB's last successful fetch crosses 10
  days — a 4-day buffer before the real 14-day cliff — independent of the current run's
  STATE. GitHub's traffic API exposes only a rolling 14-day window, and
  `fetch_github_traffic.py` accumulates `history_days` from each fetch, so a day not
  captured before it rolls out of that window is gone for good. "Last successful fetch"
  is read from `history_days`, not file mtime or `status.json`: the script rewrites
  `current.json` and `status.json` on every run, including one where every repo failed,
  but a repo's newest `history_days` key advances only when its `gh api` pull actually
  succeeds (zero-traffic days are stored too, so a quiet repo doesn't stall it — checked
  against the live cache). Doctor takes the oldest newest-key across the repos *currently
  in the registry* — a repo dropped from the registry stays in the cache and must not
  count. The key is day-granular and trails the fetch by about a day, so the 10-day line
  effectively trips about 9 days after the last pull. While active, AGE shows `N/14` (see
  AGE column).
  **`STALE` is not used for GITHUB at all.** `STALE` means a provider that should be
  actively updating our cache hasn't — a polling-cadence concept. GITHUB doesn't fit that
  shape: the source data on GitHub is always current, and the only real risk is our copy
  falling behind the 14-day window before it's pulled — a copy-deadline concept, which
  `REFRESH` expresses directly. Because `REFRESH` doesn't depend on STATE, it can sit
  beside `ERROR` in the same NOTE cell (fetches failing *and* the deadline approaching) or
  appear alone (a timer that has stopped firing). It is the escalation for the final
  approach to the deadline, not the only way to notice a problem: a dead timer is already
  visible earlier as AGE's timestamp stops advancing (see AGE column), so it needs no tag
  of its own. `REFRESH` is a conscious exception to
  this vocabulary's convention — every other tag describes what is true, this one tells
  the reader what to do — acceptable only because GITHUB is PRIVATE and seen only by the
  maintainer, so don't copy the pattern for a public-facing domain unless the same
  reasoning holds. One tag routinely maps to
  several distinct underlying conditions (AIR's `ERROR` alone covers three — missing
  coordinates, missing API key, no cache yet); DCM's active-state entry is what disambiguates, by
  matching against the provider's own free-text `note`, not the one-word tag. Its job is
  fast-scan pointing, not explanation.
- **DCM** (see DCM — Digital Core Monitor, next section) — the left-column panel that
  replaced the old "Alert Banner" and absorbed its job. In its active state, whenever a
  row has an actionable NOTE, a corresponding QRH-style entry gives the full condition and
  the remedy. This is where the Actions/Remediation table below actually surfaces to the
  user — the NOTE column stays lightweight specifically because DCM is carrying the detail.

This mirrors the SitRep/Doctor split from earlier in this doc at a smaller scale: SitRep's
banner covers runtime conditions with full message text; DCM does the same
for provider-health and config-completeness conditions, while the table itself stays a
quick-reference surface.

---

## DCM — Digital Core Monitor

DCM replaces the panel previously called "Alert Banner." It absorbs that panel's job
rather than adding a second panel beside it: the active state below is the old banner's
behavior (itself modeled on SitRep's banner), and the idle state replaces what used to be a
mostly-blank panel body with something genuinely useful in the common case (its "NO HEALTH
ALERTS" text now lives only in the header line — see Two states).

### Name and naming trail

DCM = **Digital Core Monitor.** The name went ECAM → ECCM (Electronic Central Core
Monitor) → ECM (Electronic Core Monitor) → DCM. "Electronic" was rejected because nothing
in this stack is electronic-hardware-flavored; "Digital" is accurate to what is actually
being monitored — `gtex62-core`'s domains. **"Display Core Monitor" was explicitly
rejected too:** it reads oddly, implying a monitor that displays a core rather than a
monitor *of* the digital core. Don't drift back to either.

### Two states

Matching ECAM's own E/WD-to-STATUS convention, DCM is always in exactly one of two states —
never a blend, never gauges and entries side by side:

- **Idle** — no domain has an active NOTE. The panel shows one vertical bar gauge per
  eligible, currently-enabled domain (see Gauge eligibility and Disabled domains get no
  gauge below).
- **Active** — any domain has an actionable NOTE. Full takeover: the gauges are entirely
  replaced by QRH-style entries, each a condition line, an action line and a PROC line. This
  is exactly the old Alert Banner behavior. The takeover trigger is **identical to the
  Highlight rule's** — an actionable NOTE present (see Highlight rule — actionable NOTE
  only, and NOTE Column vs. DCM) — so DCM goes active on precisely the conditions that
  highlight a row in the PROVIDERS table. Informational entries (MEDIA's `OPTIONAL` note)
  and states that are not NOTEs (HYBRID, MTR's IDLE/RUNNING) don't trigger it.

**The takeover applies to the panel body only.** The header's one-line summary — `NO
HEALTH ALERTS` when idle, `CHECK ACTIONS (N)` when active, N being the count of active
entries — is a separate, always-present fast top-level check, unaffected by which state
DCM's body is in. It reads the same actionable-NOTE condition but is rendered
independently: the header is the quick answer, DCM's body is the detail.

Takeover is domain-agnostic: an entry is raised for *every* domain with an actionable NOTE,
including domains that never get a gauge (NET, GITHUB's `REFRESH`, and so on). Gauge
eligibility only shapes the idle state. Entry text is the fixed remediation from Actions /
Remediation, not generated prose.

### Active-state overflow — scrolling

When more entries are active than the panel holds, the entry list scrolls, by the same
mechanism as SitRep's alert banner: the window start is a pure function of wall-clock time
(`floor(os.time() / interval) % total`, 3s by default), wrapping circularly, so it needs no
persisted animation state and never pads. The unit is one whole entry block — the domain bar
and its condition, action and PROC lines — so the window always advances by a complete
procedure, never mid-procedure. There is no count suffix. Entry ordering is still the
provider's alphabetical, unranked order (see Open Questions).

### Gauge mechanics

Each gauge is a vertical bar with **the domain's own TTL printed as its top label.** This is
a per-domain scale, not a normalized 0-1 ratio: each domain's real numbers stay legible and
comparable to its own limit rather than to an artificial common denominator — the same
logic as individual aircraft gauges having individual redlines instead of one shared
normalized dial (AIR's 900 and WEATHER's 300, by launcher default, each read on their own
scale). The marker's vertical position is current AGE against that domain's own TTL: **top =
fresh (AGE near 0), falling toward the bottom as AGE approaches TTL.**

AGE past TTL makes the domain's STATE WARN with a NOTE (see "STATE is derived"), which puts
DCM in its active state — so an idle-state gauge never has to represent an over-limit
marker.

### Gauge eligibility

A general rule, restated for any future provider rather than a one-time list. A domain gets
a gauge only if **both** hold:

1. **Its AGE is a duration against a single TTL** — it is in the AGE column's duration
   group (see Provider Table — Layout), not the timestamp group. The timestamp-group domains
   (CALENDAR, CONNECT, GITHUB, MEDIA, MTR, PFSENSE) have no single countdown-able TTL, so
   there is nothing to plot. This condition matters: CALENDAR's TTL would pass the second
   condition on its own, but it has no duration AGE.
2. **Its TTL meaningfully exceeds Conky's own refresh cadence**, so the marker has a real
   range to visibly traverse over time.

Condition 1 yields exactly fifteen candidates — net, time, system, vpn, orb, alerts, astro,
ap, pihole, weather, solar, modem, aviation, air, network, the duration group — and
condition 2 removes four:

| Excluded | TTL | Why |
| --- | --- | --- |
| NET, SYSTEM, TIME | 1s | At Conky's own cadence there is no visible range; the marker would just flicker or jump between redraws, reading as noise or a broken widget rather than data |
| NETWORK | 5s | Confirmed too close to the flicker zone for reliable per-refresh motion |

There is no fixed numeric cutoff beyond that observed boundary: 5s is confirmed too close,
and the smallest eligible launcher default is VPN's 10s.

**Final eligible set — eleven domains:** AIR, ALERTS, AP, ASTRO,
AVIATION, MODEM, ORB, PIHOLE, SOLAR, VPN, WEATHER. Any future provider is admitted or
excluded by the rule above with no edit here; a polling provider in the 30-60s range that
`airgradient-provider-design.md` proposes for AirGradient would qualify automatically.

NETWORK's exclusion stands on its own: its AGE is a real duration in the PROVIDERS table (see
the AGE column), but at 5s it is too close to the flicker zone for a gauge. NET, SYSTEM and
TIME are blank by the 1s reasoning above.

### Disabled domains get no gauge

A gauge represents AGE against TTL, and both are undefined for a DISABLED domain — no cache
is being written, so there is nothing to plot. An empty slot would misread as either "zero
age, perfectly fresh" (wrong) or a rendering error, so a DISABLED domain gets **no gauge at
all, not a blank one.** The gauge set is dynamic: a gauge is drawn for every eligible domain
whose STATE is not DISABLED.

The row's width is therefore itself informational — fewer gauges means more eligible
domains are disabled. Only eligible domains count toward it: of the eleven, four (AP,
MODEM, PIHOLE, VPN) are DISABLED under the shipped defaults, leaving seven gauges. MTR,
PFSENSE and MEDIA are DISABLED under the shipped defaults too (`core.toml.example` sets
`mtr = false`, all four `[providers.pfsense]` sub-flags false, and `media = false` — see
Disabled Domains for why MEDIA ships off), but none was ever gauge-eligible, so their DISABLED
rows are excluded from the count entirely.

### Layout

Gauges are equally spaced across whatever is present, **re-flowing to fill the full panel
width** — not fixed positional slots with gaps left for absent domains. Re-flowing keeps the gauge
row matching the PROVIDERS table's own row set.

For the real build, spacing is computed across the full panel width *including the panel
edges themselves*, not merely evenly between the first and last visible gauge. Otherwise a
small enabled-domain count (shipped defaults) would leave the gauges clustered in the
middle with dead margin on both sides rather than genuinely filling the panel.

### Domain codes and legend

Codes are three letters, using a standard abbreviation where one already exists (AVN for
AVIATION) rather than an arbitrary truncation. **Two codes are deliberately shorter than
three letters: AP and WX.** Both are already unambiguous on their own — they are not
truncations. The design assumes they will also read cleanly alongside the three-letter
codes without looking like an inconsistency; that is unconfirmed (see Open Questions) until
the actual DCM panel is built. No on-panel legend explains the exception — settled: none is
needed.

| Code | Domain | Note |
| --- | --- | --- |
| AIR | AIR | |
| ALR | ALERTS | |
| AP | AP (access points) | Deliberate two-letter exception |
| AST | ASTRO | |
| AVN | AVIATION | Standard aviation abbreviation |
| MDM | MODEM | |
| ORB | ORB | |
| PIH | PIHOLE | |
| SOL | SOLAR | |
| VPN | VPN | |
| WX | WEATHER | Deliberate two-letter exception |

### Panel growth rule

The widget's left column stacks DCM above the RUNTIME and CONFIG panels; PROVIDERS sits
beside it. **General rule for any future addition:** when a provider is added, PROVIDERS
grows by one row and DCM grows matching vertical space in the left column, so the two
panels stay visually height-aligned. RUNTIME and CONFIG are fixed-content panels (six root
paths and five config fields respectively) that never grow with provider count; they simply
shift downward as DCM's height increases above them.

PROVIDERS already has **one row reserved for the AirGradient air-quality provider**, beyond
the 21 domains counted in Provider Table — Layout. Its design is in
`airgradient-provider-design.md` (titled "AirGradient Engine Integration"):
`shared/airgradient/{profile}/status.json`, written atomically, with the pfSense provider's
three-value `state` convention. The aquarium / Home Assistant integration is a real future
candidate but has **no design doc yet**, unlike AirGradient, so no table space is reserved
for it — it is flagged here as a known future possibility only.

### Gauge-row capacity

**Unconfirmed design assumption — see Open Questions.** The design assumes the gauge row
fits comfortably beyond the eleven eligible domains, legibly with two-letter codes, up to the
fifteen candidates that existed before the eligibility exclusions were finalized. That was
never verified in text; check it once the actual DCM panel is built. No overflow or widening
logic is designed in the meantime. If a future addition ever pushes the eligible, enabled
count meaningfully past fifteen, that is a threshold to revisit then, not something to design
against speculatively today.

### Color

No dedicated color layer. DCM stays within the existing shared OSA/SitRep/Doctor palette,
single-hue, consistent with every other part of Doctor's design in this doc.

---

## Actions / Remediation

Every non-NOMINAL state maps to fixed remediation text, not generated prose — same principle
as alerts' fixed per-condition messages, applied to config-completeness and provider
health instead of runtime conditions. This is the text DCM's active state shows, not the
NOTE column.

**Generic fallback shape:**

| Condition | Action text |
| --- | --- |
| Enabled provider, missing profile TOML | "Add `<domain>.toml.example` under `examples/runtime/`, rerun bootstrap" (documented bootstrap gap — falls back to 60s TTL silently otherwise) |
| Provider stale past TTL, no `degraded` state reported | "Check API key / network reachability for `<domain>`" |
| Config var present but placeholder (`LAT=`, `LON=-`) | "Edit `<file>`, set `<var>`" |
| pfSense/AP SSH gate stuck | "Check SSH alias / sshpass credentials" |
| Domain disabled | No per-domain text — the footer pointer, `TO ENABLE PROVIDERS, SEE README § Provider Toggles` (see Disabled Domains above) |
| Dual-gated domain enabled in `core.toml`, cache missing/stale, absent from the launching suite's `[domains]` | "`<DOMAIN>` is enabled in `core.toml` but not listed in `[domains]` of `suites/doctor.toml` — add it, or the launcher never starts it." — PROC: `DOMAIN NOT LISTED` |
| Profile TOML lacks the key the launcher parses its TTL from (any domain without its own row below) | "`<DOMAIN>` profile TOML has no `<key>` — running on the launcher's default cadence, not the configured one." — PROC: `FALLBACK TTL` |
| Provider reports `error`/`degraded`/`partial`/`waiting` and its `note` matches no known condition | "`<DOMAIN>` reports `<TAG>`: `<note, verbatim>`" — PROC: `UNRECOGNIZED NOTE` (the generic fallback entry, so DCM never has a null PROC) |

**Fifth category — "silent" gaps. Fully historical as of 2026-09-17: zero exceptions
remain.** This category existed because some domains noticed a partial failure well
enough to write a `note`, but left the envelope's top-level `state:"ok"` — a Doctor
check reading only `state` would have missed these entirely, and critically, those rows
got no NOTE tag at all (not even a wrong one). Ten such rows were confirmed across six
domains over three passes: a failed tunnel ping and a failed `wg show` dump (VPN, two
separate conditions, the second closed last — see below); a bad DOCSIS registration
value, an all-unlocked upstream array, and a channel-table parse failure (MODEM, three
conditions); a down AQI source with the other still resolving (AIR, two conditions); a
failing speedtest hidden in a nested field (CONNECT); and null NIC/WAN-IP fields
(NETWORK). All ten were fixed **at the source** — the fetch scripts now elevate their
own `state` to `"degraded"` and name what's wrong, the same shape aviation/weather
already used — rather than being added to a Doctor-side lookup table. This is no longer
a live design constraint for Doctor: **every domain's `state` field is trustworthy on
its own, with no domain-specific exception anywhere** — matching the original goal that
motivated closing this category rather than building a per-domain nested-field lookup
table for it. `doctor-missing-conditions.md` has the full per-domain evidence, including
the consumer check each of these ten required before shipping (see below) and live
verification against the real code for every one.

**VPN's `wg dump`/`health` case — the row this whole category used to keep open — was
closed last, 2026-09-17.** It was deliberately left untouched through the first two
passes: `health` going `"DEAD"` already gave Doctor a trustworthy signal, so nothing was
broken. But it was also the one row that would have forced Doctor to special-case VPN —
"read `health` instead of `state` for this domain" — which the earlier "closed" framing
above glossed over. Closing it removes that exception entirely: `fetch_vpn.sh` now sets
`state:"degraded"` for this case too, gated on `connectionstate == "Connected"` rather
than on `health == "DEAD"` directly, since `health` also reads `"DEAD"` on an entirely
ordinary voluntary disconnect (PIA tears the `wgpia0` interface down on disconnect,
which would make the wg dump fail too, for a completely different and non-alarming
reason) — gating on `health` would have flagged every routine disconnect as
`"degraded"`. Confirmed this doesn't collide with the tunnel-ping fix already in the
same script: the two conditions can't both fire for the same underlying cause (a failed
wg dump already forces `health:"DEAD"`, which is exactly what excludes the tunnel-ping
check from also firing), so at most one note fragment appears per poll. The consumer
check for this one didn't need new work — `fetch_alerts.sh`'s `ok_states` widening from
the earlier pass already accepts `"degraded"` generically for VPN, not tied to any one
reason — confirmed by reading the call site rather than assumed, and re-verified live
against an isolated cache root regardless.

**AIR, CONNECT, NETWORK, and MODEM's remaining case were closed the same way (2026-09-17),
each with its own consumer check first** — same discipline as the VPN/MODEM pass, not
assumed safe just because it worked there:

- **MODEM's third condition**: an empty `upstream_channels`/`downstream_ofdm_channels`
  array (`parse_channel_table()`'s own "table not found"/"has no rows"/"header mapping
  incomplete" notes, previously appended without a state change) now elevates the same
  way the other two MODEM conditions already do. No new consumer work needed — this
  reason is also `"degraded"`, which `fetch_alerts.sh`'s `ok_states` widening from the
  first pass already accepts for MODEM regardless of which of the three reasons caused
  it; confirmed the event-log parsing this feeds stays independent of the channel-table
  parsing either way (separate HTML pages, same as before).
- **AIR**: no cross-domain consumer of `shared/air/` exists in core at all (grepped the
  whole repo). OSA's own `env.lua` reads `status.json`'s `state`, but only special-cases
  `state == "error"` — `"degraded"` falls through to a normal render exactly like AIR's
  own pre-existing `"partial"` state already did, confirmed live by running OSA's actual,
  unmodified `env.lua` against a synthetic degraded cache. `gtex62-osa` was not modified.
- **CONNECT and NETWORK**: both fixes touch only `status.json`; every real consumer found
  (`fetch_net.sh`, OSA's `net.lua`, `gtex62-clean-suite-e`'s `monitor_helpers.lua`) reads
  the *other* file, `current.json`, via plain leaf-field `jq`/`json_query` lookups with
  `//`/fallback chains and never touches `.state` at all — confirmed by reading each
  consumer directly, not just checking file lists. Structurally unaffected regardless of
  what `status.json` says, since they don't read that file.

**VPN and MODEM's field lists were cross-checked against `gtex62-sitrep`'s own display
logic (`lua/suite/vpn.lua`, `lua/suite/pf.lua`), not just the fetch scripts, and the two
gaps that check surfaced were fixed at the source (2026-09-17) rather than left for
Doctor to special-case** — `doctor-missing-conditions.md`'s VPN/MODEM entries have the
full evidence, including the consumer check and live verification below. This remains a
reference-only pass for Doctor itself: `fetch_doctor.sh` still reads each domain's cache
file directly, same as every other provider, never through SitRep's code or cache —
SitRep was mined purely to borrow its already-solved field selection, and was not
modified.

- **VPN**: a failed `wg show` dump degrading `latest_handshake_seconds`/`transfer` to
  `null` was left as-is — `health` already catches it as `"DEAD"`. But
  `tunnel_latency_ms:null` turned out to be a *separate* signal — SitRep's own code
  treats it as going null both when disconnected and when "the ping itself fails while
  otherwise connected," so a lone dropped tunnel ping could leave `tunnel_latency_ms`
  null while `health` still read healthy, with `health` alone unable to catch it.
  `fetch_vpn.sh` now elevates `state` to `"degraded"` for exactly that case, with a note
  naming when the tunnel ping last succeeded.
- **MODEM**: `connectivity_state.status` — the CM1000's own DOCSIS registration state —
  turned out to be SitRep's *primary* modem-health signal (its whole DOCSIS header line
  exists to answer "is the modem actually registered with Comcast," not "did the scrape
  succeed"), and could read a genuine problem value (not `"OK"`, not empty) while
  `status.json`'s top-level `state` stayed `"ok"` — `fetch_modem.py` only ever errored on
  that field's row being *missing*, never on a present-but-bad value. This was a bigger,
  previously unflagged silent gap than the channel-table-header-mapping case (still open,
  left as-is). A fully-unlocked `upstream_channels` array was a second, smaller instance
  of the same shape (SitRep's own average used to silently render it as a plausible
  `0.0`, not a missing-data marker). `fetch_modem.py` now elevates `state` for both.
- **Fixing either required a third file**: `providers/alerts/fetch_alerts.sh` is the only
  other consumer of `vpn.json`/modem `status.json`, and its killswitch-blocking/T3-burst
  detection both gated on a strict `state == "ok"` read — a new `"degraded"` value would
  have silently frozen that detection for as long as the new conditions held, which for
  MODEM's DOCSIS-registration case could mean the entire length of a real outage (exactly
  what T3-burst tracking exists to help corroborate). `load_json()` there now takes an
  `ok_states` tuple; only the VPN/MODEM call sites widen it to `("ok", "degraded")`, since
  the new degraded reasons are provably orthogonal to the specific fields alerts reads
  from each (confirmed by tracing where those fields come from in both fetch scripts).
  Every other call site (pfsense status, pihole, ap_status, ap_clients, mtr) keeps the
  original strict default.
- **Follow-up candidate, not done this pass** (explicitly out of scope per the task that
  drove this fix): SitRep's `vpn.lua`/`pf.lua` currently re-derive "is this degraded"
  from the same raw fields Doctor now also checks (`connectivity_state.status`,
  `upstream_channels[].locked`, `tunnel_latency_ms`) rather than reading the new `state`
  value directly. Once Doctor ships, simplifying SitRep's Lua to read `state` instead
  would remove that duplication — but `state` still falls through to a normal render for
  `"degraded"` today (confirmed, not changed), so SitRep's display is unaffected either
  way in the meantime.

**Full QRH entries now exist (2026-09-20).** Every condition row below has a full procedure
in [`doctor-qrh.md`](../../gtex62-doctor/docs/doctor-qrh.md), in the `gtex62-doctor` repo
beside the suite that renders it. The `Action text` column is DCM's fixed one-line action;
the QRH procedure is the long form that DCM's `PROC:` line names, and the `PROC` column gives
each procedure's exact title (`PROC: NET FALLBACK TTL`). The three rows marked *(none)* — MTR's
IDLE and RUNNING, PFSENSE's HYBRID — are not conditions and have no procedure. DISABLED has
no row here at all; it collapses to the footer pointer (see Disabled Domains).

**Per-domain remediation, verified against every domain's real fetch script and the live
installed profile TOMLs (2026-09-16) — see `doctor-missing-conditions.md` for full
evidence.** These override the generic shape above wherever real behavior diverges from
it (a silent TTL fallback instead of an explicit error, a nested field instead of a
top-level `state`, or wording that would be actively wrong if left generic — e.g. ALERTS
has no API of its own, so "check API key" would be wrong for it). Domains not listed
(SYSTEM, TIME past preflight) use the generic "provider isn't running" line as-is:

`—` does not appear anywhere in the NOTE column below. Every domain's `state` is
trustworthy on its own — zero exceptions, zero domain-specific reads needed.

| Domain | NOTE | Condition | Action text | PROC |
| --- | --- | --- | --- | --- |
| AIR | `ERROR` | missing coordinates | "Set `[location] lat`/`lon` in the air profile or `site.toml`" | `AIR COORDINATES MISSING` |
| AIR | `ERROR` | missing API key | "Set OpenWeather Air Pollution API key in the air profile" | `AIR API KEY MISSING` |
| AIR | `ERROR` | no cache yet | "Check OpenWeather/AirNow API reachability for AIR" | `AIR NO CACHE` |
| AIR | `PARTIAL` | no provider timestamp | "AIR cache has data but no reliable timestamp — check AirNow/OpenWeather API status" | `AIR NO TIMESTAMP` |
| AIR | `DEGRADED` | note starts "openweather source invalid" | "OpenWeather AQI source down — check API key/quota" — fixed at the source 2026-09-17; only fires while the *other* source is still resolving a timestamp, otherwise it's the pre-existing `PARTIAL` row above | `AIR OPENWEATHER DEGRADED` |
| AIR | `DEGRADED` | note starts "airnow source invalid" | "AirNow AQI source down — check API key/quota" — fixed at the source 2026-09-17, same shape as the OpenWeather row above; gated on AirNow actually being enabled, so a site that never configured it doesn't get falsely flagged | `AIR AIRNOW DEGRADED` |
| ALERTS | `STALE` | Missing/stale `banner.json` | "Alerts provider isn't running — check `fetch_alerts.sh` is wired into the refresh loop" — **not** "check API key/network," alerts has no API of its own and always writes `state:"ok"` when it runs at all | `ALERTS NOT RUNNING` |
| AP | `ERROR` | no AP IPs configured | "Set `[ap] ips`/`labels` in `site.toml`" | `AP NO IPS CONFIGURED` |
| AP | `ERROR` | password file not found | "Create `~/.config/zyxel_ap/.pass`" | `AP PASSWORD FILE MISSING` |
| AP | `DEGRADED` | SSH gate tripped | "Check SSH alias / sshpass credentials for AP" — never "check PFSENSE row"; AP's gate and cache are independently self-contained, confirmed not a category-4 dependency despite the architecture doc's cache-layout comment suggesting otherwise | `AP SSH GATE` |
| ASTRO | `ERROR` | missing location | "Set `[location] lat`/`lon` in the astro profile or `site.toml`" | `ASTRO LOCATION MISSING` |
| ASTRO | `MISSING` | TTL reads 60s, can't confirm real vs. fallback | "ASTRO profile TOML has no `[cache]` section — cannot confirm the 60s TTL is configured, not a fallback. Rerun bootstrap if the file is absent; if it exists, add `[cache] refresh_sec` by hand. Then restart the suite." — bootstrap skips a profile that already exists, and `--force` overwrites the whole file, discarding local edits; the launcher reads TTLs once at startup, so the restart is required either way (see `ASTRO FALLBACK TTL`) | `ASTRO FALLBACK TTL` |
| AVIATION | `DEGRADED` | one of metar/taf failing | "`<FIELD>` fetch failing for AVIATION; serving cached data from `<last_ok>`" (field + timestamp straight from `note`) | `AVIATION DEGRADED` |
| AVIATION | `DEGRADED` | both failing | "METAR and TAF both failing for AVIATION; serving cached data" | `AVIATION DEGRADED` |
| AVIATION | `ERROR` | no cache yet | "Check aviationweather.gov reachability for AVIATION" | `AVIATION NO CACHE` |
| CALENDAR | `MISSING` | Missing cache entirely | "Calendar has never run — check `refresh_loop`/`initial_refresh` wiring" — not a credentials message, this provider reads local text files only | `CALENDAR NEVER RUN` |
| CONNECT | `DEGRADED` | note starts "speedtest failing" | "Speedtest failing — check `speedtest` CLI is installed/licensed (`--accept-license --accept-gdpr`)" — fixed at the source 2026-09-17 (`status.json`'s `state` now follows `current.json`'s nested `speedtest.state` instead of staying unconditionally `"ok"`); `speedtest.state:"disabled"` (never enabled in the profile) deliberately still reads `"ok"`, since that's not a failure | `CONNECT SPEEDTEST FAILING` |
| CONNECT | `STALE` | Speedtest stale beyond `max_age_days`, no error (Doctor-derived from `current.json`'s own `age_days`, not `status.json`'s age) | "No speedtest has run in N days (on-demand only, no automatic refresh) — run manually" | `CONNECT SPEEDTEST STALE` |
| GITHUB | `ERROR` | Empty repo registry | "Populate `~/.config/conky/github-traffic-repos.json`" | `GITHUB REGISTRY EMPTY` |
| GITHUB | `ERROR` | fetch failed for one or more repos | "GitHub API fetch failing for: `<repos>` — check `gh auth status`" | `GITHUB FETCH FAILING` |
| GITHUB | `MISSING` | Cache never written (never run) — GITHUB has no `STALE`; see `REFRESH` | "Check `systemctl --user status gtex62-github-traffic.timer`" — GITHUB runs on a systemd timer entirely outside the launcher's `refresh_loop`, so a missing cache means the timer needs attention, not `fetch_github.sh` itself | `GITHUB NEVER RUN` |
| GITHUB | `REFRESH` | Age of last successful fetch (newest `history_days` key, oldest across registry repos) ≥ 10 days — independent of STATE, so it can sit beside `ERROR` or appear alone (Doctor-derived; AGE shows `N/14`) | "GitHub traffic copy is `N`/14 days behind — run `systemctl --user start gtex62-github-traffic.service` now, then check `systemctl --user status gtex62-github-traffic.timer` (timer not firing) and `gh auth status` (fetches failing — an `ERROR` in the same cell). The API keeps only a rolling 14-day window, so older data is lost" | `GITHUB REFRESH` |
| MEDIA | `DEGRADED` | `local_dir` unreachable | "local_dir unreachable — check NAS mount" | `MEDIA LOCAL DIR UNREACHABLE` |
| MEDIA | `OPTIONAL` | `genius_token` unset | Config-completeness, not WARN — informational only ("Genius API not configured — optional") | `MEDIA GENIUS NOT CONFIGURED` |
| MODEM | `ERROR` | password not configured | "Set `[credentials].password` in the modem profile TOML (not `CHANGE_ME`)" | `MODEM PASSWORD NOT SET` |
| MODEM | `DEGRADED` | note starts "modem unreachable" | "Check pfSense NAT path to 192.168.100.1 (modem admin UI)" | `MODEM UNREACHABLE` |
| MODEM | `DEGRADED` | note starts "modem auth failed" | "Check modem credentials in `[credentials].password`" | `MODEM AUTH FAILED` |
| MODEM | `DEGRADED` | note mentions "header mapping incomplete", "not found", or "has no rows" | "Modem admin UI layout may have changed — check the channel-table note in MODEM's status" — fixed at the source 2026-09-17, the last of MODEM's three silent gaps; triggers on either channel table (`usTable`/`d31dsTable`) coming back empty, distinct from the two conditions above and from a merely-missing `connectivity_state` row (still not elevated — a present-but-empty row is different from a present-but-bad value) | `MODEM HEADER MAPPING` |
| MODEM | `DEGRADED` | note starts "modem not registered with Comcast" | "Modem not registered with Comcast (`<connectivity_state.status>`) — check DOCSIS sync, not the scraper" — fixed at the source 2026-09-17 (`fetch_modem.py` now elevates `state` itself); SitRep's own DOCSIS header line treats this field as the primary modem-health signal | `MODEM CONN DEGRADED` |
| MODEM | `DEGRADED` | note starts "no locked upstream channels" | "Modem has no locked upstream channels — check DOCSIS upstream sync" — fixed at the source 2026-09-17; SitRep's own US AVG power average used to silently render this as a plausible `0.0` before the fix | `MODEM NO UPSTREAM LOCK` |
| MTR | `ERROR` | no `ssh_target` configured | "Set `ssh_target` in the mtr profile TOML" | `MTR NO SSH TARGET` |
| MTR | `DEGRADED` | SSH gate tripped | "Check SSH alias / sshpass credentials for MTR (Pi5)" | `MTR SSH GATE` |
| MTR | *(IDLE, not a NOTE)* | `running:false`, trigger inactive | No action — this is idle, not a problem; don't render a WARN for it | *(none)* |
| MTR | *(RUNNING, not a NOTE)* | `running:true`, overnight capture in progress | No action — the capture is doing its job in response to a real condition; the trigger already fired as designed. The gateway-offline problem itself is surfaced by ALERTS' row and DCM's active state, so MTR doesn't duplicate it | *(none)* |
| NET | `MISSING` | profile TOML missing or lacks `[cache] ttl_sec` (`state` stays `"ok"`) | "NET profile TOML missing or has no `[cache] ttl_sec` — VLAN/ping meters are running at the 60s fallback cadence, not 1s. Rerun bootstrap if the file is absent; if it exists, add `[cache] ttl_sec` by hand. Then restart the suite." — the canonical, already-documented instance of the TTL-fallback collision (see Provider Table — Layout above). Bootstrap skips a profile that already exists, and `--force` overwrites the whole file, discarding local edits; the launcher reads TTLs once at startup, so the restart is required either way (see `NET FALLBACK TTL`) | `NET FALLBACK TTL` |
| NET | `STALE` | Missing/not refreshing at all | "NET provider isn't running — check `refresh_loop` is alive" | `NET NOT RUNNING` |
| NETWORK | `DEGRADED` | note starts "null field(s):" | "NIC detection or public-IP lookup failing — check `primary_interface` config and outbound connectivity" — fixed at the source 2026-09-17; the note names exactly which of `wan_ip`/`dns`/`gateway` came back empty (one, two, or all three) | `NETWORK NULL FIELDS` |
| ORB | `MISSING` | TTL reads 60s, can't confirm real vs. fallback | "ORB profile TOML missing or has no `[cache] ttl_sec` — cannot confirm the 60s TTL is configured, not a fallback. Rerun bootstrap if the file is absent; if it exists, add `[cache] ttl_sec` by hand. Then restart the suite." (real TTL and fallback value coincide at 60s, so this genuinely cannot be told apart without the flag; AGE sits under TTL either way, so STATE stays NOMINAL beside the highlighted NOTE — see "STATE's inputs"). Bootstrap skips a profile that already exists, and `--force` overwrites the whole file, discarding local edits; the launcher reads TTLs once at startup, so the restart is required either way (see `ORB FALLBACK TTL`) | `ORB FALLBACK TTL` |
| PFSENSE | `ERROR` | no `ssh_target` configured | "Set `ssh_target` in the pfsense profile TOML" | `PFSENSE NO SSH TARGET` |
| PFSENSE | `DEGRADED` | SSH gate tripped/failed | "Check SSH alias / sshpass credentials" (shared wording with AP/MTR's own gates) | `PFSENSE SSH GATE` |
| PFSENSE | `STALE` | Any one *enabled* sub-cache stale (worst-state-wins on the single row; sub-caches whose flag is off are excluded, and WARN overrides HYBRID) | Name the specific sub-cache (status/router/pfblockerng/ifaces/arp/leases) in DCM's entry, not just "PFSENSE" — a single `degraded`/`STALE` can originate from any one of six independently-gated fetches. Pi-hole is not one of them — see the PIHOLE rows | `PFSENSE SUBCACHE STALE` |
| PFSENSE | `DEGRADED` | An *enabled*, fresh router/pfblockerng/ifaces sub-cache reporting its own non-ok state (independent of the HYBRID rollup; each has its own SSH gate) | Name the sub-cache and its own note, e.g. "`router`: ssh gate tripped" | `PFSENSE SUBCACHE DEGRADED` |
| PFSENSE | *(HYBRID, not a NOTE)* | 1-3 of the four `[providers.pfsense]` sub-flags enabled, every enabled sub-cache fresh | No action — informational, not a problem; don't render a WARN for it. Same treatment as MTR's IDLE row. Text is a template, not a static line: "pfSense is in hybrid mode using N of 4 sub-flags", where N is the number of `[providers.pfsense]` sub-flags enabled at read time (1-3 in this state; the 4 is the fixed flag count). All four flags off is DISABLED (footer pointer only), not this row | *(none)* |
| PIHOLE | `ERROR` | no `ssh_target` configured (`fetch_pihole.sh`: "no ssh_target configured") | "Set `ssh_target` in the `[pihole]` section of the pfsense profile TOML, or `[pihole] ssh_target` in `site.toml`" | `PIHOLE NO SSH TARGET` |
| PIHOLE | `DEGRADED` | SSH gate tripped ("ssh gate tripped") or SSH call failed ("ssh failed") | "Check SSH alias / sshpass credentials for PIHOLE (Pi5)" — never "check PFSENSE row"; PIHOLE's gate (`runtime/pihole`) and cache are independent of pfSense's, same self-containment as AP/MTR | `PIHOLE SSH GATE` |
| SOLAR | `WAITING` | `state:"waiting"` | "SOLAR is waiting on the WEATHER cache — check the WEATHER row, not SOLAR's own config" — defer entirely, don't render SOLAR-specific remediation. The fully-verified category-4 example (`fetch_solar.sh` polls up to 20s for weather's cache, writes explicit `state:"waiting"` if it never appears) | `SOLAR WAITING` |
| SYSTEM | `STALE` | Missing/stale at 1s TTL | "SYSTEM provider isn't running — check `refresh_loop` is alive" | `SYSTEM NOT RUNNING` |
| TIME | `STALE` | Missing/stale at 1s TTL | "TIME provider isn't running — check `refresh_loop` is alive" | `TIME NOT RUNNING` |
| VPN | `ERROR` | "piactl not found" | "PIA client not installed or not on PATH" | `VPN PIACTL MISSING` |
| VPN | `DEGRADED` | note mentions "sudo wg dump failed" or "wg not found", `connectionstate:"Connected"` | "WireGuard stats unavailable — check `/etc/sudoers.d/gtex62-core-vpn`" (or confirm the `wg` binary is installed, per which note text matches) — fixed at the source 2026-09-17, the last of the ten silent gaps closed this pass. Gated on `connectionstate == "Connected"`, not on `health == "DEAD"` directly, so an ordinary voluntary disconnect (which also drives `health` to `"DEAD"`) doesn't get misread as a fetch failure. | `VPN WG STATS DEGRADED` |
| VPN | `DEGRADED` | note starts "tunnel ping failing" | "VPN tunnel ping failing — check tunnel interface routing (transient, or `1.1.1.1` unreachable through the tunnel)" — fixed at the source 2026-09-17 (`fetch_vpn.sh` now elevates `state` itself); a separate failure mode from the sudoers case above, which is deliberately left as-is since `health` already catches it | `VPN TUNNEL PING DEGRADED` |
| WEATHER | `ERROR` | missing credentials/coordinates | "Set API key and `[location] lat`/`lon` in the weather profile" | `WEATHER CONFIG MISSING` |
| WEATHER | `DEGRADED` | one of current/forecast failing | "`<FIELD>` fetch failing for WEATHER; serving cached data from `<last_ok>`" (same pattern as AVIATION) | `WEATHER DEGRADED` |
| WEATHER | `ERROR` | no cache yet | "Check OpenWeather API reachability for WEATHER" | `WEATHER NO CACHE` |

---

## Open Questions

- **MEDIA's remediation entries** — provisional; needs the same script-level
  verification pass the other 20 domains already got (see `doctor-missing-conditions.md`).
- **ORB has no disable mechanism — open item, not fixed.** No `core.toml` flag, and
  `fetch_orb.sh`/`fetch_orb.py` never read a profile `enabled` key, so ORB always runs.
  Doctor cannot show it as DISABLED and there is nothing to point a user at. Needs a
  decision: a profile `enabled` key like the other eleven profile-gated domains (the
  consistent fix — ORB is universal infrastructure, not opt-in), or accept that it is
  unconditionally on. Until then README § Provider Toggles lists it as the one gap.
- **`fetch_lyrics.py`'s `requests` import is unguarded — recorded, not blocking.** The
  import sits at module top level, outside the script's try/except, so a fresh install
  missing `requests` would fail with a traceback and no `status.json` update on every
  poll cycle (5s by default) in which a player is active — idle cycles now take the bash
  fast-path (`506d619`) and never start Python. It is the same silent-failure shape as
  several cases already fixed in this doc (NET's TTL fallback, MODEM's connectivity
  gaps): the provider's own state never reports it, and Doctor would see only a stale
  cache. Read from the code, not reproduced by uninstalling the package. `core-launcher-design.md` already
  lists `requests` (`media`) among the Doctor-only per-domain tool checks, so the fix is
  a dependency check or a graceful failure path in the provider. Not this round.
- **DCM active-state details — two things undefined.** (1) Ordering of entries when several
  are active (`status.json` emits `entries` alphabetical by domain, unranked; overflow is
  resolved — the list scrolls, see Active-state overflow).
  (2) Whether a config-completeness alert with no row NOTE (e.g. `TZ NOT SET (UNUSED)`) raises
  an entry, since the takeover trigger is "an actionable NOTE present" (`status.json` carries
  these separately in `config_alerts`). The PROC-line question is resolved — see Resolved
  Decisions.
- **DCM gauge-row capacity — unconfirmed.** Whether the gauge row fits fifteen domains
  legibly with two-letter codes (and so whether any overflow or widening logic is ever
  needed) has no source in text: it was an assumption, never independently checked. Verify it
  against the real panel once it exists; until then, do not treat fifteen as an established
  limit.
- **AP / WX two-letter codes — unconfirmed.** The design assumes AP and WX read cleanly beside
  the three-letter codes and do not look like an inconsistency. That was never verified in
  text; confirm it against the real panel once it is built.
- **Panels beyond the PROVIDERS table** — the provider table's layout is settled (alphabetical,
  flat, DCM in the left column — see DCM). Still to sketch: config-completeness detail,
  media detail, and whatever else groups outside the provider table itself.
- **`gtex62-clean-suite-e`'s VLAN-flow widget has the same shape of bug the vpn/ap/
  modem/alerts flip caused for SitRep, unfixed — logged here, not fixed, cross-repo.**
  `lua/suite/pf.lua`'s `M.flow_fractions()` reads
  `shared/pfsense/{profile}/ifaces.json` directly with no `enabled`-check and no
  `DISABLED`-state handling, unlike every other suite panel that touches a
  suite-scoped provider (SitRep's `ap.lua`/`vpn.lua`/`pf.lua`/`pihole.lua`/
  `pfblockerng.lua` all correctly check `toml_bool(core_cfg, "providers.pfsense",
  "ifaces", false)`-equivalent gates and render an explicit `DISABLED` word). When the
  file doesn't exist — exactly the shipped `[providers.pfsense] ifaces = false`
  default — `json_query()` returns `nil`, and every VLAN's EMA state initializes to
  `{in_frac=0, out_frac=0}` and never steps, so the arc widget renders a flat, silent,
  empty flow forever, indistinguishable from genuinely zero traffic. Currently masked
  on this machine's live setup (`ifaces = true`, `ifaces.json` exists), so it hasn't
  been visibly hit — but a fresh bootstrap from the shipped example would land exactly
  here on that suite's flagship widget. Verified live (2026-09-17) by tracing
  `refresh()`/`M.flow_fractions()` end to end, not just reading the file list. Deliberately
  **not fixed in this pass** — `gtex62-clean-suite-e` is a separate repo and a separate
  task; needs its own confirmation before touching it.

- **`profiles/time/local.toml` is not strict TOML** (`America/Chicago = ...` — a bare key
  containing `/`). The launcher's awk parse tolerates it; a strict parser rejects the file.
  `fetch_doctor.sh` falls back to a lenient line reader so it sees the same keys the
  launcher does, but any other strict-TOML consumer of that profile would fail.
- **PIHOLE and PFSENSE intended TTLs differ from the launcher defaults.** PIHOLE reports 60
  (the shipped example) while the launcher's fallback is 300; PFSENSE's shipped example sets
  root `cache_ttl_sec = 1` while the launcher default is 5 (the live profile: 30). Doctor
  reports the shipped-example value as "intended"; confirm that is the value to show.

---

## Resolved Decisions

Closed items, moved out of Open Questions. The `status.json` schema they refer to is
documented in the header comment of `providers/doctor/fetch_doctor.sh`.

**Settled by the `fetch_doctor.sh` pass (2026-09-23):**

- **The TTL-fallback flag now has a concrete spec.** `ttl_fallback` (true/false/null) is a
  separate boolean beside `ttl_sec`/`age_sec`; a flagged row reports its *intended*
  `ttl_sec`, never the effective fallback. It never feeds STATE and is evaluated for every
  launcher-loop domain with a TTL key in its profile, not only NET/ORB/ASTRO (see
  Provider Table — Layout). The file is `shared/doctor/{profile}/status.json`.
- **NETWORK's AGE is not blank.** It is a real duration (see the AGE column); it is excluded
  from DCM gauges on the flicker-zone reasoning alone. `fast_track` is `true` only for NET,
  SYSTEM and TIME.
- **GITHUB's loop special-casing is settled** — read directly from its cache files, STATE
  hardcoded PRIVATE, NOTEs raised only for an applicable (existing, enabled) profile; AGE is
  the oldest of the registry repos' newest `history_days` dates, switching to `N/14` once
  `REFRESH` fires (10 days).
- **HYBRID precedence is implemented as specified:** zero enabled flags → DISABLED; 1-3
  enabled and healthy → HYBRID; WARN always overrides; a disabled sub-flag's leftover cache
  is ignored. arp and leases only rewrite inside a status fetch that finds them past their own
  TTL, so their staleness limit is their TTL plus one status cycle.
- **MTR states:** `idle` / `armed` / `running` (see State Vocabulary).
- **Staleness slack:** a row goes WARN when age exceeds `ttl_sec` + 5s, not strictly `ttl_sec`.
  A cache's age peaks just before its next rewrite at one cadence interval plus the
  difference in fetch runtime between two consecutive runs, plus whole-second mtime
  granularity — measured at 120-121s for AP's 120s TTL once the providers' own skip-check
  bug was fixed (see CHANGELOG, "provider cadence fix"). 5s covers that jitter with room
  for a slow SSH round.
- **CALENDAR's TTL stays 86400s** (`[events] cache_ttl_sec`) though the launcher loop
  rewrites its cache every 300s: a dead calendar loop is only caught after 24 hours, an
  accepted consequence of calendar data's real freshness requirement.
- **DCM overflow scrolls** (see Active-state overflow) instead of showing a "+N MORE" count,
  advancing one whole entry block at a time.
- **No gauge legend.** The AP/WX two-letter exception is not stated on the panel.
- **Doctor's own liveness:** the suite compares `status.json`'s own write time
  (`generated_epoch`) with the clock; older than 30s (6x the provider's 5s loop) the DOC header
  line reads `DOCTOR STALE - <N>S` instead of the alert summary, so a dead doctor loop is not
  mistaken for a healthy widget.
- **SOLAR's shipped example now ships `[cache] refresh_sec = 300`,** so a fresh bootstrap no
  longer raises FALLBACK TTL for it (it previously did, with no example file to restore from).
  The live astro, network and solar profiles were given their `[cache] refresh_sec` keys the same
  day, clearing the three flags on this host.
- **AGE and the DCM gauges tick at 1s** while STATE/NOTE stay on the 5s doctor loop. The
  provider emits each row's `cache_file`; the suite re-reads those mtimes once a second with a
  single `stat` and recomputes duration ages against the clock, so resets and motion show
  immediately. The one consequence: for up to a loop an AGE past its TTL can display before the
  row's STATE follows.
- **TTL cell labels** — `ON DEMAND` (CONNECT), `TIMER` (GITHUB), `WRITE` (MEDIA), `TRIGGER`
  (MTR), `VARIES` (PFSENSE) — are emitted as `ttl_label` display hints, approved as
  implemented.
- **Every condition has a QRH procedure, so no DCM entry has a null PROC.** Added: DOMAIN NOT
  LISTED, PFSENSE SUBCACHE DEGRADED, UNRECOGNIZED NOTE (the generic fallback entry), and FALLBACK
  TTL (the generic form of the per-domain fallback procedures).
- **A PROC line names a QRH procedure by its exact title** (e.g. `PROC: NET FALLBACK TTL`);
  the PROC column in Actions / Remediation maps every row.
- **`fetch_doctor.sh` emits `proc` and `detail`, never remediation prose.** The suite maps a
  procedure title to DCM's fixed action line; `detail` carries only the dynamic part (a
  sub-cache name, a day count, a repo list, the provider's note).
- **`doctor.toml.example` and the `[doctor]` flip are done:** the toggle gates
  `fetch_doctor.sh` only for a suite that lists `"doctor"` in `[domains]`.

**Resolved earlier, moved here from Open Questions:**

- PFSENSE's nested enable path — **resolved by the footer change.** The footer is a
  fixed pointer to README § Provider Toggles (see Disabled Domains), not a file path, so
  the top-level vs. `[providers.pfsense]` distinction no longer needs a per-row note.
- Silent-gap field lookup table — **resolved, not just answered.** All ten confirmed
  silent-gap conditions were closed at the source instead of needing a Doctor-side
  lookup table; see the Fifth Category note in Actions/Remediation above.
- MTR's RUNNING highlight treatment — **resolved.** RUNNING carries no actionable
  NOTE and does not highlight under the NOTE-keyed rule (see Highlight rule). It is the
  overnight capture correctly doing its job in response to a real condition — the trigger
  already fired as designed, so there is no action for the row itself. The underlying
  gateway-offline problem is already surfaced by ALERTS' own row and DCM's active state, so
  MTR doesn't duplicate that signal.
- GITHUB: `REFRESH` vs. `STALE` precedence, GITHUB's AGE format, and what "last
  successful run" reads from — **resolved.** `STALE` is dropped for GITHUB entirely, so
  there is no precedence question and no `STALE` threshold to define (see NOTE Column).
  `REFRESH` is driven by the age of the newest `history_days` key, which advances only on
  a real successful pull — closing the earlier gap where an alive-but-failing timer kept
  file timestamps fresh while history was being lost. GITHUB's AGE is in the timestamp
  group as a date-level `YYYY-MM-DD` (no script change), switching to `N/14` once
  `REFRESH` is active (see AGE column).
- PRIVATE vs. DISABLED for GITHUB — **resolved as a design decision, not a derivation
  problem.** GITHUB's STATE is hardcoded PRIVATE, never computed from its `enabled` key,
  `status.json` or any live signal: it is a fixed fact about which domain this is, since no
  user besides the maintainer can meaningfully enable it. GITHUB was never a real member
  of the OPTIONAL / ship-disabled-defaults group, so it was deleted from both rather than
  reworded. This is the same underlying fact as the loop special-case below, not a second
  question.
- **NETWORK's AGE is treated as blank — permanent by design, or a
  gap?** The sole unresolved case among the blank AGEs. NET, SYSTEM and TIME are blank
  by the 1s fast-track reasoning in the AGE column section and are not part of this
  question. NETWORK (5s TTL) sits just above that line: the AGE column lists it in the
  duration group, DCM excludes it as too close to the flicker zone, and whether its blank
  AGE is deliberate or a gap has never been confirmed. Independent of DCM, which simply
  inherits the answer.
- **The TTL-fallback flag has no concrete spec — open, narrowed.** The behavior is settled: Doctor
  derives `MISSING` for NET, ORB and ASTRO by checking each profile's existence and cache-TTL
  key directly, never from AGE/TTL (`doctor-missing-conditions.md`, NET and ORB entries), and
  STATE stays derived independently of it (see "STATE's inputs"). What is not specified
  anywhere is the flag itself: whether `doctor.json` needs a dedicated real-vs-fallback field,
  what it is called, and where that is specified. The name is also unsettled — the scaffold
  plan's `fetch_doctor.sh` writes `shared/doctor/{profile}/status.json`, not `doctor.json`. A
  related unknown: which TTL a flagged row reports — the intended one (NET's 1s) or the effective
  fallback (60s). It decides NET's STATE: against 1s the fallback's climbing AGE reads WARN;
  against 60s it would read NOMINAL beside `MISSING`, like ORB and ASTRO. `providers/doctor/` does not exist yet, so
  there is nothing to check this against.

---

## Repo / Scaffold Plan

Same sequence as SitRep's build:

- New repo `gtex62-doctor`, directory structure copied wholesale from `gtex62-sitrep`
  (`lua/suite/`, `lua/ui/frame.lua`, `theme/`, `scripts/`, `docs/`, `CLAUDE.md`).
- `palette.lua` copied wholesale from OSA/SitRep — same catalog, single dense panel.
- LICENSE (MIT), `.markdownlint.json`, `.vscode/` stubs, matching SitRep's extras.
- Git init on `main` directly.
- README states the divergence up front: Doctor has no suite-specific rendering logic,
  it exists purely to surface core's own health — no mode submenu, palette/wallpaper
  submenus once the core-launcher consolidation lands, same as SitRep.

Core-side (built 2026-09-23):

- `providers/doctor/fetch_doctor.sh <profile>` — no SSH/gate, same shape as
  `providers/alerts/fetch_alerts.sh`: reads every other domain's cache file/mtime, checks
  enable state (`core.toml [providers]` flag, or a profile-gated domain's own
  `state:"disabled"` — see Disabled Domains), surfaces any `degraded`/`state` field a provider
  already exposes (aviation's pattern), and derives the `ttl_fallback` flag from each profile's
  cache-TTL key rather than from AGE/TTL (see Provider Table — Layout). Writes
  `shared/doctor/{profile}/status.json`; schema in the script's header comment.
- `examples/runtime/suites/doctor.toml.example` — `required` list closer to the full
  provider list than a curated subset (including `pihole`, which the launcher suite-gates like
  vpn/ap/modem/alerts/mtr, and `doctor` itself, which gates the provider), since Doctor's entire
  purpose is reporting on all of them.
- `[doctor] enabled = true` flipped from inert placeholder to load-bearing, with a code comment
  in `bin/gtex62-core-launch` noting the toggle predates the implementation — same pattern as
  the vpn/ap/modem/alerts flip before SitRep.

---

## Migration Notes (from tech-hud / tri-hud reference)

| tech-hud / tri-hud check | Core equivalent |
| --- | --- |
| Per-suite config/cache dir checks | Generic: loop over `core.toml` providers and each domain's profile `enabled` / `state` |
| Weather deps/cache, MÉTAR/TAF checks | Folded into TTL/cadence + aviation's existing `degraded` state |
| `config/owm.vars LAT=` / `LON=-` placeholder check | Config-completeness entries in DCM |
| Fonts, SSH, Music/Lyrics deps | DISABLED / OPTIONAL rows, inline alphabetically, not a separate section per suite |
| tech-hud's `Actions` remediation line | Actions/Remediation lookup table above |
| tri-hud's OPTIONAL (pfSense enabled) row | OPTIONAL state, informational not a problem |
