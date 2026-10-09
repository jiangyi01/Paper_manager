#!/bin/bash
# Swift 6 isolation pitfalls that `swift build` cannot catch: callback-style Apple APIs in the
# MainActor app target (their callbacks run off the main thread). build_app.sh runs this and
# warns; Tests/PaperDeckCoreTests/PortFixesApp runs it over the sources.
#
#   tools/check_callback_apis.sh [DIR]      DIR defaults to Sources/PaperDeck
#
# Prints every hit (file:line:text) and exits 1; exits 0 when there is none. The intended
# nonisolated wrapper of such an API carries the marker comment `pd-callback-ok` on the same line
# and is skipped (the marker is the only opt-out: no file is excluded wholesale).
set -uo pipefail
cd "$(dirname "$0")/.."
DIR=${1:-Sources/PaperDeck}
PATTERN='getNotificationSettings|getPendingNotificationRequests|getDeliveredNotifications|getCurrentConfigurations|requestAuthorization\(.*\) *\{|\.add\(.*\) *\{ *(error|_)|queue: *nil'
HITS=$(grep -rnE "$PATTERN" "$DIR" 2>/dev/null | grep -v 'pd-callback-ok')
if [ -n "$HITS" ]; then
  printf '%s\n' "$HITS"
  exit 1
fi
exit 0
