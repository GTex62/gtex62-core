#!/usr/bin/env bash
# Tests for bin/gtex62-conkystart against a synthetic fixture tree (nothing real is touched).
# Runs every case under each awk flavor found (gawk, mawk). Exit status is non-zero on any
# failure.  Usage: tests/conkystart/run-tests.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE="$(cd "$HERE/../.." && pwd)"
LAUNCHER="${LAUNCHER:-$CORE/bin/gtex62-conkystart}"
BASH_BIN="$(command -v bash)"
source "$HERE/fixture.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FIX="$TMP/conky"; CACHE="$TMP/cache"; LOG="$TMP/door.log"; mkdir -p "$TMP/home"

PASS=0; FAIL=0; FLAVOR=""
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL [%s] %s\n' "$FLAVOR" "$1"; if [[ -n "${2:-}" ]]; then printf '        %s\n' "$2"; fi; }
# check <name> <exit-status-of-the-condition> [detail]
check() { if [[ "$2" -eq 0 ]]; then ok; else bad "$1" "${3:-}"; fi; }
has_out()  { grep -qF -- "$1" <<<"$OUT"; }
has_err()  { grep -qF -- "$1" <<<"$ERR"; }
count_out() { grep -cF -- "$1" <<<"$OUT" || true; }
log_n()    { grep -c . "$LOG" || true; }
log_at()   { sed -n "${1}p" "$LOG"; }

n() { local i; for i in "${!MENU[@]}"; do if [[ "${MENU[i]}" == "gtex62-$1" ]]; then echo $((i + 1)); return; fi; done; echo 0; }
sel() { local o="" x; for x in "$@"; do o+="$(n "$x") "; done; printf '%s' "${o% }"; }

EXTRA_ENV=(); ROOT_OVERRIDE=""
fresh() { rm -rf "$CACHE"; mkdir -p "$CACHE/runtime"; : > "$LOG"; EXTRA_ENV=(); ROOT_OVERRIDE=""; }
# run_l <stdin-text> [launcher args...]  ->  OUT ERR RC
run_l() {
  local root="${ROOT_OVERRIDE:-$FIX}"
  OUT="$(printf '%b' "$1" | env -i HOME="$TMP/home" PATH="$PATHX" GTEX62_CONKY_ROOT="$root" \
        GTEX62_CACHE_DIR="$CACHE" FIXTURE_LOG="$LOG" ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} \
        "$BASH_BIN" "$LAUNCHER" "${@:2}" 2>"$TMP/err")"; RC=$?
  ERR="$(cat "$TMP/err")"
}

run_flavor() {
  FLAVOR="$1"
  mkdir -p "$TMP/bin_$FLAVOR"; ln -sf "$(command -v "$FLAVOR")" "$TMP/bin_$FLAVOR/awk"
  PATHX="$TMP/bin_$FLAVOR:/usr/bin:/bin"
  local before_pass=$PASS before_fail=$FAIL
  build_fixture "$FIX"

  # ---- discovery and menu ------------------------------------------------------------
  fresh; run_l 'q\n'
  check "quit exits 0 and launches nothing" $(( RC == 0 && $(log_n) == 0 ? 0 : 1 )) "rc=$RC"
  has_out "Nothing launched."; check "quit prints a message" $?
  check "menu lists exactly the launchable suites" $(( $(grep -cE '^[0-9]+\) ' <<<"$OUT") == ${#MENU[@]} ? 0 : 1 )) "menu=${#MENU[@]}"
  grep -qx "$(n a-main)) gtex62-a-main" <<<"$OUT"; check "a main native suite has no tag" $?
  got_order="$(grep -E '^[0-9]+\) ' <<<"$OUT" | sed -E 's/^[0-9]+\) //; s/ \[.*$//' | tr '\n' ' ')"
  check "menu order is plain name order (a name that prefixes another sorts first)" $([[ "$got_order" == "${MENU[*]} " ]]; echo $?) "got:  $got_order | want: ${MENU[*]}"
  has_out "gtex62-a-comp1 [companion]"; check "companions are tagged" $?
  has_out "gtex62-legacy-launch [legacy]"; check "legacy suites are tagged" $?
  has_out "gtex62-nonsuite"; [[ $? -ne 0 ]]; check "a dir with no start script is not listed" $?
  has_out "gtex62-shared-assets"; [[ $? -ne 0 ]]; check "shared-assets is not listed" $?

  # ---- selection input ---------------------------------------------------------------
  fresh; run_l "$(sel a-main b-main)\nq\n"
  has_err "at most one main"; check "two mains are refused" $?
  has_err "you chose: gtex62-a-main, gtex62-b-main"; check "the refusal names the mains, comma-separated" $?
  check "two mains launch nothing" $(( $(log_n) == 0 ? 0 : 1 ))
  fresh; run_l 'abc\nq\n'; has_err "Not a number"; check "junk input is refused" $?
  fresh; run_l '99\nq\n'; has_err "No suite numbered 99"; check "out-of-range is refused" $?
  fresh; run_l '0\nq\n'; has_err "No suite numbered 0"; check "zero is refused" $?
  fresh; run_l '\nq\n'; has_err "Nothing selected"; check "empty input is refused" $?
  fresh; run_l ''
  check "end of input at the first prompt exits 1" $(( RC == 1 ? 0 : 1 )) "rc=$RC"
  has_err "end of input"; check "end of input says so" $?
  fresh; run_l "$(n a-main),$(n a-comp1)  $(n a-main)\n\n0\n"
  check "commas, spaces and duplicates are tolerated (main launched once)" $(( $(grep -c '^gtex62-a-main|' "$LOG") == 1 ? 0 : 1 ))

  # ---- palette grouping --------------------------------------------------------------
  fresh; run_l "$(sel a-comp2 a-main a-comp1)\n2\n0\n"
  check "same-catalog trio gets exactly one palette prompt" $(( $(count_out "Palettes for") == 1 ? 0 : 1 )) "prompts=$(count_out 'Palettes for')"
  [[ "$(log_at 1 | cut -d'|' -f1)" == gtex62-a-main && "$(log_at 2 | cut -d'|' -f1)" == gtex62-a-comp2 && "$(log_at 3 | cut -d'|' -f1)" == gtex62-a-comp1 ]]
  check "launch order is main, comp2, comp1" $? "$(cut -d'|' -f1 "$LOG" | tr '\n' ' ')"
  check "all three received the same palette" $(( $(grep -c 'PAL=cyan' "$LOG") == 3 ? 0 : 1 ))
  check "all three received the wallpaper choice" $(( $(grep -c 'WALL=none' "$LOG") == 3 ? 0 : 1 ))
  has_out "Core palettes"; check "group headings are shown in the menu" $?
  has_out "Signal palettes"; check "second group heading is shown" $?

  fresh; run_l "$(sel b-main a-comp1)\n2\n3\n0\n"
  check "cross-group selection gets two palette prompts" $(( $(count_out "Palettes for") == 2 ? 0 : 1 ))
  grep -q '^gtex62-b-main|.*PAL=dark|' "$LOG"; check "main got its own group's palette" $?
  grep -q '^gtex62-a-comp1|.*PAL=phosphor|' "$LOG"; check "companion got its own group's palette" $?

  fresh; run_l "$(sel a-main drift-comp)\n1\n1\n0\n"
  check "a one-byte catalog change splits the group (hash sensitivity)" $(( $(count_out "Palettes for") == 2 ? 0 : 1 ))

  fresh; run_l "$(sel hybrid-a hybrid-b)\n1\n1\n0\n"
  check "identical catalog bytes with different declared syntax are separate groups" $(( $(count_out "Palettes for") == 2 ? 0 : 1 )) "prompts=$(count_out 'Palettes for')"
  grep -q '^gtex62-hybrid-a|.*PAL=amber|' "$LOG"; check "hybrid-a lists its own names" $? "$(log_at 1)"
  grep -q '^gtex62-hybrid-b|.*PAL=hx|' "$LOG"; check "hybrid-b lists its own (different) names" $? "$(log_at 2)"

  fresh; run_l "$(sel a-main badsyn-comp nosyn-comp zero-comp)\n1\n0\n"
  check "unlistable suites don't add a palette prompt" $(( $(count_out "Palettes for") == 1 ? 0 : 1 ))
  has_out "gtex62-badsyn-comp: palette catalog can't be listed (syntax 'frobnicate')"; check "unknown syntax is reported" $?
  has_out "gtex62-nosyn-comp: palette catalog can't be listed (syntax 'not declared')"; check "missing syntax is reported" $?
  has_out "gtex62-zero-comp: palette catalog can't be listed (syntax 'assigned-keys')"; check "wrong syntax (zero names) is reported" $?
  grep -q '^gtex62-badsyn-comp|.*PAL=<unset>|' "$LOG"; check "unknown-syntax suite gets no palette override" $?
  grep -q '^gtex62-nosyn-comp|.*PAL=<unset>|' "$LOG"; check "no-syntax suite gets no palette override" $?
  grep -q '^gtex62-zero-comp|.*PAL=<unset>|' "$LOG"; check "zero-names suite gets no palette override" $?
  grep -q '^gtex62-a-main|.*PAL=amber|' "$LOG"; check "the listable suite is unaffected" $?
  check "unlistable suites still launch" $(( $(log_n) == 4 ? 0 : 1 )) "launched=$(log_n)"

  # ---- legacy pass-through ------------------------------------------------------------
  fresh; run_l "$(sel legacy-launch a-comp1)\n1\n0\n"
  [[ "$(log_at 1 | cut -d'|' -f1,2)" == "gtex62-legacy-launch|launch-x.sh" ]]
  check "legacy launches first via its launch-*.sh (preferred over start-conky.sh)" $? "$(log_at 1)"
  [[ "$(log_at 1)" == *"PAL=<unset>|WALL=<unset>" ]]; check "legacy gets no overrides" $? "$(log_at 1)"
  grep -q '^gtex62-a-comp1|.*PAL=amber|WALL=none' "$LOG"; check "the companion after it still gets overrides" $?
  fresh; run_l "$(sel legacy-plain)\n"
  check "a lone legacy suite needs no further input" $(( RC == 0 ? 0 : 1 )) "rc=$RC err=$ERR"
  [[ "$(log_at 1 | cut -d'|' -f1,2)" == "gtex62-legacy-plain|start-conky.sh" ]]; check "legacy without launch-*.sh uses start-conky.sh" $?
  check "a lone legacy suite asks no palette or wallpaper question" $(( $(count_out "Palettes for") + $(count_out "Available wallpapers") == 0 ? 0 : 1 ))

  # ---- wallpaper ---------------------------------------------------------------------
  fresh; run_l "$(sel a-main a-comp1)\n\n2\n"
  check "exactly one wallpaper prompt for the whole launch" $(( $(count_out "Available wallpapers") == 1 ? 0 : 1 ))
  check "the chosen wallpaper reaches every native suite" $(( $(grep -c 'WALL=b.jpg' "$LOG") == 2 ? 0 : 1 ))
  fresh; mkdir -p "$TMP/onewall"; : > "$TMP/onewall/only.png"; EXTRA_ENV=("GTEX62_WALLPAPERS_DIR=$TMP/onewall")
  run_l "$(sel a-main)\n\n"
  grep -q 'WALL=only.png' "$LOG"; check "a single wallpaper is used without a prompt" $?
  fresh; EXTRA_ENV=("GTEX62_WALLPAPERS_DIR=$TMP/no-such-dir"); run_l "$(sel a-main)\n\n"
  has_out "skipping wallpaper"; check "a missing wallpaper directory is skipped" $?
  grep -q 'WALL=<unset>' "$LOG"; check "and no wallpaper override is passed" $?

  # ---- defaults and remembered choices -------------------------------------------------
  fresh; run_l "$(sel a-main)\n\n0\n"
  grep -q 'PAL=amber' "$LOG"; check "Enter takes the manifest default palette" $?
  fresh; printf 'phosphor\n' > "$CACHE/runtime/amain-palette"; printf 'c.webp\n' > "$CACHE/runtime/amain-wallpaper"
  run_l "$(sel a-main)\n\n\n"
  grep -q 'PAL=phosphor|WALL=c.webp' "$LOG"; check "Enter takes the remembered palette and wallpaper" $? "$(log_at 1)"
  has_out "3) phosphor (default)"; check "the remembered palette is marked as the default" $?
  fresh; printf 'none\n' > "$CACHE/runtime/amain-wallpaper"; run_l "$(sel a-main)\n\n\n"
  grep -q 'WALL=none' "$LOG"; check "a remembered 'none' wallpaper is honored" $?

  # ---- environment hygiene ------------------------------------------------------------
  fresh; EXTRA_ENV=("GTEX62_CONKY_PALETTE_OVERRIDE=stale" "GTEX62_CONKY_WALLPAPER_OVERRIDE=stale")
  run_l "$(sel legacy-plain)\n"
  [[ "$(log_at 1)" == *"PAL=<unset>|WALL=<unset>" ]]; check "inherited overrides never reach a legacy suite" $? "$(log_at 1)"
  fresh; EXTRA_ENV=("GTEX62_CONKY_PALETTE_OVERRIDE=stale")
  run_l "$(sel a-main badsyn-comp)\n1\n1\n"
  grep -q '^gtex62-badsyn-comp|.*PAL=<unset>|WALL=a.png' "$LOG"; check "an inherited palette override doesn't leak to an unlisted suite" $? "$(log_at 2)"

  # ---- dry run -----------------------------------------------------------------------
  fresh; run_l "$(sel a-main a-comp1)\n2\n0\n" --dry-run
  check "dry run starts nothing" $(( $(log_n) == 0 ? 0 : 1 )) "launched=$(log_n)"
  has_out "Plan (dry run"; check "dry run prints a plan" $?
  has_out "1. gtex62-a-main  [main, native]"; check "plan lists the main first" $?
  has_out "GTEX62_CONKY_PALETTE_OVERRIDE=cyan"; check "plan shows the palette override" $?
  check "dry run exits 0" $(( RC == 0 ? 0 : 1 ))
  fresh; run_l "$(sel legacy-plain)\n" --dry-run
  has_out "no overrides; inherited overrides unset"; check "plan says a legacy suite gets no overrides" $?

  # ---- errors and options ------------------------------------------------------------
  fresh; ROOT_OVERRIDE="$TMP/no-such-root"; run_l 'q\n'
  check "a missing conky root exits 1" $(( RC == 1 ? 0 : 1 )); has_err "Conky root not found"; check "and says so" $?
  fresh; mkdir -p "$TMP/emptyroot"; ROOT_OVERRIDE="$TMP/emptyroot"; run_l 'q\n'
  check "a root with no suites exits 1" $(( RC == 1 ? 0 : 1 )); has_err "No Conky suites found"; check "and says so" $?
  fresh; ROOT_OVERRIDE="$TMP/no-such-root"; run_l 'q\n' --conky-root "$FIX"
  check "--conky-root overrides the environment" $(( RC == 0 && $(count_out "gtex62-a-main") >= 1 ? 0 : 1 )) "rc=$RC"
  fresh; run_l '' --bogus; check "an unknown option exits 2" $(( RC == 2 ? 0 : 1 )) "rc=$RC"
  fresh; run_l '' --help; check "--help exits 0" $(( RC == 0 ? 0 : 1 )); has_out "Usage:"; check "--help prints usage" $?
  fresh; touch "$FIX/gtex62-a-comp1/.fail"; run_l "$(sel a-main a-comp1 a-comp2)\n1\n0\n"; rm -f "$FIX/gtex62-a-comp1/.fail"
  check "a failing front door makes the launcher exit 1" $(( RC == 1 ? 0 : 1 )) "rc=$RC"
  has_err "Failed to start: gtex62-a-comp1"; check "the failure is named" $?
  check "the remaining suites still launch after a failure" $(( $(log_n) == 3 ? 0 : 1 )) "launched=$(log_n)"

  # ---- readers and extractors (unit) ---------------------------------------------------
  unit_tests
  printf '  %-6s %d passed, %d failed\n' "$FLAVOR" $((PASS - before_pass)) $((FAIL - before_fail))
}

unit_tests() {
  local out line
  out="$( ( PATH="$PATHX"; source "$LAUNCHER"
    local d="$TMP/unit"; rm -rf "$d"; mkdir -p "$d"
    printf 'suite_id = "x1"   # comment\nname = "n"\n\n[theme]\ndefault_palette = "amber" # d\npalette_catalog = "theme/p.lua"\n' > "$d/a.toml"
    [[ "$(manifest_top_value "$d/a.toml" suite_id)" == x1 ]] || echo "FAILU top value with trailing comment"
    [[ -z "$(manifest_top_value "$d/a.toml" default_palette)" ]] || echo "FAILU top value must not read inside a table"
    [[ "$(manifest_theme_value "$d/a.toml" default_palette)" == amber ]] || echo "FAILU theme value with trailing comment"
    [[ -z "$(manifest_theme_value "$d/a.toml" suite_id)" ]] || echo "FAILU theme value must not read outside [theme]"
    local c
    for c in 'yes|[launch]\ncompanion = true\n' 'yes|[launch]  # x\ncompanion=true # y\n' 'no|[launch]\ncompanion = false\n' \
             'no|[theme]\ncompanion = true\n' 'no|[[launch]]\ncompanion = true\n' 'no|[launch]\ncompanion = "true"\n' 'no|# nothing\n'; do
      printf '%b' "${c#*|}" > "$d/m.toml"
      if is_companion_manifest "$d/m.toml"; then got=yes; else got=no; fi
      [[ "$got" == "${c%%|*}" ]] || echo "FAILU companion reader: ${c%%|*} expected for: ${c#*|}"
    done
    write_catalog_nested "$d/n.lua"; write_catalog_assigned "$d/s.lua"
    [[ "$(list_palettes "$d/n.lua" nested-table | grep -v '^@GROUP@' | tr '\n' ' ')" == "amber cyan phosphor " ]] || echo "FAILU nested-table names"
    [[ "$(list_palettes "$d/n.lua" nested-table | grep -c '^@GROUP@')" == 2 ]] || echo "FAILU nested-table group headings"
    [[ "$(list_palettes "$d/s.lua" assigned-keys | tr '\n' ' ')" == "default dark " ]] || echo "FAILU assigned-keys names"
    [[ -z "$(list_palettes "$d/s.lua" nested-table)" ]] || echo "FAILU wrong syntax must yield no names"
    list_palettes "$d/n.lua" frobnicate; [[ $? -eq 3 ]] || echo "FAILU unknown syntax must return 3"
    list_palettes "$d/n.lua" ""; [[ $? -eq 3 ]] || echo "FAILU empty syntax must return 3"
  ) )"
  if [[ -z "$out" ]]; then
    ok
  else
    while IFS= read -r line; do bad "unit: ${line#FAILU }"; done <<<"$out"
  fi
}

FLAVORS=()
for f in gawk mawk; do if command -v "$f" >/dev/null 2>&1; then FLAVORS+=("$f"); fi; done
(( ${#FLAVORS[@]} > 0 )) || { echo "No awk found."; exit 2; }
echo "conkystart tests (awk flavors: ${FLAVORS[*]})"
for f in "${FLAVORS[@]}"; do run_flavor "$f"; done
echo
echo "total: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
