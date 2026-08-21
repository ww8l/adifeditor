#!/bin/sh
#
# Render docs/manual/manual.html to docs/ADIF-Editor-Manual.pdf.
#
# Why headless Chrome: it is the only HTML-to-PDF engine already on this machine, and
# adding one would be a new build dependency for a document. Chrome honours @page, and
# break-inside on figures, which is the whole of what the layout needs.
#
# Not wired into ci-local.sh, bundle.sh or either workflow: the manual is rebuilt by hand
# when it changes, not on every build.
#
# Usage:
#   Scripts/manual.sh            render the PDF
#   Scripts/manual.sh open       render it and open it in Preview

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/docs/manual"
STAGE="$ROOT/.build/manual"
OUT="$ROOT/docs/ADIF-Editor-Manual.pdf"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

[ -x "$CHROME" ] || {
    echo "error: Google Chrome is not at $CHROME" >&2
    echo "       It is what renders the PDF; install it or edit this script." >&2
    exit 1
}

# The version comes from the git tag rather than from the HTML, so the cover cannot
# carry a number that was right three releases ago. Same source of truth as the release
# workflow (decision 19).
VERSION="$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null || echo "unreleased")"
DATE="$(date '+%-d %B %Y')"

echo "Staging ($VERSION)…"
rm -rf "$STAGE"
mkdir -p "$STAGE/images"
cp "$SOURCE/manual.css" "$STAGE/"
# Copied rather than referenced in place so the staged copy is self-contained and the
# substitution below never touches the tracked file.
[ -n "$(ls -A "$SOURCE/images" 2>/dev/null)" ] && cp "$SOURCE"/images/* "$STAGE/images/"

# The cover's icon is the app's own, generated from the one source of truth rather than
# committed a second time under docs/ — the same reason bundle.sh generates the .icns.
sips -z 512 512 "$ROOT/Support/Icon/AppIcon-1024.png" \
    --out "$STAGE/images/app-icon.png" >/dev/null
[ -s "$STAGE/images/app-icon.png" ] || {
    echo "error: the cover icon was not produced from Support/Icon/AppIcon-1024.png" >&2
    exit 1
}

sed -e "s/{{VERSION}}/$VERSION/g" -e "s/{{DATE}}/$DATE/g" \
    "$SOURCE/manual.html" > "$STAGE/manual.html"

# Every figure the HTML asks for has to exist: a missing one renders as a silent gap in
# a document nobody proofreads twice.
MISSING="$(grep -o 'images/[a-z0-9-]*\.png' "$STAGE/manual.html" | sort -u | while read -r image; do
    [ -f "$STAGE/$image" ] || echo "$image"
done)"
[ -z "$MISSING" ] || {
    echo "error: the manual references figures that are not in docs/manual/images:" >&2
    echo "$MISSING" | sed 's/^/       /' >&2
    exit 1
}

echo "Rendering…"
# Stale output first: the wait below decides Chrome is finished by watching the file
# appear and stop growing, and an old PDF sitting there would satisfy it instantly.
rm -f "$OUT"

# A separate profile directory: without it this fights with the Chrome the user already
# has open and simply does nothing.
"$CHROME" \
    --headless=new \
    --disable-gpu \
    --no-first-run \
    --no-default-browser-check \
    --disable-extensions \
    --no-pdf-header-footer \
    --user-data-dir="$STAGE/chrome-profile" \
    --print-to-pdf="$OUT" \
    "file://$STAGE/manual.html" >/dev/null 2>&1 &
CHROME_PID=$!

# This build of Chrome writes the PDF and then does not exit, so waiting on it hangs
# forever. Watch the file instead: done when it exists and has stopped growing.
elapsed=0
size=0
while [ "$elapsed" -lt 90 ]; do
    sleep 1
    elapsed=$((elapsed + 1))
    [ -s "$OUT" ] || continue
    current="$(stat -f%z "$OUT")"
    [ "$current" = "$size" ] && break
    size="$current"
done
kill "$CHROME_PID" 2>/dev/null || true
wait "$CHROME_PID" 2>/dev/null || true

[ -s "$OUT" ] || { echo "error: no PDF was produced" >&2; exit 1; }

echo "Wrote $OUT ($(du -h "$OUT" | cut -f1))"

[ "${1:-}" = "open" ] && open "$OUT"
exit 0
