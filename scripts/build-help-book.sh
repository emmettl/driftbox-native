#!/bin/sh
# Generate the Mac's offline Help Book from DriftboxHelp, then index both words and anchors.
# Run before signing the app. No registration or cache changes are made by this script.
set -eu
cd "$(dirname "$0")/.."
. scripts/version.env
book=${1:-.build-release/Driftbox.help}
mkdir -p .build/help-book
swiftc -O -module-name DriftboxHelpGenerator Sources/DriftboxHelp/*.swift \
  scripts/help-book/main.swift -o .build/help-book/generate
.build/help-book/generate "$book" "$DRIFTBOX_VERSION" "$DRIFTBOX_BUILD"
language="$book/Contents/Resources/en.lproj"
/usr/bin/hiutil -I corespotlight -C -a -f "$language/search.cshelpindex" "$language"
# A successful process without an index is not a shippable Help Book.
test -s "$language/search.cshelpindex"
python3 scripts/check-help-book.py "$book"
