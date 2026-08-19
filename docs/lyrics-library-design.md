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
  Artist - Title.txt                     sanitized filename (see sanitize_key in reference)
  Artist - Title.lrc                     LRC-timestamped variant, also supported

shared/media/[profile]/
  lyrics.json                            ephemeral: resolved lines for current track only
  status.json                            provider health
```

`local_dir` is a single configured path, not hardcoded to `~/Music/Lyrics`. It may be a
symlink to network storage (e.g. NAS-backed music libraries) — the provider does not need
to know or care what's on the other end of the path, only that it's configured and
reachable.

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
local_dir             = "/home/gtex62/Music/Lyrics"   # resolves through symlink if present
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
- **Per-profile vs. single shared library.** Current design assumes one lyrics library
  regardless of which machine/profile is running the suite. Confirm this holds — if
  different machines should have different libraries, `local_dir` may need to move under
  `[profile]` rather than being global.
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
