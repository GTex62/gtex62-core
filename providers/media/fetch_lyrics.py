#!/usr/bin/env python3
# providers/media/fetch_lyrics.py
# Core lyrics-library provider. Promotes gtex62-tech-hud's
# lua/widgets/music.lua lyrics logic (local-check -> online-fetch ->
# write-through -> publish) to a shared core provider — same working
# behavior, not a redesign. See docs/lyrics-library-design.md for the full
# design, including the "Write-Through Safety" section this implements.
#
# Config is global (site.toml [media.lyrics]), not per-profile — one shared
# library regardless of which machine/suite is running (see design doc's
# "Per-profile vs. single shared library", resolved). PROFILE_ID below only
# scopes the *ephemeral* output (shared/media/[profile]/{lyrics.json,
# status.json}), matching every other domain's output convention.
#
# local_dir is a persistent, user-editable, NAS-backed library — never
# treated as disposable cache. Write-through is create-only: it may only
# introduce a filename that does not currently exist. No code path here
# ever replaces an existing library file.
import json
import os
import re
import socket
import sys
import time
import tomllib
from pathlib import Path
from urllib.parse import quote

import requests

HOME = Path(os.path.expanduser("~"))
XDG_CACHE_HOME = Path(os.getenv("XDG_CACHE_HOME") or (HOME / ".cache"))
CONFIG_ROOT = Path(os.getenv("GTEX62_CONFIG_DIR") or os.getenv("GTEX62_CONKY_CONFIG_DIR") or (HOME / ".config" / "gtex62-core"))
CACHE_ROOT = Path(os.getenv("GTEX62_CACHE_DIR") or os.getenv("GTEX62_CONKY_CACHE_DIR") or (XDG_CACHE_HOME / "gtex62-core"))
PROFILE_ID = sys.argv[1] if len(sys.argv) > 1 else "local"
SITE_TOML = CONFIG_ROOT / "site.toml"
OUT_DIR = CACHE_ROOT / "shared" / "media" / PROFILE_ID
TMP_DIR = CACHE_ROOT / "tmp"
LYRICS_JSON = OUT_DIR / "lyrics.json"
STATUS_JSON = OUT_DIR / "status.json"
STATE_JSON = OUT_DIR / "lyrics_state.json"
ORPHAN_STAMP = OUT_DIR / "lyrics_orphan_sweep.stamp"

HOSTNAME = socket.gethostname() or "unknown"
PID = os.getpid()

DEFAULT_LOCAL_DIR = str(HOME / "Music" / "Lyrics")
DEFAULT_PROVIDERS_NOAPI = ["lrclib", "lyrics_ovh"]
FETCH_TIMEOUT_SEC = 8
FETCH_THROTTLE_SEC = 30
MISS_RETRY_SEC = 12 * 3600
ORPHAN_TEMP_MAX_AGE_SEC = 24 * 3600
ORPHAN_SWEEP_INTERVAL_SEC = 6 * 3600
MAX_BYTES = 200_000

TEMP_NAME_RE = re.compile(r"^\.tmp\.[^.]+\.\d+$")

# -----------------------------------------------------------------------
# Config
# -----------------------------------------------------------------------


def load_toml(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        with open(path, "rb") as f:
            return tomllib.load(f)
    except Exception:
        return {}


def load_config():
    site = load_toml(SITE_TOML)
    cfg = ((site.get("media") or {}).get("lyrics") or {})
    return {
        "local_dir": str(cfg.get("local_dir") or DEFAULT_LOCAL_DIR),
        "enable_local": bool(cfg.get("enable_local", True)),
        "enable_online": bool(cfg.get("enable_online", True)),
        "providers_noapi": list(cfg.get("providers_noapi") or DEFAULT_PROVIDERS_NOAPI),
        "strip_lrc_timestamps": bool(cfg.get("strip_lrc_timestamps", True)),
        "max_bytes": int(cfg.get("max_bytes") or MAX_BYTES),
        # providers_api / genius_token are accepted for config parity with the
        # tech-hud reference (widgets/lyrics.vars carried the same fields) but
        # are inert here — the reference implementation never actually wired
        # genius into fetch_online_lyrics() either. Not a regression; promoting
        # working logic only. See docs/lyrics-library-design.md.
        "providers_api": list(cfg.get("providers_api") or []),
        "genius_token": str(cfg.get("genius_token") or ""),
    }


# -----------------------------------------------------------------------
# Generic helpers
# -----------------------------------------------------------------------


def now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def atomic_write(path: Path, content: str):
    """Standard cache-envelope write (lyrics.json/status.json/state file) —
    temp-then-rename within CACHE_ROOT, same idiom as fetch_pfsense.sh. Not
    used for library writes — those need same-directory temps on local_dir
    itself; see write_through() below."""
    path.parent.mkdir(parents=True, exist_ok=True)
    TMP_DIR.mkdir(parents=True, exist_ok=True)
    tmp = TMP_DIR / f"{path.name}.tmp.{PID}"
    tmp.write_text(content, encoding="utf-8")
    tmp.replace(path)


def sanitize_key(s: str) -> str:
    s = (s or "").lower()
    s = re.sub(r'[/\\:*?"<>|]', " ", s)
    s = re.sub(r"\s+", " ", s).strip()
    return s


def library_stem(artist: str, title: str) -> str:
    return f"{sanitize_key(artist)} - {sanitize_key(title)}"


def normalize_lyrics_text(s):
    if not s:
        return s
    s = s.replace("\\\\n", "\n").replace("\\n", "\n")
    s = s.replace("\r\n", "\n").replace("\r", "\n")
    s = re.sub(r"<\s*[Bb][Rr]\s*/?>", "\n", s)
    s = re.sub(r"[ \t]+(\n)", r"\1", s)
    s = re.sub(r"[ \t]+$", "", s)
    return s


def strip_lyrics_ovh_header(text):
    if not text:
        return text
    parts = text.split("\n", 1)
    if len(parts) != 2:
        return text
    first, rest = parts
    f = re.sub(r"\s+", " ", first).strip().lower()
    if f.startswith("paroles de la chanson "):
        return rest
    return text


LRC_TAG_RE = re.compile(r"^\[\d+:\d+\.?\d*\]")


def is_lrc_text(s):
    return bool(s) and re.search(r"\[\d+:\d+\.?\d*\]", s) is not None


def strip_lrc_prefix(line, strip_timestamps):
    if not strip_timestamps:
        return line
    out = line or ""
    while LRC_TAG_RE.match(out):
        out = LRC_TAG_RE.sub("", out, count=1)
    if out.startswith(" "):
        out = out[1:]
    return out


def is_instrumental(text):
    t = (text or "").strip()
    return t in ("Instrumental", "instrumental")


# -----------------------------------------------------------------------
# playerctl
# -----------------------------------------------------------------------


def read_cmd(argv):
    try:
        import subprocess

        out = subprocess.run(argv, capture_output=True, text=True, timeout=5).stdout
    except Exception:
        return None
    out = (out or "").strip()
    return out or None


def get_player():
    status = read_cmd(["playerctl", "status"]) or ""
    if status not in ("Playing", "Paused"):
        return status, "", ""
    artist = read_cmd(["playerctl", "metadata", "xesam:artist"]) or ""
    title = read_cmd(["playerctl", "metadata", "xesam:title"]) or ""
    return status, artist, title


# -----------------------------------------------------------------------
# Local lookup
# -----------------------------------------------------------------------


def local_dir_reachable(local_dir: str) -> bool:
    try:
        os.listdir(local_dir)
        return True
    except OSError:
        return False


def all_dest_paths(local_dir: str, raw_stem: str, safe_stem: str):
    """Every filename this track could legitimately live under. Two name
    variants (raw_stem, safe_stem — deduped when equal) x two formats. The
    real library is
    predominantly natural-case (raw_stem) — only ~2.5% of the live 489-file
    library is all-lowercase — matching the reference implementation's
    actual on-disk behavior (save_cached_lyrics tries the natural-case stem
    first, falling back to the sanitized form only when the natural name
    contains filesystem-illegal characters). A single sanitized-only scheme
    would miss the vast majority of the real library on lookup."""
    stems = [raw_stem] if raw_stem == safe_stem else [raw_stem, safe_stem]
    return [os.path.join(local_dir, f"{s}.{ext}") for s in stems for ext in ("lrc", "txt")]


def find_local(local_dir: str, raw_stem: str, safe_stem: str):
    """Lookup precedence: raw (natural-case) before sanitized fallback, .lrc
    before .txt within each — same combined order as tech-hud's reference
    find_local_lyrics(). LRC carries strictly more information (timestamps),
    so if both formats exist for a name variant, the richer format wins."""
    for stem in ([raw_stem] if raw_stem == safe_stem else [raw_stem, safe_stem]):
        for ext in ("lrc", "txt"):
            p = os.path.join(local_dir, f"{stem}.{ext}")
            if os.path.isfile(p):
                return p, ext
    return None, None


def read_lines_from(path, max_bytes):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            data = f.read(max_bytes)
    except OSError:
        return None
    return data.split("\n")


# -----------------------------------------------------------------------
# Online fetch
# -----------------------------------------------------------------------


def online_check_hosts(providers_noapi):
    hosts = []
    for name in providers_noapi:
        if name == "lyrics_ovh" and "api.lyrics.ovh" not in hosts:
            hosts.append("api.lyrics.ovh")
        elif name == "lrclib" and "lrclib.net" not in hosts:
            hosts.append("lrclib.net")
    return hosts or ["api.lyrics.ovh"]


def is_offline(providers_noapi):
    try:
        with socket.create_connection(("1.1.1.1", 443), timeout=2):
            pass
    except OSError:
        return True
    for host in online_check_hosts(providers_noapi):
        try:
            socket.getaddrinfo(host, 443)
            return False
        except OSError:
            continue
    return True


def fetch_lrclib(artist, title):
    """Returns (text, forced_ext) — lrclib tells us the format directly
    (syncedLyrics vs plainLyrics), no need to guess."""
    try:
        r = requests.get(
            "https://lrclib.net/api/get",
            params={"artist_name": artist, "track_name": title},
            timeout=FETCH_TIMEOUT_SEC,
        )
        if r.status_code != 200:
            return None
        data = r.json()
    except (requests.RequestException, ValueError):
        return None
    synced = normalize_lyrics_text(data.get("syncedLyrics"))
    if synced and synced.strip():
        return synced, "lrc"
    plain = normalize_lyrics_text(data.get("plainLyrics") or data.get("lyrics"))
    if plain and plain.strip():
        return plain, "txt"
    return None


def fetch_lyrics_ovh(artist, title):
    """Returns (text, forced_ext). forced_ext is always None here — unlike
    lrclib, lyrics.ovh doesn't tell us the format; fetch_online() falls back
    to is_lrc_text() to classify it, same as the reference."""
    url = f"https://api.lyrics.ovh/v1/{quote(artist)}/{quote(title)}"
    try:
        r = requests.get(url, timeout=FETCH_TIMEOUT_SEC)
        if r.status_code != 200:
            return None
        data = r.json()
    except (requests.RequestException, ValueError):
        return None
    text = normalize_lyrics_text(data.get("lyrics"))
    text = strip_lyrics_ovh_header(text)
    if not text or not text.strip():
        return None
    return text, None


FETCHERS = {
    "lrclib": fetch_lrclib,
    "lyrics_ovh": fetch_lyrics_ovh,
}


def fetch_online(artist, title, providers_noapi):
    """Returns (text, ext, provider_name) on hit, or (None, None, None)."""
    for name in providers_noapi:
        fn = FETCHERS.get(name)
        if not fn:
            continue
        result = fn(artist, title)
        if not result:
            continue
        text, forced_ext = result
        if is_instrumental(text):
            return "instrumental", None, name
        if text and text.strip():
            ext = forced_ext or ("lrc" if is_lrc_text(text) else "txt")
            return text, ext, name
    return None, None, None


# -----------------------------------------------------------------------
# Write-through — see docs/lyrics-library-design.md, "Write-Through Safety".
# Create-only: may only introduce a filename that does not currently exist.
# Never replaces an existing library file, under any circumstance.
# -----------------------------------------------------------------------


def write_through(local_dir: str, raw_stem: str, safe_stem: str, ext: str, text: str):
    """Returns (path, wrote: bool, error). `path` is set whenever a file for
    this track now exists at one of its legitimate locations — whether this
    call wrote it or a concurrent writer won the race. `wrote` distinguishes
    the two for status.json reporting. `error` is set only on a genuine
    failure (never on a lost race — that's success from the caller's
    perspective: publish proceeds either way, per the design's
    failure-handling rules).

    Target naming: raw_stem (natural case) first, falling back to safe_stem
    only if raw_stem can't be used as a path — matches the reference
    implementation's save_cached_lyrics(), which is why the real library is
    predominantly natural-case rather than sanitized-lowercase."""
    dests = all_dest_paths(local_dir, raw_stem, safe_stem)
    stem_candidates = [raw_stem] if raw_stem == safe_stem else [raw_stem, safe_stem]

    if not text or not text.strip():
        return None, False, "empty/whitespace-only payload refused before write"

    # Cheap pre-check: format-collision guard / another writer already done,
    # under either name variant.
    for p in dests:
        if os.path.isfile(p):
            return p, False, None

    tmp = os.path.join(local_dir, f".tmp.{HOSTNAME}.{PID}")
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(text)
            f.flush()
        # `with` block's __exit__ calls close(); a deferred write error on the
        # NAS mount surfaces there and is caught below, not just on write().
    except OSError as e:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return None, False, f"write/close failed: {e}"

    # Rename-time re-check — the actual race guard. Milliseconds have passed
    # since the pre-check; another writer may have landed a file in either
    # format, either name variant, for this same track in that window.
    for p in dests:
        if os.path.isfile(p):
            try:
                os.unlink(tmp)
            except OSError:
                pass
            return p, False, None

    # True no-replace rename via hardlink, raw_stem first. EEXIST specifically
    # means we lost the race (another writer just landed this exact target);
    # any other OSError means this stem variant isn't a usable path here
    # (illegal characters) or hardlinks aren't supported on this mount —
    # try the next stem variant, if any.
    for stem in stem_candidates:
        target = os.path.join(local_dir, f"{stem}.{ext}")
        try:
            os.link(tmp, target)
            os.unlink(tmp)
            return target, True, None
        except FileExistsError:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            return target, False, None
        except OSError:
            continue

    # Hardlink unavailable on this mount for every stem variant tried.
    # Fallback: check-then-rename against safe_stem, which is always a valid
    # path (sanitize_key strips anything filesystem-illegal). Re-check once
    # more (belt and suspenders, cheap) then a plain replace — correct
    # enough per the design doc: the race window left is milliseconds, too
    # fresh to contain a manual edit.
    for p in dests:
        if os.path.isfile(p):
            try:
                os.unlink(tmp)
            except OSError:
                pass
            return p, False, None
    target = os.path.join(local_dir, f"{safe_stem}.{ext}")
    try:
        os.replace(tmp, target)
        return target, True, None
    except OSError as e:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return None, False, f"rename failed: {e}"


def sweep_orphaned_temps(local_dir: str):
    """Once-per-run-ish (gated by ORPHAN_STAMP), delete stale write-through
    temp files older than 24h. Safe across all writers/hosts — no legitimate
    write takes anywhere near that long."""
    now = time.time()
    try:
        names = os.listdir(local_dir)
    except OSError:
        return
    for name in names:
        if not TEMP_NAME_RE.match(name):
            continue
        p = os.path.join(local_dir, name)
        try:
            st = os.stat(p)
            if now - st.st_mtime > ORPHAN_TEMP_MAX_AGE_SEC:
                os.unlink(p)
        except OSError:
            continue


def maybe_sweep_orphans(local_dir: str):
    try:
        age = time.time() - ORPHAN_STAMP.stat().st_mtime
        if age < ORPHAN_SWEEP_INTERVAL_SEC:
            return
    except OSError:
        pass
    sweep_orphaned_temps(local_dir)
    try:
        OUT_DIR.mkdir(parents=True, exist_ok=True)
        ORPHAN_STAMP.write_text(now_iso(), encoding="utf-8")
    except OSError:
        pass


# -----------------------------------------------------------------------
# Throttle state (persisted — each invocation is a fresh process, unlike the
# in-Lua-process table the tech-hud reference used)
# -----------------------------------------------------------------------


def load_state():
    try:
        with open(STATE_JSON, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_state(state):
    atomic_write(STATE_JSON, json.dumps(state, separators=(",", ":")))


def fresh_state():
    return {
        "last_track_key": "",
        "last_fetch_time": 0,
        "last_result": "",
        "last_saved_track_key": "",
        "last_saved_path": "",
    }


# -----------------------------------------------------------------------
# Publish
# -----------------------------------------------------------------------


def write_lyrics_json(state, note, track=None, lines=None, source=None, fmt=None, library_path=None):
    atomic_write(LYRICS_JSON, json.dumps({
        "state": state,
        "profile": PROFILE_ID,
        "collector": "lyrics",
        "generated_at": now_iso(),
        "note": note,
        "track": track,
        "lines": lines or [],
        "source": source,
        "format": fmt,
        "library_path": library_path,
    }, separators=(",", ":")) + "\n")


def write_status_json(state, note, extra=None):
    payload = {
        "state": state,
        "profile": PROFILE_ID,
        "collector": "lyrics",
        "generated_at": now_iso(),
        "note": note,
    }
    if extra:
        payload.update(extra)
    atomic_write(STATUS_JSON, json.dumps(payload, separators=(",", ":")) + "\n")


# -----------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------


def main():
    cfg = load_config()
    local_dir = cfg["local_dir"]

    status, artist, title = get_player()
    playing = status in ("Playing", "Paused")

    if not playing:
        write_lyrics_json("inactive", "no active player")
        write_status_json("ok", "no active player", {"local_dir_reachable": None})
        return 0

    if not artist or not title:
        write_lyrics_json("no_track", "player active but artist/title metadata missing", track={"artist": artist, "title": title})
        write_status_json("ok", "player active, no track metadata")
        return 0

    track = {"artist": artist, "title": title}
    # `key` (sanitized) is the track's throttle-state identity — stable
    # regardless of which filename variant it ends up living under.
    # `raw_stem` is the natural-case filename the reference implementation
    # actually writes first; `safe_stem` is the sanitized fallback used only
    # when raw_stem isn't a legal path. See find_local()/write_through().
    key = library_stem(artist, title)
    raw_stem = f"{artist} - {title}"
    safe_stem = key

    state = load_state()
    if state.get("last_track_key") != key:
        state = fresh_state()
        state["last_track_key"] = key

    reachable = local_dir_reachable(local_dir) if cfg["enable_local"] else False
    status_extra = {"local_dir_reachable": reachable, "local_dir": local_dir}

    # 1. Local check (also covers "found via a previous write-through" since
    # that promotes a fetched track to local for every future lookup).
    if cfg["enable_local"] and reachable:
        path, ext = find_local(local_dir, raw_stem, safe_stem)
        if path:
            lines = read_lines_from(path, cfg["max_bytes"]) or []
            lines = [strip_lrc_prefix(l, cfg["strip_lrc_timestamps"]) for l in lines]
            write_lyrics_json("ok", "found in local library", track=track, lines=lines,
                               source="local", fmt=ext, library_path=path)
            write_status_json("ok", "local hit", status_extra)
            save_state(state)
            return 0

    # Local dir configured-but-unreachable (NAS not mounted, symlink dangling,
    # permissions) is NOT "no lyrics exist" — fall through to online exactly
    # as if nothing was found locally, same as a genuine not-found.

    if not cfg["enable_online"]:
        write_lyrics_json("not_found", "not in local library, online disabled", track=track)
        write_status_json("ok", "not found, online disabled", status_extra)
        save_state(state)
        return 0

    if is_offline(cfg["providers_noapi"]):
        write_lyrics_json("offline", "not in local library, offline", track=track)
        write_status_json("ok", "offline", status_extra)
        save_state(state)
        return 0

    now = time.time()
    if key == state.get("last_track_key"):
        last_result = state.get("last_result", "")
        last_fetch_time = state.get("last_fetch_time", 0) or 0
        if last_result in ("miss", "instrumental") and (now - last_fetch_time) < MISS_RETRY_SEC:
            saved_path = state.get("last_saved_path") or None
            msg_state = "instrumental" if last_result == "instrumental" else "not_found"
            write_lyrics_json(msg_state, f"cached {last_result}, retry in {int(MISS_RETRY_SEC - (now - last_fetch_time))}s",
                               track=track, library_path=saved_path)
            write_status_json("ok", f"cached {last_result}", status_extra)
            save_state(state)
            return 0
        if (now - last_fetch_time) < FETCH_THROTTLE_SEC:
            write_lyrics_json("searching", "fetch in progress (throttled)", track=track)
            write_status_json("ok", "throttled", status_extra)
            save_state(state)
            return 0

    state["last_fetch_time"] = now
    text, ext, provider = fetch_online(artist, title, cfg["providers_noapi"])

    if text == "instrumental":
        state["last_result"] = "instrumental"
        write_lyrics_json("instrumental", f"instrumental (via {provider})", track=track)
        write_status_json("ok", "instrumental", status_extra)
        save_state(state)
        return 0

    if not text:
        state["last_result"] = "miss"
        write_lyrics_json("not_found", "no local match, no online match", track=track)
        write_status_json("ok", "miss", status_extra)
        save_state(state)
        return 0

    # Online hit. Write-through into local_dir (create-only, race-safe), then
    # publish regardless of whether the write itself succeeded — a write
    # failure costs a re-fetch next time, not a blank widget.
    write_note = None
    written_path = None
    if cfg["enable_local"]:
        if reachable:
            written_path, wrote, err = write_through(local_dir, raw_stem, safe_stem, ext, text)
            if err:
                write_note = f"write-through failed: {err}"
            elif wrote:
                write_note = f"written to library ({ext})"
            else:
                write_note = "already present in library (lost race or manual edit) — not overwritten"
        else:
            write_note = "local_dir unreachable, skipped write-through"

    lines = [strip_lrc_prefix(l, cfg["strip_lrc_timestamps"]) for l in text.split("\n")]
    state["last_result"] = "hit"
    state["last_saved_track_key"] = key
    state["last_saved_path"] = written_path or ""
    write_lyrics_json("ok", f"fetched via {provider}" + (f"; {write_note}" if write_note else ""),
                       track=track, lines=lines, source=f"online:{provider}", fmt=ext,
                       library_path=written_path)
    write_status_json("ok", write_note or f"fetched via {provider}", status_extra)
    save_state(state)

    if cfg["enable_local"] and reachable:
        maybe_sweep_orphans(local_dir)

    return 0


if __name__ == "__main__":
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    try:
        sys.exit(main())
    except Exception as e:  # noqa: BLE001 - provider must never crash the refresh loop
        try:
            write_status_json("error", f"unhandled exception: {e}")
        except Exception:
            pass
        sys.exit(0)
