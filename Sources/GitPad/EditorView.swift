import SwiftUI
import AppKit
import Carbon.HIToolbox // kVK_Escape for the hotkey recorder

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
            if !store.pill, store.paletteOpen, store.screen != .onboarding {
                CommandPalette(store: store)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(Motion.quick, value: store.lastDeleted?.original)
        .animation(Motion.quick, value: store.paletteOpen)
        .tint(theme.accentSwift) // buttons/toggles/sliders/selection take the theme accent
        // The one reactive design value. `.tint` can't carry it: it never reaches
        // `Color.accentColor`, which is why themed panels used to select in system blue.
        .environment(\.theme, theme)
        .overlay( // hairline edge; material below dims itself when the window loses key
            RoundedRectangle(cornerRadius: store.pill ? Radius.pill : Radius.panel, style: .continuous)
                .strokeBorder(Color.primary.opacity(Alpha.strokeFaint), lineWidth: 1)
                // match applyPill's curve, or the hairline snaps to its new radius while
                // the window is still growing
                .animation(Motion.pillFrame, value: store.pill)
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
            .floatingCard()
            .padding(.horizontal, 12).padding(.bottom, 12)
        }
        .task(id: store.lastDeleted?.original) { // restarts the timer for each new delete
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            store.lastDeleted = nil
        }
    }
}

/// One palette entry. A static array, not menu-derived: half these commands
/// (Sync Now, Set Up Sync, Reveal in Finder) live in the status menu or no menu at all.
/// `group` is the section header the row sits under, in array order.
struct PaletteCommand {
    let group: String
    let title: String
    let symbol: String
    var keys: String = ""
    let run: () -> Void
}

/// ⌘K: one field over every command plus note search, floating above whatever screen
/// is showing. Enter runs the highlighted row; Esc (or the scrim) closes.
struct CommandPalette: View {
    @ObservedObject var store: NoteStore
    @State private var query = ""
    @State private var index = 0
    /// Hover highlights, but never moves the keyboard selection. Letting it drive `index`
    /// is the usual palette bug: the pointer sits still, ↓ scrolls a different row under
    /// it, that row fires onHover and steals the selection back.
    @State private var hovered: Int?
    @State private var monitor: Any?
    @FocusState private var focused: Bool

    /// Commands index into `commands`; notes carry their URL.
    private enum Item {
        case cmd(Int)
        case note(URL)
    }

    private var commands: [PaletteCommand] {
        var c: [PaletteCommand] = [
            PaletteCommand(group: "Notes", title: "New Note",
                           symbol: ChromeGlyph.newNote, keys: "⌘N") { store.newNote() },
            PaletteCommand(group: "Notes", title: "Open Daily Note",
                           symbol: "calendar") { store.open(store.dailyNote()) },
            PaletteCommand(group: "Notes", title: "Append Clipboard to Daily",
                           symbol: "doc.on.clipboard") {
                guard let clip = NSPasteboard.general.string(forType: .string),
                      !clip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                store.open(store.dailyNote())
                store.appendToDaily(clip)
            },
            PaletteCommand(group: "Notes", title: "Delete Note",
                           symbol: "trash", keys: "⌘⌫") { store.deleteCurrent() },
        ]
        if store.lastDeleted != nil {
            c.append(PaletteCommand(group: "Notes", title: "Undo Delete",
                                    symbol: "arrow.uturn.backward") { store.undoDelete() })
        }
        c += [
            // ⌘L is a toggle, so name it for where it actually goes from here
            PaletteCommand(group: "Go", title: store.screen == .library ? "Back to Note" : "Library",
                           symbol: store.screen == .library ? ChromeGlyph.back : ChromeGlyph.library,
                           keys: "⌘L") { store.toggleLibrary() },
            PaletteCommand(group: "Go", title: "Search Library",
                           symbol: "magnifyingglass") { store.searchNotes() },
            PaletteCommand(group: "Go", title: "Settings",
                           symbol: ChromeGlyph.settings, keys: "⌘,") { store.openSettings() },
            PaletteCommand(group: "Go", title: "Reveal Notes in Finder", symbol: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([store.dir])
            },
            PaletteCommand(group: "Sync", title: "Save & Sync",
                           symbol: "square.and.arrow.down", keys: "⌘S") { store.saveNow() },
            PaletteCommand(group: "Sync", title: "Sync Now",
                           symbol: "arrow.clockwise") { store.requestSync?() },
            PaletteCommand(group: "Sync", title: "Set Up Sync",
                           symbol: "arrow.triangle.branch") { store.screen = .gitSetup },
            PaletteCommand(group: "Window", title: "Minimize to Pill",
                           symbol: ChromeGlyph.minimize, keys: "⌘M") { store.setPill?(true) },
        ]
        return c
    }

    /// Commands first, then notes. Notes reuse the Library's own ranking verbatim.
    private var items: [Item] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let cmds: [Int]
        if q.isEmpty {
            cmds = Array(commands.indices)
        } else {
            let tokens = NoteStore.fold(q).split(whereSeparator: \.isWhitespace).map(String.init)
            let all = commands
            cmds = all.indices.filter { i in
                let t = NoteStore.fold(all[i].title)
                return tokens.allSatisfy { t.contains($0) }
            }
        }
        let notes = q.isEmpty ? Array(store.notes.prefix(5)) : Array(store.matches(q).prefix(8))
        return cmds.map(Item.cmd) + notes.map(Item.note)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(Alpha.scrim)
                .onTapGesture { store.paletteOpen = false }
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "command").foregroundStyle(.secondary)
                    TextField("Run a command or find a note…", text: $query)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .onSubmit(runSelected)
                        .onExitCommand { store.paletteOpen = false } // beats PanelWindow.cancelOperation
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                SoftDivider()
                list
            }
            .floatingCard()
            .padding(.horizontal, 12).padding(.top, 44)
        }
        .onAppear {
            focused = true
            // The focused text field's field editor swallows ↑/↓, so `.onMoveCommand`
            // never fires. Same local-monitor trick as HotkeyRecorder, scoped to the
            // palette's lifetime — everything else passes straight through.
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                switch Int(event.keyCode) {
                case kVK_UpArrow: move(-1); return nil
                case kVK_DownArrow: move(1); return nil
                default: return event
                }
            }
        }
        .onDisappear {
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        }
        .onChange(of: query) { _ in index = 0 }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                let rows = items
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(rows.indices, id: \.self) { i in
                        separator(before: i, in: rows)
                        row(rows[i], i)
                    }
                }
                .padding(6)
                .background(LeanScrollbar()) // inside the content → enclosingScrollView hits
            }
            .frame(maxHeight: 380)
            // nil anchor = scroll the minimum to reveal the row. `.center` re-centred on
            // every keypress, so the first ↓ yanked the whole list down to centre row 1.
            .onChange(of: index) { proxy.scrollTo($0) }
        }
    }

    /// What goes above a row when its group changes: a hairline between command groups
    /// (they're self-evident — labelling four of them just adds furniture), and a real
    /// header for the notes, which do need saying. Emitted inline so `index` keeps
    /// addressing selectable rows only.
    @ViewBuilder private func separator(before i: Int, in rows: [Item]) -> some View {
        let isNote: Bool = { if case .note = rows[i] { return true }; return false }()
        if i == 0 || group(rows[i]) != group(rows[i - 1]) {
            if isNote {
                SectionLabel(text: group(rows[i]))
                    .padding(.horizontal, 8)
                    .padding(.top, i == 0 ? 2 : 9).padding(.bottom, 3)
            } else if i > 0 {
                // an explicit hairline: Divider at 0.4 all but vanished on the material.
                // -6 cancels the list's own inset so it runs edge to edge of the card.
                Rectangle().fill(Color.primary.opacity(Alpha.cardDivider))
                    .frame(height: 1)
                    .padding(.horizontal, -6).padding(.vertical, 8)
            }
        }
    }

    private func row(_ item: Item, _ i: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol(item))
                .font(Fonts.chromeGlyph) // same glyph weight as the chrome
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text(label(item)).font(.callout).lineLimit(1)
            Spacer(minLength: 8)
            if case .cmd(let c) = item, !commands[c].keys.isEmpty {
                Chip(text: commands[c].keys)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        // hover is its own, lighter state — it deliberately does NOT move `index`
        // (see the note on `hovered`), so the two can show at once
        .rowBackground(selected: i == index, hovering: hovered == i)
        .onHover { inside in
            if inside { hovered = i } else if hovered == i { hovered = nil }
        }
        .animation(Motion.quick, value: hovered)
        .onTapGesture { run(item) }
        .id(i)
    }

    private func label(_ item: Item) -> String {
        switch item {
        case .cmd(let i): return commands[i].title
        case .note(let url): return store.title(for: url)
        }
    }

    private func symbol(_ item: Item) -> String {
        switch item {
        case .cmd(let i): return commands[i].symbol
        case .note: return "doc.text"
        }
    }

    private func group(_ item: Item) -> String {
        switch item {
        case .cmd(let i): return commands[i].group
        case .note: return query.trimmingCharacters(in: .whitespaces).isEmpty ? "Recent" : "Matches"
        }
    }

    private func move(_ delta: Int) {
        let count = items.count
        guard count > 0 else { return }
        index = min(max(0, index + delta), count - 1)
    }

    private func runSelected() {
        let rows = items
        guard rows.indices.contains(index) else { return }
        run(rows[index])
    }

    private func run(_ item: Item) {
        store.paletteOpen = false
        switch item {
        case .cmd(let i): commands[i].run()
        case .note(let url): store.open(url)
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
                if showSyncDot { SyncDot(status: store.syncStatus) }
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

/// Collapsed UI: a lozenge. Double-click the body to expand (or ⌥Space, or one click on
/// the expand glyph); drag it to move — mirroring the header, where a double-click and the
/// minimize glyph both collapse. One DragGesture serves body-tap and drag: a near-zero move
/// on release is a tap, and two taps inside the system double-click interval expand. That
/// can't live in `PanelWindow.mouseDown` like the header's does — the pill's gesture covers
/// the whole window and swallows the event first. A single tap only arms, so there's no delay.
struct PillView: View {
    @ObservedObject var store: NoteStore
    @State private var lastTap = Date.distantPast
    @State private var expandHover = false

    var body: some View {
        HStack(spacing: 8) {
            SyncDot(status: store.syncStatus)
            Text(store.selected.map { store.title(for: $0) } ?? "GitPad")
                .font(.footnote.weight(.medium)).lineLimit(1)
            Spacer(minLength: 0)
            // A real control, not just a hint: ONE click expands, the way the header's
            // minimize glyph collapses in one. highPriorityGesture so it beats the
            // pill-wide drag below, which would otherwise demand a double-click here too.
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.caption2).foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(expandHover ? Color.iconHoverBg : .clear,
                            in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
                .contentShape(Rectangle())
                .onHover { expandHover = $0 }
                .animation(Motion.quick, value: expandHover)
                .highPriorityGesture(TapGesture().onEnded { store.setPill?(false) })
                .help("Expand")
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in store.pillDrag?() }
                .onEnded { _ in
                    // moved? that was a reposition, and it never counts toward a double-click
                    guard store.pillDragEnded?() != true else { lastTap = .distantPast; return }
                    let now = Date()
                    if now.timeIntervalSince(lastTap) <= NSEvent.doubleClickInterval {
                        lastTap = .distantPast // consume, so a third click doesn't re-trigger
                        store.setPill?(false)
                    } else {
                        lastTap = now // first click just arms the second
                    }
                }
        )
        .help("Double-click to expand (\(Hotkey.display))")
    }
}

// MARK: - Capture (just the editor)

struct CaptureView: View {
    @ObservedObject var store: NoteStore
    @AppStorage("fontDesign") private var fontDesign = "system"
    @AppStorage("editorFontSize") private var editorFontSize = 14.0
    @Environment(\.theme) private var theme
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
                             theme: theme)

            bottomBar
        }
        // ⌘N/⌘L/⌘S/⌘⌫/⌘M/⌘, are handled by the main-menu "Note" submenu in AppDelegate,
        // so they work from every screen — not just here.
    }

    /// Pin / move / delete without a round-trip to the Library's ⋯ menu, plus a live word
    /// count. Editor screen only — the Library already has all three on every row.
    /// The header is deliberately untouched: nothing moved out of it, it stays 42pt.
    private var bottomBar: some View {
        VStack(spacing: 0) {
            SoftDivider()
            HStack(spacing: 2) {
                Text("\(wordCount) words")
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.leading, 6)
                Spacer(minLength: 0)
                if let sel = store.selected {
                    ChromeIcon(symbol: store.isPinned(sel) ? "pin.fill" : "pin",
                               help: store.isPinned(sel) ? "Unpin" : "Pin") { store.togglePin(sel) }
                    Menu {
                        Button("Notes") { store.move(sel, to: nil) }
                        ForEach(store.folders, id: \.self) { f in
                            Button(f) { store.move(sel, to: f) }
                        }
                    } label: {
                        Image(systemName: "folder")
                            .iconSlot()
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .foregroundStyle(.secondary)
                    .help("Move to folder")
                    ChromeIcon(symbol: "trash", help: "Delete (⌘⌫)") { store.deleteCurrent() }
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 2)
        }
    }

    private var wordCount: Int {
        store.text.split(whereSeparator: \.isWhitespace).count
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
    @State private var shownRemote = "" // what we last populated `remote` with — detects user edits
    @State private var aheadBehind: (ahead: Int, behind: Int)?

    /// Local state, deliberately NOT new `Screen` cases: those would multiply the
    /// `goBack()` / settingsReturn branches for nothing. Esc and ⌘, keep working as-is;
    /// the tab just resets to General after a Setup-guide round trip.
    enum Tab: String, CaseIterable {
        case general = "General", appearance = "Appearance", shortcuts = "Shortcuts", sync = "Sync"
    }
    @State private var tab: Tab = .general

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

            Picker("Section", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12).padding(.bottom, 4)

            Form {
                switch tab {
                case .general:
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
                            .background(Color.quietFill, in: Capsule())
                        }
                    }
                    Text("The quick brown fox jumps over the lazy dog.")
                        .font(Font(MarkdownTextView.Coordinator.baseFont(CGFloat(editorFontSize), fontDesign) as CTFont))
                        .foregroundStyle(.secondary)
                }
                Section {
                    Button(role: .destructive) {
                        NSApp.terminate(nil)
                    } label: {
                        Label("Quit GitPad", systemImage: "power")
                    }
                } footer: {
                    Text("Also ⌘Q from any screen, or the menu-bar icon.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                case .appearance:
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
                } footer: {
                    Text("Changes apply immediately — there's no Save button.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                case .shortcuts:
                Section("Global Hotkey") {
                    HotkeyRecorder()
                }
                ShortcutsList()

                case .sync:
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
                            SyncDot(status: store.syncStatus)
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
                        .listRowBackground(Color.statusWarn.opacity(Alpha.iconHover))
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
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(LeanScrollbar())
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
                // Track the real remote while the field is untouched, so the doctor
                // switching to HTTPS doesn't leave a stale SSH URL sitting here for
                // Save/Return to write straight back. Mid-edit text is never clobbered.
                if remote == shownRemote { remote = url }
                shownRemote = url
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
            .background(LeanScrollbar())
            .background(Color.primary.opacity(Alpha.inset),
                        in: RoundedRectangle(cornerRadius: Radius.control))
        }
    }
}

/// Every binding, read-only (the global hotkey above it is the one rebindable thing).
/// A static table on purpose: half of these — Tab indent, Enter list-continue, the slash
/// menu, click-to-toggle — exist in no menu at all, so nothing to derive from.
/// Keep in sync with the Note menu, GitPadApp.swift:135-152.
struct ShortcutsList: View {
    private static let panel = [
        ("New note", "⌘N"), ("Library", "⌘L"), ("Command palette", "⌘K"),
        ("Save & sync", "⌘S"), ("Delete note", "⌘⌫"), ("Minimize to pill", "⌘M"),
        ("Settings", "⌘,"), ("Quit GitPad", "⌘Q"), ("Back one level / close", "Esc"),
    ]
    private static let editing = [
        ("Undo", "⌘Z"), ("Redo", "⇧⌘Z"), ("Cut", "⌘X"),
        ("Copy", "⌘C"), ("Paste", "⌘V"), ("Select all", "⌘A"),
    ]
    private static let behaviors = [
        ("Indent / outdent list item", "⇥ / ⇧⇥"), ("Continue the list", "↩"),
        ("Snippet menu", "/"), ("Toggle a checkbox", "Click ☐"),
        ("Minimize to pill", "Double-click header"),
    ]

    var body: some View {
        Group {
            Section("Panel") { rows(Self.panel) }
            Section("Editing") { rows(Self.editing) }
            Section("Editor") { rows(Self.behaviors) }
        }
    }

    private func rows(_ items: [(String, String)]) -> some View {
        ForEach(items, id: \.0) { label, keys in
            LabeledContent(label) { Chip(text: keys) }
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
                        .background(Color.primary.opacity(recording ? Alpha.strokeStrong : Alpha.hover),
                                    in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                            .strokeBorder(Color.primary.opacity(Alpha.strokeStrong)))
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
    @State private var newFolderHover = false
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
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Color.quietFill,
                        in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 8) // breathe below the chrome bar
            SoftDivider()

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
                        SectionLabel(text: "Folders") // matches the note-list section headers
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
            .background(LeanScrollbar())

            SoftDivider()
            if creatingFolder {
                TextField("Folder name", text: $newFolderName)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($folderFieldFocused)
                    // 16 = the rail's 6pt gutter + a row's 10pt inset, so the caret
                    // lines up with the folder names above it
                    .padding(.horizontal, 16).padding(.vertical, 6)
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
                    // same geometry and hover pill as a folder row, so it reads as one list
                    Label("New Folder", systemImage: "folder.badge.plus")
                        .font(.callout).lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: railSlot, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .rowBackground(hovering: newFolderHover)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 6)
                .onHover { newFolderHover = $0 }
                .animation(Motion.quick, value: newFolderHover)
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
                .frame(maxWidth: .infinity, minHeight: railSlot, alignment: .leading) // match folder-row height
                .padding(.horizontal, 10).padding(.vertical, 3)
                .rowBackground(selected: source == s)
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
                            SectionLabel(text: name)
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .background(LeanScrollbar())
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

/// One height for every sidebar row: 22pt of content + 3pt above and below ≈ 28pt.
/// Shared so the rail's sources, folders and New Folder can't drift apart.
private let railSlot: CGFloat = 22

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
            // count and ⋯ share ONE fixed slot, so nothing resizes on hover.
            // (No .fixedSize(): that re-measured on the menu's own hover highlight and
            // fed the twitch back into row layout.)
            Group {
                if hovering {
                    Menu {
                        Button("Rename…", action: rename)
                        Button("Delete Folder", role: .destructive, action: delete)
                    } label: {
                        Image(systemName: "ellipsis")
                            .rotationEffect(.degrees(90)) // vertical ⋮ (no single SF symbol for it)
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: railSlot, height: railSlot)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .tint(.secondary) // borderlessButton tints its label with accent; force it to match the chrome
                    .foregroundStyle(.secondary)
                } else {
                    Text("\(count)").font(.callout).foregroundStyle(.secondary)
                }
            }
            .frame(width: railSlot, height: railSlot)
        }
        .padding(.horizontal, 10).padding(.vertical, 3)
        .rowBackground(selected: selected, hovering: hovering)
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
                Chip(text: "Daily", font: .caption2)
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
                    .iconSlot() // constant slot; no .fixedSize() remeasure
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering) // hidden ⋯ must not eat taps meant for the row
        }
        .padding(.vertical, 5).padding(.horizontal, 6)
        .rowBackground(hovering: hovering)
        .onTapGesture { store.open(url) }
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }
}

// MARK: - Smart markdown editor

private let dividerKey = NSAttributedString.Key("gitpadDivider")
private let checkboxKey = NSAttributedString.Key("gitpadCheckbox") // value: Bool (checked)
private let markerKey = NSAttributedString.Key("gitpadListMarker") // value: String (display marker)

/// Drawn checkbox size and the fixed layout advance the ☐/☑ character occupies, derived
/// from the body font. ☐/☑ aren't in SF Pro — fallback fonts (☑ often gets the emoji
/// font!) have wildly different advances and line metrics, which shifted the text and line
/// height between the unchecked, typed, and checked states. The glyph is laid out at 0.1pt
/// with a kern of exactly `checkboxAdvance`, so both states occupy identical space and the
/// drawn box is the single source of truth. The advance exceeds the box side by a gap so
/// the label doesn't crowd the box (the space character alone was too tight).
private func checkboxSide(_ f: NSFont) -> CGFloat { (f.capHeight * 1.45).rounded() }
private func checkboxAdvance(_ f: NSFont) -> CGFloat { checkboxSide(f) + (f.pointSize * 0.3).rounded() }

/// Pure list logic: parsing, renumbering, and display markers. Disk stays CommonMark
/// (`- ` bullets, `1. 2. 3.` ordinals at every depth); letters/romans and •/◦/▪ are
/// display-layer only, drawn by DividerLayoutManager over cleared text.
enum ListLogic {
    /// 1=indent  2=bullet/checkbox  3=number  4=content
    static let listRegex = try! NSRegularExpression(
        pattern: #"^(\s*)(?:([-*+☐☑]) |(\d+)\. )(.*)$"#)

    static func match(_ line: String) -> NSTextCheckingResult? {
        listRegex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))
    }

    static func letterLabel(_ n: Int) -> String { // 1 → a, 27 → aa
        var n = n, s = ""
        while n > 0 { n -= 1; s = String(UnicodeScalar(UInt8(97 + n % 26))) + s; n /= 26 }
        return s
    }

    static func romanLabel(_ n: Int) -> String {
        guard n > 0 else { return "\(n)" }
        let pairs: [(Int, String)] = [(1000, "m"), (900, "cm"), (500, "d"), (400, "cd"),
                                      (100, "c"), (90, "xc"), (50, "l"), (40, "xl"),
                                      (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")]
        var n = n, s = ""
        for (v, r) in pairs { while n >= v { s += r; n -= v } }
        return s
    }

    /// Ordered: 1. → a. → i. by depth; bullets: • → ◦ → ▪ (cycling every 3 levels).
    static func displayMarker(number: Int?, depth: Int) -> String {
        if let n = number {
            switch depth % 3 {
            case 1: return letterLabel(n) + "."
            case 2: return romanLabel(n) + "."
            default: return "\(n)."
            }
        }
        switch depth % 3 {
        case 1: return "◦"
        case 2: return "▪"
        default: return "•"
        }
    }

    /// Rewrites ordinals so every ordered run counts 1, 2, 3… per depth. A non-list
    /// line breaks all runs; a bullet/checkbox breaks the run at its own depth;
    /// dedenting past a depth resets the deeper counters.
    static func renumber(_ lines: [String]) -> [String] {
        var counters: [Int: Int] = [:] // depth → last ordinal
        return lines.map { line in
            guard let m = match(line) else { counters.removeAll(); return line }
            let ns = line as NSString
            let depth = ns.substring(with: m.range(at: 1)).count / 2
            counters = counters.filter { $0.key <= depth }
            guard m.range(at: 3).location != NSNotFound else {
                counters[depth] = 0
                return line
            }
            let n = (counters[depth] ?? 0) + 1
            counters[depth] = n
            let numR = m.range(at: 3)
            return ns.substring(with: numR) == "\(n)" ? line : ns.replacingCharacters(in: numR, with: "\(n)")
        }
    }
}

struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat = 14
    var design: String = "system"
    var theme: Theme = Theme.named("System")

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
        tv.textContainerInset = EditorMetrics.inset // room to breathe, like a real notes app
        tv.defaultParagraphStyle = Coordinator.paragraphStyle
        tv.drawsBackground = false
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isAutomaticDashSubstitutionEnabled = false // keep "---" as typed → divider
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        // Highlight only — no .foregroundColor. AppKit's default recolors selected glyphs,
        // which un-hides the `.clear` backing markers ("2." showing under the drawn "b.").
        // Keeping stored colors is also what Notes/Xcode do.
        tv.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor]
        tv.delegate = context.coordinator
        storage.delegate = context.coordinator
        context.coordinator.textView = tv

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.verticalScroller = LeanScroller()
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? SmartTextView, let storage = tv.textStorage else { return }
        context.coordinator.parent = self
        if context.coordinator.fontSize != fontSize || context.coordinator.design != design
            || context.coordinator.themeID != theme.id {
            context.coordinator.fontSize = fontSize
            context.coordinator.design = design
            // string compare, not the whole Theme: this guard is what keeps a stray
            // updateNSView from re-highlighting the entire document
            context.coordinator.themeID = theme.id
            tv.font = Coordinator.baseFont(fontSize, design)
            context.coordinator.highlight(storage, range: NSRange(location: 0, length: storage.length))
        }
        if tv.string != text {
            tv.string = text
            // Wholesale replacement — every queued undo action points at ranges in the
            // document that just went away. Only fires on external changes (typing keeps the
            // binding equal via textDidChange), so nothing undoable is lost.
            tv.undoManager?.removeAllActions()
            if text == "# " { // fresh note: caret after the title marker, keyboard ready to type
                tv.setSelectedRange(NSRange(location: 2, length: 0))
                DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
            }
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
            p.lineHeightMultiple = EditorMetrics.lineHeightMultiple
            p.paragraphSpacing = EditorMetrics.paragraphSpacing
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
            // Deferred on purpose: layout-affecting attribute edits (kern, fonts) made
            // synchronously inside didProcessEditing leave stale glyph advances on the
            // initial full-document pass, and renumbering mutates text — illegal here.
            // Typed characters don't flash meanwhile because typingAttributes are set
            // explicitly (refreshTypingAttributes).
            guard editedMask.contains(.editedCharacters) else { return }
            let loc = min(editedRange.location, storage.length)
            let safe = NSRange(location: loc, length: min(editedRange.length, storage.length - loc))
            let para = (storage.string as NSString).paragraphRange(for: safe)
            // Must be read HERE: isUndoing is only true while undo executes, and by the time
            // the async block runs it's false again — so the deferred renumber would register
            // a *new* top-level undo group (redo stack cleared, next ⌘Z undoes the renumber).
            // highlight() below still runs: attribute-only, registers nothing, and undone text
            // needs restyling.
            let um = self.textView?.undoManager
            let isUndoRedo = (um?.isUndoing ?? false) || (um?.isRedoing ?? false)
            DispatchQueue.main.async { [weak self, weak storage] in
                guard let self, let storage else { return }
                var range = para
                if let tv = self.textView, !isUndoRedo, !self.isRenumbering, !tv.hasMarkedText() {
                    self.isRenumbering = true
                    self.renumberListBlock(tv, around: para.location)
                    self.isRenumbering = false
                    // renumbering may have shifted lengths; re-clamp, keeping the full span —
                    // an Enter edit covers TWO paragraphs (split line + new line), and collapsing
                    // to one left the new line unstyled (raw "2."/"☐") until the next keystroke
                    let ns = storage.string as NSString
                    let loc = min(para.location, ns.length)
                    let len = min(para.length, ns.length - loc)
                    range = ns.paragraphRange(for: NSRange(location: loc, length: len))
                }
                self.highlight(storage, range: range)
            }
        }

        private var isRenumbering = false

        /// One pass over the contiguous list block around the edit — covers Enter, Tab,
        /// Backspace, paste, and undo without per-command bookkeeping. Only ordinals that
        /// actually differ are rewritten; the changed lines re-highlight via their own
        /// didProcessEditing round (a fixpoint: the second pass changes nothing).
        private func renumberListBlock(_ tv: NSTextView, around loc: Int) {
            guard let storage = tv.textStorage else { return }
            let ns = tv.string as NSString
            guard ns.length > 0 else { return }
            let anchor = ns.paragraphRange(for: NSRange(location: min(loc, ns.length), length: 0))
            func isList(_ r: NSRange) -> Bool {
                ListLogic.match(ns.substring(with: r)) != nil
            }
            var start = anchor.location
            while start > 0 {
                let prev = ns.paragraphRange(for: NSRange(location: start - 1, length: 0))
                guard isList(prev) else { break }
                start = prev.location
            }
            var end = anchor.location + anchor.length
            while end < ns.length {
                let next = ns.paragraphRange(for: NSRange(location: end, length: 0))
                guard isList(next) else { break }
                end = next.location + next.length
            }
            let block = NSRange(location: start, length: end - start)
            guard block.length > 0 else { return }

            var lineRanges: [NSRange] = []
            var lines: [String] = []
            ns.enumerateSubstrings(in: block, options: [.byParagraphs]) { sub, subR, _, _ in
                lineRanges.append(subR)
                lines.append(sub ?? "")
            }
            let fixed = ListLogic.renumber(lines)
            var edits: [(NSRange, String)] = [] // number subrange in storage coords → new digits
            for (i, new) in fixed.enumerated() where new != lines[i] {
                guard let m = ListLogic.match(lines[i]), m.range(at: 3).location != NSNotFound,
                      let f = ListLogic.match(new), f.range(at: 3).location != NSNotFound else { continue }
                let numR = NSRange(location: lineRanges[i].location + m.range(at: 3).location,
                                   length: m.range(at: 3).length)
                edits.append((numR, (new as NSString).substring(with: f.range(at: 3))))
            }
            guard !edits.isEmpty else { return }

            let sel = tv.selectedRange()
            var delta = 0
            for (r, s) in edits.reversed() { // back-to-front keeps earlier offsets valid
                guard tv.shouldChangeText(in: r, replacementString: s) else { continue }
                storage.replaceCharacters(in: r, with: s)
                tv.didChangeText()
                if r.location < sel.location { delta += (s as NSString).length - r.length }
            }
            tv.setSelectedRange(NSRange(location: max(0, sel.location + delta), length: sel.length))
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
            let tinyFont = NSFont.systemFont(ofSize: 0.1)
            func checkKern(_ glyph: String) -> CGFloat {
                checkboxAdvance(f) - (glyph as NSString).size(withAttributes: [.font: tinyFont]).width
            }
            // headings get air above them; body spacing stays at the shared style's 6pt.
            // minimumLineHeight floors the line at the heading font's height — the hidden
            // "#{1,3} " marker is 0.1pt, so an empty "# " line (every fresh note) would
            // otherwise collapse to a ~2pt fragment with an invisible caret.
            func headingStyle(_ before: CGFloat, _ hFont: NSFont) -> NSParagraphStyle {
                let p = Self.paragraphStyle.mutableCopy() as! NSMutableParagraphStyle
                p.paragraphSpacingBefore = before
                p.minimumLineHeight = (NSLayoutManager().defaultLineHeight(for: hFont)
                    * EditorMetrics.lineHeightMultiple).rounded()
                return p
            }
            // typographic scale: H1 ≈ 1.6×, H2 ≈ 1.3×, H3 ≈ 1.15× body
            let (o1, o2, o3) = EditorMetrics.headingOffsets
            let (b1, b2, b3) = EditorMetrics.headingSpaceBefore
            let h1 = Self.bold(Self.baseFont(fontSize + o1, design))
            let h2 = Self.bold(Self.baseFont(fontSize + o2, design))
            let h3 = Self.bold(Self.baseFont(fontSize + o3, design))
            let list: [(NSRegularExpression, [NSAttributedString.Key: Any])] = [
                (re(#"^# .*$"#), [.font: h1, .paragraphStyle: headingStyle(b1, h1)]),
                (re(#"^## .*$"#), [.font: h2, .paragraphStyle: headingStyle(b2, h2)]),
                (re(#"^### .*$"#), [.font: h3, .paragraphStyle: headingStyle(b3, h3)]),
                // hide the hash marks entirely so headers read as rendered titles
                // (no lookahead: a bare "# " collapses immediately, so the line never
                // jumps left when the first title character lands)
                (re(#"^#{1,3} "#), [.foregroundColor: NSColor.clear,
                                    .font: NSFont.systemFont(ofSize: 0.1)]),
                (re(#"\*\*[^*\n]+\*\*"#), [.font: Self.bold(f)]),
                (re(#"(?<!\*)\*[^*\n]+\*(?!\*)"#), [.obliqueness: 0.15]),
                (re(#"~~[^~\n]+~~"#), [.strikethroughStyle: NSUnderlineStyle.single.rawValue]),
                (re(#"`[^`\n]+`"#), [.font: NSFont.monospacedSystemFont(
                                        ofSize: fontSize + EditorMetrics.codeSizeDelta, weight: .regular),
                                     .foregroundColor: theme.code]),
                // strike/dim only the text after a checked box (fixed 2-char lookbehind)
                (re(#"(?<=☑ ).*$"#), [.foregroundColor: NSColor.secondaryLabelColor,
                                      .strikethroughStyle: NSUnderlineStyle.single.rawValue]),
                // hide the raw glyph AND neutralize its fallback-font layout: 0.1pt font +
                // a kern that pins the advance to the drawn box width, so ☐ and ☑ occupy
                // identical space (no text shift or line-height jump on toggle/typing)
                (re(#"☐"#), [.foregroundColor: NSColor.clear, .font: tinyFont,
                             .kern: checkKern("☐"), checkboxKey: false]),
                (re(#"☑"#), [.foregroundColor: NSColor.clear, .font: tinyFont,
                             .kern: checkKern("☑"), checkboxKey: true]),
                // dashes hidden; DividerLayoutManager draws a full-width rule instead
                (re(#"^\s*[-—]{3,}\s*$"#), [.foregroundColor: NSColor.clear, dividerKey: true]),
            ]
            cachedRules = (fontSize, design, themeID, base, list)
            listStyleCache.removeAll()
            prefixWidthCache.removeAll()
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
            applyListLayout(storage, in: range)
            storage.endEditing()
            if let tv = textView { refreshTypingAttributes(tv) }
        }

        // MARK: list layout — hanging indents + display markers
        private var listStyleCache: [String: NSParagraphStyle] = [:]
        private var prefixWidthCache: [String: CGFloat] = [:]

        /// Per list paragraph: a hanging indent so wrapped lines align under the content
        /// (not the margin), a real per-depth visual indent (2 literal spaces alone are
        /// ~7pt — invisible), and a display marker (• ◦ ▪ / 1. a. i.) drawn by the layout
        /// manager over the cleared source marker. Disk text is untouched.
        private func applyListLayout(_ storage: NSTextStorage, in range: NSRange) {
            let ns = storage.string as NSString
            let font = Self.baseFont(fontSize, design)
            let unit = (fontSize * EditorMetrics.indentUnitFactor).rounded() // extra indent per nest level
            ns.enumerateSubstrings(in: range, options: [.byParagraphs]) { sub, subR, _, _ in
                guard let line = sub, let m = ListLogic.match(line) else { return }
                let lineNS = line as NSString
                let depth = lineNS.substring(with: m.range(at: 1)).count / 2
                let prefix = lineNS.substring(to: m.range(at: 4).location) // indent + marker + " "

                let width: CGFloat
                if let w = self.prefixWidthCache[prefix] { width = w } else {
                    let marker = m.range(at: 2).location != NSNotFound
                        ? lineNS.substring(with: m.range(at: 2)) : ""
                    if marker == "☐" || marker == "☑" {
                        // the glyph's layout advance is pinned to checkboxAdvance, not its
                        // fallback-font width — measure the rest and add the pinned advance
                        let rest = lineNS.substring(with: m.range(at: 1)) + " "
                        width = (rest as NSString).size(withAttributes: [.font: font]).width
                            + checkboxAdvance(font)
                    } else {
                        width = (prefix as NSString).size(withAttributes: [.font: font]).width
                    }
                    self.prefixWidthCache[prefix] = width
                }
                let key = "\(depth)|\(width)"
                let style: NSParagraphStyle
                if let s = self.listStyleCache[key] { style = s } else {
                    let p = NSMutableParagraphStyle()
                    p.lineHeightMultiple = EditorMetrics.lineHeightMultiple
                    // tighter inside lists; same for bullets and numbers
                    p.paragraphSpacing = EditorMetrics.listParagraphSpacing
                    p.firstLineHeadIndent = CGFloat(depth) * unit
                    p.headIndent = p.firstLineHeadIndent + width // wrap under the content
                    self.listStyleCache[key] = p
                    style = p
                }
                storage.addAttribute(.paragraphStyle, value: style, range: subR)

                // bullets and numbers get a drawn display marker; checkboxes are drawn already
                let bulletR = m.range(at: 2)
                let numberR = m.range(at: 3)
                if numberR.location != NSNotFound {
                    let n = Int(lineNS.substring(with: numberR)) ?? 0
                    let markerR = NSRange(location: subR.location + numberR.location,
                                          length: numberR.length + 1) // digits + "."
                    storage.addAttributes([.foregroundColor: NSColor.clear,
                                           markerKey: ListLogic.displayMarker(number: n, depth: depth)],
                                          range: markerR)
                } else if bulletR.location != NSNotFound {
                    let marker = lineNS.substring(with: bulletR)
                    if marker != "☐" && marker != "☑" {
                        let markerR = NSRange(location: subR.location + bulletR.location, length: bulletR.length)
                        storage.addAttributes([.foregroundColor: NSColor.clear,
                                               markerKey: ListLogic.displayMarker(number: nil, depth: depth)],
                                              range: markerR)
                    }
                }
            }
        }

        /// NSTextView derives typingAttributes from the character before the caret — right
        /// after a hidden marker that's clear + 0.1pt, so the first character typed was
        /// invisible for a frame. Set them explicitly from the paragraph context instead.
        func refreshTypingAttributes(_ tv: NSTextView) {
            let (base, _) = rules()
            var attrs = base
            let ns = tv.string as NSString
            let caret = min(tv.selectedRange().location, ns.length)
            let line = ns.substring(with: ns.lineRange(for: NSRange(location: caret, length: 0)))
            let (o1, o2, o3) = EditorMetrics.headingOffsets
            if line.hasPrefix("# ") { attrs[.font] = Self.bold(Self.baseFont(fontSize + o1, design)) }
            else if line.hasPrefix("## ") { attrs[.font] = Self.bold(Self.baseFont(fontSize + o2, design)) }
            else if line.hasPrefix("### ") { attrs[.font] = Self.bold(Self.baseFont(fontSize + o3, design)) }
            tv.typingAttributes = attrs
        }

        // MARK: auto list continuation
        func textView(_ tv: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) { return continueList(tv) }
            if selector == #selector(NSResponder.insertTab(_:)) { return indentList(tv, out: false) }
            if selector == #selector(NSResponder.insertBacktab(_:)) { return indentList(tv, out: true) }
            if selector == #selector(NSResponder.deleteBackward(_:)) { return smartDeleteBackward(tv) }
            return false
        }

        /// Replace `r` with `s` through the undo-aware channel, WITHOUT the caret-moves-to-
        /// end-of-insertion behavior of insertText(_:replacementRange:).
        private func replaceText(_ tv: NSTextView, _ r: NSRange, _ s: String) -> Bool {
            guard tv.shouldChangeText(in: r, replacementString: s), let storage = tv.textStorage else { return false }
            storage.replaceCharacters(in: r, with: s)
            tv.didChangeText()
            return true
        }

        /// Tab / Shift-Tab nest list items by two spaces per level. Caret and selection are
        /// preserved (mapped through the edits), so repeated Tab on a block works. Markdown
        /// nests via leading whitespace and `to/fromMarkdown` preserves it. Tab never emits
        /// a literal \t — that's an indented code block in Markdown on disk.
        private func indentList(_ tv: NSTextView, out: Bool) -> Bool {
            let ns = tv.string as NSString
            let sel = tv.selectedRange()
            var scan = sel
            if scan.length > 0, ns.lineRange(for: NSRange(location: scan.location + scan.length, length: 0))
                .location == scan.location + scan.length {
                scan.length -= 1 // selection ends exactly at a line start → don't drag that line in
            }
            let span = ns.lineRange(for: scan)
            var starts: [Int] = [] // line starts that are list items (span may be one empty line)
            var i = span.location
            repeat {
                let lr = ns.lineRange(for: NSRange(location: i, length: 0))
                if ListLogic.match(ns.substring(with: lr)) != nil { starts.append(lr.location) }
                i = lr.location + lr.length
            } while i < span.location + span.length
            if starts.isEmpty {
                guard !out else { return true } // shift-tab outside a list: no-op
                tv.insertText("  ", replacementRange: sel) // plain tab → two spaces
                return true
            }

            // No explicit undo group: groupsByEvent already opened one for this Tab press, so
            // nesting here pushed an empty group whenever every replaceText skipped — and an
            // empty group silently swallows one ⌘Z.
            var edits: [(Int, Int)] = [] // (line start, char delta)
            for start in starts.sorted(by: >) { // back-to-front keeps earlier offsets valid
                if !out {
                    if replaceText(tv, NSRange(location: start, length: 0), "  ") { edits.append((start, 2)) }
                } else if start < ns.length, ns.substring(with: NSRange(location: start, length: 1)) == "\t" {
                    if replaceText(tv, NSRange(location: start, length: 1), "") { edits.append((start, -1)) }
                } else {
                    var n = 0 // strip up to two leading spaces
                    while n < 2, start + n < ns.length,
                          ns.substring(with: NSRange(location: start + n, length: 1)) == " " { n += 1 }
                    if n > 0, replaceText(tv, NSRange(location: start, length: n), "") { edits.append((start, -n)) }
                }
            }

            var mapped = sel // map the original selection through the edits
            for (loc, d) in edits {
                if loc <= mapped.location { mapped.location = max(mapped.location + d, loc) }
                else if loc < mapped.location + mapped.length { mapped.length = max(mapped.length + d, 0) }
            }
            tv.setSelectedRange(mapped)
            return true
        }

        private func continueList(_ tv: NSTextView) -> Bool {
            let ns = tv.string as NSString
            let caret = tv.selectedRange().location
            let lineR = ns.lineRange(for: NSRange(location: min(caret, ns.length), length: 0))
            let upToCaret = ns.substring(with: NSRange(location: lineR.location, length: caret - lineR.location))
            let lineNS = upToCaret as NSString
            guard let m = ListLogic.match(upToCaret) else { return false }
            let content = lineNS.substring(with: m.range(at: 4))
            if content.isEmpty {
                let indent = lineNS.substring(with: m.range(at: 1))
                if indent.count >= 2 { // nested empty item: outdent one level, keep the marker
                    if replaceText(tv, NSRange(location: lineR.location, length: 2), "") {
                        tv.setSelectedRange(NSRange(location: caret - 2, length: 0))
                    }
                } else { // top level: exit the list
                    tv.insertText("", replacementRange: NSRange(location: lineR.location, length: caret - lineR.location))
                }
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

        static let headingPrefix = try! NSRegularExpression(pattern: #"^#{1,3} "#)

        /// Backspace with the caret right after a list or heading marker removes the whole
        /// marker in one go (Notes-style) — a title drops back to plain text instead of
        /// leaving a stray "#", and a stripped ☐ never lingers invisibly.
        private func smartDeleteBackward(_ tv: NSTextView) -> Bool {
            let sel = tv.selectedRange()
            guard sel.length == 0, sel.location > 0 else { return false }
            let ns = tv.string as NSString
            let lineR = ns.lineRange(for: NSRange(location: min(sel.location, ns.length), length: 0))
            let line = ns.substring(with: lineR)
            if let h = Self.headingPrefix.firstMatch(in: line,
                    range: NSRange(location: 0, length: (line as NSString).length)),
               sel.location == lineR.location + h.range.length {
                let r = NSRange(location: lineR.location, length: h.range.length)
                if replaceText(tv, r, "") { tv.setSelectedRange(NSRange(location: lineR.location, length: 0)) }
                return true
            }
            guard let m = ListLogic.match(line) else { return false }
            let contentStart = lineR.location + m.range(at: 4).location
            guard sel.location == contentStart else { return false }
            let markerLoc = m.range(at: 2).location != NSNotFound ? m.range(at: 2).location
                                                                  : m.range(at: 3).location
            let r = NSRange(location: lineR.location + markerLoc,
                            length: m.range(at: 4).location - markerLoc)
            if replaceText(tv, r, "") { tv.setSelectedRange(NSRange(location: r.location, length: 0)) }
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
            refreshTypingAttributes(tv)
            if tv.selectedRange().length == 0 {
                actionPopover.performClose(nil)
                return
            }
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(showActions), object: nil)
            perform(#selector(showActions), with: nil, afterDelay: 0.25)
        }

        @objc private func showActions() {
            guard let tv = textView, tv.window != nil, tv.selectedRange().length > 0,
                  tv.window?.firstResponder === tv, // no bar while the ⌘K palette holds focus
                  NSEvent.pressedMouseButtons == 0,
                  let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            if actionPopover.contentViewController == nil {
                // Built once and kept. Nothing here reads \.theme today; anything added that
                // does would need re-injecting on theme change, since this host never updates.
                actionPopover.contentViewController = NSHostingController(rootView: ActionBar(coordinator: self))
                actionPopover.behavior = .transient
            }
            // pure view-space geometry — screen-space conversion put the bar far from the text
            let gr = lm.glyphRange(forCharacterRange: tv.selectedRange(), actualCharacterRange: nil)
            var rect = lm.boundingRect(forGlyphRange: gr, in: tc)
            rect.origin.x += tv.textContainerOrigin.x
            rect.origin.y += tv.textContainerOrigin.y
            guard rect.width > 0, rect.height > 0 else { return }
            // .maxY renders the bar ABOVE the selection — fine low in the window, but for
            // text near the top it juts outside the borderless panel. Flip to below when
            // the selection sits in the upper half of the visible viewport.
            let below = rect.midY < tv.visibleRect.midY // flipped coords: smaller y = higher
            actionPopover.show(relativeTo: rect, of: tv, preferredEdge: below ? .minY : .maxY)
        }

        /// Toggle, not just wrap: the mark comes off text that already carries it, so a
        /// second tap on Bold un-bolds instead of producing `****text****`. The selection
        /// survives either way (kept on the plain text) so taps keep toggling.
        /// ponytail: `*` on a `**x**` selection strips one pair — bold becomes italic
        /// rather than nesting. Nesting the same family is the rarer intent.
        func wrap(_ mark: String) {
            guard let tv = textView else { return }
            let ns = tv.string as NSString
            let sel = tv.selectedRange()
            let s = ns.substring(with: sel)
            let n = (mark as NSString).length

            if sel.length >= 2 * n, s.hasPrefix(mark), s.hasSuffix(mark) { // marks inside the selection
                let inner = (s as NSString).substring(with: NSRange(location: n, length: sel.length - 2 * n))
                if replaceText(tv, sel, inner) {
                    tv.setSelectedRange(NSRange(location: sel.location, length: sel.length - 2 * n))
                }
            } else if sel.location >= n, sel.location + sel.length + n <= ns.length, // marks around it
                      ns.substring(with: NSRange(location: sel.location - n, length: n)) == mark,
                      ns.substring(with: NSRange(location: sel.location + sel.length, length: n)) == mark {
                let wide = NSRange(location: sel.location - n, length: sel.length + 2 * n)
                if replaceText(tv, wide, s) {
                    tv.setSelectedRange(NSRange(location: wide.location, length: sel.length))
                }
            } else if replaceText(tv, sel, mark + s + mark) {
                tv.setSelectedRange(NSRange(location: sel.location + n, length: sel.length))
            }
            actionPopover.performClose(nil)
        }

        func makeTodo() { makeList("☐ ") }

        /// Convert the selected paragraphs to a `prefix` list. Every line already in that
        /// marker family → strip back to plain text, so the button toggles. `"1. "` inserts
        /// the literal prefix and lets the deferred renumber pass fix the ordinals.
        func makeList(_ prefix: String) {
            guard let tv = textView else { return }
            let ns = tv.string as NSString
            let para = ns.paragraphRange(for: tv.selectedRange())
            let lines = ns.substring(with: para).components(separatedBy: "\n")
            let filled = lines.filter { !$0.isEmpty }
            let strip = !filled.isEmpty && filled.allSatisfy { Self.inFamily($0, prefix) }

            let out = lines.map { line -> String in
                guard !line.isEmpty else { return line }
                let (indent, body) = Self.split(line)
                guard !Self.inFamily(line, prefix) else {
                    // already ours: strip it, or leave it alone so ☑ keeps its check
                    return strip ? indent + body : line
                }
                // an existing marker of another family converts in place (was: "☐ - foo")
                return indent + prefix + body
            }.joined(separator: "\n")

            if replaceText(tv, para, out) {
                tv.setSelectedRange(NSRange(location: para.location, length: (out as NSString).length))
            }
            actionPopover.performClose(nil)
        }

        /// Set a heading on every selected line; the same level again clears it.
        /// One `replaceText` over the whole paragraph range → one undo step, no grouping.
        func setHeading(_ level: Int) {
            guard let tv = textView else { return }
            let ns = tv.string as NSString
            let para = ns.paragraphRange(for: tv.selectedRange())
            let want = String(repeating: "#", count: level) + " "
            let lines = ns.substring(with: para).components(separatedBy: "\n")
            let filled = lines.filter { !$0.isEmpty }
            let strip = !filled.isEmpty && filled.allSatisfy { $0.hasPrefix(want) }

            let out = lines.map { line -> String in
                guard !line.isEmpty else { return line }
                let lns = line as NSString
                var plain = line
                if let h = Self.headingPrefix.firstMatch(in: line,
                        range: NSRange(location: 0, length: lns.length)) {
                    plain = lns.substring(from: h.range.length)
                }
                return strip ? plain : want + plain
            }.joined(separator: "\n")

            if replaceText(tv, para, out) {
                tv.setSelectedRange(NSRange(location: para.location, length: (out as NSString).length))
            }
            actionPopover.performClose(nil)
        }

        /// `[selection](url)`. A URL sitting on the clipboard fills the target — otherwise the
        /// parens are left empty with the caret inside them, ready to type.
        func insertLink() {
            guard let tv = textView else { return }
            let sel = tv.selectedRange()
            let s = (tv.string as NSString).substring(with: sel)
            let clip = (NSPasteboard.general.string(forType: .string) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let url = (clip.hasPrefix("http://") || clip.hasPrefix("https://")) ? clip : ""
            if replaceText(tv, sel, "[\(s)](\(url))") {
                let caret = sel.location + (s as NSString).length + 3 + (url as NSString).length
                tv.setSelectedRange(NSRange(location: caret, length: 0)) // before the ")"
            }
            actionPopover.performClose(nil)
        }

        /// (leading whitespace, text after any list marker) — so a line converts in place
        /// between families instead of stacking markers.
        static func split(_ line: String) -> (indent: String, body: String) {
            guard let m = ListLogic.match(line) else { return ("", line) }
            let ns = line as NSString
            return (ns.substring(with: m.range(at: 1)), ns.substring(with: m.range(at: 4)))
        }

        /// Is the line already this prefix's marker family? ☐ and ☑ are one family (so
        /// converting to to-dos never unchecks anything), and any ordinal counts as "1. ".
        static func inFamily(_ line: String, _ prefix: String) -> Bool {
            guard let m = ListLogic.match(line) else { return false }
            if prefix == "1. " { return m.range(at: 3).location != NSNotFound }
            guard m.range(at: 2).location != NSNotFound else { return false }
            let bullet = (line as NSString).substring(with: m.range(at: 2))
            if prefix == "☐ " { return bullet == "☐" || bullet == "☑" }
            return bullet == String(prefix.dropLast())
        }
    }
}

/// The selection bar: inline marks | headings | list conversions | link.
/// Lives in its own NSHostingController (the popover's), so it inherits nothing from
/// EditorView's view tree — including the `.tint` that themes every other control.
struct ActionBar: View {
    let coordinator: MarkdownTextView.Coordinator

    /// ChromeIcon, not bespoke buttons: it already carries the house hover background,
    /// glyph size/weight and tooltip, so the selection menu matches every other control.
    /// Headings reuse the slash menu's own Title/Subtitle glyphs — same action reached two
    /// ways shouldn't wear two icons — and the dividers group marks / headings / lists.
    var body: some View {
        HStack(spacing: 2) {
            ChromeIcon(symbol: "bold", help: "Bold") { coordinator.wrap("**") }
            ChromeIcon(symbol: "italic", help: "Italic") { coordinator.wrap("*") }
            ChromeIcon(symbol: "strikethrough", help: "Strikethrough") { coordinator.wrap("~~") }
            ChromeIcon(symbol: "chevron.left.forwardslash.chevron.right",
                       help: "Inline code") { coordinator.wrap("`") }
            rule
            ChromeIcon(symbol: "textformat.size", help: "Title") { coordinator.setHeading(1) }
            ChromeIcon(symbol: "textformat", help: "Subtitle") { coordinator.setHeading(2) }
            rule
            ChromeIcon(symbol: "list.bullet", help: "Bullet list") { coordinator.makeList("- ") }
            ChromeIcon(symbol: "list.number", help: "Numbered list") { coordinator.makeList("1. ") }
            ChromeIcon(symbol: "checklist", help: "Checklist") { coordinator.makeTodo() }
            rule
            ChromeIcon(symbol: "link", help: "Link") { coordinator.insertLink() }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
    }

    private var rule: some View { Divider().frame(height: 14) }
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
            // Size from the text's cap height and sit the box ON the baseline, not on the
            // line-fragment's midY — the fragment is inflated by lineHeightMultiple, so the
            // old boundingRect box floated and drifted with font/size.
            // the glyph itself is 0.1pt; size the box from the body text right after it,
            // matching the kerned advance the glyph was pinned to (see checkboxAdvance)
            var font = (storage.attribute(.font, at: min(range.location + 1, storage.length - 1),
                                          effectiveRange: nil) as? NSFont)
                ?? .systemFont(ofSize: NSFont.systemFontSize)
            if font.pointSize < 1 { font = .systemFont(ofSize: NSFont.systemFontSize) }
            let frag = lineFragmentRect(forGlyphAt: gr.location, effectiveRange: nil)
            let loc = location(forGlyphAt: gr.location) // glyph offset within its fragment
            let baselineY = frag.minY + loc.y + origin.y
            let side = checkboxSide(font)
            // flipped space: smaller y is higher. The box is taller than the cap height, so
            // center it on the cap band — it dips slightly below the baseline like a native
            // checkbox instead of towering above the text.
            // frag.minX + loc.x is the glyph's left edge → indented checkboxes stay aligned.
            let box = NSRect(x: frag.minX + loc.x + origin.x,
                             y: baselineY - side + ((side - font.capHeight) / 2).rounded(),
                             width: side, height: side)
            drawCheckbox(in: box, checked: checked)
        }

        storage.enumerateAttribute(markerKey, in: charRange) { value, range, _ in
            guard let display = value as? String else { return }
            let gr = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let font = (storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
                ?? .systemFont(ofSize: NSFont.systemFontSize)
            let frag = lineFragmentRect(forGlyphAt: gr.location, effectiveRange: nil)
            let loc = location(forGlyphAt: gr.location)
            // right-align to the source marker's trailing edge so the content start (and
            // caret positions) never move: "iii." may be wider than "3." — it grows left.
            var trailingX = loc.x
            let next = gr.location + gr.length // the space after the marker, same line
            if next < numberOfGlyphs {
                trailingX = location(forGlyphAt: next).x
            }
            let attrs: [NSAttributedString.Key: Any] = [.font: font,
                                                        .foregroundColor: NSColor.secondaryLabelColor]
            let str = display as NSString
            let w = str.size(withAttributes: attrs).width
            // draw(at:) takes the glyph-box top-left in this flipped view
            str.draw(at: NSPoint(x: frag.minX + trailingX - w + origin.x,
                                 y: frag.minY + loc.y - font.ascender + origin.y),
                     withAttributes: attrs)
        }
    }

    private func drawCheckbox(in box: NSRect, checked: Bool) {
        let side = box.width
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
            // lighter, thinner outline — the box should recede until it's ticked
            NSColor.quaternaryLabelColor.setStroke()
            path.lineWidth = 1.1; path.stroke()
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
            // hit zone is the glyph itself, not the whole indented prefix — clicks on the
            // indentation or at the content start place the caret / start a drag as normal
            if let m = Self.checkboxRegex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)),
               case let boxStart = lineR.location + m.range(at: 2).location,
               idx >= boxStart, idx <= boxStart + 1 {
                let boxR = NSRange(location: boxStart, length: 1)
                let checked = ns.substring(with: boxR) == "☑"
                insertText(checked ? "☐" : "☑", replacementRange: boxR)
                // tactile confirmation on the same event that flips the box (causality)
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                return
            }
            // a click landing inside a hidden heading marker (it's ~0pt wide at the line's
            // left edge) snaps the caret to the title text instead of before the "#"
            if let h = MarkdownTextView.Coordinator.headingPrefix.firstMatch(in: line,
                    range: NSRange(location: 0, length: (line as NSString).length)),
               idx >= lineR.location, idx < lineR.location + h.range.length {
                setSelectedRange(NSRange(location: lineR.location + h.range.length, length: 0))
                window?.makeFirstResponder(self)
                return
            }
        }
        super.mouseDown(with: event)
    }
}
