#!/usr/bin/env bash
# providers/media/fetch_lyrics.sh
# Core lyrics-library provider. Thin wrapper — same shape as
# fetch_modem.sh/fetch_github_traffic.py's callers — since the text/JSON/HTTP
# and write-through logic lives in fetch_lyrics.py rather than the bash+awk
# TOML-helper style used by fetch_pfsense.sh/fetch_net.sh. See
# docs/lyrics-library-design.md.
#
# Idle fast-path: this runs every poll cycle (5s default) whether or not any
# player exists, and starting Python + importing `requests` is ~130ms of the
# ~160ms a full cycle costs. When `playerctl status` says nothing is
# Playing/Paused, fetch_lyrics.py's main() would only write the "inactive"
# pair below and return — so write the identical pair from here and skip
# Python entirely (~10-20ms). Output must stay byte-identical to
# fetch_lyrics.py's no-player branch (modulo generated_at): if that branch
# changes, change this. Any doubt (odd profile id, write failure) falls
# through to the Python path, which is the source of truth. When it does, the
# status already read here is passed along (GTEX62_MEDIA_PLAYER_STATUS) so
# Python doesn't repeat the query.
set -euo pipefail

PROFILE_ID="${1:-local}"

# What `playerctl status` said this cycle, handed to Python below so a playing
# cycle doesn't query it twice. Stays empty if the fast-path never got as far
# as asking (odd profile id) — Python then asks for itself.
PLAYER_STATUS=""

idle_fast_path() {
  # Profile id is interpolated into JSON below without escaping; anything
  # outside a plain identifier goes to Python's json.dumps instead.
  [[ "$PROFILE_ID" =~ ^[A-Za-z0-9._-]+$ ]] || return 1

  # 5s cap mirrors fetch_lyrics.py's read_cmd() timeout; playerctl failing
  # (no players, not installed, timed out) all mean "no active player" there too.
  PLAYER_STATUS="$(timeout 5 playerctl status 2>/dev/null || true)"
  case "$PLAYER_STATUS" in
    Playing | Paused) return 1 ;;
  esac

  # Same CACHE_ROOT resolution as fetch_lyrics.py.
  local cache_root out_dir tmp_dir now
  cache_root="${GTEX62_CACHE_DIR:-${GTEX62_CONKY_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/gtex62-core}}"
  out_dir="$cache_root/shared/media/$PROFILE_ID"
  tmp_dir="$cache_root/tmp"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  mkdir -p "$out_dir" "$tmp_dir" || return 1
  printf '{"state":"inactive","profile":"%s","collector":"lyrics","generated_at":"%s","note":"no active player","track":null,"lines":[],"source":null,"format":null,"library_path":null}\n' \
    "$PROFILE_ID" "$now" > "$tmp_dir/lyrics.json.tmp.$$" || return 1
  mv -f "$tmp_dir/lyrics.json.tmp.$$" "$out_dir/lyrics.json" || return 1
  printf '{"state":"ok","profile":"%s","collector":"lyrics","generated_at":"%s","note":"no active player","local_dir_reachable":null}\n' \
    "$PROFILE_ID" "$now" > "$tmp_dir/status.json.tmp.$$" || return 1
  mv -f "$tmp_dir/status.json.tmp.$$" "$out_dir/status.json" || return 1
  return 0
}

if idle_fast_path; then
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GTEX62_MEDIA_PLAYER_STATUS="$PLAYER_STATUS" python3 "$SCRIPT_DIR/fetch_lyrics.py" "$PROFILE_ID"
