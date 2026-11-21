# LiteTube

A native macOS YouTube desktop client built with Swift, AppKit, and AVFoundation engineered to stay under **100 MB RAM** (~60–75 MB physical footprint during active playback vs. 500–700+ MB in Chromium).

## Install

Download and open `LiteTube-*-arm64.pkg` from [GitHub Releases](https://github.com/Heinrich-XIAO/litetube/releases). It installs `LiteTube.app` into `/Applications` (so Spotlight and Raycast pick it up) and asks before quitting an already running copy. The app is unsigned, so right-click → **Open** the first time (or run `xattr -dr com.apple.quarantine /Applications/LiteTube.app`).

## Build & Run

```bash
./install-macos.sh          # build & install /Applications/LiteTube.app
./build_app.sh              # just build ./LiteTube.app
./make-pkg.sh               # package LiteTube.app as LiteTube-<version>.pkg

open -a LiteTube
# Or open directly to a video/timestamp:
open -n /Applications/LiteTube.app --args "https://www.youtube.com/watch?v=E-TF2d2WKwk&t=1535s"
```

CI builds and publishes the Apple Silicon PKG on every push to `main` (`.github/workflows/auto-release.yml`) and on `v*` tags (`.github/workflows/release.yml`).
