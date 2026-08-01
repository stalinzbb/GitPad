import SwiftUI
import AppKit

struct OnboardingView: View {
    @ObservedObject var store: NoteStore
    @State private var step = 0
    @State private var remote = ""
    @AppStorage("onboarded") private var onboarded = false

    private var pages: [(symbol: String, title: String, body: String)] { [
        ("keyboard", "Instant capture",
         "Press \(Hotkey.display) from anywhere.\nGitPad floats over whatever you're doing."),
        ("text.badge.checkmark", "Just type",
         "It saves itself. Type / for commands,\n⌘N for a new note, ⌘L for your library."),
        ("arrow.triangle.branch", "Sync with git",
         "Optional. Keep your notes in a private git repo\nand they follow you everywhere."),
    ] }
    @State private var testResult: String?
    @State private var ghReady = false
    @State private var working = false
    /// Set when the host rejected our SSH key — names the key to copy, same as Fix sync.
    @State private var sshKeyToFix: String?

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
                // Signed in to the gh CLI → skip the whole create-a-repo-and-paste-a-URL
                // dance; it's the same one-click path Settings → Set up sync offers.
                if ghReady {
                    Button { createRepo() } label: {
                        Label(working ? "Creating…" : "Create a private repo for me",
                              systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.bordered)
                    .disabled(working)
                    Text("or paste a repo URL:")
                        .font(.caption2).foregroundStyle(.tertiary)
                } else {
                    Link("Open github.com/new ↗", destination: URL(string: "https://github.com/new")!)
                        .font(.callout)
                }
                HStack(spacing: 6) {
                    TextField("git@github.com:you/notes.git", text: $remote)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                    Button("Test") { testConnection() }
                        .disabled(remote.trimmingCharacters(in: .whitespaces).isEmpty || working)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                if let result = testResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(result.hasPrefix("✓") ? Color.green : result == "…" ? Color.secondary : Color.red)
                    if result.hasPrefix("✗") {
                        Text("Clear the URL to skip sync for now.")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                if let key = sshKeyToFix {
                    HStack(spacing: 10) {
                        Button("Copy public key") {
                            let pub = (try? String(contentsOfFile: key + ".pub", encoding: .utf8)) ?? ""
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(pub, forType: .string)
                        }
                        Link("Add a key on GitHub ↗",
                             destination: URL(string: "https://github.com/settings/ssh/new")!)
                    }
                    .font(.caption)
                }
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(i == step ? Color.primary : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
            }
            Button(step < 2 ? "Continue" : "Start writing") {
                withAnimation(Motion.pop) {
                    if step < 2 { step += 1 } else { finish() }
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(working)
            .padding(.bottom, 24)
        }
        .padding()
        .onAppear {
            // finishes long before anyone reaches page 3 (same hop as GitSetupView)
            DispatchQueue.global().async {
                let gh = GitSync.ghReady()
                DispatchQueue.main.async { ghReady = gh }
            }
        }
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
                if r.status == 0 { testResult = "✓ Connected"; sshKeyToFix = nil }
                else { classify(r.out) }
            }
        }
    }

    /// One friendly line for a failed reachability check — plus the key to copy when the
    /// host rejected this Mac's SSH key, so the fix is right here instead of in Settings.
    private func classify(_ out: String) {
        testResult = "✗ " + GitSync.friendlyError(out)
        let s = out.lowercased()
        sshKeyToFix = s.contains("permission denied") || s.contains("publickey")
            ? GitSync.offeredSSHKey(in: store.dir) : nil
    }

    /// gh CLI path: make the repo, wire up auth, sync once. Same call chain as
    /// GitSetupView — it fills in `remote`, so finishing then takes the normal route.
    private func createRepo() {
        working = true
        testResult = "…"
        DispatchQueue.global().async {
            let url = GitSync.ghCreateRepo("gitpad-notes")
            let ok = url.map { u -> Bool in
                GitSync.setRemote(u, in: store.dir)
                return GitSync.sync(dir: store.dir)
            } ?? false
            DispatchQueue.main.async {
                working = false
                if let url, ok {
                    remote = url
                    testResult = "✓ Repo created & synced"
                    sshKeyToFix = nil
                } else {
                    testResult = "✗ Couldn't create the repo — paste a URL instead"
                }
            }
        }
    }

    /// Empty field = skip sync, instantly. A URL that's been typed gets checked first:
    /// saving an unreachable remote silently is how people ended up thinking sync worked.
    private func finish() {
        let url = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return done() }
        working = true
        testResult = "…"
        DispatchQueue.global().async {
            let r = GitSync.run(["ls-remote", url], in: store.dir)
            DispatchQueue.main.async {
                working = false
                guard r.status == 0 else { return classify(r.out) } // stay on this page
                GitSync.setRemote(url, in: store.dir)
                if url.hasPrefix("https://") { GitSync.enableHTTPSAuth() }
                done()
            }
        }
    }

    private func done() {
        onboarded = true
        store.screen = .capture
    }
}

/// Step-by-step git sync onboarding, reachable any time from Settings.
struct GitSetupView: View {
    @ObservedObject var store: NoteStore
    @State private var remote = ""
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
                    .padding(.leading, 30)
                    .disabled(working)
                    Text("Prefer your own? Paste an SSH or HTTPS URL below instead.")
                        .font(.caption2).foregroundStyle(.tertiary).padding(.leading, 30)
                } else {
                    step(1, "Create a private repository",
                         "Any git host works. On GitHub: New repository → Private.")
                    Link("Open github.com/new ↗", destination: URL(string: "https://github.com/new")!)
                        .font(.callout)
                        .padding(.leading, 30)
                }

                step(2, "Paste the repo URL",
                     "SSH (git@github.com:you/notes.git) uses this Mac's keys — nothing to log into. HTTPS works too if you use the gh CLI or a credential helper.")
                TextField("git@github.com:you/notes.git", text: $remote)
                    .textFieldStyle(.roundedBorder)
                    .padding(.leading, 30)

                step(3, "Save & Sync",
                     "GitPad checks the connection, syncs once, then keeps syncing on every save, every 5 minutes, and on wake.")
            }
            .padding(20)
            Spacer()
            if let r = result {
                Text(r).font(.caption)
                    .foregroundStyle(r.hasPrefix("✓") ? Color.green : Color.red)
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
                .background(Color.accentColor.opacity(0.15), in: Circle())
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
