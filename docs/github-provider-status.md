# GitHub Provider Status

Current implementation state of the core `github` provider: script location, output
schema, configuration, and known constraints. Written Oct 1, 2026 to close a
provider-documentation coverage gap identified across `docs/` — `github` had never had
its own doc; see [Core Docs](README.md)'s Provider Reference intro for the other domains
in the same position. Personal-use provider (own GitHub traffic stats only), but nothing
in the script or this doc is private — no tokens or repo names are committed anywhere;
see Configuration below.

Companion docs: [Architecture](architecture.md) (provider pattern, cache layout — github's
TTL row there says only `"varies"`, which this doc resolves), [Doctor Missing
Conditions](doctor-missing-conditions.md)'s GITHUB section (the investigation this doc's
findings are drawn from).

---

## Implementation Status

### `providers/github/fetch_github.sh` + `fetch_github_traffic.py` ✓ COMPLETE

Thin bash wrapper (`fetch_github.sh`, 7 lines, same split as `fetch_modem.sh`/
`fetch_modem.py`) delegating to a Python script that owns everything: TOML loading,
GitHub API calls via the `gh` CLI, atomic writes, and the status envelope.

- Pulls `repos/{repo}/traffic/clones` (14-day rolling window, GitHub's own retention
  limit) via `gh api` for each repo in a registry file, auths through whatever `gh auth`
  session is already active on the host — no API key/token handling in this codebase at
  all.
- Merges each fetch's `clones` entries into a **per-day history dict keyed by date**,
  carried forward run over run (`existing.get("repos")` loaded and updated, not
  replaced) — this is how it tracks lifetime totals past GitHub's 14-day API window,
  since each successful run's 14 days get folded into the running history before the
  oldest ones would otherwise age out.
- `complete_lifetime` flag: true once a repo is more than 14 days old *and* has been
  polled continuously since before that cutoff, i.e. the running history dict actually
  has full coverage rather than a gap from before polling started — computed once and
  cached (`existing_repo.get("complete_lifetime")`) rather than recomputed every run,
  with a manual per-repo `complete_lifetime` override available in the registry entry.
- Writes one `{repo_slug}.total` file per repo (e.g. `GH0042`) alongside `current.json`
  for whatever suite renders it as a simple string meter.

### No launcher integration — entirely systemd-timer-driven

**Resolved, not "varies"** (contrast with Architecture's TTL table entry): unlike every
other domain, `github` has **no `initial_refresh` or `refresh_loop` entry anywhere in
`gtex62-core-launch`** — it sits completely outside the launcher's per-domain TTL
mechanism. Cadence is owned entirely by a systemd user timer:

```text
systemd/user/gtex62-github-traffic.timer   — OnBootSec=10m, OnUnitActiveSec=12h, Persistent=true
systemd/user/gtex62-github-traffic.service — oneshot, runs fetch_github_traffic.py directly
                                              (not through fetch_github.sh)
```

Effective real-world cadence is whichever is longer: the 12h timer interval, or the
script's own 6h internal `cache_ttl_sec` skip-if-fresh check — in practice, ~12h. A
missing `profiles/github/<profile>.toml` is harmless here (unlike NET/ORB's TTL-fallback
risk): `load_toml()` returns `{}`, and `if profile and not profile.get("enabled", True)`
short-circuits to "proceed as enabled" for a falsy/empty profile, so the script just runs
with code defaults (`cache_ttl_sec=21600`).

The service unit's `ExecStartPost` also copies the cache directory and the repo registry
file to a NAS backup path (`/mnt/NAS_Data/Data/Linux/backups/conky/misc/`) when that path
is writable — a personal backup step, not part of the provider contract.

**Doctor implication:** a Doctor check for this domain should verify
`systemctl --user status gtex62-github-traffic.timer` is active, not a `refresh_loop`/
profile-TOML remediation — that's the wrong layer for this one domain.

---

## Output Schema

### status.json

`shared/github/{profile}/status.json` — written by `fetch_github_traffic.py`.

```json
{
  "state": "error",
  "profile": "default",
  "collector": "github",
  "generated_at": "2026-10-01T14:23:00Z",
  "note": "fetch failed for: owner/repo-a, owner/repo-b"
}
```

Flat envelope, same shape as `vpn.json`/`pihole.json` (`profile`/`collector`/
`generated_at`/`note`) — no per-field sub-objects, no `ssh_gate`.

#### State Field Values

| Value | Meaning |
| --- | --- |
| `"ok"` | Every configured repo's `gh api` call succeeded this run (or the run was skipped as still-fresh under `cache_ttl_sec`) |
| `"error"` | `profile disabled` (not actually possible — see below), `"no repos configured"` (empty registry), or **`"fetch failed for: <repos>"`** (one or more `gh api` calls failed) |
| `"disabled"` | Only reachable if a profile TOML exists *and* sets `enabled = false` explicitly — the shipped template ships `enabled = false` by default (see Configuration), so this is actually the common first-run state, not a rare one |

**Known convention mismatch, not fixed here:** a **partial** failure (some repos
succeeded, some didn't) is reported as `state: "error"`, the same as a *total* failure —
this domain has no `"degraded"` state. Every other provider with a per-item or per-field
failure mode (`weather`'s `current`/`forecast` split, `aviation`'s `metar`/`taf` split,
`network`'s null-field check) uses `"degraded"` for "some but not all failed" and reserves
`"error"` for "nothing usable came back." `github` predates that convention and was never
retrofitted. In practice this under-reports: a Doctor check reading only `state` can't
tell "every repo is failing" from "nine repos are fine and the tenth hit a rate limit"
without parsing `note`'s repo list by hand. Flagged here; not fixed, since fixing it means
touching the one domain actually in regular personal use and there's no live incident
forcing it.

### current.json

`shared/github/{profile}/current.json` — written by `fetch_github_traffic.py`.

```json
{
  "generated_at": "2026-10-01T14:23:00Z",
  "updated_at_epoch": 1759327380,
  "profile": "default",
  "repos": {
    "owner/repo-a": {
      "source": "github_api_traffic_clones",
      "window_count": 12,
      "window_uniques": 4,
      "lifetime_count": 340,
      "lifetime_uniques": 58,
      "complete_lifetime": true,
      "repo_created_at": "2026-01-15T03:22:10Z",
      "note": null,
      "history_days": {
        "2026-09-30": { "timestamp": "2026-09-30T00:00:00Z", "count": 2, "uniques": 1 }
      }
    }
  }
}
```

`window_count`/`window_uniques` are GitHub's raw 14-day-window totals, passed through
unmodified. `lifetime_count`/`lifetime_uniques` are summed from this script's own
`history_days` accumulator (see Implementation Status above), not from GitHub — they're
only as complete as the repo's polling history, which `complete_lifetime` flags. Keyed
by full `owner/repo` slug; `{repo_slug}.total` files (alongside this) replace `/` with
`_` for filesystem-safe filenames.

---

## Configuration

`profiles/github/{profile}.toml`:

```toml
profile_id = "default"
enabled = false   # ships false on purpose — see comment in the example template

[repos]
# registry_path = "~/.config/conky/github-traffic-repos.json"

[request]
cache_ttl_sec = 21600   # 6h; GitHub traffic data changes at most hourly
```

**GITHUB has no `core.toml [providers]` flag of its own** — unlike vpn/ap/modem/alerts/
mtr, the profile's own `enabled` key is the *only* toggle, and the shipped template sets
it `false` by default so a fresh bootstrap doesn't start polling an unconfigured registry
(this reasoning is documented inline in
`examples/runtime/profiles/github/default.toml.example`).

**Repo registry** (`~/.config/conky/github-traffic-repos.json`, default path) — not part
of either git repo, not an example/template file:

```json
{ "repos": ["owner/repo-a", { "repo": "owner/repo-b", "note": "side project" }] }
```

Entries can be a plain string or an object with `note` and an optional
`complete_lifetime` override (see Implementation Status above). `GITHUB_TRAFFIC_REPOS`
(comma-separated) can append extra repos via environment variable without touching the
registry file — used for one-off/ad-hoc tracking.

**Auth** — entirely delegated to `gh`'s own credential storage (`gh auth login`), not
read or stored by this codebase in any form.

---

## Known Constraints

- **No `"degraded"` state** — see the convention-mismatch note above.
- **14-day API window** means a polling gap longer than 14 days (timer disabled, host
  off, `gh auth` expired) silently loses whatever clone activity happened entirely inside
  the gap — `lifetime_count` undercounts for that stretch with no flag raised, since
  `complete_lifetime` only tracks "has polling run continuously since before the repo
  turned 14 days old," not "did any individual gap exceed 14 days."
- **No rate-limit handling** — `gh api` failures (including a 403 rate-limit response)
  are indistinguishable from any other fetch failure in `note`; all get folded into the
  same `"fetch failed for: <repos>"` message.
- **`fetch_github.sh` is a pure pass-through** — always worth checking
  `fetch_github_traffic.py` directly when debugging; the shell wrapper adds nothing of
  its own beyond argv forwarding.

---

## Remaining Work

- [ ] `"degraded"` state for partial multi-repo failure, matching weather/aviation/
      network's convention — not fixed, see Known convention mismatch above.
- [ ] No Doctor-side verification yet that `gtex62-github-traffic.timer` is active
      (the correct remediation layer per this doc's own finding) — doctor-design.md's
      GITHUB row should be checked against this once Doctor's per-domain checks are
      implemented for this domain.
- [ ] No dedicated session/verification history exists for this domain predating this
      doc — reconstructed from reading the script and systemd units directly, not from
      prior prose or a live incident.

---

## Session History

- **Oct 1, 2026 — This doc written; first pass.** No code changes. Backfills the
  documentation gap identified while updating [Core Docs](README.md)'s Provider
  Reference index and the domain lists in [README.md](../README.md)/
  [Architecture](architecture.md) (both were missing the `doctor` domain; see those
  files' own history). Findings here are drawn from reading
  `fetch_github_traffic.py`, both systemd units, and the shipped profile template
  directly, cross-checked against [Doctor Missing Conditions](doctor-missing-conditions.md)'s
  prior GITHUB investigation rather than duplicating it.
