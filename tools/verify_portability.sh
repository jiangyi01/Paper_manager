#!/bin/bash
# The portability gates (PORTABILITY_PLAN §6.1). Zero quota: nothing here runs claude or codex,
# installs into the install folder, or reads or writes the app's own settings domain.
#
#   tools/verify_portability.sh [--jobs N]     everything: release build, ./test.sh, the selftests,
#                                              tools/check_build_config.sh, the grep allowlist
#   tools/verify_portability.sh --quick        skip the release build and the test run (selftests
#                                              use .build/debug/PaperDeck, built if missing)
#   tools/verify_portability.sh --greps-only   only the grep allowlist (G1–G6)
#
# The grep allowlist (§6.4) runs from the repo root over the code and the user-facing docs:
#   G1 institution literals only in Sources/PaperDeckConfig/Presets/OrganizationPresets.swift
#   G2 the author's identity only in the 5 default-value lines (BuildIdentity, build_app.sh, plists)
#   G3 personal folders / home paths only in the LegacyInstall preset (1 line)
#   G4 cloud-root name logic only in CloudRootLocator (and the institution preset)
#   G5 machine paths in the scripts only as overridable defaults
#   G6 the signing-certificate name (informational)
# Exit 0 when every gate passes.
set -uo pipefail
cd "$(dirname "$0")/.."

JOBS=""; QUICK=0; GREPS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --jobs|-j) JOBS=${2:-}; shift ;;
    --quick) QUICK=1 ;;
    --greps-only) GREPS=1 ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
J=(); [ -n "$JOBS" ] && J=(-j "$JOBS")

FAILS=0
gate() { echo; echo "== $1"; }
pass() { echo "  ✓ $1"; }
failed() { FAILS=$((FAILS + 1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "$2" | sed 's/^/      /'; }
step() {   # name command…
  local name=$1; shift
  local log; log=$(mktemp "${TMPDIR:-/tmp}/pd-verify.XXXXXX")
  if "$@" > "$log" 2>&1; then pass "$name"; else failed "$name" "$(tail -15 "$log")"; fi
  rm -f "$log"
}
# Like step, and the output must hold no compiler warning (the build is warning-free); the last
# summary line ("Build complete!" / "Test run with N tests … passed") is shown.
step_clean() {   # name command…
  local name=$1; shift
  local log; log=$(mktemp "${TMPDIR:-/tmp}/pd-verify.XXXXXX")
  if "$@" > "$log" 2>&1; then
    local warnings; warnings=$(grep -E ': warning: ' "$log" | sort -u)
    local summary; summary=$(grep -E 'Build complete!|Test run with [0-9]+ tests' "$log" | tail -1)
    if [ -z "$warnings" ]; then pass "$name — no warnings${summary:+ · $summary}"
    else failed "$name: $(wc -l <<< "$warnings" | tr -d ' ') compiler warning(s)" "$(head -15 <<< "$warnings")"; fi
  else
    failed "$name" "$(tail -15 "$log")"
  fi
  rm -f "$log"
}

# ---- the grep allowlist ------------------------------------------------------------------
greps() {
  local USER_DOCS="README.md README.zh-CN.md docs/USER_GUIDE.md docs/TROUBLESHOOTING.md docs/guides docs/BUILDING.md docs/INSTALL_RECIPIENT.md docs/ARCHITECTURE-CONFIG.md"
  local CODE="Sources Resources Package.swift build_app.sh test.sh tools"
  local existing="" p
  for p in $CODE $USER_DOCS; do [ -e "$p" ] && existing="$existing $p"; done
  # The patterns are spelled in pieces so this file never matches itself.
  local INST='wash''u|wus''tl|washing''ton ?university' AUTHOR='yi''jiang' PERSONAL='Paper''_reading|/Users/[A-Za-z]'
  local CLOUD='CloudStorage/One''Drive|hasPrefix\("One''Drive|contains\("One''Drive|One''Drive-Personal|One''Drive-SharedLibraries'
  local out

  gate "G1 institution literals (only the institution preset)"
  # shellcheck disable=SC2086
  out=$(grep -rnIiE "$INST" $existing | grep -v '^Sources/PaperDeckConfig/Presets/OrganizationPresets\.swift:')
  if [ -z "$out" ]; then pass "no institution literal outside OrganizationPresets.swift"; else failed "institution literals found" "$out"; fi

  gate "G2 author identity (exactly the 5 default-value lines)"
  # shellcheck disable=SC2086
  out=$(grep -rnI "$AUTHOR" $existing)
  local got want
  got=$(sed -E 's/^([^:]+):([0-9]+):.*/\1:\2/' <<< "$out" | sed -E 's#^(Sources/PaperDeckShared/BuildIdentity\.swift|build_app\.sh):[0-9]+$#\1#' | sort)
  want=$(printf '%s\n' "Resources/Info.plist:10" "Resources/Info.plist:56" "Resources/PaperDeckWidget-Info.plist:8" \
         "Sources/PaperDeckShared/BuildIdentity.swift" "build_app.sh" | sort)
  if [ "$got" = "$want" ]; then pass "only BuildIdentity.defaultBundleID, the build_app.sh default and Info.plist:10/56, PaperDeckWidget-Info.plist:8"
  else failed "unexpected identity lines" "$out"; fi

  gate "G3 personal folders and home paths (exactly the legacy import folder)"
  # shellcheck disable=SC2086
  out=$(grep -rnIE "$PERSONAL" $existing)
  if [ "$(wc -l <<< "$out" | tr -d ' ')" = 1 ] && grep -q '^Sources/PaperDeckConfig/Presets/LegacyInstall\.swift:' <<< "$out"; then
    pass "only LegacyInstall.importFolder"
  else
    failed "unexpected personal paths" "$out"
  fi

  gate "G4 cloud-root name logic (only CloudRootLocator)"
  out=$(grep -rnE "$CLOUD" Sources --include='*.swift' \
        | grep -vE '^Sources/PaperDeckConfig/(Mail/CloudRootLocator|Presets/OrganizationPresets)\.swift:')
  if [ -z "$out" ]; then pass "no cloud-root name checks outside CloudRootLocator"; else failed "cloud-root logic elsewhere" "$out"; fi

  gate "G5 machine paths in scripts only as overridable defaults"
  out=$(grep -n 'CommandLine''Tools' test.sh | grep -vF '${PAPERDECK_DEV_DIR:-')
  if [ -z "$out" ]; then pass "test.sh: the tools path only inside \${PAPERDECK_DEV_DIR:-…}"; else failed "test.sh hard-codes the tools path" "$out"; fi
  out=$(grep -nE '/Applic''ations' build_app.sh | grep -vF '${PAPERDECK_INSTALL_DIR:-/Applic''ations}' | grep -vE '^[0-9]+:[[:space:]]*#')
  if [ -z "$out" ]; then pass "build_app.sh: the install folder only inside \${PAPERDECK_INSTALL_DIR:-…} and comments"
  else failed "build_app.sh hard-codes the install folder" "$out"; fi

  gate "G6 signing-certificate name (informational)"
  # shellcheck disable=SC2086
  out=$(grep -rnI 'PaperDeck Local'' Signing' $existing)
  local unexpected
  unexpected=$(grep -vE '^(Sources/PaperDeckShared/BuildIdentity\.swift|build_app\.sh|docs/BUILDING\.md|README\.md|README\.zh-CN\.md):' <<< "$out" | grep -v '^$')
  echo "$out" | sed 's/^/    /'
  if [ -n "$unexpected" ]; then echo "  ! outside the allowed files (BuildIdentity.swift, build_app.sh, docs/BUILDING.md, README.md, README.zh-CN.md):"; echo "$unexpected" | sed 's/^/      /'; fi
}

if [ "$GREPS" = 1 ]; then
  greps
  echo; [ "$FAILS" = 0 ] && echo "✅ grep allowlist passed" || echo "❌ $FAILS gate(s) failed"
  [ "$FAILS" = 0 ]; exit
fi

# ---- build and tests -------------------------------------------------------------------------
if [ "$QUICK" = 0 ]; then
  gate "release build and tests"
  step_clean "swift build -c release ${J[*]:-}" swift build -c release ${J[@]+"${J[@]}"}
  step_clean "./test.sh ${J[*]:-}" ./test.sh ${J[@]+"${J[@]}"}
  BIN=.build/release/PaperDeck
else
  gate "debug build (quick)"
  [ -x .build/debug/PaperDeck ] || step "swift build ${J[*]:-}" swift build ${J[@]+"${J[@]}"}
  BIN=.build/debug/PaperDeck
fi

# ---- selftests (pure / scratch only) -------------------------------------------------------
gate "selftests"
FIX=Tests/PaperDeckCoreTests/Fixtures/config
LEGACY_PLIST=$(find "$FIX" -name 'legacy-*-domain.plist' | head -1)   # the synthetic legacy-install domain
for lang in en zh; do
  step "--selftest strings --check org-strings-v1.json --lang $lang" "$BIN" --selftest strings --check "$FIX/org-strings-v1.json" --lang "$lang"
done
for t in settings onboarding mail-notify app-rules; do
  for lang in en zh; do step "--selftest $t --lang $lang" "$BIN" --selftest "$t" --lang "$lang"; done
done

# ---- the migration and configuration CLI on the synthetic domains (§6.2.2, §6.3.1) -------------
gate "configuration CLI (synthetic domains)"
SCR=$(mktemp -d "${TMPDIR:-/tmp}/pd-verify-config.XXXXXX")
trap 'rm -rf "$SCR"' EXIT
if "$BIN" --migrate-dry-run --plist "$LEGACY_PLIST" --db-exists yes --out "$SCR/migrated.plist" > "$SCR/plan.txt" 2>&1; then
  allowed='^write (config\.migrationVersion|config\.origin|config\.migratedAt|config\.migrationNote|org\.preset|profile\.field|mail\.dateOrder|import\.lastFolder)='
  if grep -qx 'origin=legacy' "$SCR/plan.txt" && ! grep '^write ' "$SCR/plan.txt" | grep -vqE "$allowed"; then
    pass "legacy domain: origin legacy, writes only the allowed keys"
  else
    failed "legacy migration plan" "$(cat "$SCR/plan.txt")"
  fi
else
  failed "--migrate-dry-run (legacy)" "$(cat "$SCR/plan.txt")"
fi
CFG=$("$BIN" --config --plist "$SCR/migrated.plist" --db-exists yes 2>&1)
LEGACY_ORG=$(sed -n 's/^org=//p' <<< "$CFG")
if grep -qx 'field=lifeSciencesCompBio' <<< "$CFG" && grep -qx 'stage=phd' <<< "$CFG" && grep -qx 'origin=legacy' <<< "$CFG" \
   && grep -qx 'dateOrder=mdy' <<< "$CFG" && grep -qx 'channel=local' <<< "$CFG" && [ -n "$LEGACY_ORG" ] && [ "$LEGACY_ORG" != generic ]; then
  pass "migrated legacy domain: org $LEGACY_ORG, life sciences, PhD, legacy, month-first, channel local"
else
  failed "--config on the migrated legacy domain" "$CFG"
fi
SHA=$("$BIN" --config --plist "$SCR/migrated.plist" --db-exists yes --card-prompt-sha256 2>/dev/null)
WANT=$(shasum -a 256 "$FIX/card-system-prompt-v1.txt" | cut -d' ' -f1)
if [ -n "$SHA" ] && [ "$SHA" = "$WANT" ]; then pass "card prompt sha256 = card-system-prompt-v1.txt"; else failed "card prompt sha256 $SHA ≠ $WANT"; fi
if "$BIN" --migrate-dry-run --plist "$FIX/fresh-domain.plist" --db-exists no --out "$SCR/fresh.plist" > "$SCR/fresh.txt" 2>&1 \
   && grep -qx 'origin=fresh' "$SCR/fresh.txt" && grep -qx 'write mail.dateOrder=auto' "$SCR/fresh.txt"; then
  CFG=$("$BIN" --config --plist "$SCR/fresh.plist" --db-exists no 2>&1)
  if grep -qx 'org=generic' <<< "$CFG" && grep -qx 'field=general' <<< "$CFG" && grep -qx 'stage=phd' <<< "$CFG" && grep -qx 'dateOrder=auto' <<< "$CFG"; then
    pass "fresh domain: generic, general, PhD, automatic date order"
  else
    failed "--config on the migrated fresh domain" "$CFG"
  fi
else
  failed "--migrate-dry-run (fresh)" "$(cat "$SCR/fresh.txt")"
fi

# ---- the build script --------------------------------------------------------------------------
gate "build_app.sh configuration"
step "tools/check_build_config.sh" tools/check_build_config.sh

greps

echo
if [ "$FAILS" = 0 ]; then echo "✅ every portability gate passed"; else echo "❌ $FAILS gate(s) failed"; fi
[ "$FAILS" = 0 ]
