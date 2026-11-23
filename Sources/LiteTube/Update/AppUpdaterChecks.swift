import Foundation

extension AppUpdater {
    /// Headless checks of the updater's pure logic. Returns one message per failed check.
    static func selfChecks() -> [String] {
        var fails: [String] = []
        func expect(_ ok: Bool, _ what: String) { if !ok { fails.append("updater: \(what)") } }

        // Versions: a leading v and suffixes are ignored; missing parts count as zero.
        expect(parseVersion("v2.1.0") == [2, 1, 0], "parseVersion v2.1.0")
        expect(parseVersion("1.0.0-rc1") == [1, 0, 0], "parseVersion with suffix")
        expect(isNewer("v0.0.3", than: "0.0.2"), "0.0.3 should be newer than 0.0.2")
        expect(!isNewer("0.0.2", than: "1.0.0"), "0.0.2 should not be newer than 1.0.0")
        expect(isNewer("1.0.1", than: "1.0"), "1.0.1 should be newer than 1.0")
        expect(!isNewer("1.0", than: "1.0.0"), "1.0 and 1.0.0 are the same version")
        expect(trimmedTag("v0.0.2") == "0.0.2", "trimmedTag strips v")

        // Release parsing and the arm64 / x86_64 pick.
        let json = """
        {"tag_name":"v0.0.3","html_url":"https://example.invalid/r","body":"notes",
         "assets":[
           {"name":"LiteTube-0.0.3-x86_64.pkg","browser_download_url":"https://example.invalid/x","size":10},
           {"name":"LiteTube-0.0.3-arm64.pkg","browser_download_url":"https://example.invalid/a","size":20},
           {"name":"SHA256SUMS","browser_download_url":"https://example.invalid/s","size":5}]}
        """
        if let rel = try? parseRelease(Data(json.utf8)) {
            let arm = assets(of: rel, arch: "arm64")
            expect(arm.pkg?.name == "LiteTube-0.0.3-arm64.pkg", "arm64 pick")
            expect(arm.sums?.name == "SHA256SUMS", "checksum asset pick")
            expect(assets(of: rel, arch: "x86_64").pkg?.name == "LiteTube-0.0.3-x86_64.pkg", "x86_64 pick")
            expect(assets(of: rel, arch: "riscv").pkg == nil, "no build for an unknown arch")
        } else {
            fails.append("updater: release JSON did not parse")
        }

        // SHA256SUMS: the file name must match exactly, with the binary-mode star tolerated.
        let sums = "abc123  LiteTube-0.0.3-arm64.pkg\nfff000 *LiteTube-0.0.3-x86_64.pkg\n"
        expect(parseChecksums(sums, name: "LiteTube-0.0.3-arm64.pkg") == "abc123", "checksum lookup")
        expect(parseChecksums(sums, name: "LiteTube-0.0.3-x86_64.pkg") == "fff000", "checksum lookup with star")
        expect(parseChecksums(sums, name: "missing.pkg") == nil, "checksum for an unlisted file")

        // Shell quoting: an apostrophe in a path must not end the quoted word.
        expect(shq("/Applications/Lite Tube.app") == "'/Applications/Lite Tube.app'", "shq plain path")
        expect(shq("a'b") == "'a'\\''b'", "shq escapes apostrophes")

        // The swap script: the paths and bundle id are filled in, and no placeholder or old name is left behind.
        let script = swapScript(newApp: "/tmp/new.app", target: "/Applications/LiteTube.app", package: "/tmp/x.pkg")
        expect(script.contains("TARGET='/Applications/LiteTube.app'"), "swap script target")
        expect(script.contains("NEW='/tmp/new.app'"), "swap script new app")
        expect(!script.contains("@NEW@") && !script.contains("@TARGET@") && !script.contains("@LOG@"), "swap script placeholders filled")
        expect(script.contains("pgrep -x LiteTube"), "swap script waits for LiteTube")
        expect(!script.contains("Kotassium"), "swap script has no leftover Kotassium name")
        expect(script.hasPrefix("#!/bin/sh"), "swap script has a shebang")

        return fails
    }
}
