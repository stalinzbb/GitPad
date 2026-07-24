import AppKit
import SwiftUI

// GitPad --uitest — drive the real editor stack headless through Tab/Enter/Backspace
// (precondition-based like --selftest, so it survives -c release)
if CommandLine.arguments.contains("--uitest") {
    _ = NSApplication.shared
    func makeEditor(_ text: String) -> (SmartTextView, MarkdownTextView.Coordinator) {
        let storage = NSTextStorage()
        let layout = DividerLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 520, height: CGFloat.greatestFiniteMagnitude))
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        let tv = SmartTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 400), textContainer: container)
        tv.allowsUndo = true
        let coord = MarkdownTextView.Coordinator(MarkdownTextView(text: .constant(text)))
        coord.textView = tv
        tv.delegate = coord
        storage.delegate = coord
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
        return (tv, coord)
    }
    func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) } // flush deferred renumber

    // Tab on a caret at end of a list line: line indents, caret stays at its text position
    var (tv, coord) = makeEditor("- one\n- two\n")
    tv.setSelectedRange(NSRange(location: 5, length: 0)) // end of "- one"
    precondition(coord.textView(tv, doCommandBy: #selector(NSResponder.insertTab(_:))))
    precondition(tv.string == "  - one\n- two\n", tv.string)
    precondition(tv.selectedRange() == NSRange(location: 7, length: 0), "\(tv.selectedRange())")

    // Tab on a multi-line selection ending at a line start: last line untouched, selection survives
    (tv, coord) = makeEditor("1. a\n2. b\n3. c\n")
    tv.setSelectedRange(NSRange(location: 0, length: 10)) // "1. a\n2. b\n" incl. trailing \n
    precondition(coord.textView(tv, doCommandBy: #selector(NSResponder.insertTab(_:))))
    precondition(tv.string == "  1. a\n  2. b\n3. c\n", tv.string)
    let sel = tv.selectedRange()
    precondition(sel.location == 2 && sel.length == 12, "\(sel)") // still spans both lines
    // repeated Tab keeps working on the block
    precondition(coord.textView(tv, doCommandBy: #selector(NSResponder.insertTab(_:))))
    precondition(tv.string == "    1. a\n    2. b\n3. c\n", tv.string)
    spin() // renumber pass: nested items restart at 1, top level restarts
    precondition(tv.string == "    1. a\n    2. b\n1. c\n", tv.string)

    // Enter mid-list splits and renumbers the following lines
    (tv, coord) = makeEditor("1. a\n2. b\n3. c\n")
    tv.setSelectedRange(NSRange(location: 9, length: 0)) // end of "2. b"
    precondition(coord.textView(tv, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    spin()
    precondition(tv.string == "1. a\n2. b\n3. \n4. c\n", tv.string)

    // Enter on an empty nested item outdents one level, keeping the marker
    (tv, coord) = makeEditor("- a\n  - \n")
    tv.setSelectedRange(NSRange(location: 8, length: 0)) // end of "  - "
    precondition(coord.textView(tv, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    precondition(tv.string == "- a\n- \n", tv.string)
    precondition(tv.selectedRange() == NSRange(location: 6, length: 0), "\(tv.selectedRange())")

    // Enter on an empty top-level item exits the list
    (tv, coord) = makeEditor("- a\n- \n")
    tv.setSelectedRange(NSRange(location: 6, length: 0))
    precondition(coord.textView(tv, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    precondition(tv.string == "- a\n\n", tv.string)

    // Backspace at content start removes the whole marker in one go
    (tv, coord) = makeEditor("  ☐ task\n")
    tv.setSelectedRange(NSRange(location: 4, length: 0)) // right after "☐ "
    precondition(coord.textView(tv, doCommandBy: #selector(NSResponder.deleteBackward(_:))))
    precondition(tv.string == "  task\n", tv.string)
    precondition(tv.selectedRange() == NSRange(location: 2, length: 0), "\(tv.selectedRange())")

    // The line created by Enter is styled in the same deferred pass — its marker must be
    // cleared-for-display immediately, not on the next keystroke (was: raw "2."/"☐" flash)
    func markerCleared(_ tv: SmartTextView, at loc: Int) -> Bool {
        (tv.textStorage?.attribute(.foregroundColor, at: loc, effectiveRange: nil) as? NSColor) == NSColor.clear
    }
    (tv, coord) = makeEditor("1. p\n  1. A\n")
    tv.setSelectedRange(NSRange(location: 11, length: 0)) // end of "  1. A"
    precondition(coord.textView(tv, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    spin()
    precondition(tv.string == "1. p\n  1. A\n  2. \n", tv.string)
    precondition(markerCleared(tv, at: 14), "new nested ordinal not display-styled") // the "2"
    (tv, coord) = makeEditor("☐ a\n")
    tv.setSelectedRange(NSRange(location: 3, length: 0))
    precondition(coord.textView(tv, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    spin()
    precondition(tv.string == "☐ a\n☐ \n", tv.string)
    precondition(markerCleared(tv, at: 4), "new checkbox glyph not display-styled")

    // Toggling ☐ ↔ ☑ must not move the text: both glyphs are pinned to the same fixed
    // advance (their fallback fonts — emoji for ☑! — have wildly different widths)
    (tv, coord) = makeEditor("☐ task\n")
    spin() // let the deferred styling pass run
    guard let lm = tv.layoutManager else { preconditionFailure("no layout manager") }
    let xUnchecked = lm.location(forGlyphAt: lm.glyphIndexForCharacter(at: 2)).x
    let hUnchecked = lm.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).height
    tv.insertText("☑", replacementRange: NSRange(location: 0, length: 1))
    spin()
    let xChecked = lm.location(forGlyphAt: lm.glyphIndexForCharacter(at: 2)).x
    let hChecked = lm.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).height
    precondition(abs(xChecked - xUnchecked) < 0.5, "text shifted on toggle: \(xUnchecked) → \(xChecked)")
    precondition(abs(hChecked - hUnchecked) < 0.5, "line height changed on toggle: \(hUnchecked) → \(hChecked)")

    // A fresh note's empty "# " line must be full H1 height — its glyphs are hidden at
    // 0.1pt, and without the minimumLineHeight floor the caret collapsed to invisibility
    (tv, coord) = makeEditor("# ")
    spin()
    let hEmptyTitle = tv.layoutManager!.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).height
    (tv, coord) = makeEditor("# Title")
    spin()
    let hFullTitle = tv.layoutManager!.lineFragmentRect(forGlyphAt: 2, effectiveRange: nil).height
    precondition(abs(hEmptyTitle - hFullTitle) < 1.5,
                 "empty title line collapsed: \(hEmptyTitle) vs \(hFullTitle)")

    // Backspace right after a heading marker drops the title to plain text
    (tv, coord) = makeEditor("# Title\n")
    tv.setSelectedRange(NSRange(location: 2, length: 0))
    precondition(coord.textView(tv, doCommandBy: #selector(NSResponder.deleteBackward(_:))))
    precondition(tv.string == "Title\n", tv.string)
    precondition(tv.selectedRange() == NSRange(location: 0, length: 0), "\(tv.selectedRange())")

    // Deleting a middle numbered line renumbers the rest, caret preserved
    (tv, coord) = makeEditor("1. a\n2. b\n3. c\n")
    tv.setSelectedRange(NSRange(location: 5, length: 5)) // "2. b\n"
    tv.insertText("", replacementRange: tv.selectedRange())
    spin()
    precondition(tv.string == "1. a\n2. c\n", tv.string)

    print("uitest OK")
    exit(0)
}

// CLI entry for tests: GitPad --sync <notesDir>
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--sync" {
    exit(GitSync.sync(dir: URL(fileURLWithPath: CommandLine.arguments[2])) ? 0 : 1)
}

// Library row parser check: GitPad --selftest (precondition, so it survives -c release)
if CommandLine.arguments.contains("--selftest") {
    let m = NoteStore.parseMeta("# Title\n\nsome body\n- [x] a\n- [ ] b\n")
    precondition(m.done == 1 && m.total == 2 && m.snippet == "some body", "\(m)")
    precondition(NoteStore.parseMeta("# Only a title\n").snippet.isEmpty)
    precondition(NoteStore.parseMeta("# T\n- [ ] first\n").snippet == "first")
    // nested (indented) checkboxes must survive the markdown round-trip — the persistence
    // guarantee behind Tab/Shift-Tab list nesting (Fix B).
    let nested = "# T\n  - [ ] a\n    - [x] b\n"
    let editor = NoteStore.fromMarkdown(nested)
    precondition(editor.contains("  ☐ a") && editor.contains("    ☑ b"), editor)
    precondition(NoteStore.toMarkdown(editor) == nested, NoteStore.toMarkdown(editor))
    // search folding: "cafe" must find "Café" (diacritics + case)
    precondition(NoteStore.fold("Café Notes").contains(NoteStore.fold("cafe")))
    precondition(NoteStore.fold("RÉSUMÉ") == NoteStore.fold("resume"))
    // tolerant read: other editors' `* [X]` variants map to glyphs (write stays canonical `- [x]`)
    precondition(NoteStore.fromMarkdown("* [X] a\n+ [ ] b\n").contains("☑ a"))
    precondition(NoteStore.fromMarkdown("* [X] a\n+ [ ] b\n").contains("☐ b"))
    // ordered lists renumber per depth; bullets and non-list lines break the runs
    precondition(ListLogic.renumber(["1. a", "5. b", "  3. x", "  9. y", "2. c"])
        == ["1. a", "2. b", "  1. x", "  2. y", "3. c"])
    precondition(ListLogic.renumber(["1. a", "text", "5. b"]) == ["1. a", "text", "1. b"])
    precondition(ListLogic.renumber(["1. a", "- b", "5. c"]) == ["1. a", "- b", "1. c"])
    // display markers cycle 1. → a. → i. by depth
    precondition(ListLogic.displayMarker(number: 3, depth: 0) == "3.")
    precondition(ListLogic.displayMarker(number: 3, depth: 1) == "c.")
    precondition(ListLogic.displayMarker(number: 3, depth: 2) == "iii.")
    precondition(ListLogic.letterLabel(27) == "aa")
    precondition(ListLogic.romanLabel(4) == "iv" && ListLogic.romanLabel(9) == "ix")
    precondition(ListLogic.displayMarker(number: nil, depth: 1) == "◦")
    print("selftest OK")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
