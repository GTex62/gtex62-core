#!/usr/bin/env bash
# providers/media/fetch_lyrics.sh
# Core lyrics-library provider. Thin wrapper — same shape as
# fetch_modem.sh/fetch_github_traffic.py's callers — since the text/JSON/HTTP
# and write-through logic lives in fetch_lyrics.py rather than the bash+awk
# TOML-helper style used by fetch_pfsense.sh/fetch_net.sh. See
# docs/lyrics-library-design.md.
set -euo pipefail

PROFILE_ID="${1:-local}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

python3 "$SCRIPT_DIR/fetch_lyrics.py" "$PROFILE_ID"
