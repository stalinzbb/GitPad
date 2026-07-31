import AppKit
import CryptoKit
import Foundation

/// Release-metadata check against GitHub. Deliberately tiny and deliberately quiet:
/// nothing here ever interrupts writing, and every failure is a no-op.
///
/// Why not `/releases/latest`: GitPad's releases are all marked *pre-release*, and that
/// endpoint only ever returns a full release — it 404s for this repo today. Listing the
/// most recent few and taking the first non-draft entry works either way.
enum Updater {
    /// A published release worth telling the user about.
    /// `zipURL`/`sha256` are optional: a release can exist with the page but no usable
    /// asset (mid-upload, or a docs-only tag), in which case we can still link to it.
    struct Release: Equatable {
        let version: String   // tag with the leading "v" stripped — "0.9.3"
        let zipURL: URL?      // asset named GitPad-<version>.zip
        let sha256: String?   // that asset's digest, "sha256:" prefix stripped
        let pageURL: URL      // html_url — the always-available fallback

        // Version identifies a release; the rest is derived from it.
        static func == (a: Release, b: Release) -> Bool { a.version == b.version }
    }

    enum State: Equatable {
        case none
        case available(Release)
        case busy(String)     // stage label: "Downloading…" / "Verifying…" / "Installing…"
        case ready(String)    // staged and verified, version string
        case failed(String)
    }

    /// nil under `swift run` (no bundle, no Info.plist) — the updater disables itself
    /// rather than guessing, so a dev build can't try to replace itself.
    static let currentVersion: String? =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

    /// Same escape-hatch shape as `GITPAD_DIR` / `GITPAD_DEVICE_NAME`: point the check
    /// at a local JSON file to exercise the whole path without publishing a release.
    static let feedURL: URL = {
        if let s = ProcessInfo.processInfo.environment["GITPAD_UPDATE_FEED"],
           let u = URL(string: s) { return u }
        return URL(string: "https://api.github.com/repos/stalinzbb/GitPad/releases?per_page=5")!
    }()

    /// Constant fallback for every "something went wrong, go look yourself" path — so a
    /// failure state never has to carry a URL around just to offer the manual route.
    static let releasesPage = URL(string: "https://github.com/stalinzbb/GitPad/releases")!

    /// Fetch off-main, call back on main with a release *newer than what's running*, or nil.
    ///
    /// `ok` is false only when the feed itself couldn't be read or parsed. The background
    /// timer ignores it (a flaky network must never nag); the Settings button uses it to
    /// tell "you're up to date" from "I couldn't reach GitHub".
    static func check(_ completion: @escaping (_ release: Release?, _ ok: Bool) -> Void) {
        guard let current = currentVersion else { completion(nil, false); return }
        let finish: (Release?, Bool) -> Void = { r, ok in
            DispatchQueue.main.async { completion(r, ok) }
        }
        // ponytail: the file:// branch exists so GITPAD_UPDATE_FEED can be a local file.
        // URLSession's file handling isn't worth depending on for the one path we debug with.
        if feedURL.isFileURL {
            DispatchQueue.global().async {
                let data = try? Data(contentsOf: feedURL)
                finish(parse(data, current), data != nil)
            }
            return
        }
        var req = URLRequest(url: feedURL, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            finish(parse(data, current), data != nil)
        }.resume()
    }

    /// Numeric per component — "0.9.10" is newer than "0.9.9", which a string compare
    /// gets backwards. Missing components read as 0, so "1.0" > "0.9.3".
    /// ponytail: a non-numeric component (a "-beta" suffix) reads as 0 and simply won't
    /// look newer. Tags here are plain `vX.Y.Z`; parse suffixes when one actually ships.
    static func isNewer(_ v: String, than current: String) -> Bool {
        let a = v.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: feed decoding

    private struct FeedRelease: Decodable {
        let tag_name: String
        let draft: Bool
        let html_url: String
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
            let digest: String?   // "sha256:<hex>" — GitHub populates this per asset
        }
    }

    /// First non-draft entry, or nil if it isn't newer than what's running.
    /// Every parse failure collapses to nil: a malformed feed must never surface as a nag.
    /// Internal, not private, so `--selftest` can drive it with a literal feed.
    static func parse(_ data: Data?, _ current: String) -> Release? {
        guard let data,
              let feed = try? JSONDecoder().decode([FeedRelease].self, from: data),
              let latest = feed.first(where: { !$0.draft }),
              let page = URL(string: latest.html_url) else { return nil }
        let version = latest.tag_name.hasPrefix("v")
            ? String(latest.tag_name.dropFirst()) : latest.tag_name
        guard isNewer(version, than: current) else { return nil }
        // Tags are v-prefixed, assets are not: v0.9.3 → GitPad-0.9.3.zip
        let zip = latest.assets.first { $0.name == "GitPad-\(version).zip" }
        return Release(
            version: version,
            zipURL: zip.flatMap { URL(string: $0.browser_download_url) },
            sha256: zip?.digest.flatMap {
                $0.hasPrefix("sha256:") ? String($0.dropFirst("sha256:".count)) : nil
            },
            pageURL: page)
    }

    // MARK: - Install

    /// True when this Mac has the cask installed. Homebrew owns the app then, and a
    /// self-update would leave brew's metadata pointing at a version that isn't there.
    static var isBrewInstall: Bool {
        ["/opt/homebrew/Caskroom/gitpad", "/usr/local/Caskroom/gitpad"]
            .contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// Whether *we* are a real signed release. A dev build isn't, and replacing one with a
    /// downloaded release would silently discard the developer's local build.
    /// Cached: it shells out, and the answer can't change while we run.
    static let selfIsDeveloperID: Bool = GitSync.exec("/usr/bin/codesign", [
        "--verify", "--strict",
        "-R=anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\"",
        Bundle.main.bundleURL.path,
    ]).status == 0

    private static let teamID = "7X256UY552"

    /// Who must have signed the bundle we're about to run, spelled as a codesign
    /// requirement: Apple's chain, the Developer ID leaf, our team, our bundle id.
    /// Deliberately says nothing about the *version* — this validates provenance, not
    /// claims, which is also what lets it be tested against a previous real release.
    private static let requirement = """
        anchor apple generic and identifier "com.stalinzbb.gitpad" \
        and certificate 1[field.1.2.840.113635.100.6.2.6] \
        and certificate leaf[field.1.2.840.113635.100.6.1.13] \
        and certificate leaf[subject.OU] = "\(teamID)"
        """

    private static let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("GitPadUpdate", isDirectory: true)

    /// Single-flight. Read and written on main only.
    private static var installing = false

    /// Download → verify → swap → relaunch.
    ///
    /// Nothing on disk is touched until the downloaded bundle has passed *every* check,
    /// so any failure leaves the running app exactly as it was.
    static func install(_ r: Release, state: @escaping (State) -> Void) {
        guard !installing else { return }
        if let refusal = refusalReason() { state(.failed(refusal)); return }
        guard let zip = r.zipURL, let expected = r.sha256 else {
            // No asset, or GitHub published none of its digest: we will not install
            // something we can't verify. The release page still works.
            state(.failed("Can't verify this release — install it manually"))
            return
        }
        installing = true
        state(.busy("Downloading…"))

        let fail: (String) -> Void = { why in
            try? FileManager.default.removeItem(at: scratch)
            DispatchQueue.main.async { installing = false; state(.failed(why)) }
        }

        URLSession.shared.downloadTask(with: zip) { tmp, _, _ in
            // URLSession deletes tmp as soon as this closure returns — move it out first.
            guard let tmp, let zipFile = stash(tmp) else { fail("Download failed"); return }
            DispatchQueue.main.async { state(.busy("Verifying…")) }
            DispatchQueue.global().async {
                switch unpack(zipFile, expecting: expected) {
                case .failed(let why):
                    fail(why)
                case .ok(let newApp):
                    DispatchQueue.main.async {
                        state(.busy("Installing…"))
                        if let why = swap(Bundle.main.bundleURL, with: newApp) { fail(why); return }
                        try? FileManager.default.removeItem(at: scratch)
                        installing = false
                        relaunch()
                    }
                }
            }
        }.resume()
    }

    /// Reasons to refuse before touching the network. nil means go ahead.
    ///
    /// `GITPAD_ALLOW_DEV_UPDATE=1` lifts both *policy* gates so the install path can be
    /// exercised on the machine that builds GitPad — which necessarily has the cask
    /// installed and produces ad-hoc-signed bundles. It lifts nothing about the
    /// *download*: the hash, the Developer ID chain and notarization are checked with or
    /// without it, because those are what make a downloaded bundle safe to run.
    private static func refusalReason() -> String? {
        let testing = ProcessInfo.processInfo.environment["GITPAD_ALLOW_DEV_UPDATE"] == "1"
        // Machine-wide, not per-bundle: if the cask is installed we hand the job back to
        // brew rather than desync its receipt. Over-refusing here is the safe direction.
        if isBrewInstall, !testing {
            return "Installed with Homebrew — run: brew upgrade --cask gitpad"
        }
        if !selfIsDeveloperID, !testing { return "Dev build — install manually" }
        let parent = Bundle.main.bundleURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            return "\(parent.lastPathComponent) isn't writable — install manually"
        }
        return nil
    }

    /// Fresh scratch dir with the download moved into it.
    private static func stash(_ tmp: URL) -> URL? {
        let fm = FileManager.default
        try? fm.removeItem(at: scratch)
        guard (try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)) != nil
        else { return nil }
        let dest = scratch.appendingPathComponent("update.zip")
        guard (try? fm.moveItem(at: tmp, to: dest)) != nil else { return nil }
        return dest
    }

    /// Nothing here is *handled*, only reported, so this is a plain two-case result
    /// rather than a `Result` with an `Error` type that would never be inspected.
    private enum Unpacked {
        case ok(URL)
        case failed(String)
    }

    /// zip on disk → a bundle we are willing to run. Fails closed at every step.
    /// Blocking: codesign and spctl each take a moment. Call it off the main thread.
    private static func unpack(_ zip: URL, expecting sha: String) -> Unpacked {
        guard let got = fileSHA256(zip) else { return .failed("Couldn't read the download") }
        guard got.caseInsensitiveCompare(sha) == .orderedSame else {
            return .failed("Verification failed — nothing was changed")
        }
        // ditto, never unzip: unzip drops the extended attributes the signature seals
        // over, and the bundle then fails codesign with "a sealed resource is missing or
        // invalid". Verified the hard way against the real 0.9.3 release.
        let out = scratch.appendingPathComponent("app", isDirectory: true)
        guard GitSync.exec("/usr/bin/ditto", ["-x", "-k", zip.path, out.path]).status == 0 else {
            return .failed("Couldn't expand the download")
        }
        let apps = ((try? FileManager.default.contentsOfDirectory(
            at: out, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "app" }
        guard apps.count == 1, let app = apps.first else {
            return .failed("Verification failed — nothing was changed")
        }
        guard verify(app) else { return .failed("Verification failed — nothing was changed") }
        // Future-proofing: URLSession doesn't quarantine here (unsandboxed app, no
        // LSFileQuarantineEnabled), so there's no translocation risk today — but a stray
        // quarantine bit would make the relaunched copy run from a read-only mount.
        _ = GitSync.exec("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        return .ok(app)
    }

    /// All three must pass: signed by us under Apple's chain, notarized (a stapled
    /// ticket satisfies this offline), and actually GitPad.
    static func verify(_ app: URL) -> Bool {
        guard GitSync.exec("/usr/bin/codesign",
                           ["--verify", "--deep", "--strict", "-R=" + requirement, app.path])
            .status == 0 else { return false }
        guard GitSync.exec("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path])
            .status == 0 else { return false }
        return Bundle(url: app)?.bundleIdentifier == "com.stalinzbb.gitpad"
    }

    private static func fileSHA256(_ file: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Move-aside rather than `replaceItemAt`: renaming the *running* bundle is safe —
    /// the executable keeps running from the renamed inode — and both renames are
    /// same-volume, so each one is atomic. Any failure rolls the old bundle back.
    static func swap(_ place: URL, with new: URL) -> String? {
        let fm = FileManager.default
        let aside = place.deletingLastPathComponent().appendingPathComponent(
            ".\(place.lastPathComponent).old-\(ProcessInfo.processInfo.processIdentifier)")
        try? fm.removeItem(at: aside)
        do { try fm.moveItem(at: place, to: aside) } catch { return "Couldn't replace the app" }
        do { try fm.moveItem(at: new, to: place) } catch {
            try? fm.moveItem(at: aside, to: place) // put it back exactly as it was
            return "Couldn't replace the app"
        }
        try? fm.removeItem(at: aside) // best effort; a leftover .old-<pid> is harmless
        return nil
    }

    /// Launch the freshly-swapped bundle, then quit. No helper process and no shell:
    /// the running executable survives the rename, so it can start its own replacement.
    private static func relaunch() {
        Hotkey.stop()
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
