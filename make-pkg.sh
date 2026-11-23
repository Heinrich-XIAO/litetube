#!/bin/sh
# Build an installable macOS package from LiteTube.app.
#   ./make-pkg.sh [output.pkg]
set -eu
cd "$(dirname "$0")"

if [ "$(uname -s)" != "Darwin" ]; then
    echo "This must run on macOS." >&2
    exit 1
fi

default_version() {
    # The newest published tag, so an installed build matches the latest release. 0.0.0 when offline.
    v=$(git -C "$(pwd)" ls-remote --tags --refs origin 2>/dev/null | sed -n 's#.*refs/tags/v\([0-9][0-9.]*\)$#\1#p' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
    echo "${v:-0.0.0}"
}
VERSION="${LITETUBE_VERSION:-$(default_version)}"
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
