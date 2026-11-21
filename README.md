# LiteTube

A native macOS YouTube desktop client built with Swift, AppKit, and AVFoundation engineered to stay under **100 MB RAM** (~60–75 MB physical footprint during active playback vs. 500–700+ MB in Chromium).

## Build & Run

```bash
./build_app.sh
open -n ./LiteTube.app
# Or open directly to a video/timestamp:
open -n ./LiteTube.app --args "https://www.youtube.com/watch?v=E-TF2d2WKwk&t=1535s"
```
