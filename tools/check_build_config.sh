#!/bin/bash
# Checks build_app.sh's configuration layering (PORTABILITY_PLAN §2.11, §5.7) without building:
# defaults, build.local.env, environment, flags, rejected keys, bundle/widget id rules. Each case
# runs a copy of build_app.sh in a scratch folder with `env -i`, so this repo's own build.local.env
# and your environment never leak in, and --print-config builds and signs nothing.
#
#   tools/check_build_config.sh                       configuration cases only (seconds)
#   tools/check_build_config.sh --staging [--sign X] [--jobs N]
#        + one real `./build_app.sh --no-install` in this repo (a release build): the staged
#          plists equal Resources/*.plist apart from PD*, CFBundleVersion and DT*; the signature's
#          identifier is the bundle id and (unless ad-hoc) the designated requirement is
#          certificate-based; nothing is copied into the install folder and nothing is stopped.
#          --sign - signs ad-hoc (no keychain access at all).
# Exit 0 when every check passes.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)

STAGING=0; SIGN=""; JOBS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --staging) STAGING=1 ;;
    --sign) SIGN=${2:-}; shift ;;
    --jobs|-j) JOBS=${2:-}; shift ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

PASS=0; FAILS=0
ok() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
bad() { FAILS=$((FAILS + 1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "$2" | sed 's/^/      /'; }

SCR=$(mktemp -d "${TMPDIR:-/tmp}/pd-check-build.XXXXXX")
trap 'rm -rf "$SCR"' EXIT
FAKEHOME="$SCR/home"; mkdir -p "$FAKEHOME"

# A scratch copy of the script (its folder is where build.local.env is read from).
fresh() { rm -rf "$SCR/w"; mkdir -p "$SCR/w"; cp "$ROOT/build_app.sh" "$SCR/w/"; }
# run [VAR=value …] -- ARGS…  → stdout+stderr in $OUT, exit code in $RC
run() {
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  OUT=$(cd "$SCR/w" && env -i PATH="$PATH" HOME="$FAKEHOME" ${envs[@]+"${envs[@]}"} ./build_app.sh "$@" 2>&1); RC=$?
}
expect_config() {   # name expected-lines
  if [ "$RC" = 0 ] && [ "$(grep -v '^(with ' <<< "$OUT")" = "$2" ]; then ok "$1"; else bad "$1" "rc=$RC"$'\n'"$OUT"; fi
}
expect_refused() {  # name message-fragment
  if [ "$RC" = 2 ] && grep -qF -- "$2" <<< "$OUT"; then ok "$1"; else bad "$1" "rc=$RC"$'\n'"$OUT"; fi
}

DEFAULT_BUNDLE=$(sed -nE 's/^BUNDLE_ID="\$\{FLAG_BUNDLE_ID:-\$\{PAPERDECK_BUNDLE_ID:-([^}]*)\}\}"$/\1/p' "$ROOT/build_app.sh")
DEFAULT_IDENTITY=$(sed -nE 's/^IDENTITY="\$\{FLAG_SIGN:-\$\{PAPERDECK_SIGN_IDENTITY:-([^}]*)\}\}"$/\1/p' "$ROOT/build_app.sh")
SWIFT_DEFAULT=$(sed -nE 's/^ *public static let defaultBundleID = "([^"]*)"$/\1/p' "$ROOT/Sources/PaperDeckShared/BuildIdentity.swift")
SWIFT_IDENTITY=$(sed -nE 's/^ *public static let defaultSigningIdentityName = "([^"]*)"$/\1/p' "$ROOT/Sources/PaperDeckShared/BuildIdentity.swift")
PLIST_BUNDLE=$(plutil -extract CFBundleIdentifier raw -o - "$ROOT/Resources/Info.plist")
PLIST_WIDGET=$(plutil -extract CFBundleIdentifier raw -o - "$ROOT/Resources/PaperDeckWidget-Info.plist")

echo "build_app.sh configuration"
if [ -n "$DEFAULT_BUNDLE" ] && [ "$DEFAULT_BUNDLE" = "$SWIFT_DEFAULT" ] && [ "$DEFAULT_BUNDLE" = "$PLIST_BUNDLE" ] \
   && [ "$PLIST_WIDGET" = "$DEFAULT_BUNDLE.widget" ] && [ -n "$DEFAULT_IDENTITY" ] && [ "$DEFAULT_IDENTITY" = "$SWIFT_IDENTITY" ]; then
  ok "script, BuildIdentity and Resources/*.plist agree on the default bundle id and certificate name"
else
  bad "defaults disagree" "script=$DEFAULT_BUNDLE swift=$SWIFT_DEFAULT plist=$PLIST_BUNDLE widget=$PLIST_WIDGET identity=$DEFAULT_IDENTITY/$SWIFT_IDENTITY"
fi

fresh; run -- --print-config
expect_config "defaults (no build.local.env, empty environment)" "bundle=$DEFAULT_BUNDLE
widget=$DEFAULT_BUNDLE.widget
identity=$DEFAULT_IDENTITY
install=/Applications
keychain=$DEFAULT_BUNDLE.mail
channel=local"

fresh
printf '%s\r\n' "# lab build" "" "PAPERDECK_BUNDLE_ID=org.example.paperdeck" > "$SCR/w/build.local.env"
cat >> "$SCR/w/build.local.env" <<'EOF'
  export PAPERDECK_SIGN_IDENTITY = "Example Lab Signing"
PAPERDECK_INSTALL_DIR='~/Applications'
PAPERDECK_CHANNEL=distribution
EOF
run -- --print-config
expect_config "build.local.env overrides the defaults (comments, CRLF, export, quotes, ~/)" "bundle=org.example.paperdeck
widget=org.example.paperdeck.widget
identity=Example Lab Signing
install=$FAKEHOME/Applications
keychain=org.example.paperdeck.mail
channel=distribution"
if grep -qF "(with build.local.env)" <<< "$OUT"; then ok "--print-config notes that build.local.env was used"; else bad "build.local.env note missing" "$OUT"; fi

run PAPERDECK_BUNDLE_ID=net.example.env PAPERDECK_KEYCHAIN_SERVICE=net.example.secrets -- --print-config
expect_config "the environment overrides build.local.env" "bundle=net.example.env
widget=net.example.env.widget
identity=Example Lab Signing
install=$FAKEHOME/Applications
keychain=net.example.secrets
channel=distribution"

run PAPERDECK_BUNDLE_ID=net.example.env -- --print-config --bundle-id io.example.flag --sign - --install-dir /tmp/pd-install
expect_config "flags override the environment" "bundle=io.example.flag
widget=io.example.flag.widget
identity=-
install=/tmp/pd-install
keychain=io.example.flag.mail
channel=distribution"

fresh; run -- --print-config --package
if [ "$RC" = 0 ] && grep -qx "channel=distribution" <<< "$OUT"; then ok "--package builds the distribution channel"; else bad "--package channel" "$OUT"; fi

fresh; printf 'PATH=/tmp/evil\n' > "$SCR/w/build.local.env"; run -- --print-config
expect_refused "an unknown key in build.local.env is refused" "'PATH' is not a build setting"
fresh; printf 'PAPERDECK_BUNDLE_ID\n' > "$SCR/w/build.local.env"; run -- --print-config
expect_refused "a line without = is refused" "expected KEY=VALUE"
fresh; printf 'PAPERDECK_SIGN_IDENTITY=$(touch %s/pwned)`touch %s/pwned2`\n' "$SCR" "$SCR" > "$SCR/w/build.local.env"; run -- --print-config
if [ "$RC" = 0 ] && [ ! -e "$SCR/pwned" ] && [ ! -e "$SCR/pwned2" ] && grep -qF 'identity=$(touch' <<< "$OUT"; then
  ok "build.local.env is data: \$(…) and backticks are never run"
else
  bad "build.local.env was evaluated" "$OUT"
fi
fresh; run PAPERDECK_WIDGET_ID=org.other.widget -- --print-config
expect_refused "a widget id that doesn't extend the bundle id is refused" "must start with"
fresh; run PAPERDECK_WIDGET_ID=$DEFAULT_BUNDLE.desk -- --print-config
if [ "$RC" = 0 ] && grep -qx "widget=$DEFAULT_BUNDLE.desk" <<< "$OUT"; then ok "a prefixed widget id is accepted"; else bad "prefixed widget id" "$OUT"; fi
for badid in "paperdeck" "org..x" "org.ex ample" "org.example_x" "-"; do
  fresh; run -- --print-config --bundle-id "$badid"
  if [ "$RC" = 2 ]; then ok "bundle id '$badid' is refused"; else bad "bundle id '$badid' accepted" "$OUT"; fi
done
fresh; run PAPERDECK_CHANNEL=beta -- --print-config
expect_refused "an unknown channel is refused" "must be local or distribution"
fresh; run -- --print-config --jobs 0
expect_refused "--jobs must be positive" "--jobs must be a positive number"
fresh; run -- --no-install --dev
expect_refused "--dev can't be combined with --no-install (it would write the installed app's settings)" "--dev writes"
fresh; run -- --package --run
expect_refused "--run can't be combined with --package" "--run needs an install"
fresh; run -- --frobnicate
expect_refused "an unknown flag is refused" "unknown option"

if [ "$STAGING" = 1 ]; then
  echo "staging build (./build_app.sh --no-install)"
  APP_PLIST=/Applications/PaperDeck.app/Contents/Info.plist
  before_app=$(stat -f '%m %z' "$APP_PLIST" 2>/dev/null || echo none)
  before_pids=$(pgrep -x PaperDeck | sort | tr '\n' ' ')
  before_number=$(cat .build_number 2>/dev/null || echo none)
  args=(--no-install); [ -n "$SIGN" ] && args+=(--sign "$SIGN"); [ -n "$JOBS" ] && args+=(--jobs "$JOBS")
  LOG="$SCR/staging.log"
  if env -u PAPERDECK_BUNDLE_ID -u PAPERDECK_WIDGET_ID -u PAPERDECK_SIGN_IDENTITY -u PAPERDECK_INSTALL_DIR \
       -u PAPERDECK_KEYCHAIN_SERVICE -u PAPERDECK_CHANNEL ./build_app.sh "${args[@]}" > "$LOG" 2>&1; then
    ok "./build_app.sh ${args[*]} succeeded"
  else
    bad "./build_app.sh ${args[*]} failed" "$(tail -20 "$LOG")"
  fi
  CFG=$(./build_app.sh --print-config 2>/dev/null)
  B=$(sed -n 's/^bundle=//p' <<< "$CFG"); WID=$(sed -n 's/^widget=//p' <<< "$CFG"); K=$(sed -n 's/^keychain=//p' <<< "$CFG")
  ST=.build/stage/PaperDeck.bundle
  strip_plist() {  # plist out — without PD*, CFBundleVersion and DT* keys, as XML
    cp "$1" "$2"
    for key in $(plutil -convert xml1 -o - "$1" | sed -nE 's#^'$'\t''<key>((PD|DT)[A-Za-z]*|CFBundleVersion)</key>$#\1#p'); do
      plutil -remove "$key" "$2"
    done
    plutil -convert xml1 "$2"
  }
  for pair in "$ST/Contents/Info.plist:Resources/Info.plist" "$ST/Contents/PlugIns/PaperDeckWidget.appex/Contents/Info.plist:Resources/PaperDeckWidget-Info.plist"; do
    staged=${pair%%:*}; source=${pair#*:}
    if [ ! -f "$staged" ]; then bad "staged $(basename "$(dirname "$(dirname "$staged")")") plist missing"; continue; fi
    strip_plist "$staged" "$SCR/a.plist"; strip_plist "$source" "$SCR/b.plist"
    if cmp -s "$SCR/a.plist" "$SCR/b.plist"; then ok "staged plist = $source (apart from PD*, CFBundleVersion, DT*)"
    else bad "staged plist differs from $source" "$(diff "$SCR/b.plist" "$SCR/a.plist" | head -20)"; fi
  done
  PL="$ST/Contents/Info.plist"
  stamp() { plutil -extract "$1" raw -o - "$2" 2>/dev/null; }
  if [ "$(stamp PDHostBundleIdentifier "$PL")" = "$B" ] && [ "$(stamp PDKeychainService "$PL")" = "$K" ] \
     && [ "$(stamp PDBuildChannel "$PL")" = local ] && [ -n "$(stamp PDSigningIdentity "$PL")" ] \
     && [ "$(stamp PDHostBundleIdentifier "$ST/Contents/PlugIns/PaperDeckWidget.appex/Contents/Info.plist")" = "$B" ] \
     && [ "$(stamp CFBundleIdentifier "$ST/Contents/PlugIns/PaperDeckWidget.appex/Contents/Info.plist")" = "$WID" ]; then
    ok "PD* stamps: host $B, keychain $K, channel local, signing $(stamp PDSigningIdentity "$PL")"
  else
    bad "PD* stamps" "$(plutil -p "$PL" | grep PD)"
  fi
  SIG=$(codesign -dv "$ST" 2>&1)
  if grep -qx "Identifier=$B" <<< "$SIG"; then ok "codesign Identifier=$B"; else bad "codesign identifier" "$SIG"; fi
  if [ "$(stamp PDSigningIdentity "$PL")" != adhoc ]; then
    if codesign -d -r- "$ST" 2>&1 | grep -q 'certificate leaf'; then ok "designated requirement is certificate-based"
    else bad "designated requirement is not certificate-based"; fi
  else
    echo "  – ad-hoc signature: the certificate requirement check doesn't apply"
  fi
  after_app=$(stat -f '%m %z' "$APP_PLIST" 2>/dev/null || echo none)
  after_pids=$(pgrep -x PaperDeck | sort | tr '\n' ' ')
  after_number=$(cat .build_number 2>/dev/null || echo none)
  if [ "$before_app" = "$after_app" ]; then ok "nothing was copied into /Applications"; else bad "the installed app changed ($before_app → $after_app)"; fi
  if [ "$before_pids" = "$after_pids" ]; then ok "no running PaperDeck was stopped"; else bad "running PaperDeck processes changed ($before_pids → $after_pids)"; fi
  if [ "$before_number" = "$after_number" ]; then ok "a staging-only build doesn't use up a build number"; else bad ".build_number changed ($before_number → $after_number)"; fi
fi

echo "$PASS passed, $FAILS failed"
[ "$FAILS" = 0 ]
