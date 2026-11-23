import AppKit
import CryptoKit

/// In-app updates from GitHub Releases. A Swift port of Kotassium's updater.py, with the same steps:
/// check the latest release, download the arm64 PKG, verify it against SHA256SUMS, unpack the app,
/// and hand a detached helper the swap. The helper waits for the quit, parks the current app as
/// LiteTube.app.old, moves the new bundle into place and reopens it. macOS Installer is the fallback
/// for locations the app cannot replace itself. A failed swap writes its reason to the cache,
/// and the next launch shows it.
final class AppUpdater {
    static let shared = AppUpdater()
    static let didChange = Notification.Name("LiteTubeUpdaterDidChange")

    static let repo = "Heinrich-XIAO/litetube"
    /// The release feed. LITETUBE_UPDATE_API_URL points tests at a local copy of the same JSON shape.
    static var api: String {
        ProcessInfo.processInfo.environment["LITETUBE_UPDATE_API_URL"]
            ?? "https://api.github.com/repos/\(repo)/releases/latest"
    }
    static let userAgent = "LiteTube-Updater"
    static let bundleID = "com.litetube.mac"
    static let checkInterval: TimeInterval = 6 * 3600

    enum Phase: Equatable { case idle, checking, downloading, installing, ready, failed }

    struct Status {
        var phase: Phase = .idle
        var pct = 0
        var error: String?
        var available = false
        var latest: String?
        var url: String?
        var notes: String?
        var checked: Date?
    }

    struct Asset { let name: String; let url: URL; let size: Int64 }
    struct Release { let tag: String; let htmlURL: String; let body: String; let assets: [Asset] }

    /// Mutated only on the main thread; read it there.
    private(set) var status = Status()
    private var release: Release?
    private var timer: Timer?
    private var autoInstallStarted = false

    // MARK: - Environment

    /// The running bundle, or nil when this is a plain build (swift run, Xcode) rather than LiteTube.app.
    static var appPath: String? {
        let path = Bundle.main.bundlePath
        return path.hasSuffix(".app") ? path : nil
    }

    var supported: Bool { AppUpdater.appPath != nil }

    var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    var arch: String {
        var sys = utsname()
        uname(&sys)
        let machine = withUnsafePointer(to: &sys.machine) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }.lowercased()
        return ["arm64", "aarch64"].contains(machine) ? "arm64" : "x86_64"
    }

    /// True when this copy can be updated through the swap or the Installer.
    var canInstall: Bool {
        guard let app = AppUpdater.appPath else { return false }
        if app.contains("/AppTranslocation/") || app.hasPrefix("/Volumes/") { return false }
        // /Applications is handled by the Installer even when the user cannot write there.
        if app == "/Applications/LiteTube.app" { return true }
        return FileManager.default.isWritableFile(atPath: (app as NSString).deletingLastPathComponent)
    }

    /// The in-place swap needs only the write bit on the folder holding the app. When it is missing,
    /// the verified package goes to macOS Installer instead (the same split as can_swap() in updater.py).
    var canSwap: Bool {
        guard let app = AppUpdater.appPath else { return false }
        if app.contains("/AppTranslocation/") || app.hasPrefix("/Volumes/") { return false }
        return FileManager.default.isWritableFile(atPath: (app as NSString).deletingLastPathComponent)
    }

    var rollbackAvailable: Bool {
        guard supported, canInstall, AppUpdater.appPath == "/Applications/LiteTube.app" else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: "/Applications/LiteTube.app.old", isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: - Lifecycle

    /// Call once at launch. Reports a swap failure left by an earlier update, then checks in the background.
    func start() {
        if let text = AppUpdater.takeFailure() {
            mutate { $0.phase = .failed; $0.error = text }
        }
        guard supported else { return }
        if ProcessInfo.processInfo.environment["LITETUBE_UPDATE_AUTOINSTALL"] == "1" {
            // Test hook for the end-to-end run: accept the first offered update without a click.
            NotificationCenter.default.addObserver(forName: AppUpdater.didChange, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.status.available, self.status.phase == .idle, !self.autoInstallStarted else { return }
                self.autoInstallStarted = true
                self.startInstall()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.checkInBackground() }
        timer = Timer.scheduledTimer(withTimeInterval: AppUpdater.checkInterval, repeats: true) { [weak self] _ in
            self?.checkInBackground()
        }
    }

    /// Hide the banner for the offered version, and clear a failure so the page stops showing it.
    func dismissBanner() {
        if let latest = status.latest {
            UserDefaults.standard.set(latest, forKey: UpdateBanner.dismissedKey)
        }
        mutate { s in
            if s.phase == .failed { s.phase = .idle; s.error = nil }
        }
    }

    /// Manual "Check for Updates". Does nothing while another check or install is running.
    func checkNow() {
        if let text = AppUpdater.takeFailure() {
            mutate { $0.phase = .failed; $0.error = text }
        }
        guard status.phase == .idle || status.phase == .failed else { return }
        mutate { $0.phase = .checking; $0.error = nil }
        Task { await self.performCheck() }
    }

    private func checkInBackground() {
        guard status.phase == .idle || status.phase == .failed else { return }
        checkNow()
    }

    // MARK: - Check

    private func performCheck() async {
        do {
            let rel = try await fetchLatest()
            let (pkg, _) = AppUpdater.assets(of: rel, arch: arch)
            let available = AppUpdater.isNewer(rel.tag, than: currentVersion) && pkg != nil
            mutate { s in
                s.phase = .idle
                s.latest = AppUpdater.trimmedTag(rel.tag)
                s.url = rel.htmlURL
                s.notes = String(rel.body.prefix(2000))
                s.available = available
                s.checked = Date()
                s.error = pkg == nil ? "no build for this Mac in \(rel.tag)" : nil
                if !available { s.latest = nil }
            }
            if available { setRelease(rel) } else { setRelease(nil) }
        } catch {
            mutate { s in
                s.phase = .idle
                s.available = false
                s.latest = nil
                s.error = "update check failed: \(error.localizedDescription)"
            }
        }
    }

    private func fetchLatest() async throws -> Release {
        var req = URLRequest(url: URL(string: AppUpdater.api)!)
        req.setValue(AppUpdater.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: req)
        return try AppUpdater.parseRelease(data)
    }

    // MARK: - Install

    /// Download, verify and install in one go. Mirrors start_install() in updater.py.
    func startInstall() {
        guard supported else {
            mutate { $0.error = "LiteTube can only update from the installed app" }
            return
        }
        guard canInstall else {
            mutate { $0.error = "LiteTube can only update from an installed app outside a disk image. Move it to Applications and try again." }
            return
        }
        guard status.phase == .idle || status.phase == .failed else { return }
        mutate { $0.phase = .downloading; $0.pct = 0; $0.error = nil }
        Task { await self.install() }
    }

    private func install() async {
        do {
            let rel = try await releaseForInstall()
            let (pkg, sums) = AppUpdater.assets(of: rel, arch: arch)
            guard let package = pkg else {
                throw UpdateError("no build for this Mac in \(rel.tag)")
            }
            let file = try await download(package, sums: sums)
            mutate { $0.phase = .installing; $0.pct = 100 }

            var staged: URL?
            if canSwap {
                do { staged = try stage(file) } catch {
                    AppUpdater.log("could not unpack \(file.lastPathComponent): \(error.localizedDescription)")
                }
            }
            guard let newApp = staged else {
                openInstaller(file)
                return
            }
            try launchSwap(newApp: newApp, package: file)
            quitRunningApp()
            watchForFailure()
        } catch {
            AppUpdater.log("install failed: \(error.localizedDescription)")
            mutate { $0.phase = .failed; $0.pct = 0; $0.error = error.localizedDescription }
        }
    }

    private func releaseForInstall() async throws -> Release {
        let cached = await MainActor.run { self.release }
        if let rel = cached, AppUpdater.isNewer(rel.tag, than: currentVersion),
           AppUpdater.assets(of: rel, arch: arch).0 != nil {
            return rel
        }
        return try await fetchLatest()
    }

    private func setRelease(_ rel: Release?) {
        DispatchQueue.main.async { self.release = rel }
    }

    private func mutate(_ change: @escaping (inout Status) -> Void) {
        let apply = {
            change(&self.status)
            NotificationCenter.default.post(name: AppUpdater.didChange, object: self)
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    // MARK: - Download

    private func download(_ asset: Asset, sums: Asset?) async throws -> URL {
        AppUpdater.pruneCache()
        let dest = AppUpdater.cacheDir.appendingPathComponent(asset.name)
        let part = dest.appendingPathExtension("part")
        let want = await checksum(for: asset.name, in: sums)

        try await FileDownloader.fetch(from: asset.url, to: part, expectedSize: asset.size) { pct in
            self.mutate { $0.pct = pct }
        }
        let digest = try AppUpdater.sha256(of: part)
        if let want, digest != want {
            try? FileManager.default.removeItem(at: part)
            throw UpdateError("checksum mismatch for \(asset.name)")
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: part, to: dest)
        mutate { $0.pct = 100 }
        return dest
    }

    private func checksum(for name: String, in sums: Asset?) async -> String? {
        guard let sums else { return nil }
        var req = URLRequest(url: sums.url)
        req.setValue(AppUpdater.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return AppUpdater.parseChecksums(String(decoding: data, as: UTF8.self), name: name)
    }

    // MARK: - Stage (unpack the PKG without Installer)

    private func stage(_ package: URL) throws -> URL {
        let fm = FileManager.default
        let dest = AppUpdater.cacheDir.appendingPathComponent("LiteTube.new.app")
        let work = AppUpdater.cacheDir.appendingPathComponent("stage.work")
        try? fm.removeItem(at: work)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let expanded = work.appendingPathComponent("expanded")
        var bundle: URL?
        if (try? AppUpdater.run("/usr/sbin/pkgutil", ["--expand-full", package.path, expanded.path]))?.status == 0 {
            bundle = AppUpdater.findBundle(in: expanded)
        }
        if bundle == nil {
            // Older macOS has no --expand-full: expand, then unpack the payload (gzip or bare cpio) ourselves.
            try? fm.removeItem(at: expanded)
            let (code, out) = try AppUpdater.run("/usr/sbin/pkgutil", ["--expand", package.path, expanded.path])
            guard code == 0 else { throw UpdateError("could not expand the package: \(out)") }
            guard let payload = AppUpdater.findFile(named: "Payload", in: expanded) else {
                throw UpdateError("no payload in \(package.lastPathComponent)")
            }
            let payloadDir = work.appendingPathComponent("payload")
            try fm.createDirectory(at: payloadDir, withIntermediateDirectories: true)
            let head = (try? FileHandle(forReadingFrom: payload).readData(ofLength: 2)) ?? Data()
            let script: String
            if head == Data([0x1f, 0x8b]) {
                script = "/usr/bin/gzip -dc \"$1\" | (cd \"$2\" && /usr/bin/cpio -idm)"
            } else if head == Data([0x30, 0x37]) {
                script = "(cd \"$2\" && /usr/bin/cpio -idm) < \"$1\""
            } else {
                throw UpdateError("unsupported package payload for \(package.lastPathComponent)")
            }
            let (c, o) = try AppUpdater.run("/bin/sh", ["-c", script, "sh", payload.path, payloadDir.path])
            guard c == 0 else { throw UpdateError("could not unpack the payload: \(o)") }
            bundle = AppUpdater.findBundle(in: payloadDir)
        }
        guard let found = bundle else { throw UpdateError("no LiteTube.app inside \(package.lastPathComponent)") }
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: found, to: dest)
        AppUpdater.ensureRunnable(dest)
        return dest
    }

    // MARK: - Swap helper

    private func launchSwap(newApp: URL, package: URL) throws {
        let script = AppUpdater.cacheDir.appendingPathComponent("swap.sh")
        let text = AppUpdater.swapScript(newApp: newApp.path, target: AppUpdater.appPath ?? "/Applications/LiteTube.app", package: package.path)
        try text.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        AppUpdater.log("swap helper started for \(newApp.lastPathComponent)")
    }

    private func quitRunningApp() {
        _ = try? AppUpdater.run("/usr/bin/osascript", ["-e", "tell application id \"\(AppUpdater.bundleID)\" to quit"])
    }

    /// The helper reports failures into the cache. Read them while this process is still alive.
    private func watchForFailure() {
        DispatchQueue.global().async {
            let end = Date().addingTimeInterval(90)
            while Date() < end {
                Thread.sleep(forTimeInterval: 1)
                if let text = AppUpdater.takeFailure() {
                    self.mutate { s in
                        if s.phase == .installing || s.phase == .ready {
                            s.phase = .failed; s.error = String(text.prefix(300)); s.pct = 0
                        }
                    }
                    return
                }
            }
        }
    }

    /// Fallback: macOS Installer owns the replacement, with its own confirmation.
    private func openInstaller(_ package: URL) {
        AppUpdater.log("handing \(package.lastPathComponent) to macOS Installer")
        _ = try? AppUpdater.run("/usr/bin/open", ["-a", "Installer", package.path])
        mutate { $0.phase = .ready; $0.pct = 100 }
    }

    // MARK: - Pure helpers (also exercised by SelfTest)

    struct UpdateError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static func parseVersion(_ text: String) -> [Int] {
        let nums = text.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap { Int($0) }
        return nums.isEmpty ? [0] : Array(nums.prefix(3))
    }

    static func isNewer(_ latest: String, than current: String) -> Bool {
        var a = parseVersion(latest), b = parseVersion(current)
        let n = max(a.count, b.count)
        a += Array(repeating: 0, count: n - a.count)
        b += Array(repeating: 0, count: n - b.count)
        return a.lexicographicallyPrecedes(b) == false && a != b
    }

    static func trimmedTag(_ tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    static func assets(of rel: Release, arch: String) -> (pkg: Asset?, sums: Asset?) {
        let pkg = rel.assets.first { $0.name.hasSuffix(".pkg") && $0.name.contains(arch) }
        let sums = rel.assets.first { $0.name.uppercased().hasPrefix("SHA256SUMS") }
        return (pkg, sums)
    }

    static func parseRelease(_ data: Data) throws -> Release {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UpdateError("unexpected response from GitHub")
        }
        let raw = (obj["assets"] as? [[String: Any]]) ?? []
        let assets: [Asset] = raw.compactMap { a in
            guard let name = a["name"] as? String,
                  let url = (a["browser_download_url"] as? String).flatMap(URL.init(string:)) else { return nil }
            return Asset(name: name, url: url, size: (a["size"] as? NSNumber)?.int64Value ?? 0)
        }
        return Release(tag: obj["tag_name"] as? String ?? "",
                       htmlURL: obj["html_url"] as? String ?? "",
                       body: obj["body"] as? String ?? "",
                       assets: assets)
    }

    static func parseChecksums(_ text: String, name: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            if parts.count == 2, parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "*")) == name {
                return String(parts[0]).lowercased()
            }
        }
        return nil
    }

    /// Single-quote a value for the shell, escaping embedded quotes.
    static func shq(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func swapScript(newApp: String, target: String, package: String) -> String {
        swapTemplate
            .replacingOccurrences(of: "@NEW@", with: shq(newApp))
            .replacingOccurrences(of: "@TARGET@", with: shq(target))
            .replacingOccurrences(of: "@PKG@", with: shq(package))
            .replacingOccurrences(of: "@FAIL@", with: shq(failureFile.path))
            .replacingOccurrences(of: "@LOG@", with: shq(logFile.path))
    }

    static let swapTemplate = #"""
#!/bin/sh
# LiteTube silent update - generated by AppUpdater, runs after the quit.
set -u
NEW=@NEW@
TARGET=@TARGET@
PKG=@PKG@
PREVIOUS="$TARGET.old"
FAIL=@FAIL@
LOG=@LOG@

log() { printf '%s %s\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG"; }
report() { log "FAILED: $1"; printf '%s\n' "$1" > "$FAIL"; }
detail() { if [ -n "${1:-}" ]; then printf '%s' "$1"; else printf 'the command failed without a message'; fi; }

: >> "$LOG" 2>/dev/null || LOG=/dev/null
: > "$FAIL" 2>/dev/null
log "=== update as $(/usr/bin/id -un): $NEW -> $TARGET"

# 1. wait for the quit request to take effect (about 15 seconds)
n=0
while /usr/bin/pgrep -x LiteTube >/dev/null 2>&1; do
    n=$((n + 1))
    if [ "$n" -ge 30 ]; then
        break
    fi
    /bin/sleep 0.5
done

# 2. still running: terminate it, then kill it. Nothing after the download click waits on a person.
if /usr/bin/pgrep -x LiteTube >/dev/null 2>&1; then
    log "LiteTube is still running; terminating it"
    /bin/kill -TERM $(/usr/bin/pgrep -x LiteTube) 2>/dev/null
    m=0
    while /usr/bin/pgrep -x LiteTube >/dev/null 2>&1; do
        m=$((m + 1))
        if [ "$m" -ge 20 ]; then
            /bin/kill -KILL $(/usr/bin/pgrep -x LiteTube) 2>/dev/null
            /bin/sleep 2
            break
        fi
        /bin/sleep 0.5
    done
fi

# 3. give up only if the app genuinely cannot be stopped
if /usr/bin/pgrep -x LiteTube >/dev/null 2>&1; then
    report "LiteTube did not quit, so the update was not installed"
    exit 1
fi

# 4. never put a bundle we cannot open into place; restore the exec bit that unpacking can drop
APP_BIN="$NEW/Contents/MacOS/LiteTube"
if [ ! -f "$APP_BIN" ]; then
    report "the downloaded update is missing its app bundle"
    exit 1
fi
if [ ! -x "$APP_BIN" ]; then
    /bin/chmod 755 "$APP_BIN" 2>/dev/null
    log "restored the executable bit on the staged app"
fi
if [ ! -x "$APP_BIN" ]; then
    report "the downloaded update cannot start ($(/bin/ls -ld "$APP_BIN" 2>&1))"
    exit 1
fi

# 5. both renames need the folder holding the app to be writable; otherwise hand the package to Installer
HOLD=$(/usr/bin/dirname "$TARGET")
if [ ! -w "$HOLD" ]; then
    if [ -n "$PKG" ] && [ -f "$PKG" ] && /usr/bin/open -a Installer "$PKG" >/dev/null 2>&1; then
        log "$HOLD is not writable; macOS Installer is finishing the update"
        exit 0
    fi
    report "LiteTube cannot write to $HOLD, so the update was not installed; move LiteTube to Applications and try again"
    exit 1
fi

# 6. keep the current app for rollback, parked aside rather than deleted in place
if [ -e "$PREVIOUS" ]; then
    /bin/rm -rf "$PREVIOUS" 2>/dev/null
fi
if [ -e "$PREVIOUS" ]; then
    OUT=$(/bin/mv "$PREVIOUS" "$PREVIOUS.stale.$$" 2>&1)
    if [ -e "$PREVIOUS" ]; then
        report "could not back up the current app ($(detail "$OUT")); the update was not installed"
        exit 1
    fi
    log "parked an unremovable previous copy as $PREVIOUS.stale.$$"
fi
if [ -d "$TARGET" ]; then
    OUT=$(/bin/mv "$TARGET" "$PREVIOUS" 2>&1)
    if [ -e "$TARGET" ]; then
        report "could not back up the current app ($(detail "$OUT")); the update was not installed"
        exit 1
    fi
    log "parked the current app as $PREVIOUS"
fi

# 7. move the new bundle into the place the old one left, putting the old one back if the new one is wrong
OUT=$(/bin/mv "$NEW" "$TARGET" 2>&1)
if [ -f "$TARGET/Contents/MacOS/LiteTube" ] && [ ! -x "$TARGET/Contents/MacOS/LiteTube" ]; then
    /bin/chmod 755 "$TARGET/Contents/MacOS/LiteTube" 2>/dev/null
    log "restored the executable bit on the installed app"
fi
if [ ! -x "$TARGET/Contents/MacOS/LiteTube" ]; then
    WHY=$(detail "$OUT")
    if [ -z "$OUT" ]; then
        WHY=$(/bin/ls -ld "$TARGET" "$TARGET/Contents/MacOS" 2>&1)
    fi
    /bin/rm -rf "$TARGET" 2>/dev/null
    if [ -d "$PREVIOUS" ]; then
        /bin/mv "$PREVIOUS" "$TARGET" 2>>"$LOG" || log "could not put the previous app back"
    fi
    if [ -n "$PKG" ] && [ -f "$PKG" ] && /usr/bin/open -a Installer "$PKG" >/dev/null 2>&1; then
        log "the swap failed ($WHY); macOS Installer is finishing the update"
        exit 0
    fi
    report "could not install the update: $WHY"
    exit 1
fi
/bin/rm -f "$FAIL"
log "installed $TARGET"

if [ -n "$PKG" ]; then
    /bin/rm -f "$PKG"
fi
for STALE in "$PREVIOUS".stale.*; do
    if [ -e "$STALE" ]; then
        /bin/rm -rf "$STALE" 2>/dev/null && log "removed $STALE"
    fi
done

# 8. reopen the new version
/usr/bin/open "$TARGET"
exit 0
"""#

    static var cacheDir: URL {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LiteTube/update", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var failureFile: URL { cacheDir.appendingPathComponent("install-failed.txt") }
    static var logFile: URL { cacheDir.appendingPathComponent("install.log") }

    /// Read and clear a swap failure left by the helper.
    static func takeFailure() -> String? {
        guard let text = try? String(contentsOf: failureFile, encoding: .utf8) else { return nil }
        try? FileManager.default.removeItem(at: failureFile)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func log(_ text: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(text)\n"
        guard let data = line.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: logFile.path) {
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
        }
        if let h = try? FileHandle(forWritingTo: logFile) {
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
            try? h.close()
        }
    }

    /// Keep only the package in use: each release is ~300 MB, so old ones are deleted.
    static func pruneCache() {
        let dir = cacheDir
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names where [".pkg", ".dmg", ".part"].contains(where: { name.hasSuffix($0) }) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 18), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func ensureRunnable(_ bundle: URL) {
        let macos = bundle.appendingPathComponent("Contents/MacOS")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: macos.path)) ?? []
        for name in names {
            let path = macos.appendingPathComponent(name).path
            if !FileManager.default.isExecutableFile(atPath: path) {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            }
        }
    }

    static func findBundle(in root: URL) -> URL? {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in e where url.pathExtension == "app" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/MacOS/LiteTube").path) {
                return url
            }
        }
        return nil
    }

    static func findFile(named name: String, in root: URL) -> URL? {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in e where url.lastPathComponent == name {
            return url
        }
        return nil
    }

    @discardableResult
    static func run(_ path: String, _ args: [String]) throws -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

/// Streams a release asset to disk and reports whole-number progress.
private final class FileDownloader: NSObject, URLSessionDownloadDelegate {
    private let dest: URL
    private let expectedSize: Int64
    private let progress: (Int) -> Void
    private var completion: ((Result<Void, Error>) -> Void)?
    private var session: URLSession?
    private var lastPct = -1

    private init(dest: URL, expectedSize: Int64, progress: @escaping (Int) -> Void, completion: @escaping (Result<Void, Error>) -> Void) {
        self.dest = dest
        self.expectedSize = expectedSize
        self.progress = progress
        self.completion = completion
    }

    static func fetch(from url: URL, to dest: URL, expectedSize: Int64, progress: @escaping (Int) -> Void) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let d = FileDownloader(dest: dest, expectedSize: expectedSize, progress: progress) { cont.resume(with: $0) }
            let session = URLSession(configuration: .default, delegate: d, delegateQueue: nil)
            d.session = session
            var req = URLRequest(url: url, timeoutInterval: 60)
            req.setValue(AppUpdater.userAgent, forHTTPHeaderField: "User-Agent")
            session.downloadTask(with: req).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = expectedSize > 0 ? expectedSize : totalBytesExpectedToWrite
        guard total > 0 else { return }
        let pct = min(99, Int(totalBytesWritten * 100 / total))
        if pct != lastPct { lastPct = pct; progress(pct) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is removed when this method returns, so move it into place here.
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            finish(.failure(AppUpdater.UpdateError("download failed with HTTP \(http.statusCode)")))
            return
        }
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
        // A successful download is finished by didFinishDownloadingTo.
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let completion else { return }
        self.completion = nil
        if case .success = result {
            let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
            if expectedSize > 0 && size != expectedSize {
                completion(.failure(AppUpdater.UpdateError("short download (\(size)/\(expectedSize) bytes)")))
                session?.finishTasksAndInvalidate()
                return
            }
        }
        completion(result)
        session?.finishTasksAndInvalidate()
    }
}
