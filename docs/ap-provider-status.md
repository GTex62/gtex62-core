# AP Provider Status

Implementation state of the core `ap` provider — the Zyxel access-point domain.
Split into its own doc rather than a subsection of
[pfSense Provider Status](pfsense-provider-status.md): different device class
(Zyxel WBE530/NWA-series, not pfSense/FreeBSD), different auth model (password
via `sshpass`, not key-based SSH), and its own provider directory
(`providers/ap/`, not `providers/pfsense/`) — the shared thread with the
pfSense domains is only that its two output files live under the same
`shared/pfsense/{profile}/` cache directory (see Output Location below).

Companion docs: [pfSense Provider Status](pfsense-provider-status.md) (gate
pattern, TOML resolution, atomic-write convention this provider reuses),
[SitRep Relocation Plan](archive/sitrep-relocation-plan.md) (archived/superseded — the
resume checklist this provider unblocked).

---

## Implementation Status

### `providers/ap/fetch_ap.sh` ✓ IMPLEMENTED (Aug 19, 2026)

New provider directory — first core provider with password-based SSH auth.
Implements:

- Site-TOML resolution for AP IPs/labels/cache TTL (`[ap]` section, parallel
  to `[pihole]`) via the same `parse_root_value`/`parse_section_value` awk
  helpers used by `fetch_pihole.sh`
- Cache TTL check before SSH (skips poll if cache is fresh)
- **One SSH session per AP** (was 3 sessions/AP = 9 connections total across
  the legacy `ap_status_all_clients.sh` for 3 APs) — batches
  `show version` + `show cpu status` + `show wireless-hal station info` into
  a single `sshpass`/`ssh -tt` heredoc per device
- Gate integration via `providers/pfsense/pf-ssh-gate.sh` (reused directly,
  not duplicated) with its own state dir (`runtime/ap`) — see Auth &
  Transport below for why this domain's gate semantics differ slightly from
  the pfSense domains'
- Atomic JSON write via Python + `os.replace()`, same as `fetch_pihole.sh`
- Output to `shared/pfsense/{profile}/ap_status.json` and
  `shared/pfsense/{profile}/ap_clients.json`

### Output Location

Both output files live under `shared/pfsense/{profile}/`, **not** a new
`shared/ap/` tree, per the schema originally sketched in
[pfSense Provider Status § AP Provider](pfsense-provider-status.md). This was
kept as-is: SitRep's cache-consumer view model reads all pfSense-domain-family
files from one directory per profile, and AP data is scoped to the same site
profile as the router it's attached to.

---

## Auth & Transport

**Zyxel password auth — a permanent hardware constraint, not a TODO.** The
WBE530/NWA-series APs do not support key-based SSH. `fetch_ap.sh` preserves
the legacy `zyxel_cmd.sh` transport's exact credential-storage approach rather
than introducing a new one: a hardcoded path,
`$HOME/.config/zyxel_ap/.pass`, read by `sshpass -f`. This path is
intentionally **not** made TOML-configurable — one fixed place credentials
live, matching the legacy convention exactly. SSH options
(`PubkeyAuthentication=no`, `KbdInteractiveAuthentication=yes`,
`PreferredAuthentications=keyboard-interactive,password`, `-tt` for a
pseudo-tty the Zyxel CLI requires) are ported unchanged from `zyxel_cmd.sh`.

**Gate semantics differ subtly from the single-target pfSense domains.** The
`runtime/ap` gate is shared across all 3 physical APs (matching legacy
behavior — `pf-ssh-gate.sh` was never per-device there either), but:

- A single AP being unreachable (timeout/connection refused) does **not**
  trip the gate and does **not** degrade the envelope `state` — that AP's
  entry just gets `"online": false` in `ap_status.json`/`ap_clients.json`
  while the envelope stays `"ok"`. Confirmed with the user (Aug 19, 2026)
  before implementing, since this is a one-provider-many-targets shape none
  of the existing gate consumers have.
- An **auth failure** (permission denied, host key failure, etc. — same
  `should_trip_gate()` string-matching ported from `zyxel_cmd.sh`) does trip
  the shared gate, and the envelope `state` becomes `"degraded"` for that run
  — matching how the pfSense-family domains already treat a tripped gate.
  Because the gate is shared and re-checked before each AP's SSH attempt
  inside the same run, an auth failure on AP1 cascades to skip AP2/AP3 in
  that run too — this is the same cascade the legacy scripts exhibited
  (`zyxel_cmd.sh` re-checks `pf-ssh-gate.sh allow` internally before every
  call), not a new behavior.

**Verified (Aug 19, 2026):** live run against all 3 physical APs — all 3
authenticated successfully (rc=0, gate reset each time), confirming the
sshpass/keyboard-interactive transport works end-to-end from the new provider
location.

---

## Output Schemas

Both files share the same `state`/`ssh_gate`/`profile`/`collector`/
`generated_at` envelope used by every other domain
(`status.json`/`router.json`/`pfblockerng.json`/`pihole.json`) — **this
supersedes the flatter `generated_at` + `aps[]` sketch originally drafted in
[pfSense Provider Status § AP Provider](pfsense-provider-status.md)**; that
sketch predates this decision and should not be read as the final shape.
`ssh_target` is set to the literal string `"ap-fleet"` rather than a single
host, since this domain polls 3 targets under one shared gate, not one.

### ap_status.json

```json
{
  "state": "ok",
  "profile": "main_router",
  "collector": "ap_status",
  "generated_at": "2026-08-19T05:11:19Z",
  "ssh_target": "ap-fleet",
  "ssh_gate": { "status": "OK", "tripped": false, "left_seconds": 0, "reason": "" },
  "aps": [
    { "label": "CLOSET",     "ip": "192.168.40.4", "online": true, "model": "NWA130BE", "cpu_pct": 2, "clients": 9 },
    { "label": "OFFICE",     "ip": "192.168.40.5", "online": true, "model": "NWA130BE", "cpu_pct": 2, "clients": 8 },
    { "label": "GREAT ROOM", "ip": "192.168.40.6", "online": true, "model": "NWA130BE", "cpu_pct": 2, "clients": 13 }
  ]
}
```

`model` is whatever `show version` reports for that device (confirmed live:
the fleet actually reports `NWA130BE`, not `WBE530` as the doc's original
placeholder example assumed — `ap_ipmap.csv`'s comments still say WBE530,
that's just a device label, not the `show version` model string).
`clients` is a **raw count of `MAC:` lines** in `show wireless-hal station
info` output — ported unchanged from `ap_status_all_clients.sh`'s
`grep -cE '^[[:space:]]{2}MAC:'`. `model`/`cpu_pct` are `null` and `clients`
is `0` when `online` is `false`.

### ap_clients.json

```json
{
  "state": "ok",
  "profile": "main_router",
  "collector": "ap_clients",
  "generated_at": "2026-08-19T05:11:19Z",
  "ssh_target": "ap-fleet",
  "ssh_gate": { "status": "OK", "tripped": false, "left_seconds": 0, "reason": "" },
  "mismatch_total": 0,
  "aps": [
    {
      "label": "CLOSET",
      "ip": "192.168.40.4",
      "online": true,
      "clients": [
        { "mac": "aa:bb:cc:dd:ee:ff", "ip": "192.168.20.12", "name": "Ka Nght Stnd" }
      ],
      "unknown": [],
      "mismatches": []
    }
  ]
}
```

**The join** (per AP, per SSH session): `show wireless-hal station info`
returns one `index: N` block per associated station, each with a `MAC:` line
immediately followed by an `IPv4:` line (confirmed live — this pairing is
reliable and 1:1, unlike the legacy script's approach, see below). The
provider pairs each `MAC:` with the very next `IPv4:` line, then (as of
Aug 20, 2026 — see Device Map below) joins the **MAC** against
`devices.toml`: a match produces a `{mac, ip, name}` entry in `clients`; no
match puts the **raw IP** (not an object) in `unknown`, per the schema
originally sketched in
[pfSense Provider Status § AP Provider](pfsense-provider-status.md). IPs of
`0.0.0.0` or `172.29.*` are dropped entirely before the join, matching
`ap_clients_named.sh`'s `extract_ips` filter exactly.

**A real MAC↔IP join is new — the legacy scripts didn't do one.**
`ap_clients_named.sh` never associates a specific MAC with a specific IP; it
globally extracts and dedupes all `IPv4:` lines in the output, decoupled from
which station block they came from. The new provider's block-scoped
`MAC:`→next-`IPv4:` pairing is stricter and is what makes the `mac` field in
`ap_clients.json` meaningful at all. This was flagged as the most
join-logic-ambiguous part of this domain and confirmed with the user
(Aug 19, 2026) by pulling a live raw sample first — see Auth & Transport
above for the verification run.

**Known discrepancy, preserved not fixed:** because `ap_status.json`'s
`clients` count is a *raw* `MAC:` line count and `ap_clients.json`'s
known+unknown count is *IP-filtered*, the two can legitimately disagree on a
given AP (e.g. one station reporting `0.0.0.0` before acquiring a lease). This
is not a bug in the port — the two legacy scripts already disagreed the same
way (confirmed live, Aug 19, 2026: OFFICE showed 8 raw `MAC:` lines vs. 7
filtered/known, on **both** the legacy scripts and the new provider,
identically). Fixing it would be a design change, not a port — out of scope
here.

**MAC/IP mismatch detection (`MSMTCH`) — IMPLEMENTED (Aug 22, 2026).** For
every client whose MAC resolves to a known `devices.toml` entry (i.e. every
entry that lands in `clients[]`), the provider also compares the client's
*current* IP (from the AP's own station table, same value already in that
entry's `ip` field) against `devices.toml`'s *documented* `ip` field for
that MAC. A difference produces an entry in a new per-AP `mismatches[]`
array — same shape/placement pattern as `unknown[]` — holding
`{mac, ip, documented_ip, name}`: `ip` is the live value, `documented_ip`
is what `devices.toml` says it should be. The matching `clients[]` entry is
left unchanged (unaffected by whether a mismatch was found) — a mismatched
client still appears in both `clients[]` and `mismatches[]`. Per-AP count is
simply `mismatches[].length`; a top-level `mismatch_total` integer (sibling
of `aps[]`) sums it network-wide, per the two-level display design in
[SitRep Design Notes § Access Points panel](../../gtex62-sitrep/design/sitrep-design-notes.md)
(network-wide total feeds the future alert banner, per-AP breakdown shows
how many of that AP's own clients are contributing to the total). The two
`ip:`-keyed no-MAC WLED placeholder entries are skipped by design, same as
the existing client join — they have no real MAC to check a mismatch
condition against.

`load_devicemap()` was extended, not duplicated, to support this: it now
returns `{mac: (display_name, documented_ip)}` instead of
`{mac: display_name}`, so the one MAC→devices.toml lookup built in the Aug
20, 2026 join-migration session now also feeds this check — no second
parallel lookup was written.

**Verified (Aug 22, 2026):** `jq .` valid on live output; `mismatch_total`
is `0` across all 3 APs on the live fleet (every currently-connected known
client's IP matches its documented `devices.toml` entry today). Spot-check:
manually confirmed one live client (MAC `e2:77:2c:da:18:09`, the "A14"
phone, connected to CLOSET at the time) against `devices.toml`'s documented
IP for that MAC (`192.168.30.20`) — exact match, consistent with the
network-wide 0-mismatch result. Simulated-mismatch test: ran the provider a
second time against a scratch copy of `devices.toml` (real file untouched,
confirmed via unchanged mtime/checksum afterward) with that same MAC's `ip`
deliberately changed to a wrong value, pointed at a throwaway cache
directory — `mismatch_total` correctly went from `0` to `1`, attributed to
the correct AP (CLOSET, where that client was actually connected), with the
correct `documented_ip` in the flagged entry.

### Device Map

**Updated Aug 20, 2026 — migrated from `ap_ipmap.csv` to `devices.toml`.**
`fetch_ap.sh` now joins each client's `mac` against
`~/.config/gtex62-core/devices.toml` (MAC-keyed, covers all 5 VLANs). The
path is resolved directly from `CONFIG_ROOT`, same convention as
`PROFILE_TOML`/`SITE_TOML` — not TOML-configurable. See
[pfSense Provider Status § Device Inventory](pfsense-provider-status.md) for
`devices.toml`'s schema and how it was built/validated, and that doc's
Session History for the join-migration entry (cross-check results, etc.).

Originally (through Aug 19, 2026) this provider instead read
`config/ap_ipmap.csv` under `GTEX62_CONFIG_DIR` — a core-owned manual-sync
copy of `gtex62-tech-hud/config/ap_ipmap.csv`, IP-keyed, kept because the
engine must stay suite-agnostic (`gtex62-tech-hud` is read-only for this
effort and, per [SitRep Relocation Plan](archive/sitrep-relocation-plan.md)
(archived/superseded), the engine must never depend on a suite directory
existing). That copy is no
longer read by this provider as of the migration above; neither it nor the
read-only tech-hud original were edited or deleted — both still exist,
untouched. `[ap] ipmap_path` in `site.toml` is now unused, dead
configuration (see Configuration below).

---

## Configuration

`site.toml`:

```toml
[ap]
enabled = true
cache_ttl_sec = 120
ips = "192.168.40.4,192.168.40.5,192.168.40.6"
labels = "CLOSET,OFFICE,GREAT ROOM"
ipmap_path = "config/ap_ipmap.csv"
```

`ips`/`labels` are comma-separated strings (not TOML arrays) — matches the
`parse_section_value` awk helper's single-value-per-key capability, same
convention as every other domain's site.toml section. Index-paired: `ips[0]`
gets `labels[0]`. `ipmap_path` is unused as of Aug 20, 2026 (see Device Map
above) — left in the live `site.toml` and this example rather than cleaned
up, since removing dead config wasn't part of that session's scope.

---

## Verification (Aug 19, 2026)

**Mechanical:** `jq .` valid on both files; all 3 AP entries populated in
both, live run against real hardware (not a fixture).

**Cross-check against both legacy scripts, live, read-only:**

| Field | `ap_status_all_clients.sh` | `fetch_ap.sh` → `ap_status.json` | Match |
| --- | --- | --- | --- |
| CLOSET model/cpu/clients | NWA130BE / 3% / 9 | NWA130BE / 2% / 9 | Model+count exact; cpu_pct differs by 1 (sampling drift between two independent `show cpu status` calls, expected) |
| OFFICE model/cpu/clients | NWA130BE / 3% / 8 | NWA130BE / 2% / 8 | Same as above |
| GREAT ROOM model/cpu/clients | NWA130BE / 2% / 13 | NWA130BE / 2% / 13 | Exact |

| Field | `ap_clients_named.sh` | `fetch_ap.sh` → `ap_clients.json` | Match |
| --- | --- | --- | --- |
| CLOSET known names (9) | Ka Frn, Ka Nght Stnd, Ka Piano, Lx Chime, Lx Drbll, Lx M Bed, Lx Wrk Rm, Ro C Wrkout, Ro M Bed | identical set | Exact |
| OFFICE known names (7) | AirG1, Ka Comp, Lx Cave, Rachio, Ro C, S24U, WLED Win | identical set | Exact |
| GREAT ROOM known names (13) | A14, Ka End T, Litr, Lx Aqr, Lx Frnt Ent, Lx G Rm, Lx Ktchn, Lx Lvng Rm, Ro C Bed, Ro G Rm, SubZ, Taurus, WLED Aqr | identical set | Exact |

All three APs' known-client name sets matched **exactly**, including the
OFFICE raw-vs-filtered count discrepancy discussed above, which reproduced
identically on both the legacy scripts and the new provider. No `unknown`
entries on any AP in this run (every currently-associated client is in
`ap_ipmap.csv`).

---

## Remaining Work

- [x] Expand `config/ap_ipmap.csv` → `devices.toml` with a MAC column
      (tracked in [pfSense Provider Status § Device Inventory](pfsense-provider-status.md),
      Aug 20, 2026) and move `fetch_ap.sh`'s join from IP-keyed to MAC-keyed
      (Aug 20, 2026 — see Device Map above) — done in two sessions, both
      complete. The join is now immune to a device's IP drifting.
- [x] Sync mechanism for the core-owned `ap_ipmap.csv` copy — moot as
      predicted: `devices.toml` replaced it as `fetch_ap.sh`'s join source
      (Aug 20, 2026), so the copy's staleness no longer matters to this
      provider. The file itself still exists, untouched and now unread (see
      Device Map above).
- [ ] `gtex62-tech-hud`'s legacy `ap_status_all_clients.sh` /
      `ap_clients_named.sh` remain untouched and in production — no
      migration of the suite itself happens in this session (guardrail).
- [x] MAC/IP mismatch detection (`MSMTCH`) — `mismatches[]` per AP +
      top-level `mismatch_total` in `ap_clients.json` (Aug 22, 2026 —
      see the MSMTCH subsection above). Core-side only; SitRep's
      `MSMTCH` header-row display and alert-banner wiring remain
      design-only (see
      [SitRep Design Notes § Access Points panel](../../gtex62-sitrep/design/sitrep-design-notes.md)).
