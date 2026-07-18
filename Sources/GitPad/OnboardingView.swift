import SwiftUI

struct OnboardingView: View {
    @ObservedObject var store: NoteStore
    @State private var step = 0
    @State private var remote = ""
    @AppStorage("onboarded") private var onboarded = false

    private let pages: [(symbol: String, title: String, body: String)] = [
        ("keyboard", "Instant capture",
         "Press ⌥ Space from anywhere.\nGitPad floats over whatever you're doing."),
        ("text.badge.checkmark", "Just type",
         "It saves itself. Type / for commands,\n⌘N for a new note, ⌘L for your library."),
        ("arrow.triangle.branch", "Sync with git",
         "Optional. Create a private repo (github.com/new),\npaste its SSH URL, and your notes follow you everywhere.\nUses your existing SSH keys — nothing to log into."),
    ]
    @State private var testResult: String?

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
                HStack(spacing: 6) {
                    TextField("git@github.com:you/notes.git", text: $remote)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                    Button("Test") { testConnection() }
                        .disabled(remote.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                if let result = testResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(result.hasPrefix("✓") ? Color.green : result == "…" ? Color.secondary : Color.red)
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
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    if step < 2 { step += 1 } else { finish() }
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .padding(.bottom, 24)
        }
        .padding()
    }

    @ViewBuilder private var symbol: some View {
        let img = Image(systemName: pages[step].symbol)
            .font(.system(size: 44, weight: .light))
            .foregroundStyle(.tint)
        Group {
            if #available(macOS 14.0, *) {
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
                testResult = r.status == 0 ? "✓ Connected"
                    : "✗ Can't reach the repo — check the URL and your SSH key"
            }
        }
    }

    private func finish() {
        let url = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if !url.isEmpty { GitSync.setRemote(url, in: store.dir) }
        onboarded = true
        store.screen = .capture
    }
}

/// Step-by-step git sync onboarding, reachable any time from Settings.
struct GitSetupView: View {
    @ObservedObject var store: NoteStore
    @State private var remote = ""
    @State private var testResult: String?

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("Set up sync").font(.headline)
                HStack {
                    Button { store.screen = .settings } label: {
                        Image(systemName: "chevron.left").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                }
            }
            .padding(12)

            VStack(alignment: .leading, spacing: 18) {
                step(1, "Create a private repository",
                     "Any git host works. On GitHub: New repository → Private → no README needed.")
                Link("Open github.com/new ↗", destination: URL(string: "https://github.com/new")!)
                    .font(.callout)
                    .padding(.leading, 30)

                step(2, "Paste its SSH URL",
                     "Uses the SSH keys already on this Mac — nothing to log into.")
                TextField("git@github.com:you/notes.git", text: $remote)
                    .textFieldStyle(.roundedBorder)
                    .padding(.leading, 30)

                step(3, "Test & turn on",
                     "GitPad then syncs on every save, every 5 minutes, and on wake.")
                HStack(spacing: 10) {
                    Button("Test connection") { test() }
                        .disabled(remote.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let r = testResult {
                        Text(r).font(.caption)
                            .foregroundStyle(r.hasPrefix("✓") ? Color.green : r == "…" ? Color.secondary : Color.red)
                    }
                }
                .padding(.leading, 30)
            }
            .padding(20)
            Spacer()
            Button("Save & Sync") {
                GitSync.setRemote(remote.trimmingCharacters(in: .whitespacesAndNewlines), in: store.dir)
                store.requestSync?()
                store.screen = .settings
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(remote.trimmingCharacters(in: .whitespaces).isEmpty)
            .padding(.bottom, 20)
        }
        .onAppear {
            DispatchQueue.global().async {
                let url = GitSync.remoteURL(in: store.dir)
                DispatchQueue.main.async { if remote.isEmpty { remote = url } }
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

    private func test() {
        let url = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        testResult = "…"
        DispatchQueue.global().async {
            let r = GitSync.run(["ls-remote", url], in: store.dir)
            DispatchQueue.main.async {
                testResult = r.status == 0 ? "✓ Connected" : "✗ Can't reach — check URL & SSH key"
            }
        }
    }
}
