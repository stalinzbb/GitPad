import SwiftUI
import AppKit

// MARK: - Root switcher

struct EditorView: View {
    @ObservedObject var store: NoteStore

    var body: some View {
        ZStack {
            GlassBackground()
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
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.85), value: store.screen)
        }
        .frame(minWidth: 280, minHeight: 180)
    }
}

/// Liquid glass on macOS 26+, vibrancy fallback below.
struct GlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            return NSGlassEffectView()
        }
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {}
}

// MARK: - Capture (just the editor)

struct CaptureView: View {
    @ObservedObject var store: NoteStore
    @AppStorage("fontDesign") private var fontDesign = "system"
    @AppStorage("editorFontSize") private var editorFontSize = 14.0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { store.onHide?() } label: { Image(systemName: "xmark") }
                    .help("Hide (Esc)")
                Text(store.selected.map { store.title(for: $0) } ?? "")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if !store.compact, let sel = store.selected {
                    Text(store.modified(sel), format: .dateTime.month(.abbreviated).day())
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Button { store.newNote() } label: { Image(systemName: "square.and.pencil") }
                    .help("New note (⌘N)")
                    .keyboardShortcut("n")
                Button { store.screen = .library } label: { Image(systemName: "square.grid.2x2") }
                    .help("Library (⌘L)")
                    .keyboardShortcut("l")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)

            MarkdownTextView(text: $store.text,
                             fontSize: store.compact ? 12 : CGFloat(editorFontSize),
                             design: fontDesign)
        }
        .background(
            Button("") { store.deleteCurrent() }
                .keyboardShortcut(.delete, modifiers: .command)
                .opacity(0)
        )
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var store: NoteStore
    @AppStorage("fontDesign") private var fontDesign = "system"
    @AppStorage("editorFontSize") private var editorFontSize = 14.0

    var body: some View {
        VStack(spacing: 20) {
            Text("Settings").font(.title3.weight(.semibold)).padding(.top, 18)
            Form {
                Picker("Font", selection: $fontDesign) {
                    Text("System").tag("system")
                    Text("Serif").tag("serif")
                    Text("Rounded").tag("rounded")
                    Text("Mono").tag("mono")
                }
                .pickerStyle(.segmented)
                HStack {
                    Slider(value: $editorFontSize, in: 11...20, step: 1) { Text("Size") }
                    Text("\(Int(editorFontSize)) pt").font(.caption).foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
            }
            .frame(maxWidth: 320)
            Text("Aa — The quick brown fox")
                .font(previewFont)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Done") { store.screen = .capture }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .padding(.bottom, 20)
        }
        .padding(.horizontal)
    }

    private var previewFont: Font {
        let d: Font.Design = fontDesign == "serif" ? .serif
            : fontDesign == "rounded" ? .rounded
            : fontDesign == "mono" ? .monospaced : .default
        return .system(size: CGFloat(editorFontSize), design: d)
    }
}

// MARK: - Library (full-panel switcher)

struct LibraryView: View {
    @ObservedObject var store: NoteStore
    @State private var query = ""
    @State private var folder: String? = nil   // nil = All
    @FocusState private var searchFocused: Bool

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
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .keyboardShortcut("l")
            }
            .buttonStyle(.borderless)
            .padding(12)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip("All", nil)
                    ForEach(store.folders, id: \.self) { chip($0, $0) }
                    Button { promptNewFolder() } label: {
                        Image(systemName: "folder.badge.plus").font(.caption)
                    }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("New folder")
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

    private func promptNewFolder() {
        let alert = NSAlert()
        alert.messageText = "New folder"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            store.createFolder(field.stringValue)
        }
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
        if context.coordinator.fontSize != fontSize || context.coordinator.design != design {
            context.coordinator.fontSize = fontSize
            context.coordinator.design = design
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
        private var slashLocation: Int?
        private let actionPopover = NSPopover()

        init(_ parent: MarkdownTextView) {
            self.parent = parent
            self.fontSize = parent.fontSize
            self.design = parent.design
        }

        // MARK: fonts
        static func baseFont(_ size: CGFloat, _ design: String) -> NSFont {
            let d: NSFontDescriptor.SystemDesign = design == "serif" ? .serif
                : design == "rounded" ? .rounded
                : design == "mono" ? .monospaced : .default
            let desc = NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(d)
            return desc.flatMap { NSFont(descriptor: $0, size: size) } ?? .systemFont(ofSize: size)
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

        private var cachedRules: (size: CGFloat, design: String,
                                  base: [NSAttributedString.Key: Any],
                                  rules: [(NSRegularExpression, [NSAttributedString.Key: Any])])?

        private func rules() -> (base: [NSAttributedString.Key: Any],
                                 rules: [(NSRegularExpression, [NSAttributedString.Key: Any])]) {
            if let c = cachedRules, c.size == fontSize, c.design == design { return (c.base, c.rules) }
            func re(_ p: String) -> NSRegularExpression {
                try! NSRegularExpression(pattern: p, options: [.anchorsMatchLines])
            }
            let f = Self.baseFont(fontSize, design)
            let base: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: NSColor.labelColor]
            let list: [(NSRegularExpression, [NSAttributedString.Key: Any])] = [
                (re(#"^#{1,3} .*$"#), [.font: Self.bold(Self.baseFont(fontSize + 4, design))]),
                // fade the hash marks so headers read as rendered titles
                (re(#"^#{1,3}(?= )"#), [.foregroundColor: NSColor.tertiaryLabelColor,
                                        .font: NSFont.systemFont(ofSize: fontSize - 3, weight: .light)]),
                (re(#"\*\*[^*\n]+\*\*"#), [.font: Self.bold(f)]),
                (re(#"(?<!\*)\*[^*\n]+\*(?!\*)"#), [.obliqueness: 0.15]),
                (re(#"~~[^~\n]+~~"#), [.strikethroughStyle: NSUnderlineStyle.single.rawValue]),
                (re(#"`[^`\n]+`"#), [.font: NSFont.monospacedSystemFont(ofSize: fontSize - 1, weight: .regular),
                                     .foregroundColor: NSColor.systemPurple]),
                (re(#"^\s*(?:[-*+] |\d+\. )"#), [.foregroundColor: NSColor.secondaryLabelColor]),
                (re(#"^\s*[☐☑]"#), [.foregroundColor: NSColor.controlAccentColor,
                                    .font: NSFont.systemFont(ofSize: fontSize + 1)]),
                (re(#"^\s*☑ .*$"#), [.foregroundColor: NSColor.secondaryLabelColor,
                                     .strikethroughStyle: NSUnderlineStyle.single.rawValue]),
                // dashes hidden; DividerLayoutManager draws a full-width rule instead
                (re(#"^-{3,}\s*$"#), [.foregroundColor: NSColor.clear, dividerKey: true]),
            ]
            cachedRules = (fontSize, design, base, list)
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
                  NSEvent.pressedMouseButtons == 0, let win = tv.window else { return }
            if actionPopover.contentViewController == nil {
                actionPopover.contentViewController = NSHostingController(rootView: ActionBar(coordinator: self))
                actionPopover.behavior = .transient
            }
            // anchor tightly to the selection's first line so the bar sits next to the text
            var sel = tv.selectedRange()
            let screenRect = tv.firstRect(forCharacterRange: sel, actualRange: &sel)
            var local = tv.convert(win.convertFromScreen(screenRect), from: nil)
            local = local.insetBy(dx: 0, dy: -2)
            guard local.width > 0 || local.height > 0 else { return }
            actionPopover.show(relativeTo: local, of: tv, preferredEdge: .maxY)
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
