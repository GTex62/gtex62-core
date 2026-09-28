#!/usr/bin/env bash
# Builds a synthetic Conky root for testing bin/gtex62-conkystart. The fake front doors do
# nothing but append what they received to $FIXTURE_LOG, so no test can start, stop or
# touch a real suite. Source this file, then: build_fixture <dest-dir>
#
# Sets MENU (suite directory names in the order the launcher lists them).

write_door() { # <path>
  cat > "$1" <<'EOF'
#!/usr/bin/env bash
d="$(cd "$(dirname "$0")/.." && pwd)"
printf '%s|%s|PAL=%s|WALL=%s\n' "$(basename "$d")" "$(basename "$0")" \
  "${GTEX62_CONKY_PALETTE_OVERRIDE-<unset>}" "${GTEX62_CONKY_WALLPAPER_OVERRIDE-<unset>}" >> "$FIXTURE_LOG"
if [[ -f "$d/.fail" ]]; then exit 3; fi
exit 0
EOF
  chmod +x "$1"
}

write_catalog_nested() { # <path> [extra trailing line]
  cat > "$1" <<'EOF'
return {
  default = "amber",
  palettes = {
    -- Core palettes
    amber = {
      bg = { 0.0, 0.0, 0.0 },
      fg = { 1.0, 1.0, 0.0 },
      ink = { 0.0, 0.0, 0.0 },
    },
    cyan = {
      bg = { 0.0, 0.0, 0.0 },
      fg = { 0.0, 1.0, 1.0 },
      ink = { 0.0, 0.0, 0.0 },
    },

    -- Signal palettes
    phosphor = {
      bg = { 0.0, 0.0, 0.0 },
      fg = { 0.4, 1.0, 0.4 },
      ink = { 0.0, 0.0, 0.0 },
    },
  },
}
EOF
  if [[ -n "${2:-}" ]]; then printf '%s\n' "$2" >> "$1"; fi
}

write_catalog_assigned() { # <path>
  cat > "$1" <<'EOF'
local palettes = {}

palettes["default"] = { name = "Default", bg = { 0.05, 0.05, 0.07, 0.82 } }

palettes["dark"] = { name = "Dark", bg = { 0.03, 0.04, 0.08, 0.88 } }

return palettes
EOF
}

# One file that both extractors can list, so two suites can share its exact bytes while
# declaring different syntaxes (they must not share a palette prompt).
write_catalog_hybrid() { # <path>
  cat > "$1" <<'EOF'
palettes = {}
palettes["hx"] = { name = "HybridX" }
return {
  default = "amber",
  palettes = {
    amber = { bg = { 0.0, 0.0, 0.0 } },
    cyan = { bg = { 0.0, 0.0, 0.0 } },
  },
}
EOF
}

# write_manifest <dir> <suite_id> <companion:yes|no> <syntax|-> <default> [catalog-rel]
write_manifest() {
  local dir="$1" id="$2" comp="$3" syn="$4" def="$5" rel="${6:-theme/palettes.lua}"
  {
    printf 'suite_id = "%s"\nname = "%s"\nversion = "0.0.0"\n\n' "$id" "${dir##*/}"
    printf '[theme]\ndefault_palette = "%s"\npalette_catalog = "%s"\npalette_format = "role3"\n' "$def" "$rel"
    if [[ "$syn" != "-" ]]; then printf 'palette_catalog_syntax = "%s"\n' "$syn"; fi
    if [[ "$comp" == yes ]]; then printf '\n[launch]\ncompanion = true\n'; fi
    printf '\n[[instances.chassis]]\nid = "main"\nconf = "widgets/x.conky.conf"\n'
  } > "$dir/suite.toml"
}

# mk_native <fixture> <dirname> <suite_id> <companion> <syntax|-> <default> <nested|assigned|drift>
mk_native() {
  local d="$1/$2"
  mkdir -p "$d/scripts" "$d/theme" "$d/widgets"
  write_door "$d/scripts/start-conky.sh"
  case "$7" in
    nested)   write_catalog_nested "$d/theme/palettes.lua" ;;
    drift)    write_catalog_nested "$d/theme/palettes.lua" "-- one extra byte changes the hash" ;;
    assigned) write_catalog_assigned "$d/theme/palettes.lua" ;;
    hybrid)   write_catalog_hybrid "$d/theme/palettes.lua" ;;
  esac
  write_manifest "$d" "$3" "$4" "$5" "$6"
}

build_fixture() { # <dest>
  local f="$1" d
  rm -rf "$f"; mkdir -p "$f"
  #            dir              id       comp  syntax         default    catalog
  mk_native "$f" gtex62-a-main       amain    no    nested-table   amber      nested
  mk_native "$f" gtex62-a-comp1      acomp1   yes   nested-table   amber      nested
  mk_native "$f" gtex62-a-comp2      acomp2   yes   nested-table   amber      nested
  mk_native "$f" gtex62-b-main       bmain    no    assigned-keys  default    assigned
  mk_native "$f" gtex62-b-main-e     bmaine   no    assigned-keys  default    assigned   # name is a prefix-extension of b-main
  mk_native "$f" gtex62-drift-comp   dcomp    yes   nested-table   amber      drift
  mk_native "$f" gtex62-badsyn-comp  badsyn   yes   frobnicate     amber      nested
  mk_native "$f" gtex62-nosyn-comp   nosyn    yes   -              amber      nested
  mk_native "$f" gtex62-zero-comp    zero     yes   assigned-keys  amber      nested   # wrong syntax for its file
  mk_native "$f" gtex62-hybrid-a     hyba     yes   nested-table   amber      hybrid   # same bytes as hybrid-b,
  mk_native "$f" gtex62-hybrid-b     hybb     yes   assigned-keys  hx         hybrid   # different declared syntax

  # legacy: no suite.toml. One with a launch-*.sh (must win over start-conky.sh), one plain.
  d="$f/gtex62-legacy-launch"; mkdir -p "$d/scripts"; write_door "$d/scripts/launch-x.sh"; write_door "$d/scripts/start-conky.sh"
  d="$f/gtex62-legacy-plain";  mkdir -p "$d/scripts"; write_door "$d/scripts/start-conky.sh"

  # not launchable: has widgets/ but no start script; and shared assets
  mkdir -p "$f/gtex62-nonsuite/widgets"
  mkdir -p "$f/gtex62-shared-assets/wallpapers"
  : > "$f/gtex62-shared-assets/wallpapers/a.png"
  : > "$f/gtex62-shared-assets/wallpapers/b.jpg"
  : > "$f/gtex62-shared-assets/wallpapers/c.webp"

  MENU=()
  while IFS= read -r d; do
    if [[ -x "$f/$d/scripts/start-conky.sh" ]] || compgen -G "$f/$d/scripts/launch-*.sh" >/dev/null; then MENU+=("$d"); fi
  done < <(cd "$f" && LC_ALL=C ls -d ./*/ | sed 's#^\./##; s#/$##' | LC_ALL=C sort)
}
