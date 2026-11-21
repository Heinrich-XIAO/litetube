#!/bin/sh
# Build an installable macOS package from LiteTube.app.
#   ./make-pkg.sh [output.pkg]
set -eu
cd "$(dirname "$0")"

if [ "$(uname -s)" != "Darwin" ]; then
    echo "This must run on macOS." >&2
    exit 1
fi

VERSION="${LITETUBE_VERSION:-1.0.0}"
VERSION="${VERSION#v}"
OUT="${1:-LiteTube-$VERSION.pkg}"
APP="LiteTube.app"

if [ ! -d "$APP" ]; then
    echo "$APP is missing - run ./build_app.sh first." >&2
    exit 1
fi
if [ ! -x "$APP/Contents/MacOS/LiteTube" ]; then
    echo "$APP does not contain an executable LiteTube app." >&2
    exit 1
fi

chmod +x macos-pkg-scripts/preinstall
rm -f "$OUT"
pkgbuild \
    --component "$APP" \
    --install-location /Applications \
    --identifier com.litetube.mac \
    --version "$VERSION" \
    --scripts macos-pkg-scripts \
    "$OUT"

echo "built: $(pwd)/$OUT"
