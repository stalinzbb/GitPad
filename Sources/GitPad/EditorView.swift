import SwiftUI
import AppKit

struct EditorView: View {
    @ObservedObject var store: NoteStore

    var body: some View {
        HSplitView {
            if !store.compact {
                List(store.notes, id: \.self, selection: $store.selected) { url in
                    Text(store.title(for: url))
                        .lineLimit(1)
                        .contextMenu {
                            Button("Delete") { store.delete(url) }
                        }
                }
                .frame(minWidth: 140, idealWidth: 180, maxWidth: 260)
                .toolbar { }
            }
            MarkdownTextView(text: $store.text)
                .frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .topTrailing) {
            if !store.compact {
                Button(action: { store.newNote() }) {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
        }
        .frame(minWidth: 280, minHeight: 180)
    }
}

struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = .systemFont(ofSize: 14)
        tv.textContainerInset = NSSize(width: 12, height: 12)
        tv.drawsBackground = false
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let tv = scroll.documentView as! NSTextView
        if tv.string != text {
            tv.string = text
            context.coordinator.highlight(tv)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextView
        init(_ parent: MarkdownTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            highlight(tv)
        }

        private static let rules: [(NSRegularExpression, [NSAttributedString.Key: Any])] = {
            let mono = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            func re(_ p: String) -> NSRegularExpression {
                try! NSRegularExpression(pattern: p, options: [.anchorsMatchLines])
            }
            return [
                (re(#"^#{1,3} .*$"#), [.font: NSFont.boldSystemFont(ofSize: 17)]),
                (re(#"\*\*[^*\n]+\*\*"#), [.font: NSFont.boldSystemFont(ofSize: 14)]),
                (re(#"(?<!\*)\*[^*\n]+\*(?!\*)"#), [.obliqueness: 0.15]),
                (re(#"`[^`\n]+`"#), [.font: mono, .foregroundColor: NSColor.systemPurple]),
                (re(#"^\s*([-*+]|\d+\.) "#), [.foregroundColor: NSColor.secondaryLabelColor]),
            ]
        }()

        func highlight(_ tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes([.font: NSFont.systemFont(ofSize: 14),
                                   .foregroundColor: NSColor.labelColor], range: full)
            for (regex, attrs) in Self.rules {
                regex.enumerateMatches(in: storage.string, range: full) { match, _, _ in
                    if let r = match?.range { storage.addAttributes(attrs, range: r) }
                }
            }
            storage.endEditing()
        }
    }
}
