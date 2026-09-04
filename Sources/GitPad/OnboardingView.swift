import SwiftUI

struct OnboardingView: View {
    @ObservedObject var store: NoteStore
    @State private var step = 0
    @State private var remote = ""
    @FocusState private var remoteFocused: Bool
    @AppStorage("onboarded") private var onboarded = false

    private var pages: [(symbol: String, title: String, body: String)] { [
        ("keyboard", "Instant capture",
         "Press \(Hotkey.display) from anywhere.\nGitPad floats over whatever you're doing."),
        ("text.badge.checkmark", "Just type",
         "It saves itself. Type / for commands,\n⌘N for a new note, ⌘L for your library."),
        ("arrow.triangle.branch", "Sync with git",
         "Optional. Create a private repo (github.com/new),\npaste its SSH URL, and your notes follow you everywhere.\nUses your existing SSH keys — nothing to log into."),
        ("lock.shield", "Encrypt on this Mac",
         "Optional. Keeps your notes in an encrypted disk image\nthat locks with your screen. Good for a work laptop.\nLeave blank to keep plain files."),
    ] }
    @State private var testResult: String?
    @State private var pass = ""
    @State private var pass2 = ""
    @FocusState private var passFocused: Bool
    @FocusState private var pass2Focused: Bool
    @State private var encrypting = false
    @State private var vaultResult: String?
    private var last: Int { pages.count - 1 }
    private var devBuild: Bool { ProcessInfo.processInfo.environment["GITPAD_DIR"] != nil }
    private var passInvalid: Bool { !pass.isEmpty && (pass.count < 8 || pass != pass2) }

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            symbol
            Text(pages[step].title)
                .font(.title2.weight(.semibold))
            Text(pages[step].body)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if step == 2 {
                HStack(spacing: Space.s) {
                    TextField("git@github.com:you/notes.git", text: $remote)
                        .focused($remoteFocused)
                        .fieldStyle(focused: remoteFocused)
                        .frame(width: 240)
                    Button("Test") { testConnection() }
                        .disabled(remote.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                if let result = testResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(result.hasPrefix("✓") ? Color.statusOK : result == "…" ? Color.secondary : Color.statusErr)
                }
            }
            if step == last, !devBuild {
                VStack(spacing: Space.s) {
                    SecureField("Passphrase", text: $pass)
                        .focused($passFocused)
                        .fieldStyle(focused: passFocused)
                    SecureField("Confirm passphrase", text: $pass2)
                        .focused($pass2Focused)
                        .fieldStyle(focused: pass2Focused)
                    Text(vaultResult ?? "At least 8 characters. There is no recovery.")
                        .font(.caption)
                        .foregroundStyle(vaultResult == nil ? Color.secondary : Color.statusErr)
                }
                .frame(width: 240)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(0..<pages.count, id: \.self) { i in
                    Circle()
                        .fill(i == step ? Color.primary : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
            }
            Button(step < last ? "Continue" : encrypting ? "Encrypting…" : "Start writing") {
                withAnimation(Motion.pop) {
                    if step < last { step += 1 } else { finish() }
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(step == last && (encrypting || passInvalid))
            .padding(.bottom, 24)
        }
        .padding()
    }

    @ViewBuilder private var symbol: some View {
        let img = Image(systemName: pages[step].symbol)
            .font(.system(size: 44, weight: .light))
            .foregroundStyle(.tint)
        Group {
            if #available(macOS 14.0, *), !Motion.reduce {
                img.symbolEffect(.bounce, value: step)
            } else {
                img
            }
        }
        .id(step)
        .transition(.scale(scale: 0.6).combined(with: .opacity))
        .frame(height: 60)
    }

    private func testConnection() {
        let url = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        testResult = "…"
        DispatchQueue.global().async {
            let r = GitSync.run(["ls-remote", url], in: store.dir)
            DispatchQueue.main.async {
                testResult = r.status == 0 ? "✓ Connected" : "✗ " + GitSync.friendlyError(r.out)
            }
        }
    }

    private func finish() {
        let url = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if !url.isEmpty { GitSync.setRemote(url, in: store.dir) }
        guard !pass.isEmpty, !devBuild else { onboarded = true; store.screen = .capture; return }
        // The folder already holds today's note (NoteStore.open), so it moves into the vault too.
        encrypting = true; vaultResult = nil
        store.flushPendingSave()
        let queue = store.onSyncQueue ?? { DispatchQueue.global().async(execute: $0) }
        queue {
            let err = Vault.create(passphrase: pass)
            DispatchQueue.main.async {
                encrypting = false
                if let err { vaultResult = "✗ " + err; return }
                pass = ""; pass2 = ""
                store.refresh()
                onboarded = true
                store.screen = .capture
            }
        }
    }
}

/// Step-by-step git sync onboarding, reachable any time from Settings.
struct GitSetupView: View {
    @ObservedObject var store: NoteStore
    @Environment(\.theme) private var theme
    @State private var remote = ""
    @FocusState private var remoteFocused: Bool
    @State private var result: String?
    @State private var working = false
    @State private var ghReady = false

    private var trimmed: String { remote.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            ChromeBar(store: store, title: "Set up sync", showSettings: false, showSyncDot: false) {
                ChromeIcon(symbol: ChromeGlyph.back, help: "Back (Esc)") { store.goBack() }
            }

            VStack(alignment: .leading, spacing: 18) {
                if ghReady {
                    step(1, "Create a private repo — one click",
                         "You're signed in to the gh CLI, so GitPad can make the repo and wire up auth for you. No SSH keys needed.")
                    Button { createRepo() } label: {
                        Label("Create a private repo for me", systemImage: "wand.and.stars")
                    }
                    .padding(.leading, Space.gutter + Space.l)
                    .disabled(working)
                    Text("Prefer your own? Paste an SSH or HTTPS URL below instead.")
                        .font(.caption2).foregroundStyle(.tertiary).padding(.leading, Space.gutter + Space.l)
                } else {
                    step(1, "Create a private repository",
                         "Any git host works. On GitHub: New repository → Private.")
                    Link("Open github.com/new ↗", destination: URL(string: "https://github.com/new")!)
                        .font(.callout)
                        .padding(.leading, Space.gutter + Space.l)
                }

                step(2, "Paste the repo URL",
                     "SSH (git@github.com:you/notes.git) uses this Mac's keys — nothing to log into. HTTPS works too if you use the gh CLI or a credential helper.")
                TextField("git@github.com:you/notes.git", text: $remote)
                    .focused($remoteFocused)
                    .fieldStyle(focused: remoteFocused)
                    .padding(.leading, Space.gutter + Space.l)

                step(3, "Save & Sync",
                     "GitPad checks the connection, syncs once, then keeps syncing on every save, every 5 minutes, and on wake.")
            }
            .padding(Space.gutter)
            Spacer()
            if let r = result {
                Text(r).font(.caption)
                    .foregroundStyle(r.hasPrefix("✓") ? Color.statusOK : Color.statusErr)
                    .padding(.bottom, 6)
            }
            Button(working ? "Working…" : "Save & Sync") { saveAndSync() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmed.isEmpty || working)
                .padding(.bottom, 20)
        }
        .onAppear {
            DispatchQueue.global().async {
                let url = GitSync.remoteURL(in: store.dir)
                let gh = GitSync.ghReady()
                DispatchQueue.main.async {
                    if remote.isEmpty { remote = url }
                    ghReady = gh
                }
            }
        }
    }

    private func step(_ n: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.caption.weight(.bold))
                .frame(width: 20, height: 20)
                .background(theme.selection, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Save remote → reachability check → sync, reporting one friendly line.
    private func saveAndSync() {
        let url = trimmed
        working = true
        result = nil
        DispatchQueue.global().async {
            GitSync.setRemote(url, in: store.dir)
            if url.hasPrefix("https://") { GitSync.enableHTTPSAuth() } // let gh's token drive https pushes
            let ls = GitSync.run(["ls-remote", url], in: store.dir)
            if ls.status != 0 {
                let msg = GitSync.friendlyError(ls.out)
                DispatchQueue.main.async { result = "✗ " + msg; working = false }
                return
            }
            let ok = GitSync.sync(dir: store.dir)
            DispatchQueue.main.async {
                result = ok ? "✓ Synced — you're all set" : "✗ Sync failed — try again"
                working = false
                store.refresh()
            }
        }
    }

    private func createRepo() {
        working = true
        result = nil
        DispatchQueue.global().async {
            let url = GitSync.ghCreateRepo("gitpad-notes")
            DispatchQueue.main.async {
                working = false
                if let url { remote = url; saveAndSync() }
                else { result = "✗ Couldn't create the repo — paste an SSH URL instead" }
            }
        }
    }
}
