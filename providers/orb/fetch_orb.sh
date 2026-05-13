#!/usr/bin/env bash
set -euo pipefail

PROFILE="${1:-home}"
CACHE_ROOT="${GTEX62_CACHE_DIR:-${GTEX62_CONKY_CACHE_DIR:-$HOME/.cache/gtex62-core}}"
OUT_DIR="$CACHE_ROOT/shared/orb/$PROFILE"
TMP_DIR="$CACHE_ROOT/tmp"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$OUT_DIR" "$TMP_DIR"

TMP_OUT="$TMP_DIR/orb_ephemeris_${PROFILE}_$$.tmp"
OUT_FILE="$OUT_DIR/ephemeris.vars"

if python3 "$SCRIPT_DIR/fetch_orb.py" "$PROFILE" > "$TMP_OUT" 2>/dev/null; then
  mv -f "$TMP_OUT" "$OUT_FILE"
else
  rm -f "$TMP_OUT"
fi
