import SwiftUI
import AppKit
import Carbon.HIToolbox // kVK_Escape for the hotkey recorder

// MARK: - Themes (token set consumed by the editor + chrome)
//
// Curated presets, not a base×color matrix (see GROWTH-style decision: real palettes
// like Nord/Dracula are defined for ONE mode; the matrix would invent ugly combos and
// double the tokens). Adding a theme is one row below — appearance/swatch/SwiftUI color
// all derive from `base` + hex, so you only pick the 3 colors that actually differ.

enum ThemeBase {
    case system, light, dark
    var appearance: NSAppearance.Name? {
        switch self { case .system: return nil; case .light: return .aqua; case .dark: return .darkAqua }
    }
}

struct Theme: Identifiable {
    let id: String
    let appearance: NSAppearance.Name?  // nil = follow system; drives every native control
    let accent: NSColor                 // checkboxes, chips (and, wrapped, the SwiftUI tint)
    let code: NSColor                   // inline code
    private let tintHex: UInt?          // opaque panel surface. nil = System (follow the OS)

    var accentSwift: Color { Color(nsColor: accent) }
    /// The panel's own background. Text sits on THIS, never on the desktop — which is what
    /// keeps the window readable over a white backdrop. System follows the OS window color,
    /// so it adapts light/dark instead of having no surface at all.
    var surface: Color { tintHex.map { Color(hex: $0) } ?? Color(nsColor: .windowBackgroundColor) }
    var swatchBg: Color { surface }

    /// The common case: a preset from hex colors + a light/dark base.
    init(id: String, base: ThemeBase, accent: UInt, code: UInt, tint: UInt) {
        self.id = id; self.appearance = base.appearance
        self.accent = NSColor(hex: accent); self.code = NSColor(hex: code); self.tintHex = tint
    }
    /// System: dynamic accent that follows the OS, no tint wash.
    private init(system id: String) {
        self.id = id; self.appearance = nil
        self.accent = .controlAccentColor; self.code = .systemPurple; self.tintHex = nil
    }

    static let all: [Theme] = [
        Theme(system: "System"),
        Theme(id: "Sepia",            base: .light, accent: 0xA87538, code: 0x996B33, tint: 0xF5E8CF),
        Theme(id: "Nord",             base: .dark,  accent: 0x87BFD1, code: 0xA3BF8C, tint: 0x2E3340),
        Theme(id: "Dracula",          base: .dark,  accent: 0xBD94FA, code: 0x4FE67A, tint: 0x292936),
        Theme(id: "Solarized Light",  base: .light, accent: 0x268CD1, code: 0x859900, tint: 0xFCF5E3),
    ]

    static func named(_ id: String) -> Theme { all.first { $0.id == id } ?? all[0] }
}

extension Color {
    init(hex: UInt) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

extension NSColor {
    convenience init(hex: UInt) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// Central motion tokens. `reduce` is read at interaction time (no observer), and a
/// nil animation means "instant" — so Reduce Motion falls out for free everywhere.
enum Motion {
    static var reduce: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    // screen: critically-damped reposition; quick: snappy hover; pop: momentum bounce.
    static var screen: Animation? { reduce ? nil : .spring(response: 0.32, dampingFraction: 0.85) }
    static var quick:  Animation? { reduce ? nil : .spring(response: 0.18, dampingFraction: 0.9) }
    static var pop:    Animation? { reduce ? nil : .spring(response: 0.30, dampingFraction: 0.7) }
}

/// Contrast floor for the floating panel. The window blends `.behindWindow`, so without
/// a real surface the text renders against whatever is on screen — unreadable over white,
/// because `labelColor` follows the window's *appearance*, not the actual backdrop.
/// One tunable: how much of the material shows through.
enum PanelSurface {
    static var reduceTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }
    static var opacity: Double { reduceTransparency ? 1.0 : 0.92 }
}

/// Ambient sync-state color, shared by every NavBar dot + the pill.
func syncColor(_ status: SyncStatus) -> Color {
    switch status {
    case .synced: return .green
    case .offline: return .orange
    default: return .secondary.opacity(0.4)
    }
}

// MARK: - Root switcher

struct EditorView: View {
    @ObservedObject var store: NoteStore
    @AppStorage("theme") private var themeID = "System"

    private var theme: Theme { Theme.named(themeID) }

    var body: some View {
        ZStack {
            GlassBackground()
            // the contrast floor: content always sits on the theme's own surface
            Rectangle().fill(theme.surface).opacity(PanelSurface.opacity).allowsHitTesting(false)
            Group {
                if store.pill {
                    PillView(store: store)
                } else {
                    screens
                }
            }
            if !store.pill, store.lastDeleted != nil {
                UndoDeleteBanner(store: store)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.quick, value: store.lastDeleted?.original)
        .tint(theme.accentSwift) // buttons/toggles/sliders/selection take the theme accent
        .overlay( // hairline edge; material below dims itself when the window loses key
            RoundedRectangle(cornerRadius: store.pill ? 20 : 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .frame(minWidth: store.pill ? 0 : 280, minHeight: store.pill ? 0 : 180)
        .onAppear { store.applyAppearance?(theme.appearance) }
        .onChange(of: themeID) { _ in store.applyAppearance?(theme.appearance) }
    }

    @ViewBuilder private var screens: some View {
        Group {
            switch store.screen {
            case .onboarding:
                OnboardingView(store: store)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            case .capture:
                CaptureView(store: store)
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)))
            case .library:
                LibraryView(store: store)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)))
            case .settings:
                SettingsView(store: store)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            case .gitSetup:
                GitSetupView(store: store)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            case .conflicts:
                ConflictView(store: store)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(Motion.screen, value: store.screen)
    }
}

// MARK: - Shared navigation chrome

/// One header for every screen: [left] · [center title/context] · [right].
/// chevron.left always means "back one level"; xmark only appears on Capture.
struct NavBar<L: View, C: View, R: View>: View {
    @ViewBuilder var left: () -> L
    @ViewBuilder var center: () -> C
    @ViewBuilder var right: () -> R

    var body: some View {
        ZStack {
            center()
            HStack { left(); Spacer(); right() }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        // 8pt: the icon containers carry their own inset, so the glyphs still land
        // on the same optical margin as the body text.
        .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 6)
    }
}

/// Every chrome control is this: one identical square container, one glyph size/weight,
/// one hover background. Alignment then comes from the container geometry rather than
/// from each SF Symbol's own optical center — which is why mixing a heavy glyph
/// (square.and.pencil) with a thin one (xmark) used to read as misaligned.
/// Pair it with symmetric glyphs; see `ChromeGlyph`.
struct ChromeIcon: View {
    let symbol: String
    let help: String
    var tint: Color? = nil // only the conflict badge deviates from the secondary chrome
    let action: () -> Void
    @State private var hovering = false

    static let side: CGFloat = 28 // container; 2pt gaps → ~30pt pitch

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .symbolRenderingMode(.monochrome)
                .frame(width: Self.side, height: Self.side)
                .background(hovering ? Color.primary.opacity(0.08) : .clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint ?? Color.secondary)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .help(help)
    }
}

/// The chrome glyph set — symmetric, matched optical weight, so the clusters balance.
enum ChromeGlyph {
    static let back     = "chevron.left"
    static let library  = "square.grid.2x2"
    static let newNote  = "plus"          // was square.and.pencil (heavy, juts top-right)
    static let settings = "gearshape"
    static let minimize = "minus"         // was a busy 4-arrow glyph
    static let close    = "xmark"
    static let conflict = "exclamationmark.triangle.fill"
}

/// "Note deleted — Undo", bottom-anchored, self-dismissing. The delete already went to
/// the Trash; this just makes the slip one click to reverse instead of a Finder trip.
struct UndoDeleteBanner: View {
    @ObservedObject var store: NoteStore

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                Text("Note deleted").font(.callout)
                Spacer(minLength: 0)
                Button("Undo") { store.undoDelete() }
                    .buttonStyle(.borderless)
                    .font(.callout.weight(.medium))
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
            .padding(.horizontal, 12).padding(.bottom, 12)
        }
        .task(id: store.lastDeleted?.original) { // restarts the timer for each new delete
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            store.lastDeleted = nil
        }
    }
}

/// Standard header: a screen-specific left slot + the persistent right cluster
/// (Settings · Minimize · Close) available on every screen.
struct ChromeBar<L: View>: View {
    @ObservedObject var store: NoteStore
    let title: String
    var subtitle: String? = nil
    var showSettings: Bool = true
    var showSyncDot: Bool = true
    @ViewBuilder var left: () -> L

    var body: some View {
        NavBar {
            left()
        } center: {
            NavCenter(store: store, title: title, subtitle: subtitle, showSyncDot: showSyncDot)
        } right: {
            HStack(spacing: 2) {
                if !store.conflicts.isEmpty && store.screen != .conflicts {
                    ChromeIcon(symbol: ChromeGlyph.conflict, help: "Two Macs edited the same note — review",
                               tint: .orange) { store.screen = .conflicts }
                }
                if showSettings {
                    ChromeIcon(symbol: ChromeGlyph.settings, help: "Settings (⌘,)") { store.openSettings() }
                }
                ChromeIcon(symbol: ChromeGlyph.minimize, help: "Minimize to pill (⌘M)") { store.setPill?(true) }
                ChromeIcon(symbol: ChromeGlyph.close, help: "Close (Esc)") { store.onHide?() }
            }
        }
        // double-click-to-minimize lives in PanelWindow.mouseDown (see the note there)
    }
}

/// Center slot: title with the ambient sync dot in the subtitle line.
struct NavCenter: View {
    @ObservedObject var store: NoteStore
    let title: String
    var subtitle: String? = nil
    var showSyncDot: Bool = true

    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 5) {
                if showSyncDot {
                    Circle().fill(syncColor(store.syncStatus)).frame(width: 6, height: 6)
                }
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
            }
            if let subtitle {
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: 200)
        .allowsHitTesting(false)
    }
}

/// Collapsed UI: a lozenge. Tap it to expand (or ⌥Space); drag it to move.
/// One DragGesture serves both — a near-zero move on release is treated as a tap.
struct PillView: View {
    @ObservedObject var store: NoteStore

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(syncColor(store.syncStatus)).frame(width: 7, height: 7)
            Text(store.selected.map { store.title(for: $0) } ?? "GitPad")
                .font(.footnote.weight(.medium)).lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.left.and.arrow.down.right") // affordance hint
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in store.pillDrag?() }
                .onEnded { g in
                    store.pillDragEnded?()
                    if abs(g.translation.width) + abs(g.translation.height) < 4 {
                        store.setPill?(false) // tap → expand
                    }
                }
        )
        .help("Tap to expand (\(Hotkey.display))")
    }
}

/// Refined translucent material; automatically softens when the window is inactive.
struct GlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {}
}

// MARK: - Capture (just the editor)

struct CaptureView: View {
    @ObservedObject var store: NoteStore
    @AppStorage("fontDesign") private var fontDesign = "system"
    @AppStorage("editorFontSize") private var editorFontSize = 14.0
    @AppStorage("theme") private var themeID = "System"
    @State private var nudgeDismissed = false

    var body: some View {
        VStack(spacing: 0) {
            ChromeBar(store: store,
                      title: store.selected.map { store.title(for: $0) } ?? "",
                      subtitle: store.selected.map { subtitle(for: $0) }) {
                HStack(spacing: 2) {
                    ChromeIcon(symbol: ChromeGlyph.library, help: "Library (⌘L)") { store.screen = .library }
                    ChromeIcon(symbol: ChromeGlyph.newNote, help: "New note (⌘N)") { store.newNote() }
                }
            }

            if let since = staleSince {
                HStack(spacing: 6) {
                    Text("Sync hasn't worked since \(since.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    Button("Fix") { store.openSettings() }
                        .font(.caption2).buttonStyle(.borderless)
                    Spacer(minLength: 0)
                    Button { nudgeDismissed = true } label: { Image(systemName: "xmark").font(.caption2) }
                        .buttonStyle(.borderless).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14).padding(.bottom, 6)
            }

            MarkdownTextView(text: $store.text,
                             fontSize: CGFloat(editorFontSize),
                             design: fontDesign,
                             themeID: themeID)
        }
        // ⌘N/⌘L/⌘S/⌘⌫/⌘M/⌘, are handled by the main-menu "Note" submenu in AppDelegate,
        // so they work from every screen — not just here.
    }

    /// Nag only when sync is *broken*: a deliberate local-only setup (.noRemote) never nags.
    private var staleSince: Date? {
        guard !nudgeDismissed, store.syncStatus == .offline,
              let last = UserDefaults.standard.object(forKey: "lastSyncOK") as? Date,
              Date().timeIntervalSince(last) > 86_400 else { return nil }
        return last
    }

    private func subtitle(for sel: URL) -> String {
        let date = store.modified(sel).formatted(.dateTime.month(.abbreviated).day())
        if let f = store.folder(of: sel) { return "\(f) · \(date)" }
        return date
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var store: NoteStore
    @AppStorage("fontDesign") private var fontDesign = "system"
    @AppStorage("editorFontSize") private var editorFontSize = 14.0
    @AppStorage("theme") private var themeID = "System"
    @State private var remote = ""
    @State private var aheadBehind: (ahead: Int, behind: Int)?

    // (tag, label) — system designs plus Apple-bundled note-friendly fonts.
    // Nothing here ships with the app, so open-sourcing stays clean.
    static let fonts: [(String, String)] = [
        ("system", "SF Pro (System)"),
        ("serif", "New York (Serif)"),
        ("rounded", "SF Rounded"),
        ("mono", "SF Mono"),
        ("Avenir Next", "Avenir Next"),
        ("Helvetica Neue", "Helvetica Neue"),
        ("Charter", "Charter"),
        ("Georgia", "Georgia"),
        ("Palatino", "Palatino"),
        ("Iowan Old Style", "Iowan Old Style"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ChromeBar(store: store, title: "Settings", showSettings: false, showSyncDot: false) {
                ChromeIcon(symbol: ChromeGlyph.back, help: "Back (Esc)") { store.goBack() }
            }

            Form {
                Section("Editor") {
                    Picker("Font", selection: $fontDesign) {
                        ForEach(Self.fonts, id: \.0) { tag, label in
                            Text(label).tag(tag)
                        }
                    }
                    LabeledContent("Size") {
                        HStack(spacing: 10) {
                            Text("\(Int(editorFontSize)) pt")
                                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            HStack(spacing: 0) {
                                stepper("minus") { editorFontSize = max(11, editorFontSize - 1) }
                                Divider().frame(height: 14)
                                stepper("plus") { editorFontSize = min(20, editorFontSize + 1) }
                            }
                            .background(Color.primary.opacity(0.06), in: Capsule())
                        }
                    }
                    Text("The quick brown fox jumps over the lazy dog.")
                        .font(Font(MarkdownTextView.Coordinator.baseFont(CGFloat(editorFontSize), fontDesign) as CTFont))
                        .foregroundStyle(.secondary)
                }
                Section("Global Hotkey") {
                    HotkeyRecorder()
                }
                Section {
                    HStack {
                        TextField("git@github.com:you/notes.git", text: $remote)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption.monospaced())
                            .onSubmit { saveRemote() }
                        Button("Save") { saveRemote() }
                            .disabled(remote.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    LabeledContent("Status") {
                        HStack(spacing: 8) {
                            Circle().fill(syncColor(store.syncStatus)).frame(width: 7, height: 7)
                            Group {
                                Text(store.syncStatus.label)
                                if let ab = aheadBehind, ab.ahead + ab.behind > 0 {
                                    Text("↑\(ab.ahead) ↓\(ab.behind)")
                                }
                            }
                            .font(.callout).foregroundStyle(.secondary)
                            Button(store.syncing ? "Syncing…" : "Sync Now") { store.requestSync?() }
                                .disabled(store.syncing)
                        }
                    }
                    if store.syncStatus == .offline {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            FixSyncPanel(store: store)
                        }
                        .listRowBackground(Color.orange.opacity(0.08))
                    }
                } header: {
                    HStack {
                        Text("Sync")
                        Spacer()
                        Button("Setup guide") { store.screen = .gitSetup }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tint)
                    }
                }
                if !store.conflicts.isEmpty {
                    Section("Conflicts") {
                        Button {
                            store.screen = .conflicts
                        } label: {
                            Label("Review \(store.conflicts.count) conflict\(store.conflicts.count == 1 ? "" : "s")…",
                                  systemImage: "exclamationmark.triangle.fill")
                        }
                    }
                }
                Section {
                    LabeledContent("Theme") {
                        HStack(spacing: 12) {
                            ForEach(Theme.all) { t in
                                Button { themeID = t.id } label: {
                                    Circle().fill(t.swatchBg)
                                        .frame(width: 26, height: 26)
                                        .overlay(Circle().fill(t.accentSwift).frame(width: 12, height: 12))
                                        .overlay(themeID == t.id
                                            ? Image(systemName: "checkmark")
                                                .font(.system(size: 8, weight: .bold))
                                                .foregroundStyle(.white)
                                            : nil)
                                        .overlay(Circle().strokeBorder(
                                            Color.primary.opacity(themeID == t.id ? 0.45 : 0.12),
                                            lineWidth: themeID == t.id ? 2 : 1))
                                        .animation(Motion.quick, value: themeID)
                                }
                                .buttonStyle(.plain)
                                .help(t.id)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("Changes apply immediately — there's no Save button.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .onAppear { refreshGitInfo() }
        // backgroundSync publishes a fresh .synced(Date) on each cycle → refresh ahead/behind
        // exactly when sync finishes, instead of guessing with a 2s delay.
        .onChange(of: store.syncStatus) { _ in refreshGitInfo() }
    }

    private func stepper(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 26, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func saveRemote() {
        GitSync.setRemote(remote.trimmingCharacters(in: .whitespacesAndNewlines), in: store.dir)
        store.requestSync?()
    }

    private func refreshGitInfo() {
        DispatchQueue.global().async {
            let url = GitSync.remoteURL(in: store.dir)
            let ab = GitSync.aheadBehind(in: store.dir)
            DispatchQueue.main.async {
                if remote.isEmpty { remote = url }
                aheadBehind = ab
            }
        }
    }
}

/// Sync is failing — say why in plain language and offer the one-click fix.
/// The diagnosis is deliberately async: `ls-remote` can hang for a long time.
struct FixSyncPanel: View {
    @ObservedObject var store: NoteStore
    @State private var problem: GitSync.SyncProblem?
    @State private var ghReady = false
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch problem {
            case nil:
                Text("Checking what went wrong…").font(.caption).foregroundStyle(.secondary)
            case .sshAuth(let key):
                Text("The repo host rejected this Mac's SSH key (\(URL(fileURLWithPath: key).lastPathComponent)).")
                    .font(.caption)
                if ghReady {
                    Button("Switch to HTTPS via GitHub CLI") { switchToHTTPS() }
                }
                Button("Copy public key") {
                    let pub = (try? String(contentsOfFile: key + ".pub", encoding: .utf8)) ?? ""
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(pub, forType: .string)
                    note = pub.isEmpty ? "Couldn't read \(key).pub" : "Copied — paste it at your host"
                }
                if GitSync.remoteURL(in: store.dir).contains("github.com") {
                    Link("Add a key on GitHub ↗", destination: URL(string: "https://github.com/settings/ssh/new")!)
                        .font(.caption)
                }
            case .repoMissing:
                Text("That repository isn't there — check the URL.").font(.caption)
                Button("Set up sync…") { store.screen = .gitSetup }
            case .hostKeyChanged:
                Text("The server's SSH key changed. That can be a man-in-the-middle attack — verify the new key with your host before trusting it.")
                    .font(.caption).foregroundStyle(.orange)
            case .httpsNeedsLogin:
                Text("This HTTPS URL needs a login. Sign in to the gh CLI (`gh auth login`) or use the SSH URL instead.")
                    .font(.caption)
            case .offline:
                Text("Network unreachable — GitPad retries every 5 minutes.").font(.caption)
            case .noRemote, .ok:
                EmptyView()
            }
            if let note {
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.borderless)
        .onAppear(perform: diagnose)
    }

    private func diagnose() {
        DispatchQueue.global().async {
            let p = GitSync.diagnose(dir: store.dir)
            let gh = GitSync.ghReady()
            DispatchQueue.main.async { problem = p; ghReady = gh }
        }
    }

    /// Exactly the manual fix: point origin at HTTPS and let gh's token drive it.
    private func switchToHTTPS() {
        guard let https = GitSync.httpsURL(from: GitSync.remoteURL(in: store.dir)) else { return }
        note = "Switching…"
        DispatchQueue.global().async {
            GitSync.setRemote(https, in: store.dir)
            GitSync.enableHTTPSAuth()
            DispatchQueue.main.async {
                note = "Now using \(https)"
                store.requestSync?()
                diagnose()
            }
        }
    }
}

// MARK: - Conflicts

/// One screen for every conflict copy: what happened, both versions, three ways out.
struct ConflictView: View {
    @ObservedObject var store: NoteStore
    @State private var selection: URL?

    private var copy: URL? { selection ?? store.conflicts.first }

    var body: some View {
        VStack(spacing: 0) {
            ChromeBar(store: store, title: "Conflicts", showSettings: false, showSyncDot: false) {
                ChromeIcon(symbol: ChromeGlyph.back, help: "Back (Esc)") { store.goBack() }
            }

            Text("Two Macs edited the same note between syncs. GitPad kept this Mac's version and saved the other alongside it — nothing was lost.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14).padding(.bottom, 8)

            if let copy {
                if store.conflicts.count > 1 {
                    Picker("", selection: Binding(get: { copy }, set: { selection = $0 })) {
                        ForEach(store.conflicts, id: \.self) { c in
                            Text(store.title(for: c)).tag(c)
                        }
                    }
                    .labelsHidden().padding(.horizontal, 14).padding(.bottom, 6)
                }
                if let orig = store.original(for: copy) {
                    HStack(spacing: 8) {
                        pane("On this Mac", orig)
                        pane("From \(store.conflictDevice(copy))", copy)
                    }
                    .padding(.horizontal, 14)
                    HStack(spacing: 10) {
                        Button("Keep Mine") { resolve { store.resolveDiscard(copy) } }
                        Button("Use Theirs") { resolve { store.resolveKeep(copy) } }
                        Button("Keep Both") { resolve { store.resolveKeepBoth(copy) } }
                    }
                    .font(.callout).padding(.vertical, 12)
                } else {
                    // the original is gone — this Mac deleted it while the other edited it
                    VStack(spacing: 8) {
                        Text("The note this came from no longer exists on this Mac.")
                            .font(.caption).foregroundStyle(.secondary)
                        pane("From \(store.conflictDevice(copy))", copy)
                        HStack(spacing: 10) {
                            Button("Keep as Note") { resolve { store.resolveKeepBoth(copy) } }
                            Button("Discard") { resolve { store.resolveDiscard(copy) } }
                        }
                        .font(.callout)
                    }
                    .padding(14)
                }
            }
            Spacer(minLength: 0)
        }
        .onChange(of: store.conflicts) { list in if list.isEmpty { store.goBack() } }
    }

    private func resolve(_ action: () -> Void) {
        action()
        selection = nil
    }

    private func pane(_ label: String, _ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView {
                Text((try? String(contentsOf: url, encoding: .utf8)) ?? "")
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .frame(minHeight: 120)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

/// Records a new global hotkey: click to arm, then press a modified key combo.
/// A local key-down monitor captures (and consumes) the first press; Esc cancels.
struct HotkeyRecorder: View {
    @State private var recording = false
    @State private var display = Hotkey.display
    @State private var monitor: Any?
    @State private var warning: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Shortcut")
                Spacer()
                Button { recording ? stop() : start() } label: {
                    Text(recording ? "Press keys…" : display)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.primary.opacity(recording ? 0.12 : 0.06),
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text(warning ?? (recording
                             ? "Esc cancels."
                             : "Press \(display) from any app to summon GitPad — click to change."))
                .font(.caption)
                .foregroundStyle(warning == nil ? .secondary : Color.orange)
        }
        .onDisappear(perform: stop) // never leave a live monitor behind
    }

    private func start() {
        recording = true
        warning = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil // consume every key-down while recording
        }
    }

    private func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        recording = false
    }

    private func handle(_ event: NSEvent) {
        if Int(event.keyCode) == kVK_Escape { stop(); return }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.isEmpty else { warning = "Add a modifier — ⌘, ⌥, ⌃, or ⇧"; return }
        let mods = Hotkey.carbonModifiers(flags)
        let combo = Hotkey.displayString(flags, keyCode: event.keyCode,
                                         chars: event.charactersIgnoringModifiers ?? "")
        if Hotkey.apply(keyCode: UInt32(event.keyCode), modifiers: mods) {
            let d = UserDefaults.standard
            d.set(Int(event.keyCode), forKey: "hotkeyKeyCode")
            d.set(Int(mods), forKey: "hotkeyModifiers")
            d.set(combo, forKey: "hotkeyDisplay")
            display = combo
            stop()
        } else {
            warning = "\(combo) is already in use — try another" // keep recording
        }
    }
}

// MARK: - Library (two-column: sources on the left, notes on the right)

enum LibrarySource: Hashable {
    case recent, daily, inbox, folder(String)

    var label: String {
        switch self {
        case .recent: return "Recent"
        case .daily: return "Daily"
        case .inbox: return "Inbox"
        case .folder(let f): return f
        }
    }
    var symbol: String {
        switch self {
        case .recent: return "clock"
        case .daily: return "calendar"
        case .inbox: return "tray"
        case .folder: return "folder"
        }
    }
}

struct LibraryView: View {
    @ObservedObject var store: NoteStore
    @State private var query = ""
    @State private var source: LibrarySource = .recent
    @State private var creatingFolder = false
    @State private var newFolderName = ""
    @State private var renaming: String?
    @State private var renameText = ""
    @State private var deleting: String?
    @FocusState private var searchFocused: Bool
    @FocusState private var folderFieldFocused: Bool

    // user folders shown in the rail (Daily is its own top-level item)
    private var folders: [String] { store.folders.filter { $0 != "Daily" } }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var newNoteHelp: String {
        switch source {
        case .folder(let f): return "New note in \(f)"
        case .daily: return "Open today's daily note"
        default: return "New note in Inbox (⌘N)"
        }
    }

    /// New note lands where you're browsing: a folder → that folder; Daily → today's
    /// note (the only note Daily can hold); Recent/Inbox → the Inbox (repo root).
    private func newNoteHere() {
        switch source {
        case .daily: store.open(store.dailyNote())
        case .folder(let f): store.newNote(in: f)
        default: store.newNote()
        }
    }

    private var notes: [URL] {
        let m = store.matches(query)
        guard !searching else { return m } // a search spans every folder
        return m.filter { url in
            switch source {
            case .recent: return true
            case .daily: return store.folder(of: url) == "Daily"
            case .inbox: return store.folder(of: url) == nil
            case .folder(let f): return store.folder(of: url) == f
            }
        }
    }

    private var groups: [(String, [URL])] {
        let cal = Calendar.current
        let weekAgo = Date().addingTimeInterval(-7 * 86400)
        let pinnedSet = Set(store.pinnedNotes().map(\.path))
        let pinned = notes.filter { pinnedSet.contains($0.path) }
        let rest = notes.filter { !pinnedSet.contains($0.path) }
        return ([("Pinned", pinned)] + [
            ("Today", rest.filter { cal.isDateInToday(store.modified($0)) }),
            ("This Week", rest.filter { !cal.isDateInToday(store.modified($0)) && store.modified($0) > weekAgo }),
            ("Earlier", rest.filter { store.modified($0) <= weekAgo }),
        ]).filter { !$1.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            ChromeBar(store: store, title: "Library") {
                HStack(spacing: 2) {
                    ChromeIcon(symbol: ChromeGlyph.back, help: "Back to note (⌘L / Esc)") { store.screen = .capture }
                    ChromeIcon(symbol: ChromeGlyph.newNote, help: newNoteHelp) { newNoteHere() }
                }
            }

            // full-width search — spans every folder, above the two columns
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search all notes…", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { if let first = notes.first { store.open(first) } }
                    // Esc clears an active search first; only then leaves the Library.
                    .onExitCommand { if searching { query = "" } else { store.goBack() } }
                if searching {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.tertiary)
                } else {
                    Text("⌘K").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 8) // breathe below the chrome bar
            Divider().opacity(0.4)

            HStack(spacing: 0) {
                sourceRail.disabled(searching) // browsing is paused while searching everything
                Divider()
                noteColumn
            }
        }
    }

    // MARK: left rail

    private var sourceRail: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    sourceRow(.recent)
                    sourceRow(.daily)
                    sourceRow(.inbox)
                    if !folders.isEmpty {
                        Text("FOLDERS")
                            .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            .tracking(0.6)
                            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 2)
                        ForEach(folders, id: \.self) { f in
                            FolderRailRow(name: f, count: count(.folder(f)),
                                          selected: source == .folder(f),
                                          select: { source = .folder(f) },
                                          rename: { renameText = f; renaming = f },
                                          delete: { deleting = f })
                        }
                    }
                }
                .padding(.horizontal, 6).padding(.top, 8)
            }

            Divider().opacity(0.4)
            if creatingFolder {
                TextField("Folder name", text: $newFolderName)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .focused($folderFieldFocused)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .onSubmit {
                        store.createFolder(newFolderName)
                        if !newFolderName.trimmingCharacters(in: .whitespaces).isEmpty {
                            source = .folder(newFolderName.trimmingCharacters(in: .whitespaces))
                        }
                        newFolderName = ""; creatingFolder = false
                    }
                    .onExitCommand { newFolderName = ""; creatingFolder = false }
            } else {
                Button {
                    creatingFolder = true; folderFieldFocused = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus").font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
        .frame(width: 150)
        .alert("Rename folder", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let f = renaming {
                    let new = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    store.renameFolder(f, to: new)
                    if source == .folder(f), !new.isEmpty { source = .folder(new) }
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .alert("Delete “\(deleting ?? "")”?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let f = deleting {
                    store.deleteFolder(f)
                    if source == .folder(f) { source = .recent }
                }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("Notes inside move to Inbox; the folder is removed.")
        }
    }

    /// How many notes a rail entry would show. Cheap: `notes` is already in memory.
    private func count(_ s: LibrarySource) -> Int {
        switch s {
        case .recent: return store.notes.count
        case .daily: return store.notes.filter { store.folder(of: $0) == "Daily" }.count
        case .inbox: return store.notes.filter { store.folder(of: $0) == nil }.count
        case .folder(let f): return store.notes.filter { store.folder(of: $0) == f }.count
        }
    }

    private func sourceRow(_ s: LibrarySource) -> some View {
        Button { source = s } label: {
            HStack(spacing: 6) {
                Label(s.label, systemImage: s.symbol).lineLimit(1)
                Spacer(minLength: 0)
                Text("\(count(s))").foregroundStyle(.secondary)
            }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(source == s ? Color.accentColor.opacity(0.18) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: right column

    private var noteColumn: some View {
        VStack(spacing: 0) {
            if groups.isEmpty {
                Spacer()
                Text(searching ? "No matches" : "No notes here yet")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(groups, id: \.0) { name, urls in
                        Section {
                            ForEach(urls, id: \.self) { url in
                                NoteRow(store: store, url: url)
                            }
                        } header: {
                            Text(name.uppercased())
                                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                                .tracking(0.6)
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity)
        // animate the empty↔populated / group swap on search only — NOT on refresh(),
        // which fires every 5-min sync and would churn rows.
        .animation(Motion.quick, value: query)
        .onAppear { searchFocused = true }
        .onChange(of: store.searchRequest) { _ in searchFocused = true }
    }
}

/// Folder row in the rail: tap to select; hover reveals an ⋯ menu; right-click too.
struct FolderRailRow: View {
    let name: String
    let count: Int
    let selected: Bool
    let select: () -> Void
    let rename: () -> Void
    let delete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Label(name, systemImage: "folder").font(.callout).lineLimit(1)
            Spacer(minLength: 0)
            // count and ⋯ share one slot: the row never changes width on hover
            if hovering {
                Menu {
                    Button("Rename…", action: rename)
                    Button("Delete Folder", role: .destructive, action: delete)
                } label: {
                    Image(systemName: "ellipsis")
                        .rotationEffect(.degrees(90)) // vertical ⋮ (no single SF symbol for it)
                        .font(.system(size: 13, weight: .medium))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .tint(.secondary) // borderlessButton tints its label with accent; force it to match the chrome
                .foregroundStyle(.secondary)
                .frame(width: ChromeIcon.side, height: ChromeIcon.side) // same geometry as the nav bar
                .contentShape(Rectangle())
            } else {
                Text("\(count)").font(.callout).foregroundStyle(.secondary)
                    .frame(width: ChromeIcon.side)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(selected ? Color.accentColor.opacity(0.18)
                             : (hovering ? Color.primary.opacity(0.05) : .clear),
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .contextMenu {
            Button("Rename…", action: rename)
            Button("Delete Folder", role: .destructive, action: delete)
        }
    }
}

struct NoteRow: View {
    @ObservedObject var store: NoteStore
    let url: URL
    @State private var hovering = false

    /// "3 of 7 done · yesterday" for checklists, else "first line · yesterday".
    private var detail: String {
        let m = store.meta(for: url)
        let when = store.modified(url).formatted(.relative(presentation: .named))
        if m.total > 0 { return "\(m.done) of \(m.total) done · \(when)" }
        return (m.snippet.isEmpty ? "Empty" : m.snippet) + " · \(when)"
    }

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if store.meta(for: url).total > 0 {
                        Image(systemName: "checkmark.square.fill")
                            .font(.caption2).foregroundStyle(.tint)
                    }
                    Text(store.title(for: url)).font(.callout.weight(.semibold)).lineLimit(1)
                }
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if store.folder(of: url) == "Daily" {
                Text("Daily")
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }
            Menu {
                Button("Open") { store.open(url) }
                Button(store.isPinned(url) ? "Unpin" : "Pin") { store.togglePin(url) }
                Menu("Move to") {
                    Button("Notes") { store.move(url, to: nil) }
                    ForEach(store.folders, id: \.self) { f in
                        Button(f) { store.move(url, to: f) }
                    }
                }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Divider()
                Button("Delete", role: .destructive) { store.delete(url) }
            } label: {
                Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(hovering ? 1 : 0)
        }
        .padding(.vertical, 5).padding(.horizontal, 6)
        .background(Color.primary.opacity(hovering ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { store.open(url) }
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }
}

// MARK: - Smart markdown editor

private let dividerKey = NSAttributedString.Key("gitpadDivider")
private let checkboxKey = NSAttributedString.Key("gitpadCheckbox") // value: Bool (checked)

struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat = 14
    var design: String = "system"
    var themeID: String = "System"

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1 stack so our layout manager can draw full-width dividers
        let storage = NSTextStorage()
        let layout = DividerLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)

        let tv = SmartTextView(frame: .zero, textContainer: container)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = Coordinator.baseFont(fontSize, design)
        tv.textContainerInset = NSSize(width: 20, height: 14) // room to breathe, like a real notes app
        tv.defaultParagraphStyle = Coordinator.paragraphStyle
        tv.drawsBackground = false
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isAutomaticDashSubstitutionEnabled = false // keep "---" as typed → divider
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.delegate = context.coordinator
        storage.delegate = context.coordinator
        context.coordinator.textView = tv

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? SmartTextView, let storage = tv.textStorage else { return }
        context.coordinator.parent = self
        if context.coordinator.fontSize != fontSize || context.coordinator.design != design
            || context.coordinator.themeID != themeID {
            context.coordinator.fontSize = fontSize
            context.coordinator.design = design
            context.coordinator.themeID = themeID
            tv.font = Coordinator.baseFont(fontSize, design)
            context.coordinator.highlight(storage, range: NSRange(location: 0, length: storage.length))
        }
        if tv.string != text {
            tv.string = text
            if text == "# " { tv.setSelectedRange(NSRange(location: 2, length: 0)) } // fresh note: caret after title marker
            context.coordinator.highlight(storage, range: NSRange(location: 0, length: storage.length))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: MarkdownTextView
        weak var textView: SmartTextView?
        var fontSize: CGFloat = 14
        var design: String = "system"
        var themeID: String = "System"
        private var slashLocation: Int?
        private let actionPopover = NSPopover()

        init(_ parent: MarkdownTextView) {
            self.parent = parent
            self.fontSize = parent.fontSize
            self.design = parent.design
        }

        /// Shared leading. MUST also ride in the `base` attribute dict below — `highlight()`
        /// calls `setAttributes`, which replaces every attribute on the range, so a style set
        /// only via `defaultParagraphStyle` would be wiped on the first keystroke.
        static let paragraphStyle: NSParagraphStyle = {
            let p = NSMutableParagraphStyle()
            p.lineHeightMultiple = 1.25
            p.paragraphSpacing = 6
            return p
        }()

        // MARK: fonts
        static func baseFont(_ size: CGFloat, _ design: String) -> NSFont {
            switch design {
            case "system", "serif", "rounded", "mono":
                let d: NSFontDescriptor.SystemDesign = design == "serif" ? .serif
                    : design == "rounded" ? .rounded
                    : design == "mono" ? .monospaced : .default
                let desc = NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(d)
                return desc.flatMap { NSFont(descriptor: $0, size: size) } ?? .systemFont(ofSize: size)
            default: // a named system-installed font (Avenir Next, Charter, …)
                return NSFont(name: design, size: size) ?? .systemFont(ofSize: size)
            }
        }

        private static func bold(_ f: NSFont) -> NSFont {
            NSFont(descriptor: f.fontDescriptor.withSymbolicTraits(.bold), size: f.pointSize) ?? f
        }

        // MARK: text change → binding + slash menu
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            maybeShowSlashMenu(tv)
        }

        // MARK: paragraph-scoped highlighting
        func textStorage(_ storage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                         range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            let loc = min(editedRange.location, storage.length)
            let safe = NSRange(location: loc, length: min(editedRange.length, storage.length - loc))
            let para = (storage.string as NSString).paragraphRange(for: safe)
            DispatchQueue.main.async { [weak self, weak storage] in
                guard let self, let storage else { return }
                self.highlight(storage, range: para)
            }
        }

        private var cachedRules: (size: CGFloat, design: String, theme: String,
                                  base: [NSAttributedString.Key: Any],
                                  rules: [(NSRegularExpression, [NSAttributedString.Key: Any])])?

        private func rules() -> (base: [NSAttributedString.Key: Any],
                                 rules: [(NSRegularExpression, [NSAttributedString.Key: Any])]) {
            if let c = cachedRules, c.size == fontSize, c.design == design, c.theme == themeID {
                return (c.base, c.rules)
            }
            let theme = Theme.named(themeID)
            func re(_ p: String) -> NSRegularExpression {
                try! NSRegularExpression(pattern: p, options: [.anchorsMatchLines])
            }
            let f = Self.baseFont(fontSize, design)
            let base: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: NSColor.labelColor,
                                                       .paragraphStyle: Self.paragraphStyle]
            let list: [(NSRegularExpression, [NSAttributedString.Key: Any])] = [
                // typographic scale: H1 ≈ 1.6×, H2 ≈ 1.3×, H3 ≈ 1.15× body
                (re(#"^# .*$"#), [.font: Self.bold(Self.baseFont(fontSize + 8, design))]),
                (re(#"^## .*$"#), [.font: Self.bold(Self.baseFont(fontSize + 4, design))]),
                (re(#"^### .*$"#), [.font: Self.bold(Self.baseFont(fontSize + 2, design))]),
                // hide the hash marks entirely so headers read as rendered titles
                (re(#"^#{1,3} (?=\S)"#), [.foregroundColor: NSColor.clear,
                                          .font: NSFont.systemFont(ofSize: 0.1)]),
                (re(#"\*\*[^*\n]+\*\*"#), [.font: Self.bold(f)]),
                (re(#"(?<!\*)\*[^*\n]+\*(?!\*)"#), [.obliqueness: 0.15]),
                (re(#"~~[^~\n]+~~"#), [.strikethroughStyle: NSUnderlineStyle.single.rawValue]),
                (re(#"`[^`\n]+`"#), [.font: NSFont.monospacedSystemFont(ofSize: fontSize - 1, weight: .regular),
                                     .foregroundColor: theme.code]),
                (re(#"^\s*(?:[-*+] |\d+\. )"#), [.foregroundColor: NSColor.secondaryLabelColor]),
                // strike/dim only the text after a checked box (fixed 2-char lookbehind)
                (re(#"(?<=☑ ).*$"#), [.foregroundColor: NSColor.secondaryLabelColor,
                                      .strikethroughStyle: NSUnderlineStyle.single.rawValue]),
                // hide the raw glyph; DividerLayoutManager draws a real checkbox at its rect
                (re(#"☐"#), [.foregroundColor: NSColor.clear, checkboxKey: false]),
                (re(#"☑"#), [.foregroundColor: NSColor.clear, checkboxKey: true]),
                // dashes hidden; DividerLayoutManager draws a full-width rule instead
                (re(#"^\s*[-—]{3,}\s*$"#), [.foregroundColor: NSColor.clear, dividerKey: true]),
            ]
            cachedRules = (fontSize, design, themeID, base, list)
            return (base, list)
        }

        func highlight(_ storage: NSTextStorage, range: NSRange) {
            guard range.location + range.length <= storage.length else { return }
            (storage.layoutManagers.first as? DividerLayoutManager)?.accent = Theme.named(themeID).accent
            let (base, list) = rules()
            storage.beginEditing()
            storage.setAttributes(base, range: range)
            for (regex, attrs) in list {
                regex.enumerateMatches(in: storage.string, range: range) { match, _, _ in
                    if let r = match?.range { storage.addAttributes(attrs, range: r) }
                }
            }
            storage.endEditing()
        }

        // MARK: auto list continuation
        func textView(_ tv: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) { return continueList(tv) }
            return false
        }

        private static let listRegex = try! NSRegularExpression(
            pattern: #"^(\s*)(?:([-*+☐☑]) |(\d+)\. )(.*)$"#)

        private func continueList(_ tv: NSTextView) -> Bool {
            let ns = tv.string as NSString
            let caret = tv.selectedRange().location
            let lineR = ns.lineRange(for: NSRange(location: min(caret, ns.length), length: 0))
            let upToCaret = ns.substring(with: NSRange(location: lineR.location, length: caret - lineR.location))
            let lineNS = upToCaret as NSString
            guard let m = Self.listRegex.firstMatch(in: upToCaret,
                    range: NSRange(location: 0, length: lineNS.length)) else { return false }
            let content = lineNS.substring(with: m.range(at: 4))
            if content.isEmpty {
                tv.insertText("", replacementRange: NSRange(location: lineR.location, length: caret - lineR.location))
                return true
            }
            var prefix = lineNS.substring(with: m.range(at: 1))
            if m.range(at: 3).location != NSNotFound, let n = Int(lineNS.substring(with: m.range(at: 3))) {
                prefix += "\(n + 1). "
            } else {
                let marker = lineNS.substring(with: m.range(at: 2))
                prefix += (marker == "☐" || marker == "☑") ? "☐ " : marker + " "
            }
            tv.insertText("\n" + prefix, replacementRange: tv.selectedRange())
            return true
        }

        // MARK: slash commands
        private func maybeShowSlashMenu(_ tv: NSTextView) {
            let caret = tv.selectedRange().location
            let ns = tv.string as NSString
            guard caret > 0, caret <= ns.length,
                  ns.character(at: caret - 1) == UInt16(UnicodeScalar("/").value) else { return }
            if caret >= 2 {
                let prev = ns.character(at: caret - 2)
                guard prev == 32 || prev == 10 || prev == 9 else { return }
            }
            slashLocation = caret - 1

            let now = Date()
            let items: [(String, String, String)] = [
                ("Title", "textformat.size", "# "),
                ("Subtitle", "textformat", "## "),
                ("Bullet List", "list.bullet", "- "),
                ("To-do", "checklist", "☐ "),
                ("Numbered List", "list.number", "1. "),
                ("Date", "calendar", now.formatted(date: .abbreviated, time: .omitted) + " "),
                ("Time", "clock", now.formatted(date: .omitted, time: .shortened) + " "),
                ("Divider", "minus", "---\n"),
            ]
            let menu = NSMenu()
            for (title, symbol, snippet) in items {
                let mi = NSMenuItem(title: title, action: #selector(insertSnippet(_:)), keyEquivalent: "")
                mi.target = self
                mi.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                mi.representedObject = snippet
                menu.addItem(mi)
            }
            guard let win = tv.window else { return }
            let screenRect = tv.firstRect(forCharacterRange: NSRange(location: slashLocation!, length: 1), actualRange: nil)
            let local = tv.convert(win.convertFromScreen(screenRect), from: nil)
            menu.popUp(positioning: nil, at: NSPoint(x: local.minX, y: local.maxY), in: tv)
        }

        @objc private func insertSnippet(_ sender: NSMenuItem) {
            guard let tv = textView, let loc = slashLocation,
                  let snippet = sender.representedObject as? String,
                  loc < (tv.string as NSString).length else { return }
            tv.insertText(snippet, replacementRange: NSRange(location: loc, length: 1))
            slashLocation = nil
        }

        // MARK: highlight-to-actions mini toolbar
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            if tv.selectedRange().length == 0 {
                actionPopover.performClose(nil)
                return
            }
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(showActions), object: nil)
            perform(#selector(showActions), with: nil, afterDelay: 0.25)
        }

        @objc private func showActions() {
            guard let tv = textView, tv.selectedRange().length > 0,
                  NSEvent.pressedMouseButtons == 0,
                  let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            if actionPopover.contentViewController == nil {
                actionPopover.contentViewController = NSHostingController(rootView: ActionBar(coordinator: self))
                actionPopover.behavior = .transient
            }
            // pure view-space geometry — screen-space conversion put the bar far from the text
            let gr = lm.glyphRange(forCharacterRange: tv.selectedRange(), actualCharacterRange: nil)
            var rect = lm.boundingRect(forGlyphRange: gr, in: tc)
            rect.origin.x += tv.textContainerOrigin.x
            rect.origin.y += tv.textContainerOrigin.y
            guard rect.width > 0, rect.height > 0 else { return }
            actionPopover.show(relativeTo: rect, of: tv, preferredEdge: .maxY)
        }

        func wrap(_ mark: String) {
            guard let tv = textView else { return }
            let sel = tv.selectedRange()
            let s = (tv.string as NSString).substring(with: sel)
            tv.insertText(mark + s + mark, replacementRange: sel)
            actionPopover.performClose(nil)
        }

        func makeTodo() {
            guard let tv = textView else { return }
            let ns = tv.string as NSString
            let para = ns.paragraphRange(for: tv.selectedRange())
            let lines = ns.substring(with: para)
                .components(separatedBy: "\n")
                .map { $0.isEmpty || $0.hasPrefix("☐ ") ? $0 : "☐ " + $0 }
                .joined(separator: "\n")
            tv.insertText(lines, replacementRange: para)
            actionPopover.performClose(nil)
        }
    }
}

struct ActionBar: View {
    let coordinator: MarkdownTextView.Coordinator
    var body: some View {
        HStack(spacing: 12) {
            action("bold") { coordinator.wrap("**") }
            action("italic") { coordinator.wrap("*") }
            action("strikethrough") { coordinator.wrap("~~") }
            action("chevron.left.forwardslash.chevron.right") { coordinator.wrap("`") }
            action("checklist") { coordinator.makeTodo() }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    private func action(_ symbol: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) { Image(systemName: symbol).frame(width: 18, height: 16) }
            .buttonStyle(.borderless)
    }
}

/// Draws a full-width rule for `---` lines and a real checkbox for ☐/☑
/// (their text is set to clear; the character stays in the model for editing).
final class DividerLayoutManager: NSLayoutManager {
    var accent: NSColor = .controlAccentColor

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)

        storage.enumerateAttribute(dividerKey, in: charRange) { value, range, _ in
            guard value != nil else { return }
            let gr = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = boundingRect(forGlyphRange: gr, in: container)
            let y = rect.midY + origin.y
            let path = NSBezierPath()
            path.move(to: NSPoint(x: origin.x + 2, y: y))
            path.line(to: NSPoint(x: origin.x + container.size.width - 4, y: y))
            path.lineWidth = 1
            NSColor.separatorColor.setStroke()
            path.stroke()
        }

        storage.enumerateAttribute(checkboxKey, in: charRange) { value, range, _ in
            guard let checked = value as? Bool else { return }
            let gr = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = boundingRect(forGlyphRange: gr, in: container)
            rect.origin.x += origin.x; rect.origin.y += origin.y
            drawCheckbox(in: rect, checked: checked)
        }
    }

    private func drawCheckbox(in glyphRect: NSRect, checked: Bool) {
        let side = min(glyphRect.width, glyphRect.height) * 0.82
        let box = NSRect(x: glyphRect.minX, y: glyphRect.midY - side / 2, width: side, height: side)
        let path = NSBezierPath(roundedRect: box, xRadius: side * 0.28, yRadius: side * 0.28)
        if checked {
            accent.setFill(); path.fill()
            // y grows downward here (NSTextView is flipped): mid-left → bottom dip → top-right
            let c = NSBezierPath()
            c.move(to: NSPoint(x: box.minX + side * 0.24, y: box.minY + side * 0.48))
            c.line(to: NSPoint(x: box.minX + side * 0.42, y: box.minY + side * 0.68))
            c.line(to: NSPoint(x: box.minX + side * 0.76, y: box.minY + side * 0.30))
            c.lineWidth = max(1.4, side * 0.12)
            c.lineCapStyle = .round; c.lineJoinStyle = .round
            NSColor.white.setStroke(); c.stroke()
        } else {
            NSColor.tertiaryLabelColor.setStroke()
            path.lineWidth = 1.3; path.stroke()
        }
    }
}

/// NSTextView that toggles ☐/☑ on click.
final class SmartTextView: NSTextView {
    private static let checkboxRegex = try! NSRegularExpression(pattern: #"^(\s*)([☐☑]) "#)

    override func mouseDown(with event: NSEvent) {
        let ns = string as NSString
        if ns.length > 0 {
            let pt = convert(event.locationInWindow, from: nil)
            let idx = characterIndexForInsertion(at: pt)
            let lineR = ns.lineRange(for: NSRange(location: min(idx, ns.length - 1), length: 0))
            let line = ns.substring(with: lineR)
            if let m = Self.checkboxRegex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)),
               idx >= lineR.location, idx < lineR.location + m.range.length {
                let boxR = NSRange(location: lineR.location + m.range(at: 2).location, length: 1)
                let checked = ns.substring(with: boxR) == "☑"
                insertText(checked ? "☐" : "☑", replacementRange: boxR)
                // tactile confirmation on the same event that flips the box (causality)
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                return
            }
        }
        super.mouseDown(with: event)
    }
}
