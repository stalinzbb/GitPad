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
}
