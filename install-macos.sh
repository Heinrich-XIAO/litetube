#!/bin/sh
# Install LiteTube.app into /Applications. Run this ON macOS.
set -eu
cd "$(dirname "$0")"

if [ "$(uname -s)" != "Darwin" ]; then
    echo "This must run on macOS." >&2
    exit 1
fi

./build_app.sh
rm -rf /Applications/LiteTube.app
cp -R LiteTube.app /Applications/
echo "installed /Applications/LiteTube.app"
echo "First launch: right-click > Open (the app is unsigned)."
