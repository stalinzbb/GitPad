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
    // NSTextView takes its undo manager from its window, so undo tests need one. Borderless
    // and never ordered in — nothing appears on screen.
    var undoWindows: [NSWindow] = [] // keep alive; a released window drops the undo manager
    func makeUndoableEditor(_ text: String) -> (SmartTextView, MarkdownTextView.Coordinator) {
        let (tv, coord) = makeEditor(text)
        let w = NSWindow(contentRect: tv.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView?.addSubview(tv)
        w.makeFirstResponder(tv)
        undoWindows.append(w)
        return (tv, coord)
    }

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

    // Selection bar: wrap() is a toggle, through both detection paths
    (tv, coord) = makeEditor("hello world\n")
    tv.setSelectedRange(NSRange(location: 0, length: 5))
    coord.wrap("**")
    precondition(tv.string == "**hello** world\n", tv.string)
    precondition(tv.selectedRange() == NSRange(location: 2, length: 5), "\(tv.selectedRange())")
    coord.wrap("**") // marks around the selection → strip
    precondition(tv.string == "hello world\n", tv.string)
    precondition(tv.selectedRange() == NSRange(location: 0, length: 5), "\(tv.selectedRange())")
    tv.setSelectedRange(NSRange(location: 0, length: 5))
    coord.wrap("**")
    tv.setSelectedRange(NSRange(location: 0, length: 9)) // "**hello**" — marks inside
    coord.wrap("**")
    precondition(tv.string == "hello world\n", tv.string)

    // setHeading: set, clear, and re-level
    (tv, coord) = makeEditor("a line\n")
    tv.setSelectedRange(NSRange(location: 0, length: 0))
    coord.setHeading(2)
    precondition(tv.string == "## a line\n", tv.string)
    coord.setHeading(2)
    precondition(tv.string == "a line\n", tv.string)
    (tv, coord) = makeEditor("# Title\n")
    tv.setSelectedRange(NSRange(location: 0, length: 0))
    coord.setHeading(2)
    precondition(tv.string == "## Title\n", tv.string)

    // makeList converts across families, toggles off, and lets renumber fix ordinals
    (tv, coord) = makeEditor("☐ a\nplain\n☑ c\n")
    tv.setSelectedRange(NSRange(location: 0, length: 13))
    coord.makeList("- ")
    precondition(tv.string == "- a\n- plain\n- c\n", tv.string)
    coord.makeList("- ") // all one family now → strip
    precondition(tv.string == "a\nplain\nc\n", tv.string)
    coord.makeList("1. ")
    spin()
    precondition(tv.string == "1. a\n2. plain\n3. c\n", tv.string)
    // nesting survives the conversion (indent must not be duplicated)
    (tv, coord) = makeEditor("  - x\n")
    tv.setSelectedRange(NSRange(location: 0, length: 5))
    coord.makeList("☐ ")
    precondition(tv.string == "  ☐ x\n", tv.string)

    // converting to to-dos must not uncheck an existing ☑
    (tv, coord) = makeEditor("☑ done\nplain\n")
    tv.setSelectedRange(NSRange(location: 0, length: 12))
    coord.makeTodo()
    precondition(tv.string == "☑ done\n☐ plain\n", tv.string)

    // insertLink with nothing usable on the clipboard: empty parens, caret between them
    NSPasteboard.general.clearContents()
    (tv, coord) = makeEditor("docs\n")
    tv.setSelectedRange(NSRange(location: 0, length: 4))
    coord.insertLink()
    precondition(tv.string == "[docs]()\n", tv.string)
    precondition(tv.selectedRange() == NSRange(location: 7, length: 0), "\(tv.selectedRange())")

    // Undo across a renumbering edit must converge on the original and keep redo alive.
    // The deferred renumber is its own top-level group (the event group has closed by the
    // time it runs), so an Enter mid-list is two presses — but each ⌘Z must make progress.
    // Before the fix it ping-ponged: undo ran the renumber again, which registered a *new*
    // group and wiped the redo stack, so the list never came back.
    (tv, coord) = makeUndoableEditor("1. a\n2. b\n3. c\n")
    tv.setSelectedRange(NSRange(location: 9, length: 0)) // end of "2. b"
    precondition(coord.textView(tv, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    spin()
    precondition(tv.string == "1. a\n2. b\n3. \n4. c\n", tv.string)
    tv.undoManager?.undo() // the renumber
    spin()
    precondition(tv.string == "1. a\n2. b\n3. \n3. c\n", "undo #1 didn't revert the renumber: \(tv.string)")
    tv.undoManager?.undo() // the Enter
    spin()
    precondition(tv.string == "1. a\n2. b\n3. c\n", "undo #2 didn't restore the original: \(tv.string)")
    precondition(tv.undoManager?.canRedo == true, "redo stack cleared — the renumber re-registered")
    tv.undoManager?.redo(); spin()
    tv.undoManager?.redo(); spin()
    precondition(tv.string == "1. a\n2. b\n3. \n4. c\n", "redo didn't replay: \(tv.string)")

    // A no-op Shift-Tab must not eat the previous undo. indentList used to open its own undo
    // group around edits that all skipped, pushing an empty group that swallowed one ⌘Z.
    (tv, coord) = makeUndoableEditor("- one\n")
    tv.setSelectedRange(NSRange(location: 5, length: 0))
    tv.insertText(" two", replacementRange: tv.selectedRange())
    spin()
    precondition(coord.textView(tv, doCommandBy: #selector(NSResponder.insertBacktab(_:)))) // no indent to strip
    precondition(tv.string == "- one two\n", tv.string)
    tv.undoManager?.undo()
    spin()
    precondition(tv.string == "- one\n", "empty undo group swallowed the edit: \(tv.string)")

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

    // lean scrollbar: our scroller survives being installed, and stays eligible for
    // overlay drawing (false here means AppKit silently draws its own knob instead)
    precondition(LeanScroller.isCompatibleWithOverlayScrollers)
    let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
    sv.hasVerticalScroller = true
    LeanScrollbar.Swapper.install(in: sv)
    sv.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
    sv.tile()
    precondition(sv.verticalScroller is LeanScroller)
    precondition(sv.verticalScroller!.frame.width > 0, "\(sv.verticalScroller!.frame)")

    // Updater: version compare is numeric per component — a string compare gets 10 vs 9 wrong
    precondition(Updater.isNewer("0.9.10", than: "0.9.9"))
    precondition(Updater.isNewer("1.0", than: "0.9.3"))     // short version, missing parts = 0
    precondition(!Updater.isNewer("0.9.3", than: "0.9.3"))  // same → nothing to offer
    precondition(!Updater.isNewer("0.9.2", than: "0.9.3"))  // older → never downgrade
    // feed parsing: skip drafts, strip the tag's "v", match the un-prefixed asset name,
    // strip the digest's "sha256:" — every one of those mismatches is a silent failure
    let feed = Data("""
    [{"tag_name":"v1.5.0","draft":true,"html_url":"https://e/d","assets":[]},
     {"tag_name":"v0.9.9","draft":false,"html_url":"https://e/0.9.9",
      "assets":[{"name":"GitPad-0.9.9.dmg","browser_download_url":"https://e/d.dmg","digest":"sha256:dd"},
                {"name":"GitPad-0.9.9.zip","browser_download_url":"https://e/GitPad-0.9.9.zip","digest":"sha256:ab"}]}]
    """.utf8)
    let rel = Updater.parse(feed, "0.9.3")
    precondition(rel?.version == "0.9.9", "draft skipped, v stripped: \(String(describing: rel))")
    precondition(rel?.sha256 == "ab", "picked the zip's digest, not the dmg's")
    precondition(rel?.zipURL?.lastPathComponent == "GitPad-0.9.9.zip")
    precondition(rel?.pageURL.absoluteString == "https://e/0.9.9")
    precondition(Updater.parse(feed, "0.9.9") == nil) // already running it
    precondition(Updater.parse(feed, "1.2.0") == nil) // running something newer
    // a release whose asset hasn't uploaded yet still surfaces — the page link is the fallback
    let noAsset = Data(#"[{"tag_name":"v0.9.9","draft":false,"html_url":"https://e/n","assets":[]}]"#.utf8)
    precondition(Updater.parse(noAsset, "0.9.3")?.zipURL == nil)
    precondition(Updater.parse(noAsset, "0.9.3")?.version == "0.9.9")
    // garbage and no-network must both be silent, never a nag
    precondition(Updater.parse(Data("not json".utf8), "0.9.3") == nil)
    precondition(Updater.parse(nil, "0.9.3") == nil)

    // Updater.swap: the move-aside that replaces a *running* bundle. A half-finished swap
    // is the one failure here that loses the user's app, so both directions are checked.
    let fm = FileManager.default
    let sandbox = fm.temporaryDirectory.appendingPathComponent("gitpad-swaptest-\(getpid())")
    try? fm.removeItem(at: sandbox)
    try! fm.createDirectory(at: sandbox.appendingPathComponent("staged"), withIntermediateDirectories: true)
    let live = sandbox.appendingPathComponent("GitPad.app")
    let fresh = sandbox.appendingPathComponent("staged/GitPad.app")
    try! "old".write(to: live, atomically: true, encoding: .utf8)
    try! "new".write(to: fresh, atomically: true, encoding: .utf8)
    precondition(Updater.swap(live, with: fresh) == nil)
    precondition((try? String(contentsOf: live, encoding: .utf8)) == "new", "swap didn't install")
    precondition(try! fm.contentsOfDirectory(atPath: sandbox.path)
        .allSatisfy { !$0.hasPrefix(".GitPad.app.old-") }, "move-aside copy left behind")
    // source gone → must fail *and* roll the original back, not leave an empty slot
    precondition(Updater.swap(live, with: sandbox.appendingPathComponent("absent.app")) != nil)
    precondition((try? String(contentsOf: live, encoding: .utf8)) == "new", "rollback lost the app")
    try? fm.removeItem(at: sandbox)

    print("selftest OK")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
