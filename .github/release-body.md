## LiteTube

Native macOS YouTube desktop client built with Swift, AppKit, and AVFoundation.

### macOS

Download and open the installer package:

- `LiteTube-*-arm64.pkg` — Apple Silicon (M1 and later)

The installer places LiteTube in `/Applications`. If it is running, the installer
asks whether to quit it; choosing Cancel safely aborts the update.

The app is **unsigned and not notarized**. On first launch macOS
will refuse to open it. Either right-click the app → **Open** →
**Open**, or run:

```sh
xattr -dr com.apple.quarantine /Applications/LiteTube.app
```
