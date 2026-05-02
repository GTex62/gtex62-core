#!/usr/bin/env bash
set -euo pipefail

PROFILE_ID="${1:-default}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

python3 "$SCRIPT_DIR/fetch_github_traffic.py" "$PROFILE_ID"
