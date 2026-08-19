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
[SitRep Relocation Plan](sitrep-relocation-plan.md) (the resume checklist this
provider unblocks).

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
  "aps": [
    {
      "label": "CLOSET",
      "ip": "192.168.40.4",
      "online": true,
      "clients": [
        { "mac": "aa:bb:cc:dd:ee:ff", "ip": "192.168.20.12", "name": "Ka Nght Stnd" }
      ],
      "unknown": []
    }
  ]
}
```

**The join** (per AP, per SSH session): `show wireless-hal station info`
returns one `index: N` block per associated station, each with a `MAC:` line
immediately followed by an `IPv4:` line (confirmed live — this pairing is
reliable and 1:1, unlike the legacy script's approach, see below). The
provider pairs each `MAC:` with the very next `IPv4:` line, then joins the IP
against `ap_ipmap.csv` (see IP Map below): a match produces a `{mac, ip,
name}` entry in `clients`; no match puts the **raw IP** (not an object) in
`unknown`, per the schema originally sketched in
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

### IP Map

`fetch_ap.sh` reads `config/ap_ipmap.csv` under `GTEX62_CONFIG_DIR`
(`~/.config/gtex62-core/config/ap_ipmap.csv` by default) — a **core-owned
copy** of `gtex62-tech-hud/config/ap_ipmap.csv`, made because the engine must
stay suite-agnostic (`gtex62-tech-hud` is read-only for this effort and, per
[SitRep Relocation Plan](sitrep-relocation-plan.md), the engine must never
depend on a suite directory existing). This copy is a plain manual sync as of
Aug 19, 2026, not a symlink or generated artifact — **re-copy manually if the
tech-hud original changes** until `devices.toml` (see Remaining Work below)
replaces it. Path is configurable via `[ap] ipmap_path` in `site.toml`
(relative to `GTEX62_CONFIG_DIR`).

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
gets `labels[0]`.

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

- [ ] Expand `config/ap_ipmap.csv` → `devices.toml` with a MAC column
      (tracked in [pfSense Provider Status § Device Inventory](pfsense-provider-status.md))
      — once that lands, `fetch_ap.sh`'s join can move from IP-keyed to
      MAC-keyed, which would also let it identify a device that changed IP
      without editing the map.
- [ ] Decide a real sync mechanism for the core-owned `ap_ipmap.csv` copy
      (manual re-copy is a known drift risk, see IP Map above) — likely moot
      once `devices.toml` replaces both copies.
- [ ] `gtex62-tech-hud`'s legacy `ap_status_all_clients.sh` /
      `ap_clients_named.sh` remain untouched and in production — no
      migration of the suite itself happens in this session (guardrail).
