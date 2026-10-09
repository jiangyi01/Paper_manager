#!/bin/bash
# Run the Swift Testing suites with Command Line Tools only (no Xcode/XCTest).
# CLT ships Testing.framework outside the default search paths, so point the
# compiler and the runtime loader at it. Extra args pass through, e.g.
#   ./test.sh --filter Scheduler
#   ./test.sh -j 8
# Where Testing.framework lives: PAPERDECK_DEV_DIR (environment, or a PAPERDECK_DEV_DIR=… line in
# build.local.env), else the Command Line Tools default, else derived from `xcode-select -p`.
set -euo pipefail
cd "$(dirname "$0")"

# build.local.env (never sourced): only its PAPERDECK_DEV_DIR line matters here; the environment wins.
if [ -z "${PAPERDECK_DEV_DIR:-}" ] && [ -f build.local.env ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?PAPERDECK_DEV_DIR[[:space:]]*=(.*)$ ]]; then
      val=${BASH_REMATCH[2]}
      val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
      if [[ "$val" =~ ^\"(.*)\"$ ]] || [[ "$val" =~ ^\'(.*)\'$ ]]; then val=${BASH_REMATCH[1]}; fi
      PAPERDECK_DEV_DIR=$val
    fi
  done < build.local.env
fi

# The developer directory that holds Frameworks/Testing.framework (Command Line Tools layout) or
# Library/Frameworks/Testing.framework (an Xcode platform layout), plus usr/lib.
frameworks_in() {
  if [ -d "$1/Frameworks/Testing.framework" ]; then echo "$1/Frameworks"
  elif [ -d "$1/Library/Frameworks/Testing.framework" ]; then echo "$1/Library/Frameworks"
  fi
}
DEV="${PAPERDECK_DEV_DIR:-/Library/Developer/CommandLineTools/Library/Developer}"
FW=$(frameworks_in "$DEV")
if [ -z "$FW" ] && [ -z "${PAPERDECK_DEV_DIR:-}" ]; then
  SEL=$(xcode-select -p 2>/dev/null || true)
  for cand in "$SEL/Library/Developer" "$SEL/Platforms/MacOSX.platform/Developer"; do
    [ -n "$SEL" ] || break
    FW=$(frameworks_in "$cand")
    if [ -n "$FW" ]; then DEV=$cand; break; fi
  done
fi
if [ -z "$FW" ]; then
  echo "❌ Swift Testing (Testing.framework) not found under ${PAPERDECK_DEV_DIR:-the Command Line Tools or \$(xcode-select -p)}." >&2
  echo "   Install the Command Line Tools (xcode-select --install), or set PAPERDECK_DEV_DIR to the folder" >&2
  echo "   that contains Frameworks/Testing.framework (e.g. in build.local.env)." >&2
  exit 1
fi
exec swift test --disable-xctest \
  -Xswiftc -F -Xswiftc "$FW" \
  -Xlinker -rpath -Xlinker "$FW" \
  -Xlinker -rpath -Xlinker "$DEV/usr/lib" \
  "$@"
