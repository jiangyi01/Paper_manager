#!/bin/bash
# Build PaperDeck.app without Xcode (SwiftPM + manual bundling + codesign) and install it.
#
#   ./build_app.sh [--run] [--dev] [--test] [--no-widget] [--allow-adhoc]
#                  [--bundle-id ID] [--sign NAME|SHA1|-] [--install-dir DIR] [--no-install]
#                  [--package] [--jobs N] [--print-config] [--help]
#
#   --run           launch the app after installing
#   --dev           force AI OFF (defaults agent.mode=off, assist.mode=off, dedupe.ai.auto=false) — used
#                   during development so GUI checks never spend subscription quota. Normal builds
#                   leave the settings alone.
#   --test          run ./test.sh before building
#   --no-widget     skip the WidgetKit extension
#   --allow-adhoc   sign ad-hoc when the signing identity is missing
#                   (TCC/widget/keychain grants then reset on every rebuild)
#   --bundle-id ID  bundle id (reverse DNS); the widget becomes ID.widget
#   --sign X        signing identity: a certificate name, its SHA-1, or "-" for ad-hoc
#   --install-dir D install into D (e.g. ~/Applications) instead of /Applications
#   --no-install    build, stamp, sign and verify in .build/stage only: nothing is copied into the
#                   install folder, no running copy is stopped, nothing is registered or written
#   --package       a copy to give to someone else: channel "distribution", a zip of PaperDeck.app
#                   in dist/ with its .sha256 and INSTALL.md (implies --no-install)
#   --jobs N        parallel build jobs (swift build -j N; also passed to ./test.sh)
#   --print-config  print the resolved configuration and exit (builds nothing)
#
# Configuration, lowest to highest precedence:
#   1. the defaults below (the values every earlier build used);
#   2. build.local.env next to this script (git-ignored; KEY=VALUE lines, # comments; read as
#      data and never sourced; only the keys in ALLOWED_KEYS are accepted);
#   3. PAPERDECK_* environment variables;
#   4. the flags above.
# Keys: PAPERDECK_BUNDLE_ID, PAPERDECK_WIDGET_ID (must start with the bundle id + "."),
#       PAPERDECK_SIGN_IDENTITY, PAPERDECK_INSTALL_DIR, PAPERDECK_KEYCHAIN_SERVICE,
#       PAPERDECK_CHANNEL (local|distribution), PAPERDECK_JOBS, PAPERDECK_DEV_DIR (test.sh).
# Changing the bundle id starts a fresh settings domain, keychain service, permissions and
# widget — settings don't carry over (see docs/BUILDING.md).
#
# The bundle is assembled and verified in .build/stage/PaperDeck.bundle (no .app suffix, so
# LaunchServices never registers the staging copy) and then synced in place into the install folder.
set -euo pipefail
cd "$(dirname "$0")"

fail() { echo "❌ $*" >&2; exit 1; }
usage_fail() { echo "❌ $*" >&2; exit 2; }

# ---- 0. configuration -----------------------------------------------------------------
ALLOWED_KEYS="PAPERDECK_BUNDLE_ID PAPERDECK_WIDGET_ID PAPERDECK_SIGN_IDENTITY PAPERDECK_INSTALL_DIR PAPERDECK_KEYCHAIN_SERVICE PAPERDECK_CHANNEL PAPERDECK_JOBS PAPERDECK_DEV_DIR"

RUN=0; DEV=0; TEST=0; WIDGET=1; ADHOC_OK=0; NO_INSTALL=0; PACKAGE=0; PRINT=0
FLAG_BUNDLE_ID=""; FLAG_SIGN=""; FLAG_INSTALL_DIR=""; FLAG_JOBS=""
need_value() { [ $# -ge 2 ] && [ -n "$2" ] && [ "${2#--}" = "$2" ] || usage_fail "$1 needs a value"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --run) RUN=1 ;;
    --dev) DEV=1 ;;
    --test) TEST=1 ;;
    --no-widget) WIDGET=0 ;;
    --allow-adhoc) ADHOC_OK=1 ;;
    --no-install) NO_INSTALL=1 ;;
    --package) PACKAGE=1 ;;
    --print-config) PRINT=1 ;;
    --bundle-id) need_value "$@"; FLAG_BUNDLE_ID=$2; shift ;;
    --sign) [ $# -ge 2 ] && [ -n "$2" ] || usage_fail "--sign needs a value"; FLAG_SIGN=$2; shift ;;
    --install-dir) need_value "$@"; FLAG_INSTALL_DIR=$2; shift ;;
    --jobs|-j) need_value "$@"; FLAG_JOBS=$2; shift ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) usage_fail "unknown option: $1 (see ./build_app.sh --help)" ;;
  esac
  shift
done

# build.local.env: a value applies only when the environment doesn't set that key.
ENV_FILE=build.local.env
ENV_FILE_USED=0
if [ -f "$ENV_FILE" ]; then
  ENV_FILE_USED=1
  n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line=${line%$'\r'}
    if [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]]; then continue; fi
    if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]]; then
      key=${BASH_REMATCH[2]}; val=${BASH_REMATCH[3]}
      val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
      if [[ "$val" =~ ^\"(.*)\"$ ]] || [[ "$val" =~ ^\'(.*)\'$ ]]; then val=${BASH_REMATCH[1]}; fi
      case " $ALLOWED_KEYS " in
        *" $key "*) ;;
        *) usage_fail "$ENV_FILE:$n: '$key' is not a build setting (allowed: $ALLOWED_KEYS)" ;;
      esac
      if [ -z "${!key:-}" ]; then printf -v "$key" '%s' "$val"; fi
    else
      usage_fail "$ENV_FILE:$n: expected KEY=VALUE"
    fi
  done < "$ENV_FILE"
fi

expand_home() { case "$1" in "~") printf '%s' "$HOME" ;; "~/"*) printf '%s' "$HOME/${1#\~/}" ;; *) printf '%s' "$1" ;; esac; }

BUNDLE_ID="${FLAG_BUNDLE_ID:-${PAPERDECK_BUNDLE_ID:-com.yijiang.paperdeck}}"
[[ "$BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || usage_fail "bundle id '$BUNDLE_ID' is not reverse DNS (letters, digits, hyphens; at least two labels)"
WIDGET_ID="${PAPERDECK_WIDGET_ID:-$BUNDLE_ID.widget}"
case "$WIDGET_ID" in
  "$BUNDLE_ID".*) [[ "$WIDGET_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || usage_fail "widget id '$WIDGET_ID' is not reverse DNS" ;;
  *) usage_fail "widget id '$WIDGET_ID' must start with '$BUNDLE_ID.' (macOS only loads a widget whose id extends its app's)" ;;
esac
IDENTITY="${FLAG_SIGN:-${PAPERDECK_SIGN_IDENTITY:-PaperDeck Local Signing}}"
INSTALL_DIR=$(expand_home "${FLAG_INSTALL_DIR:-${PAPERDECK_INSTALL_DIR:-/Applications}}")
INSTALL_DIR=${INSTALL_DIR%/}
[ -n "$INSTALL_DIR" ] || usage_fail "the install folder can't be /"
KEYCHAIN_SERVICE="${PAPERDECK_KEYCHAIN_SERVICE:-$BUNDLE_ID.mail}"
CHANNEL="${PAPERDECK_CHANNEL:-local}"
[ "$PACKAGE" = 1 ] && CHANNEL=distribution
case "$CHANNEL" in local|distribution) ;; *) usage_fail "PAPERDECK_CHANNEL must be local or distribution (got '$CHANNEL')" ;; esac
JOBS="${FLAG_JOBS:-${PAPERDECK_JOBS:-}}"
if [ -n "$JOBS" ]; then [[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || usage_fail "--jobs must be a positive number (got '$JOBS')"; fi
[ "$PACKAGE" = 1 ] && NO_INSTALL=1

if [ "$PRINT" = 1 ]; then
  echo "bundle=$BUNDLE_ID"
  echo "widget=$WIDGET_ID"
  echo "identity=$IDENTITY"
  echo "install=$INSTALL_DIR"
  echo "keychain=$KEYCHAIN_SERVICE"
  echo "channel=$CHANNEL"
  if [ "$ENV_FILE_USED" = 1 ]; then echo "(with $ENV_FILE)" >&2; fi
  exit 0
fi

if [ "$NO_INSTALL" = 1 ]; then
  [ "$DEV" = 1 ] && usage_fail "--dev writes the installed app's settings; it can't be combined with --no-install/--package"
  [ "$RUN" = 1 ] && usage_fail "--run needs an install; it can't be combined with --no-install/--package"
fi

APP="$INSTALL_DIR/PaperDeck.app"
STAGE=.build/stage/PaperDeck.bundle
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
JOBS_ARGS=(); [ -n "$JOBS" ] && JOBS_ARGS=(-j "$JOBS")

# The widget target only exists once the extension has been added (M7).
if ! grep -q '"PaperDeckWidget"' Package.swift; then WIDGET=0; fi

# ---- 1. signing identity (checked before compiling) ------------------------------------
cert_steps() {
  cat >&2 <<EOF
   Create it once (about a minute):
     1. Open Keychain Access ▸ Keychain Access menu ▸ Certificate Assistant ▸ Create a Certificate…
     2. Name: $1
        Identity Type: Self Signed Root · Certificate Type: Code Signing
     3. Tick "Let me override defaults", Continue, and set Validity Period (days): 3650
     4. Continue through the remaining pages (defaults are fine) and Create.
   Then run this script again. Or pass --allow-adhoc / --sign - (permissions then reset on every build).
EOF
}
SIGN=""; SIGN_NAME=""
if [ "$IDENTITY" = "-" ]; then
  SIGN="-"; SIGN_NAME=adhoc
  echo "⚠️  Signing ad-hoc: TCC (Documents), notifications-by-cdhash and the widget reset on every rebuild."
else
  IDENTITIES=$(security find-identity -p codesigning 2>/dev/null || true)
  if [[ "$IDENTITY" =~ ^[0-9A-Fa-f]{40}$ ]]; then
    MATCH=$(grep -i -m1 "$IDENTITY" <<< "$IDENTITIES" || true)
    [ -n "$MATCH" ] && SIGN_NAME=$(sed -E 's/^[^"]*"(.*)"[^"]*$/\1/' <<< "$MATCH")
  elif grep -qF "\"$IDENTITY\"" <<< "$IDENTITIES"; then
    SIGN_NAME="$IDENTITY"
  fi
  if [ -n "$SIGN_NAME" ]; then
    SIGN="$IDENTITY"
    # Certificate expiry: warn below 60 days (a new certificate means one more set of grants).
    PEM=$(security find-certificate -c "$SIGN_NAME" -p 2>/dev/null || true)
    if [ -n "$PEM" ]; then
      END=$(/usr/bin/openssl x509 -noout -enddate <<< "$PEM" 2>/dev/null | sed 's/^notAfter=//' || true)
      if ! /usr/bin/openssl x509 -noout -checkend $((60 * 86400)) <<< "$PEM" >/dev/null 2>&1; then
        echo "⚠️  The signing certificate \"$SIGN_NAME\" expires ${END:-soon}. Create a new one (same name, Validity 3650 days)"
        echo "    and delete the old one; macOS will ask for Documents and notification access once more."
      fi
    fi
  elif [ "$ADHOC_OK" = 1 ]; then
    SIGN="-"; SIGN_NAME=adhoc
    echo "⚠️  Signing identity \"$IDENTITY\" not found — signing ad-hoc: TCC (Documents), notifications-by-cdhash and the widget reset on every rebuild."
  else
    echo "❌ Signing identity \"$IDENTITY\" not found." >&2
    cert_steps "$IDENTITY"
    exit 1
  fi
fi

[ "$TEST" = 1 ] && ./test.sh "${JOBS_ARGS[@]+"${JOBS_ARGS[@]}"}"

# ---- 2. compile -------------------------------------------------------------------------
swift build -c release "${JOBS_ARGS[@]+"${JOBS_ARGS[@]}"}" --product PaperDeck
[ "$WIDGET" = 1 ] && swift build -c release "${JOBS_ARGS[@]+"${JOBS_ARGS[@]}"}" --product PaperDeckWidget
BIN=$(swift build -c release --show-bin-path)

# Build number: one more than both the last build here and the installed copy.
LAST=$(cat .build_number 2>/dev/null || echo 0); [[ "$LAST" =~ ^[0-9]+$ ]] || LAST=0
INSTALLED=$(plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist" 2>/dev/null || echo 0)
[[ "$INSTALLED" =~ ^[0-9]+$ ]] || INSTALLED=0
BUILD=$(( (LAST > INSTALLED ? LAST : INSTALLED) + 1 ))
# A staging-only check doesn't use up a number; installs and packages do.
if [ "$NO_INSTALL" = 0 ] || [ "$PACKAGE" = 1 ]; then echo "$BUILD" > .build_number; fi
SDK_VER=$(xcrun --show-sdk-version)
SDK_BUILD=$(xcrun --show-sdk-build-version)

# Swift 6 isolation pitfalls that `swift build` cannot catch (warn only). The intended nonisolated
# wrapper of such an API marks its line `// pd-callback-ok` (tools/check_callback_apis.sh).
if [ -x tools/check_callback_apis.sh ] && ! tools/check_callback_apis.sh Sources/PaperDeck; then
  echo "⚠️  callback-style APIs found in the MainActor app target (use async variants / queue: .main / a nonisolated wrapper marked // pd-callback-ok)"
fi

# ---- 3. assemble and stamp in staging ------------------------------------------------------
rm -rf .build/stage
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN/PaperDeck" "$STAGE/Contents/MacOS/PaperDeck"
cp Resources/Info.plist "$STAGE/Contents/Info.plist"
cp Resources/AppIcon.icns "$STAGE/Contents/Resources/AppIcon.icns"
# SwiftPM resource bundles (if any target declares resources)
for rb in "$BIN"/*.bundle; do [ -e "$rb" ] && [[ "$(basename "$rb")" != *Tests* ]] && cp -R "$rb" "$STAGE/Contents/Resources/"; done
PL="$STAGE/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD" "$PL"
plutil -replace DTSDKName -string "macosx$SDK_VER" "$PL"
plutil -replace DTPlatformVersion -string "$SDK_VER" "$PL"
plutil -replace DTSDKBuild -string "$SDK_BUILD" "$PL"
plutil -replace DTPlatformName -string macosx "$PL"
# Identity (Resources/*.plist keep their literals; with the defaults these are the same values).
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$PL"
plutil -replace CFBundleURLTypes.0.CFBundleURLName -string "$BUNDLE_ID" "$PL"
plutil -replace PDHostBundleIdentifier -string "$BUNDLE_ID" "$PL"
plutil -replace PDKeychainService -string "$KEYCHAIN_SERVICE" "$PL"
plutil -replace PDSigningIdentity -string "$SIGN_NAME" "$PL"
plutil -replace PDBuildChannel -string "$CHANNEL" "$PL"

if [ "$WIDGET" = 1 ]; then
  APPEX="$STAGE/Contents/PlugIns/PaperDeckWidget.appex"
  mkdir -p "$APPEX/Contents/MacOS"
  cp "$BIN/PaperDeckWidget" "$APPEX/Contents/MacOS/PaperDeckWidget"
  cp Resources/PaperDeckWidget-Info.plist "$APPEX/Contents/Info.plist"
  WPL="$APPEX/Contents/Info.plist"
  plutil -replace CFBundleVersion -string "$BUILD" "$WPL"
  plutil -replace DTSDKName -string "macosx$SDK_VER" "$WPL"
  plutil -replace DTPlatformVersion -string "$SDK_VER" "$WPL"
  plutil -replace DTSDKBuild -string "$SDK_BUILD" "$WPL"
  plutil -replace DTPlatformName -string macosx "$WPL"
  plutil -replace CFBundleIdentifier -string "$WIDGET_ID" "$WPL"
  plutil -replace PDHostBundleIdentifier -string "$BUNDLE_ID" "$WPL"
fi

# ---- 4. sign (inner first, never --deep) --------------------------------------------
if [ "$WIDGET" = 1 ]; then
  codesign --force --sign "$SIGN" --identifier "$WIDGET_ID" \
    --entitlements Resources/PaperDeckWidget.entitlements "$APPEX"
fi
codesign --force --sign "$SIGN" --identifier "$BUNDLE_ID" "$STAGE"

# ---- 5. verify in staging ---------------------------------------------------------
codesign --verify --deep --strict "$STAGE" || fail "codesign verification failed"
SIGINFO=$(codesign -dv "$STAGE" 2>&1)
grep -qx "Identifier=$BUNDLE_ID" <<< "$SIGINFO" || fail "wrong signing identifier"
if [ "$SIGN" != "-" ]; then
  DR=$(codesign -d -r- "$STAGE" 2>&1)
  grep -q 'certificate leaf' <<< "$DR" \
    || fail "designated requirement is not certificate-based (would reset TCC grants every build)"
fi
plutil -lint "$PL" >/dev/null || fail "Info.plist invalid"
VT=$(vtool -show-build "$STAGE/Contents/MacOS/PaperDeck")
grep -q 'minos 26' <<< "$VT" || fail "unexpected minos"
if [ "$WIDGET" = 1 ]; then
  plutil -lint "$WPL" >/dev/null || fail "widget Info.plist invalid"
  ENT=$(codesign -d --entitlements - "$APPEX" 2>/dev/null)
  grep -q 'com.apple.security.app-sandbox' <<< "$ENT" \
    || fail "widget is not sandboxed (pkd would refuse it)"
  W="$APPEX/Contents/MacOS/PaperDeckWidget"
  UNDEF=$(nm -u "$W"); DEFS=$(nm -gU "$W")
  grep -q '_NSExtensionMain' <<< "$UNDEF" || fail "widget does not reference _NSExtensionMain"
  grep -q ' _main$' <<< "$DEFS" || fail "widget lost its Swift main (WidgetBundle.main())"
  ENTRY=$(otool -l "$W" | awk '/LC_MAIN/{f=1} f&&/entryoff/{print $2; exit}')
  STUBS=$(otool -l "$W" | awk '/sectname __stubs/{f=1} f&&/offset/{print $2; exit}')
  STUBS_SIZE=$(otool -l "$W" | awk '/sectname __stubs/{f=1} f&&/size/{print $2; exit}')
  if [ -n "$ENTRY" ] && [ -n "$STUBS" ]; then
    E=$((ENTRY)); S=$((STUBS)); Z=$((STUBS_SIZE))
    { [ "$E" -ge "$S" ] && [ "$E" -lt $((S + Z)) ]; } || fail "widget LC_MAIN does not point at the _NSExtensionMain stub"
  fi
fi

# ---- 6. package (a copy for someone else; never installed here) -------------------------------
if [ "$PACKAGE" = 1 ]; then
  VERSION=$(plutil -extract CFBundleShortVersionString raw -o - "$PL")
  mkdir -p dist
  ZIP="dist/PaperDeck-$VERSION-$BUILD.zip"
  PKG=$(mktemp -d "${TMPDIR:-/tmp}/paperdeck-package.XXXXXX")
  ditto "$STAGE" "$PKG/PaperDeck.app"
  rm -f "$ZIP" "$ZIP.sha256"
  ditto -c -k --sequesterRsrc --keepParent "$PKG/PaperDeck.app" "$ZIP"
  "$LSREG" -u "$PKG/PaperDeck.app" 2>/dev/null || true
  rm -rf "$PKG"
  ( cd dist && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256" )
  if [ -f docs/INSTALL_RECIPIENT.md ]; then cp docs/INSTALL_RECIPIENT.md dist/INSTALL.md; fi
  echo "📦 $ZIP ($(cut -d' ' -f1 < "$ZIP.sha256" | cut -c1-12)…) + dist/INSTALL.md — send both; never send the signing certificate."
fi

if [ "$NO_INSTALL" = 1 ]; then
  echo "✅ Staged $STAGE (build $BUILD, bundle $BUNDLE_ID, signed: $SIGN_NAME, channel $CHANNEL) — not installed"
  exit 0
fi

# ---- 7. stop the running copy of THIS install (SIGTERM → graceful applicationShouldTerminate) ----
APP_RE=$(printf '%s' "$APP" | sed 's/[][\.*^$()+?{}|]/\\&/g')
running() { pgrep -f "^$APP_RE/Contents/MacOS/PaperDeck( |$)" || true; }
PIDS=$(running)
if [ -n "$PIDS" ]; then
  kill -TERM $PIDS 2>/dev/null || true
  for _ in $(seq 1 50); do [ -z "$(running)" ] && break; sleep 0.1; done
  PIDS=$(running)
  if [ -n "$PIDS" ]; then kill -KILL $PIDS 2>/dev/null || true; fi
fi

# ---- 8. install in place ------------------------------------------------------------
mkdir -p "$APP"
/usr/bin/rsync -a --delete "$STAGE/" "$APP/"
codesign --verify --deep --strict "$APP" || fail "installed bundle failed verification"

# ---- 9. dev mode: never spend AI quota from GUI checks ---------------------------
if [ "$DEV" = 1 ]; then
  defaults write "$BUNDLE_ID" agent.mode off
  defaults write "$BUNDLE_ID" assist.mode off
  defaults write "$BUNDLE_ID" dedupe.ai.auto -bool false
  echo "ℹ️  AI reading, Explain & Ask and the automatic duplicate judge forced OFF (dev build)."
fi

# ---- 10. register --------------------------------------------------------------------
"$LSREG" -f -R -trusted "$APP" 2>/dev/null || true
[ "$WIDGET" = 1 ] && pluginkit -a "$APP/Contents/PlugIns/PaperDeckWidget.appex" 2>/dev/null || true
OTHERS=$("$LSREG" -dump 2>/dev/null | grep -oE 'path: +[^(]*PaperDeck\.(app|bundle)' | sed 's/path: *//' | sort -u | grep -v "^$APP\$" || true)
if [ -n "$OTHERS" ]; then
  echo "⚠️  Other registered PaperDeck copies (can shadow the installed one):"
  echo "$OTHERS" | sed 's/^/     /'
  echo "   Remove with: $LSREG -u <path>"
fi

echo "✅ Built $APP (build $BUILD, signed: $SIGN_NAME)"
if [ "$RUN" = 1 ]; then open "$APP"; echo "Launched."; fi
