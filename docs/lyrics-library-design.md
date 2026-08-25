# Lyrics Library — Core Domain Design

Design for promoting tech-hud's lyrics handling to a core-owned domain, shared across
all suites. Split out from the broader media domain design (player status, cover art)
because this piece is expected to change more as it gets used.

Reference implementation: `gtex62-tech-hud/lua/widgets/music.lua`,
`gtex62-tech-hud/config/lyrics.vars`.

---

## Core Distinction: Library vs. Cache

Tech-hud's lyrics handling isn't just a cache — `LYRICS_LOCAL_DIRS` and
`LYRICS_CACHE_DIR` point at the same directory, which makes fetched lyrics permanently
"local" once written. A user can manually edit a lyrics file (better formatting, fixed
line breaks, corrected timestamps) and that edit persists indefinitely, since local-dir
lookup happens before any online fetch.

This means the lyrics directory is **user-curated content**, not disposable cache. It
must not live under `$GTEX62_CACHE_DIR` or any path that a cache-clear script might wipe.
Everything else the media domain produces (player status, cover art, resolved lines for
the *current* track) is disposable and regenerates on its own — this directory is the
one exception.

| | Library (`~/Music/Lyrics` or wherever configured) | Ephemeral cache (`shared/media/[profile]/`) |
| --- | --- | --- |
| Contents | One file per track, user-editable | Current-track state only |
| Survives cache clear | Yes — must | No — expected to be wiped/regenerated |
| Written by | Provider fetch (write-through), or manually by user | Provider, every poll cycle |
| Read by | Provider lookup (first check) | Suite widget (draw time) |

---

## Directory Structure

```text
[configured local_dir]/                  persistent, user-editable, survives cache clears
  Artist - Title.txt                     natural-case filename (primary — see below)
  Artist - Title.lrc                     LRC-timestamped variant, also supported

shared/media/[profile]/
  lyrics.json                            ephemeral: resolved lines for current track only
  status.json                            provider health
```

`local_dir` is a single configured path, not hardcoded to `~/Music/Lyrics`. It may be a
symlink to network storage (e.g. NAS-backed music libraries) — the provider does not need
to know or care what's on the other end of the path, only that it's configured and
reachable.

**Filename: natural-case primary, sanitized fallback — not sanitized-only.** Verified
against the real 489-file library: only 13 files (2.7%) are already all-lowercase: the
rest carry the artist/title's natural case (`10cc - I'm Not in Love.lrc`,
`Aerosmith - Get The Lead Out (2012 Remaster).lrc`). This matches the reference
implementation exactly — `save_cached_lyrics()` writes `Artist - Title.ext` (natural
case, unmodified) first, falling back to `sanitize_key(artist) - sanitize_key(title)`
only when the natural-case path fails to open for writing (filesystem-illegal characters,
e.g. `AC/DC` — the handful of all-lowercase files in the real library, like
`ac dc - are you ready.lrc`, are exactly this fallback case). `find_local_lyrics()`
checks both name variants on lookup, natural-case first. The core provider preserves this
dual-name scheme exactly — a sanitized-only lookup would miss ~97% of the real library.

---

## Lookup / Write-Through Order

Preserves tech-hud's existing behavior exactly — this is a promotion of working logic to
core, not a redesign of the logic itself:

1. **Local check.** Look for `[local_dir]/[sanitized artist - title].txt` (or `.lrc`).
   If found, use as-is. This is where manual edits live and take precedence permanently.
2. **Online fetch.** If not found locally and online is enabled (`is_offline` check
   passes), try configured providers in order (e.g. `lrclib`, `lyrics_ovh`).
3. **Write-through.** On successful fetch, write the result into `local_dir` — not into
   a separate cache directory. This is what promotes a fetched track to "local" for every
   future lookup.
4. **Publish.** Write resolved, display-ready lines (post LRC-stripping, normalization)
   to `shared/media/[profile]/lyrics.json` for suite widgets to read at draw time.

Suite widgets never call providers or touch `local_dir` directly — they only read
`lyrics.json`. All fetch/lookup/write-through logic lives in the core provider.

---

## Config

Move out of per-suite `config/lyrics.vars` into core-level config (`site.toml` or
equivalent), same tier as other install-specific values (pfSense host, AP IPs, etc. per
the conversion guide's §0.6 hardcoded-values inventory).

```toml
[media.lyrics]
local_dir             = "/mnt/NAS_Music/Lyrics/"      # single shared library, global — not per-profile
enable_local          = true
enable_online         = true
providers_noapi       = ["lrclib", "lyrics_ovh"]       # order = preference
# providers_scrape     = []                             # optional, may break, opt-in
providers_api         = ["genius"]
genius_token          = ""                              # gitignored, not committed
strip_lrc_timestamps  = true
curl_silent           = true
```

**Secret handling:** `genius_token` must carry forward the same gitignore treatment as
the current `widgets/lyrics.vars` entry. If config moves to `site.toml`, either keep the
token in a separate gitignored file that `site.toml` references, or gitignore the
specific config file that holds it — do not let it land in a committed core config file.

---

## Failure Handling

The local directory may be unreachable — NAS not mounted, symlink dangling, permissions
issue. This needs an explicit path, since it wasn't a concern when the directory was
always local to the suite's own machine:

- **On lookup failure** (can't read `local_dir`): skip local check, proceed to online
  fetch as if nothing was found locally. Do not treat an unreachable directory as "no
  lyrics exist" — that would trigger unnecessary re-fetches once the path is back.
- **On write-through failure** (fetched successfully, but can't write to `local_dir`):
  still publish the fetched lines to `lyrics.json` for the current draw cycle — the
  widget should show lyrics even if the library write failed. Log the write failure to
  `status.json` so it's visible, but don't block on it. The result: a temporary NAS
  outage costs a re-fetch next time, not a blank widget.
- **On total failure** (no local, no online, offline detected): `lyrics.json` reflects
  "no lyrics available" state; suite widget already handles this per its existing
  inactive/empty display logic.

---

## Migration Notes (from tech-hud reference)

| tech-hud function | Core equivalent |
| ------------------ | ---------------- |
| `load_lyrics_vars()` | Replaced by core config read (`site.toml` section above) |
| `get_local_dirs()` | Single configured `local_dir`, not a comma-separated list — see open question below |
| `get_cache_dir()` | Removed — local dir and write-through target are now the same path by design |
| `resolve_lyrics_lines()` | Moves to core provider; suite widget instead reads `lyrics.json` |
| `is_offline()`, `get_online_check_hosts()` | Moves to core provider |
| `normalize_lyrics_text()`, `strip_lrc_prefix()`, `is_lrc_text()` | Moves to core provider (text processing happens before publish, not at draw time) |
| `sanitize_key()` | Moves to core provider (used for both lookup and write-through filenames) |

Suite-side `music.lua` shrinks to: read `lyrics.json`, apply `wrap_lines_for_width` /
marquee / max-lines display logic — all rendering concerns, nothing fetch-related.

---

## Open Questions

- **Multiple read dirs vs. single write target.** Tech-hud's `LYRICS_LOCAL_DIRS`
  supports a comma-separated list. Current design collapses this to one `local_dir` for
  simplicity (one write target, one source of truth). If there's a real case for reading
  from multiple existing collections while writing to one canonical path, revisit —
  keep read as a list, write as a single target.
- ~~**Per-profile vs. single shared library.**~~ **Resolved.** One shared library,
  regardless of which machine/profile is running the suite: `local_dir` is a single
  global path (`/mnt/NAS_Music/Lyrics/`, NAS-backed) configured once in `site.toml`, not
  duplicated per profile. The `[profile]` output namespace (`shared/media/[profile]/`)
  still applies to the *ephemeral* `lyrics.json`/`status.json` — only the library path
  itself is global.
- ~~**`.txt` vs `.lrc` precedence.**~~ **Resolved.** Current library (475 files) has no
  same-track duplicates across formats, so this isn't a live conflict — but the rule is
  codified now to prevent write-through from creating one later:
  - **Lookup:** check `.lrc` first, then `.txt`. LRC carries strictly more information
    (timestamps), so if both ever exist, the richer format wins.
  - **Write-through:** write with the extension matching the provider's native output
    format — `.lrc` from `lrclib`, `.txt` from `lyrics_ovh`. Don't convert formats on
    write.
  - **Collision guard:** if a fetch would produce a file in a different format than one
    that already exists locally for that track, do not overwrite. A manually-edited
    local file — regardless of format — always wins over a fresh fetch. This extends the
    "manual edits are permanent" principle from the local-check-first design to also
    cover format mismatches, not just presence/absence.

---

## Write-Through Safety

Resolves the three remaining gaps (concurrent writers, write atomicity, filename
collisions) flagged by a stronger-model review of the design above.

### Governing principle

**`local_dir` is create-only from the provider's perspective.** Write-through may only
introduce a filename (either extension) that does not currently exist. No code path ever
replaces an existing library file. Every rule below — the format-collision guard, the
concurrent-writer answer, "manual edits always win" — reduces to this one sentence.
Treat it as the single invariant to enforce, not three separate scenarios.

### Concurrent write-through

Two machines/suites racing to write the same new track. No locking, no lock files —
explicitly rejected: stale-lock risk on a crashed writer, `flock()` semantics vary by NAS
mount type, and it buys nothing once writes are already no-clobber. Instead:

1. Each writer writes to its own uniquely-named temp file **in the same directory** as
   the final destination: dotfile-prefixed, `.tmp.<hostname>.<pid>` suffix. Invisible to
   library scans/music software, and never collides between writers.
2. Immediately before rename, re-check the destination for **both** extensions (`.lrc`
   and `.txt`) — and, per the natural-case/sanitized-fallback dual naming above, **both**
   name variants where they differ, four paths total. Same check the format-collision
   guard already requires, just repeated at rename time. If any now exists, another
   writer won: delete the temp file, publish the in-memory fetched copy to `lyrics.json`
   anyway, done. Nothing lost.
3. Rename only into a nonexistent destination. Plain `os.replace()`/`mv` after the check
   above is correct enough — the race window is milliseconds, and a file that fresh can't
   yet contain a manual edit. If available, prefer a true no-replace rename
   (`os.link()` + unlink the temp, treating `EEXIST` as "lost the race") — fall back to
   check-then-rename if the NAS mount rejects hardlinks (varies by SMB config).

### Write atomicity

Same temp-then-rename pattern as `fetch_pfsense.sh` (`.tmp` + `os.replace()`), with three
library-specific additions — a bad file here has no TTL and never self-heals, unlike
cache:

- **Never rename an empty/whitespace-only payload into place.** Require a
  non-empty-after-trim sanity check before rename. This is the single biggest real risk
  in the write path: an empty successful fetch would permanently poison that track,
  since local-check-first means it's never re-fetched.
- **Check the close, not just the write.** On NFS, errors can surface only at `close()`;
  only a fully successful write-and-close proceeds to rename.
- **Orphaned-temp cleanup.** Sweep `local_dir` for temp-pattern files older than 24 hours
  and delete, once per provider run. Safe across all writers/hosts since no legitimate
  write takes anywhere near 24 hours.
- **Skip fsync before rename** — not needed. Worst case on a crash is losing an
  unrenamed fetch, recovered by one re-fetch next run, same cost the design already
  accepts elsewhere.

### `sanitize_key()` collisions — known limitation

Left unhandled, by design — a documented limitation, not a runtime guard. Two
`(artist, title)` pairs that sanitize identically will share one file; the rarer track
displays the wrong lyrics; a human notices and can manually edit or accept it.

Deliberately **not** adding detection-without-resolution (e.g. embedding `[ar:]`/`[ti:]`
tags and verifying at lookup) — that degrades worse than doing nothing, since a mismatch
would force a permanent re-fetch loop under the create-only rule above.

**Verified, not assumed:** a one-time offline check ran the real filename-derived
`(artist, title)` inventory from the live library through `sanitize_key()` —
**489 files, 489 distinct sanitized keys, zero collisions.** (The library has grown from
475 files, referenced earlier in this doc, to 489 since that count was taken; the result
holds at both sizes.) The "known limitation" above is a verified fact for this library
as of 2026-08-25, not an assumption.

---

## Implementation & Verification (2026-08-25)

Implemented as `providers/media/fetch_lyrics.sh` (thin wrapper) +
`providers/media/fetch_lyrics.py` (all logic — text processing, HTTP fetch, write-through
safety), same shape as `fetch_modem.sh`/`fetch_modem.py`. Wired into
`bin/gtex62-core-launch` as a gated provider (`core.toml [providers] media`), same pattern
as vpn/ap/modem/alerts. Config lives in `site.toml [media.lyrics]` only — no
`profiles/media/*.toml`, per the resolved global-library question above.

**Real-library gap found and fixed during verification:** the Directory Structure
section's original "sanitized filename" description didn't match the reference
implementation's actual behavior. `save_cached_lyrics()` writes natural-case
`Artist - Title.ext` first, falling back to the sanitized form only when the natural name
has filesystem-illegal characters — confirmed against the real library (97.3% natural-case,
2.7% sanitized-fallback). A sanitized-only lookup, as originally drafted, would have missed
the vast majority of the real 489-file library. Fixed in both the doc (Directory Structure
section, above) and the implementation (`find_local()`/`write_through()` check/write both
name variants, raw first) before this was caught by live testing rather than by a user bug
report.

**Verified live**, against the real NAS mount (`//nas.gtex62.lan/NAS Music` via CIFS at
`/mnt/NAS_Music/Lyrics/`) and real tracks (playerctl against an actual playing track, real
lrclib.net fetch):

- Local-hit lookup against real natural-case library entries (`10cc - I'm Not in
  Love.lrc`) and real sanitized-fallback entries (`ac dc - are you ready.lrc`, from an
  artist name with a filesystem-illegal `/`).
- Full local-check → online-fetch → write-through → publish cycle end to end: played
  "Surfin' Bird" by The Trashmen (confirmed absent from the library beforehand), fetched
  from lrclib, wrote `The Trashmen - Surfin' Bird.lrc` into the real library, published
  matching lines to `lyrics.json`. Re-running against the same now-playing track
  short-circuits to the local-hit path, and the library file's checksum is unchanged
  across repeated runs (create-only holds).
- Format-collision guard: a manually-created `.txt` blocks a fetched `.lrc` from being
  written for the same track; the existing file is left untouched.
- Empty/whitespace-only payload is refused before ever reaching the write step.
- Unreachable `local_dir` is correctly detected (distinct from "not found").
- Orphaned temp-file sweep: a synthetic 25-hour-old temp is deleted, a fresh one is kept.
- **Concurrent write-through, genuinely raced**: two real OS processes (`multiprocessing`,
  distinct simulated hostnames/PIDs) targeting the same new track. First without any
  induced delay (single winner, no corruption); then with a deliberate stall inserted
  right before one process's `os.link()` call — forcing that process's rename-time
  re-check to pass (see nothing yet) and its actual `os.link()` to hit `EEXIST`, the
  harder branch, not just the cheap pre-check. Both runs: exactly one file created, exactly
  the winner's content, zero corruption, zero leftover temp files, hardlinks confirmed
  supported on this CIFS mount.
- Throttle/miss-retry state machine math checked directly against `FETCH_THROTTLE_SEC`
  (30s) and `MISS_RETRY_SEC` (12h) boundaries.

All test artifacts were written under a disposable `.claude_writethrough_test/`
subdirectory of the real library and removed afterward, except the one deliberate,
permanent, correct addition: `The Trashmen - Surfin' Bird.lrc`, fetched and written
through the real pipeline as the end-to-end verification track.
