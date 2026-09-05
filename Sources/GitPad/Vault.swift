import Foundation
import Security

/// Opt-in encrypted vault: the notes folder is an AES-256 APFS sparse bundle that macOS
/// mounts AT `NoteStore.defaultDir`, so nothing above `NoteStore.dir` knows the difference —
/// notes stay plain Markdown inside, git sync is untouched. Locked = unmounted = only
/// ciphertext bands on disk. Every call here blocks (hdiutil takes 1–3 s); callers run them
/// on the app's serial sync queue so no git process is ever mid-write when we detach.
enum Vault {
    static let mountpoint = NoteStore.defaultDir
    /// `GITPAD_VAULT` is the test hook (same shape as `GITPAD_DIR`): a scratch bundle for a
    /// scratch notes dir, enabled without touching the shared defaults. See test_vault_app.sh.
    static let bundle = ProcessInfo.processInfo.environment["GITPAD_VAULT"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GitPad/Vault.sparsebundle")
    private static let hdiutil = "/usr/bin/hdiutil"
    private static let fm = FileManager.default

    /// `GITPAD_DIR` alone = dev build: never attach the real bundle onto a scratch dir.
    static var isEnabled: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["GITPAD_VAULT"] != nil { return true }
        return env["GITPAD_DIR"] == nil && UserDefaults.standard.bool(forKey: "vaultEnabled")
    }
    static var isMounted: Bool { isVolume(mountpoint) }
    static var isLocked: Bool { isEnabled && !isMounted }

    /// A mounted volume's root has a different device id than its parent directory.
    private static func isVolume(_ dir: URL) -> Bool {
        var a = stat(), b = stat()
        guard stat(dir.path, &a) == 0, stat(dir.deletingLastPathComponent().path, &b) == 0 else { return false }
        return a.st_dev != b.st_dev
    }

    // MARK: lock / unlock

    static func unlock(passphrase: String) -> Bool {
        if isMounted { return true }
        try? fm.createDirectory(at: mountpoint, withIntermediateDirectories: true)
        chmod(mountpoint.path, 0o700)
        return attach(at: mountpoint, passphrase: passphrase)
    }

    @discardableResult
    static func lock() -> Bool {
        guard detach(mountpoint) else { return false }
        // Safety net: every `try?` write in NoteStore now fails instead of leaking plaintext
        // into the bare mountpoint while locked.
        chmod(mountpoint.path, 0o500)
        return true
    }

    private static func attach(at dir: URL, passphrase: String) -> Bool {
        let r = GitSync.exec(hdiutil, ["attach", "-quiet", "-stdinpass", "-nobrowse",
                                       "-mountpoint", dir.path, bundle.path], stdin: passphrase)
        if r.status != 0 { NSLog("vault attach: %@", r.out) }
        return r.status == 0
    }

    /// Never `-force`: a git child could hold the volume. Spotlight/Finder release theirs
    /// within a second, hence the retry.
    private static func detach(_ dir: URL) -> Bool {
        for n in 0..<5 {
            if !isVolume(dir) { return true }
            let r = GitSync.exec(hdiutil, ["detach", dir.path])
            if r.status == 0 { return true }
            NSLog("vault detach: %@", r.out)
            Thread.sleep(forTimeInterval: 0.5 * Double(n + 1))
        }
        return false
    }

    // MARK: enable / disable / erase — each returns a user-facing error, nil on success

    /// Create the image, copy the notes in, verify, and only then delete the plaintext.
    static func create(passphrase: String) -> String? {
        guard !fm.fileExists(atPath: bundle.path) else { return "A vault already exists in Application Support/GitPad" }
        try? fm.createDirectory(at: bundle.deletingLastPathComponent(), withIntermediateDirectories: true)
        let r = GitSync.exec(hdiutil, ["create", "-quiet", "-size", "10g", "-type", "SPARSEBUNDLE", "-fs", "APFS",
                                       "-volname", "GitPad", "-encryption", "AES-256", "-stdinpass", bundle.path],
                             stdin: passphrase)
        guard r.status == 0 else { NSLog("vault create: %@", r.out); return "Couldn't create the disk image" }
        let tmp = fm.temporaryDirectory.appendingPathComponent("gitpad-vault-\(getpid())")
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        func fail(_ msg: String) -> String {
            _ = detach(tmp); try? fm.removeItem(at: tmp); try? fm.removeItem(at: bundle); return msg
        }
        guard attach(at: tmp, passphrase: passphrase) else { return fail("Couldn't open the new image") }
        if let err = copyAndVerify(from: mountpoint, to: tmp) { return fail(err) }
        guard detach(tmp) else { return fail("Disk image is busy — try again") }
        try? fm.removeItem(at: tmp)
        // Point of no return: the verified copy is in the bundle. Remove the plaintext.
        for item in children(of: mountpoint) { try? fm.removeItem(at: item) }
        guard unlock(passphrase: passphrase) else { return "Encrypted, but couldn't mount — quit and relaunch GitPad" }
        savePassphrase(passphrase)
        UserDefaults.standard.set(true, forKey: "vaultEnabled")
        return nil
    }

    /// Mirror of `create`: copy out to a sibling dir on the same volume, detach, move back.
    static func remove() -> String? {
        guard isMounted else { return "Unlock the vault first" }
        let tmp = mountpoint.deletingLastPathComponent().appendingPathComponent(".GitPad.unvault-\(getpid())")
        try? fm.removeItem(at: tmp)
        if let err = copyAndVerify(from: mountpoint, to: tmp) { try? fm.removeItem(at: tmp); return err }
        guard detach(mountpoint) else { try? fm.removeItem(at: tmp); return "Vault is busy — try again" }
        chmod(mountpoint.path, 0o700)
        var moved = true
        for item in children(of: tmp) {
            do { try fm.moveItem(at: item, to: mountpoint.appendingPathComponent(item.lastPathComponent)) }
            catch { moved = false; NSLog("vault move-back: %@", error.localizedDescription) }
        }
        guard moved else { return "Some notes couldn't be moved back — the vault image was kept" }
        try? fm.removeItem(at: tmp)
        try? fm.removeItem(at: bundle)
        deletePassphrase()
        UserDefaults.standard.set(false, forKey: "vaultEnabled")
        return nil
    }

    /// Full removal from this Mac: sync, then delete notes + vault + Keychain item + settings
    /// and move the app to the Trash. Refuses rather than lose an unpushed note.
    static func erase() -> String? {
        guard ProcessInfo.processInfo.environment["GITPAD_DIR"] == nil else { return "Refusing to erase a dev build's scratch folder" }
        guard !isLocked else { return "Unlock the vault first" }
        let dir = mountpoint
        if GitSync.run(["remote", "get-url", "origin"], in: dir).status == 0, !GitSync.sync(dir: dir) {
            return "Sync failed — nothing was erased"
        }
        if isMounted, !detach(dir) { return "Vault is busy — nothing was erased" }
        try? fm.removeItem(at: bundle)
        chmod(dir.path, 0o700)
        try? fm.removeItem(at: dir)
        deletePassphrase()
        if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
        try? fm.trashItem(at: Bundle.main.bundleURL, resultingItemURL: nil)
        return nil
    }

    /// ditto keeps `.git`; the volume root grows hidden entries (.fseventsd…), so compare
    /// visible names only, then make sure the copied repo still answers to git.
    private static func copyAndVerify(from src: URL, to dst: URL) -> String? {
        let r = GitSync.exec("/usr/bin/ditto", [src.path, dst.path])
        guard r.status == 0 else { NSLog("vault ditto: %@", r.out); return "Copy failed — nothing was changed" }
        func names(_ d: URL) -> Set<String> {
            Set(children(of: d).map(\.lastPathComponent).filter { !$0.hasPrefix(".") })
        }
        guard names(src) == names(dst) else { return "Copy incomplete — nothing was changed" }
        if fm.fileExists(atPath: src.appendingPathComponent(".git").path),
           GitSync.run(["status", "--porcelain"], in: dst).status != 0 {
            return "Copied repo failed a git check — nothing was changed"
        }
        return nil
    }

    private static func children(of dir: URL) -> [URL] {
        (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [])) ?? []
    }

    // MARK: Keychain — a generic password in the login keychain, so it is exactly as safe
    // as the login password (SECURITY.md). Only GitPad's own bundle reads it without a prompt.

    private static let item: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: "com.stalinzbb.gitpad.vault",
        kSecAttrAccount: "vault",
    ]

    static var keychainPassphrase: String? {
        var q = item
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func savePassphrase(_ p: String) {
        SecItemDelete(item as CFDictionary)
        var q = item
        q[kSecValueData] = Data(p.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }

    static func deletePassphrase() { SecItemDelete(item as CFDictionary) }
}
