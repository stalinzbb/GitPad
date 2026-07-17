import AppKit

// CLI entry for tests: GitPad --sync <notesDir>
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--sync" {
    exit(GitSync.sync(dir: URL(fileURLWithPath: CommandLine.arguments[2])) ? 0 : 1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
