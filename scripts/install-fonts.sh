#!/usr/bin/env bash
set -euo pipefail

CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHARED_ASSETS="${GTEX62_SHARED_ASSETS:-${GTEX62_CONKY_SHARED_ASSETS:-$HOME/.config/conky/gtex62-shared-assets}}"
SRC_DIR="$SHARED_ASSETS/fonts"
DEST_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/fonts"
MANIFEST="$DEST_DIR/.gtex62-core-fonts.manifest"
TMP_MANIFEST="$(mktemp)"

cleanup() {
  rm -f "$TMP_MANIFEST"
}
trap cleanup EXIT

if [[ ! -d "$SRC_DIR" ]]; then
  echo "Error: shared assets fonts directory not found: $SRC_DIR" >&2
  echo "Set GTEX62_SHARED_ASSETS to the gtex62-shared-assets root and retry." >&2
  exit 1
fi

mkdir -p "$DEST_DIR"

echo "Installing gtex62 shared fonts from:"
echo "  $SRC_DIR"
echo "Into:"
echo "  $DEST_DIR"
echo

count=0
while IFS= read -r -d '' f; do
  rel="${f#"$SRC_DIR"/}"
  target="$DEST_DIR/$rel"
  mkdir -p "$(dirname "$target")"
  cp -f "$f" "$target"
  echo "$target" >> "$TMP_MANIFEST"
  (( count += 1 ))
done < <(find "$SRC_DIR" -type f \( -iname "*.ttf" -o -iname "*.otf" \) -print0 | sort -z)

mv "$TMP_MANIFEST" "$MANIFEST"

echo "Copied $count font file(s)."
echo "Rebuilding font cache..."
fc-cache -f >/dev/null

echo "Done."
echo "Manifest saved to: $MANIFEST"
echo "Tip: restart apps (or log out/in) if fonts don't appear immediately."
