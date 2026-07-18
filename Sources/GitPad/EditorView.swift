import SwiftUI
import AppKit

// MARK: - Root switcher

struct EditorView: View {
    @ObservedObject var store: NoteStore

    var body: some View {
        ZStack {
            VisualEffect()
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
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.85), value: store.screen)
        }
        .frame(minWidth: 280, minHeight: 180)
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

// MARK: - Capture (just the editor)

struct CaptureView: View {
    @ObservedObject var store: NoteStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
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

            MarkdownTextView(text: $store.text, fontSize: store.compact ? 12 : 14)
        }
        .background(
            Button("") { store.deleteCurrent() }
                .keyboardShortcut(.delete, modifiers: .command)
                .opacity(0)
        )
    }
}

// MARK: - Library (full-panel switcher)

struct LibraryView: View {
    @ObservedObject var store: NoteStore
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var groups: [(String, [URL])] {
        let cal = Calendar.current
        let weekAgo = Date().addingTimeInterval(-7 * 86400)
        let m = store.matches(query)
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
                    .onSubmit { if let first = store.matches(query).first { store.open(first) } }
                Button { store.screen = .capture } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("l")
            }
            .padding(12)
            Divider().opacity(0.4)
            List {
                ForEach(groups, id: \.0) { name, urls in
                    Section {
                        ForEach(urls, id: \.self) { url in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(store.title(for: url)).lineLimit(1)
                                    Text(store.modified(url), format: .relative(presentation: .named))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { store.open(url) }
                            .contextMenu { Button("Delete") { store.delete(url) } }
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
}

// MARK: - Smart markdown editor

struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat = 14

    func makeNSView(context: Context) -> NSScrollView {
        let tv = SmartTextView()
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = .systemFont(ofSize: fontSize)
        tv.textContainerInset = NSSize(width: 12, height: 8)
        tv.drawsBackground = false
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.delegate = context.coordinator
        tv.textStorage?.delegate = context.coordinator
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
        if context.coordinator.fontSize != fontSize {
            context.coordinator.fontSize = fontSize
            tv.font = .systemFont(ofSize: fontSize)
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
        private var slashLocation: Int?
        private let actionPopover = NSPopover()

        init(_ parent: MarkdownTextView) { self.parent = parent }

        // MARK: text change → binding + slash menu
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            maybeShowSlashMenu(tv)
        }

        // MARK: paragraph-scoped highlighting (full pass only on load)
        func textStorage(_ storage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                         range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            let safe = NSRange(location: min(editedRange.location, storage.length),
                               length: min(editedRange.length, storage.length - min(editedRange.location, storage.length)))
            let para = (storage.string as NSString).paragraphRange(for: safe)
            DispatchQueue.main.async { [weak self, weak storage] in
                guard let self, let storage else { return }
                self.highlight(storage, range: para)
            }
        }

        private var cachedRules: (size: CGFloat,
                                  base: [NSAttributedString.Key: Any],
                                  rules: [(NSRegularExpression, [NSAttributedString.Key: Any])])?

        private func rules(_ size: CGFloat) -> (base: [NSAttributedString.Key: Any],
                                                rules: [(NSRegularExpression, [NSAttributedString.Key: Any])]) {
            if let c = cachedRules, c.size == size { return (c.base, c.rules) }
            func re(_ p: String) -> NSRegularExpression {
                try! NSRegularExpression(pattern: p, options: [.anchorsMatchLines])
            }
            let base: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.labelColor]
            let list: [(NSRegularExpression, [NSAttributedString.Key: Any])] = [
                (re(#"^#{1,3} .*$"#), [.font: NSFont.boldSystemFont(ofSize: size + 3)]),
                (re(#"\*\*[^*\n]+\*\*"#), [.font: NSFont.boldSystemFont(ofSize: size)]),
                (re(#"(?<!\*)\*[^*\n]+\*(?!\*)"#), [.obliqueness: 0.15]),
                (re(#"`[^`\n]+`"#), [.font: NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular),
                                     .foregroundColor: NSColor.systemPurple]),
                (re(#"^\s*(?:[-*+](?: \[[ x]\])? |\d+\. )"#), [.foregroundColor: NSColor.secondaryLabelColor]),
                (re(#"^\s*[-*+] \[x\] .*$"#), [.foregroundColor: NSColor.secondaryLabelColor,
                                               .strikethroughStyle: NSUnderlineStyle.single.rawValue]),
            ]
            cachedRules = (size, base, list)
            return (base, list)
        }

        func highlight(_ storage: NSTextStorage, range: NSRange) {
            guard range.location + range.length <= storage.length else { return }
            let (base, list) = rules(fontSize)
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
            pattern: #"^(\s*)(?:([-*+]) (\[[ x]\] )?|(\d+)\. )(.*)$"#)

        private func continueList(_ tv: NSTextView) -> Bool {
            let ns = tv.string as NSString
            let caret = tv.selectedRange().location
            let lineR = ns.lineRange(for: NSRange(location: min(caret, ns.length), length: 0))
            let upToCaret = ns.substring(with: NSRange(location: lineR.location, length: caret - lineR.location))
            let lineNS = upToCaret as NSString
            guard let m = Self.listRegex.firstMatch(in: upToCaret,
                    range: NSRange(location: 0, length: lineNS.length)) else { return false }
            let content = lineNS.substring(with: m.range(at: 5))
            if content.isEmpty {
                // Return on an empty list item ends the list
                tv.insertText("", replacementRange: NSRange(location: lineR.location, length: caret - lineR.location))
                return true
            }
            var prefix = lineNS.substring(with: m.range(at: 1))
            if m.range(at: 4).location != NSNotFound, let n = Int(lineNS.substring(with: m.range(at: 4))) {
                prefix += "\(n + 1). "
            } else {
                prefix += lineNS.substring(with: m.range(at: 2)) + " "
                if m.range(at: 3).location != NSNotFound { prefix += "[ ] " }
            }
            tv.insertText("\n" + prefix, replacementRange: tv.selectedRange())
            return true
        }

        // MARK: slash commands (native NSMenu at the caret — free keyboard nav + type-select)
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
                ("To-do", "checklist", "- [ ] "),
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
            perform(#selector(showActions), with: nil, afterDelay: 0.3)
        }

        @objc private func showActions() {
            guard let tv = textView, tv.selectedRange().length > 0,
                  NSEvent.pressedMouseButtons == 0, let win = tv.window else { return }
            if actionPopover.contentViewController == nil {
                actionPopover.contentViewController = NSHostingController(rootView: ActionBar(coordinator: self))
                actionPopover.behavior = .transient
            }
            let screenRect = tv.firstRect(forCharacterRange: tv.selectedRange(), actualRange: nil)
            let local = tv.convert(win.convertFromScreen(screenRect), from: nil)
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
                .map { $0.isEmpty || $0.hasPrefix("- [ ] ") ? $0 : "- [ ] " + $0 }
                .joined(separator: "\n")
            tv.insertText(lines, replacementRange: para)
            actionPopover.performClose(nil)
        }
    }
}

struct ActionBar: View {
    let coordinator: MarkdownTextView.Coordinator
    var body: some View {
        HStack(spacing: 2) {
            Button { coordinator.wrap("**") } label: { Image(systemName: "bold") }
            Button { coordinator.wrap("*") } label: { Image(systemName: "italic") }
            Button { coordinator.wrap("`") } label: { Image(systemName: "chevron.left.forwardslash.chevron.right") }
            Button { coordinator.makeTodo() } label: { Image(systemName: "checklist") }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8).padding(.vertical, 5)
    }
}

/// NSTextView that toggles `- [ ]` / `- [x]` on click.
final class SmartTextView: NSTextView {
    private static let checkboxRegex = try! NSRegularExpression(pattern: #"^\s*[-*+] \[([ x])\] "#)

    override func mouseDown(with event: NSEvent) {
        let ns = string as NSString
        if ns.length > 0 {
            let pt = convert(event.locationInWindow, from: nil)
            let idx = characterIndexForInsertion(at: pt)
            let lineR = ns.lineRange(for: NSRange(location: min(idx, ns.length - 1), length: 0))
            let line = ns.substring(with: lineR)
            if let m = Self.checkboxRegex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)),
               idx >= lineR.location, idx < lineR.location + m.range.length {
                let boxR = NSRange(location: lineR.location + m.range(at: 1).location, length: 1)
                let checked = ns.substring(with: boxR) == "x"
                insertText(checked ? " " : "x", replacementRange: boxR)
                return
            }
        }
        super.mouseDown(with: event)
    }
}
