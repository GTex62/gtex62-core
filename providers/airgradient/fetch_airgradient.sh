#!/usr/bin/env bash
# providers/airgradient/fetch_airgradient.sh
# Core airgradient provider (AirGradient ONE local HTTP API + ventilation advisor).
# Thin wrapper — same shape as fetch_modem.sh — since the fetch, carry-forward and
# advisor logic live in fetch_airgradient.py. See docs/airgradient-provider-design.md.
#
# Usage: fetch_airgradient.sh <profile> [<air_profile> [<weather_profile>]]
# The air and weather profiles name the outdoor caches the advisor reads; the launcher
# passes the launching suite's own bindings.
set -euo pipefail

PROFILE_ID="${1:-indoor}"
AIR_PROFILE="${2:-home}"
WEATHER_PROFILE="${3:-home}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

python3 "$SCRIPT_DIR/fetch_airgradient.py" "$PROFILE_ID" "$AIR_PROFILE" "$WEATHER_PROFILE"
