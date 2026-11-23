#!/bin/sh
# End-to-end update test, run on macOS.
#
# 1. Build LiteTube 0.0.2 and install it into a scratch folder (not /Applications).
# 2. Build LiteTube 0.0.3, package it as a PKG, and serve it from 127.0.0.1 with the
#    same release JSON and SHA256SUMS shape GitHub publishes.
# 3. Launch the old copy with the release feed pointed at the local server. The app
#    checks, downloads, verifies, unpacks and swaps itself in, then reopens.
# 4. Check the scratch install is 0.0.3, with 0.0.2 kept as LiteTube.app.old.
# 5. Negative run: restore 0.0.2, serve a wrong checksum, and check the update is
#    refused, the installed app is untouched, and the failure is logged.
#
# Quits any running LiteTube first, because the swap helper replaces every running LiteTube.
# Nothing is published to GitHub. Usage: tools/test-update-e2e.sh [scratch-dir]
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
W=${1:-$(mktemp -d "${TMPDIR:-/tmp}/litetube-e2e.XXXXXX")}
OLD=0.0.2
NEW=0.0.3
PORT=${PORT:-8765}
FEED="http://127.0.0.1:$PORT/release.json"
APP="$W/Apps/LiteTube.app"
PLIST_KEY=CFBundleShortVersionString

fail() { echo "E2E FAIL: $1" >&2; exit 1; }
version_of() { /usr/libexec/PlistBuddy -c "Print $PLIST_KEY" "$1/Contents/Info.plist" 2>/dev/null || echo none; }
running_test_app() { pgrep -f "$APP/Contents/MacOS/LiteTube" >/dev/null 2>&1; }
stop_test_app() {
    pkill -f "$APP/Contents/MacOS/LiteTube" 2>/dev/null || true
    n=0; while running_test_app && [ $n -lt 20 ]; do sleep 0.5; n=$((n + 1)); done
}

echo "scratch folder: $W"
mkdir -p "$W/Apps" "$W/release" "$W/old-copy"

# Quit the installed copy so the swap helper only replaces the scratch app.
osascript -e 'tell application "LiteTube" to quit' >/dev/null 2>&1 || true
sleep 2

# Build the old app, then the new package.
cd "$ROOT"
LITETUBE_VERSION=$OLD ./build_app.sh >/dev/null
rm -rf "$W/old-copy/LiteTube.app" && cp -R LiteTube.app "$W/old-copy/"
cp -R "$W/old-copy/LiteTube.app" "$APP"
LITETUBE_VERSION=$NEW ./build_app.sh >/dev/null
LITETUBE_VERSION=$NEW ./make-pkg.sh "$W/release/LiteTube-$NEW-arm64.pkg" >/dev/null
[ "$(version_of "$APP")" = "$OLD" ] || fail "scratch app is not $OLD"

write_feed() {
    # $1 = "good" or "bad" (bad writes a wrong checksum)
    python3 -I - "$W/release" "$NEW" "$PORT" "$1" <<'PY'
import hashlib, json, os, sys
folder, new, port, mode = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
pkg = "LiteTube-%s-arm64.pkg" % new
path = os.path.join(folder, pkg)
digest = hashlib.sha256(open(path, "rb").read()).hexdigest()
if mode == "bad":
    digest = "0" * 64
sums = os.path.join(folder, "SHA256SUMS")
open(sums, "w").write("%s  %s\n" % (digest, pkg))
base = "http://127.0.0.1:%s" % port
release = {
    "tag_name": "v" + new,
    "html_url": base + "/release",
    "body": "Test release notes for the end-to-end check.",
    "assets": [
        {"name": pkg, "browser_download_url": base + "/" + pkg, "size": os.path.getsize(path)},
        {"name": "SHA256SUMS", "browser_download_url": base + "/SHA256SUMS", "size": os.path.getsize(sums)},
    ],
}
open(os.path.join(folder, "release.json"), "w").write(json.dumps(release))
PY
}

write_feed good
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$W/release" >"$W/server.log" 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null || true' EXIT
sleep 1
curl -sf "$FEED" >/dev/null || fail "local release feed is not reachable"

# Positive run: the app updates itself.
echo "run 1: update $OLD -> $NEW"
env LITETUBE_UPDATE_API_URL="$FEED" LITETUBE_UPDATE_AUTOINSTALL=1 "$APP/Contents/MacOS/LiteTube" >"$W/app1.log" 2>&1 &
n=0
while [ "$(version_of "$APP")" != "$NEW" ] && [ $n -lt 240 ]; do sleep 0.5; n=$((n + 1)); done
[ "$(version_of "$APP")" = "$NEW" ] || fail "app still $(version_of "$APP") after 120 s; see $W/app1.log and the update log"
[ "$(version_of "$APP.old")" = "$OLD" ] || fail "previous $OLD copy not kept as LiteTube.app.old"
n=0; while ! running_test_app && [ $n -lt 40 ]; do sleep 0.5; n=$((n + 1)); done
running_test_app || fail "updated app did not reopen"
echo "PASS: installed $(version_of "$APP"), kept $(version_of "$APP.old") as .old, and it reopened"
stop_test_app

# Negative run: a wrong checksum must be refused, and the installed app left as it was.
echo "run 2: wrong checksum must be refused"
rm -rf "$APP" "$APP.old"
cp -R "$W/old-copy/LiteTube.app" "$APP"
write_feed bad
env LITETUBE_UPDATE_API_URL="$FEED" LITETUBE_UPDATE_AUTOINSTALL=1 "$APP/Contents/MacOS/LiteTube" >"$W/app2.log" 2>&1 &
sleep 40
[ "$(version_of "$APP")" = "$OLD" ] || fail "a bad checksum changed the installed app"
LOG="$HOME/Library/Caches/LiteTube/update/install.log"
grep -q "checksum mismatch" "$LOG" 2>/dev/null || fail "the refused update was not logged"
echo "PASS: wrong checksum refused, installed app still $(version_of "$APP"), reason logged"
stop_test_app
write_feed good

echo "E2E PASS"
