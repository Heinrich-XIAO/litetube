#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

default_version() {
    # The newest published tag, so an installed build matches the latest release. 0.0.0 when offline.
    v=$(git -C "$ROOT_DIR" ls-remote --tags --refs origin 2>/dev/null | sed -n 's#.*refs/tags/v\([0-9][0-9.]*\)$#\1#p' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
    echo "${v:-0.0.0}"
}
VERSION="${LITETUBE_VERSION:-$(default_version)}"
VERSION="${VERSION#v}"

echo "Building LiteTube $VERSION (release, arm64)..."
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/LiteTube"
APP_DIR="$ROOT_DIR/LiteTube.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/LiteTube"
chmod +x "$APP_DIR/Contents/MacOS/LiteTube"
if [ -f "$ROOT_DIR/AppIcon.icns" ]; then
    cp "$ROOT_DIR/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>LiteTube</string>
    <key>CFBundleIdentifier</key>
    <string>com.litetube.mac</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>LiteTube</string>
    <key>CFBundleDisplayName</key>
    <string>LiteTube</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>LiteTube URL</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>litetube</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP_DIR"
echo "Built: $APP_DIR (version $VERSION)"
ls -lh "$APP_DIR/Contents/MacOS/LiteTube"
