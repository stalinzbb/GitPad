import AppKit

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
    print("selftest OK")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
