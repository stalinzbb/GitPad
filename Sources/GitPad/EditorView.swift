import SwiftUI
import AppKit

// MARK: - Themes (token set consumed by the editor + chrome)

struct Theme: Identifiable {
    let id: String
    let accent: NSColor   // checkboxes, chips, interactive tint
    let code: NSColor     // inline code
    let wash: Color?      // translucent tint over the material background

    static let all: [Theme] = [
        Theme(id: "System", accent: .controlAccentColor, code: .systemPurple, wash: nil),
        Theme(id: "Sepia", accent: NSColor(red: 0.72, green: 0.53, blue: 0.29, alpha: 1),
              code: NSColor(red: 0.60, green: 0.42, blue: 0.20, alpha: 1),
              wash: Color(red: 0.96, green: 0.91, blue: 0.81).opacity(0.35)),
        Theme(id: "Nord", accent: NSColor(red: 0.53, green: 0.75, blue: 0.82, alpha: 1),
              code: NSColor(red: 0.64, green: 0.75, blue: 0.55, alpha: 1),
              wash: Color(red: 0.18, green: 0.20, blue: 0.25).opacity(0.5)),
        Theme(id: "Dracula", accent: NSColor(red: 0.74, green: 0.58, blue: 0.98, alpha: 1),
              code: NSColor(red: 0.31, green: 0.90, blue: 0.48, alpha: 1),
              wash: Color(red: 0.16, green: 0.16, blue: 0.21).opacity(0.55)),
        Theme(id: "Solarized", accent: NSColor(red: 0.15, green: 0.55, blue: 0.82, alpha: 1),
              code: NSColor(red: 0.52, green: 0.60, blue: 0.00, alpha: 1),
              wash: Color(red: 0.99, green: 0.96, blue: 0.89).opacity(0.30)),
    ]

    static func named(_ id: String) -> Theme { all.first { $0.id == id } ?? all[0] }
}

// MARK: - Root switcher

struct EditorView: View {
    @ObservedObject var store: NoteStore
    @AppStorage("theme") private var themeID = "System"

    var body: some View {
        ZStack {
            GlassBackground()
            if let wash = Theme.named(themeID).wash {
                Rectangle().fill(wash).allowsHitTesting(false)
            }
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
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.85), value: store.screen)
        }
        .overlay( // hairline edge; material below dims itself when the window loses key
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .frame(minWidth: 280, minHeight: 180)
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

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // centered title + context, above the button rows
                VStack(spacing: 1) {
                    Text(store.selected.map { store.title(for: $0) } ?? "")
                        .font(.footnote.weight(.medium)).lineLimit(1)
                    if !store.compact, let sel = store.selected {
                        Text(subtitle(for: sel))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: 180)
                .allowsHitTesting(false)
                HStack(spacing: 10) {
                    Button { store.onHide?() } label: { Image(systemName: "xmark") }
                        .help("Hide (Esc)")
                    Circle()
                        .fill(syncDot)
                        .frame(width: 6, height: 6)
                        .help(store.syncStatus.label)
                    Spacer()
                    Button { store.newNote() } label: { Image(systemName: "square.and.pencil") }
                        .help("New note (⌘N)")
                        .keyboardShortcut("n")
                    Button { store.screen = .library } label: { Image(systemName: "square.grid.2x2") }
                        .help("Library (⌘L)")
                        .keyboardShortcut("l")
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)

            MarkdownTextView(text: $store.text,
                             fontSize: store.compact ? 12 : CGFloat(editorFontSize),
                             design: fontDesign,
                             themeID: themeID)
        }
        .background(Group {
            Button("") { store.deleteCurrent() }
                .keyboardShortcut(.delete, modifiers: .command)
            Button("") { store.saveNow() } // saveNow fires onSaved → git commit & push
                .keyboardShortcut("s")
        }.opacity(0))
    }

    private func subtitle(for sel: URL) -> String {
        let date = store.modified(sel).formatted(.dateTime.month(.abbreviated).day())
        if let f = store.folder(of: sel) { return "\(f) · \(date)" }
        return date
    }

    private var syncDot: Color {
        switch store.syncStatus {
        case .synced: return .green
        case .offline: return .orange
        default: return .secondary.opacity(0.4)
        }
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
            ZStack {
                Text("Settings").font(.headline)
                HStack {
                    Button { store.screen = .library } label: {
                        Image(systemName: "chevron.left").foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.borderless)
            .padding(12)

            Form {
                Section("Editor") {
                    Picker("Font", selection: $fontDesign) {
                        ForEach(Self.fonts, id: \.0) { tag, label in
                            Text(label).tag(tag)
                        }
                    }
                    HStack {
                        Slider(value: $editorFontSize, in: 11...20, step: 1) { Text("Size") }
                        Text("\(Int(editorFontSize)) pt")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }
                    Text("The quick brown fox jumps over the lazy dog.")
                        .font(Font(MarkdownTextView.Coordinator.baseFont(CGFloat(editorFontSize), fontDesign) as CTFont))
                        .foregroundStyle(.secondary)
                }
                Section("Sync") {
                    Button {
                        store.screen = .gitSetup
                    } label: {
                        Label("Set up sync — step-by-step guide", systemImage: "sparkles")
                    }
                    HStack {
                        TextField("git@github.com:you/notes.git", text: $remote)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { saveRemote() }
                        Button("Save") { saveRemote() }
                            .disabled(remote.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    LabeledContent("Status") {
                        HStack(spacing: 6) {
                            Circle().fill(statusColor).frame(width: 7, height: 7)
                            Text(store.syncStatus.label)
                            if let ab = aheadBehind, ab.ahead + ab.behind > 0 {
                                Text("↑\(ab.ahead) ↓\(ab.behind)").foregroundStyle(.tertiary)
                            }
                        }
                        .font(.callout).foregroundStyle(.secondary)
                    }
                    Button("Sync Now") {
                        store.requestSync?()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { refreshGitInfo() }
                    }
                }
                if !store.conflicts.isEmpty {
                    Section("Conflicts — both machines edited the same note") {
                        ForEach(store.conflicts, id: \.self) { copy in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(store.title(for: copy)).lineLimit(1)
                                HStack(spacing: 10) {
                                    Button("Compare") { store.open(copy) }
                                    Button("Use This Version") { store.resolveKeep(copy) }
                                    Button("Discard") { store.resolveDiscard(copy) }
                                        .foregroundStyle(.red)
                                }
                                .font(.caption)
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                Section("Appearance") {
                    Picker("Theme", selection: $themeID) {
                        ForEach(Theme.all) { Text($0.id).tag($0.id) }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .onAppear { refreshGitInfo() }
    }

    private var statusColor: Color {
        switch store.syncStatus {
        case .synced: return .green
        case .offline: return .orange
        default: return .secondary
        }
    }

    private func saveRemote() {
        GitSync.setRemote(remote.trimmingCharacters(in: .whitespacesAndNewlines), in: store.dir)
        store.requestSync?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { refreshGitInfo() }
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

// MARK: - Library (full-panel switcher)

struct LibraryView: View {
    @ObservedObject var store: NoteStore
    @State private var query = ""
    @State private var folder: String? = nil   // nil = All
    @State private var creatingFolder = false
    @State private var newFolderName = ""
    @FocusState private var searchFocused: Bool
    @FocusState private var folderFieldFocused: Bool

    private var filtered: [URL] {
        store.matches(query).filter { folder == nil || store.folder(of: $0) == folder }
    }

    private var groups: [(String, [URL])] {
        let cal = Calendar.current
        let weekAgo = Date().addingTimeInterval(-7 * 86400)
        let m = filtered
        return [
            ("Today", m.filter { cal.isDateInToday(store.modified($0)) }),
            ("This Week", m.filter { !cal.isDateInToday(store.modified($0)) && store.modified($0) > weekAgo }),
            ("Earlier", m.filter { store.modified($0) <= weekAgo }),
        ].filter { !$1.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search notes…", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { if let first = filtered.first { store.open(first) } }
                Button { store.screen = .settings } label: {
                    Image(systemName: "gearshape").foregroundStyle(.secondary)
                }
                Button { store.screen = .capture } label: {
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                }
                .help("Back to note (⌘L)")
                .keyboardShortcut("l")
            }
            .buttonStyle(.borderless)
            .padding(12)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip("All", nil)
                    ForEach(store.folders, id: \.self) { chip($0, $0) }
                    if creatingFolder {
                        TextField("Name", text: $newFolderName)
                            .textFieldStyle(.plain)
                            .font(.caption)
                            .frame(width: 80)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.1), in: Capsule())
                            .focused($folderFieldFocused)
                            .onSubmit {
                                store.createFolder(newFolderName)
                                newFolderName = ""
                                creatingFolder = false
                            }
                            .onExitCommand { creatingFolder = false }
                    } else {
                        Button {
                            creatingFolder = true
                            folderFieldFocused = true
                        } label: {
                            Image(systemName: "folder.badge.plus").font(.caption)
                        }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .help("New folder")
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 8)
            }
            Divider().opacity(0.4)

            List {
                ForEach(groups, id: \.0) { name, urls in
                    Section {
                        ForEach(urls, id: \.self) { url in
                            NoteRow(store: store, url: url)
                        }
                    } header: {
                        Text(name).font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
        .onAppear { searchFocused = true }
    }

    @ViewBuilder private func chip(_ label: String, _ value: String?) -> some View {
        Button {
            folder = value
        } label: {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(folder == value ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1),
                            in: Capsule())
        }
        .buttonStyle(.plain)
    }

}

struct NoteRow: View {
    @ObservedObject var store: NoteStore
    let url: URL
    @State private var hovering = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.title(for: url)).lineLimit(1)
                HStack(spacing: 4) {
                    if let f = store.folder(of: url) {
                        Text(f).font(.caption2).foregroundStyle(.tertiary)
                        Text("·").font(.caption2).foregroundStyle(.tertiary)
                    }
                    Text(store.modified(url), format: .relative(presentation: .named))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Menu {
                Button("Open") { store.open(url) }
                Menu("Move to") {
                    Button("Notes") { store.move(url, to: nil) }
                    ForEach(store.folders, id: \.self) { f in
                        Button(f) { store.move(url, to: f) }
                    }
                }
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
        .contentShape(Rectangle())
        .onTapGesture { store.open(url) }
        .onHover { hovering = $0 }
    }
}

// MARK: - Smart markdown editor

private let dividerKey = NSAttributedString.Key("gitpadDivider")

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
        tv.textContainerInset = NSSize(width: 12, height: 8)
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
            let base: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: NSColor.labelColor]
            let list: [(NSRegularExpression, [NSAttributedString.Key: Any])] = [
                (re(#"^#{1,3} .*$"#), [.font: Self.bold(Self.baseFont(fontSize + 4, design))]),
                // hide the hash marks entirely so headers read as rendered titles
                (re(#"^#{1,3} (?=\S)"#), [.foregroundColor: NSColor.clear,
                                          .font: NSFont.systemFont(ofSize: 0.1)]),
                (re(#"\*\*[^*\n]+\*\*"#), [.font: Self.bold(f)]),
                (re(#"(?<!\*)\*[^*\n]+\*(?!\*)"#), [.obliqueness: 0.15]),
                (re(#"~~[^~\n]+~~"#), [.strikethroughStyle: NSUnderlineStyle.single.rawValue]),
                (re(#"`[^`\n]+`"#), [.font: NSFont.monospacedSystemFont(ofSize: fontSize - 1, weight: .regular),
                                     .foregroundColor: theme.code]),
                (re(#"^\s*(?:[-*+] |\d+\. )"#), [.foregroundColor: NSColor.secondaryLabelColor]),
                (re(#"^\s*[☐☑]"#), [.foregroundColor: theme.accent,
                                    .font: NSFont.systemFont(ofSize: fontSize + 1)]),
                (re(#"^\s*☑ .*$"#), [.foregroundColor: NSColor.secondaryLabelColor,
                                     .strikethroughStyle: NSUnderlineStyle.single.rawValue]),
                // dashes hidden; DividerLayoutManager draws a full-width rule instead
                (re(#"^\s*[-—]{3,}\s*$"#), [.foregroundColor: NSColor.clear, dividerKey: true]),
            ]
            cachedRules = (fontSize, design, themeID, base, list)
            return (base, list)
        }

        func highlight(_ storage: NSTextStorage, range: NSRange) {
            guard range.location + range.length <= storage.length else { return }
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

/// Draws a full-width rule for `---` lines (their text is set to clear).
final class DividerLayoutManager: NSLayoutManager {
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
                return
            }
        }
        super.mouseDown(with: event)
    }
}
