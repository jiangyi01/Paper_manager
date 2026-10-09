#!/bin/bash
# Copy real papers into a read-only dev fixture folder (for `--selftest import|all`). Originals
# are never moved or modified; their hashes are recorded so we can prove that later:
#   shasum -a 256 -c ~/Library/Caches/PaperDeck-dev/fixtures/ORIGINALS.sha256      (fixtures untouched)
#   shasum -a 256 -c ~/Library/Caches/PaperDeck-dev/fixtures/SOURCES.sha256        (originals untouched)
#
# Which PDFs (nothing personal is built in — pick any papers you have):
#   tools/make_fixtures.sh PAPER.pdf [MORE.pdf …]
#   tools/make_fixtures.sh --list FILE            one PDF path per line; blank lines and # comments
#                                                 are skipped; a leading ~/ is your home folder
#   PAPERDECK_FIXTURE_LIST=FILE tools/make_fixtures.sh
# The folder is replaced each run. A non-PDF "bad/fake.pdf" is always added.
set -euo pipefail
FIX="$HOME/Library/Caches/PaperDeck-dev/fixtures"

SOURCES=()
add_list() {
  [ -f "$1" ] || { echo "❌ list file not found: $1" >&2; exit 2; }
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    case "$line" in ""|"#"*) continue ;; "~/"*) line="$HOME/${line#\~/}" ;; esac
    SOURCES+=("$line")
  done < "$1"
}
while [ $# -gt 0 ]; do
  case "$1" in
    --list) [ $# -ge 2 ] || { echo "❌ --list needs a file" >&2; exit 2; }; add_list "$2"; shift ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) SOURCES+=("$1") ;;
  esac
  shift
done
if [ ${#SOURCES[@]} -eq 0 ] && [ -n "${PAPERDECK_FIXTURE_LIST:-}" ]; then add_list "$PAPERDECK_FIXTURE_LIST"; fi
if [ ${#SOURCES[@]} -eq 0 ]; then
  echo "❌ no PDFs given. Usage: tools/make_fixtures.sh PAPER.pdf … | --list FILE (or PAPERDECK_FIXTURE_LIST=FILE)" >&2
  exit 2
fi

if [ -d "$FIX" ]; then chmod -R u+w "$FIX"; rm -rf "$FIX"; fi
mkdir -p "$FIX/bad"
: > "$FIX/SOURCES.sha256"
for src in "${SOURCES[@]}"; do
  if [ ! -f "$src" ]; then echo "⚠️  missing: $src"; continue; fi
  name=$(basename "$src")
  if [ -e "$FIX/$name" ]; then echo "⚠️  skipped (same file name already copied): $src"; continue; fi
  cp -p "$src" "$FIX/$name"
  shasum -a 256 "$src" >> "$FIX/SOURCES.sha256"
done
printf 'This is plain text pretending to be a PDF.\n' > "$FIX/bad/fake.pdf"
( cd "$FIX" && shopt -s nullglob && shasum -a 256 *.pdf bad/fake.pdf > ORIGINALS.sha256 )
chmod -R a-w "$FIX"/*.pdf "$FIX/bad/fake.pdf" 2>/dev/null || true
COUNT=$(find "$FIX" -maxdepth 1 -name '*.pdf' | wc -l | tr -d ' ')
echo "✅ $COUNT fixtures in $FIX"
