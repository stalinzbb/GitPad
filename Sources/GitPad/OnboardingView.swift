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
         "Optional. Point GitPad at a private repo\nand your notes follow you everywhere."),
    ]

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
                TextField("git@github.com:you/notes.git", text: $remote)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
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

    private func finish() {
        let url = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if !url.isEmpty { GitSync.setRemote(url, in: store.dir) }
        onboarded = true
        store.screen = .capture
    }
}
