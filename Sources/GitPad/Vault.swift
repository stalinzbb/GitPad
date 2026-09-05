import CryptoKit
import Foundation
import LocalAuthentication
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
        try? fm.removeItem(at: appSupport) // vault.key, staged updates
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

    // MARK: Saved passphrase — two stores, one switch.
    //
    // Default: a generic password in the login Keychain, read silently; exactly as safe as the
    // login password (SECURITY.md). Opt-in "Require Touch ID": the passphrase is sealed to a
    // Secure Enclave key created with `.userPresence`, so decrypting it shows the Touch ID sheet
    // (or the account password on Macs without Touch ID) and nothing running as you — root
    // included — can read it without that. The sealed blob lives in a plain file: it is useless
    // off this Mac's Secure Enclave. The data-protection keychain would be the textbook route,
    // but on macOS it needs a provisioning profile (a Developer-ID build with just the
    // entitlements is killed at launch); CryptoKit's Secure Enclave keys need no entitlement.
    // Every read here may block for seconds or wait on a prompt — never call on main.

    static var touchID: Bool { UserDefaults.standard.bool(forKey: "vaultTouchID") }
    static var touchIDAvailable: Bool { SecureEnclave.isAvailable }
    private static let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("GitPad")
    private static let keyFile = appSupport.appendingPathComponent("vault.key")

    static var storedPassphrase: String? { touchID ? enclavePassphrase : keychainPassphrase }

    static func savePassphrase(_ p: String) {
        if touchID, saveEnclave(p) { return }
        if touchID { NSLog("vault: Secure Enclave save failed, falling back to the Keychain") }
        UserDefaults.standard.set(false, forKey: "vaultTouchID")
        saveKeychain(p)
    }

    static func deletePassphrase() {
        SecItemDelete(item as CFDictionary)
        try? fm.removeItem(at: keyFile)
    }

    /// Move the saved passphrase between the two stores. Reading it first means turning
    /// Touch ID OFF prompts once (proof of presence) and turning it ON needs no typing.
    static func setTouchID(_ on: Bool) -> String? {
        guard on != touchID else { return nil }
        guard let p = storedPassphrase else {
            return on ? "Couldn't read the saved passphrase" : "Touch ID didn't complete — nothing changed"
        }
        deletePassphrase()
        UserDefaults.standard.set(on, forKey: "vaultTouchID")
        savePassphrase(p) // falls back to the Keychain (and flips the flag back) if the Enclave refuses
        return touchID == on ? nil : "Secure Enclave unavailable — kept the Keychain"
    }

    // Login Keychain

    private static let item: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: "com.stalinzbb.gitpad.vault",
        kSecAttrAccount: "vault",
    ]

    private static var keychainPassphrase: String? {
        var q = item
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    private static func saveKeychain(_ p: String) {
        SecItemDelete(item as CFDictionary)
        var q = item
        q[kSecValueData] = Data(p.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }

    // Secure Enclave. Blob layout: [2-byte len][SE key blob][65-byte ephemeral pubkey][AES-GCM sealed passphrase].
    // ECIES by hand: the Enclave key only does key agreement, so a throwaway P256 key derives
    // the AES key, and the same agreement — gated by Touch ID — re-derives it on read.

    private static func saveEnclave(_ p: String) -> Bool {
        var err: Unmanaged<CFError>?
        guard let ac = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, &err),
              let se = try? SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: ac) else { return false }
        let eph = P256.KeyAgreement.PrivateKey()
        guard let shared = try? eph.sharedSecretFromKeyAgreement(with: se.publicKey),
              let sealed = try? AES.GCM.seal(Data(p.utf8), using: symmetric(shared)).combined else { return false }
        let rep = se.dataRepresentation
        var blob = Data([UInt8(rep.count >> 8), UInt8(rep.count & 0xff)])
        blob.append(rep)
        blob.append(eph.publicKey.x963Representation)
        blob.append(sealed)
        try? fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return (try? blob.write(to: keyFile, options: .atomic)) != nil
    }

    private static var enclavePassphrase: String? {
        guard let blob = try? Data(contentsOf: keyFile), blob.count > 2 else { return nil }
        let n = Int(blob[0]) << 8 | Int(blob[1])
        guard blob.count > 2 + n + 65 else { return nil }
        let rep = blob[2 ..< 2 + n], pub = blob[2 + n ..< 2 + n + 65], sealed = blob[(2 + n + 65)...]
        let ctx = LAContext()
        ctx.localizedReason = "unlock your notes"
        guard let se = try? SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: rep, authenticationContext: ctx),
              let pubKey = try? P256.KeyAgreement.PublicKey(x963Representation: pub),
              let shared = try? se.sharedSecretFromKeyAgreement(with: pubKey), // the Touch ID sheet
              let box = try? AES.GCM.SealedBox(combined: sealed),
              let plain = try? AES.GCM.open(box, using: symmetric(shared)) else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    private static func symmetric(_ s: SharedSecret) -> SymmetricKey {
        s.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: Data("gitpad-vault".utf8), outputByteCount: 32)
    }
}
