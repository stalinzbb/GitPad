import Foundation

enum GitSync {
    @discardableResult
    static func run(_ args: [String], in dir: URL) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir.path] + args
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0" // never hang on auth prompts
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (127, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (p.terminationStatus, out)
    }

    static func setRemote(_ url: String, in dir: URL) {
        guard !url.isEmpty else { return }
        if run(["remote", "get-url", "origin"], in: dir).status == 0 {
            run(["remote", "set-url", "origin", url], in: dir)
        } else {
            run(["remote", "add", "origin", url], in: dir)
        }
    }

    /// Commit local edits, reconcile with origin, push. Never surfaces a merge UI:
    /// clean merges happen silently; a real same-file conflict keeps the local
    /// version and writes the remote version alongside as "<name> (conflict <date>).md".
    /// Returns true if the repo is left in a consistent, pushed (or no-remote) state.
    static func sync(dir: URL) -> Bool {
        if run(["rev-parse", "--git-dir"], in: dir).status != 0 {
            run(["init", "-b", "main"], in: dir)
            run(["config", "user.name", "GitPad"], in: dir)
            run(["config", "user.email", "gitpad@localhost"], in: dir)
        }

        // 1. commit local changes
        run(["add", "-A"], in: dir)
        if run(["diff", "--cached", "--quiet"], in: dir).status != 0 {
            let stamp = ISO8601DateFormatter().string(from: Date())
            run(["commit", "-m", "autosave \(stamp)"], in: dir)
        }

        // no remote configured → local-only mode, still fine
        guard run(["remote", "get-url", "origin"], in: dir).status == 0 else { return true }

        let branch = run(["rev-parse", "--abbrev-ref", "HEAD"], in: dir).out
        guard run(["fetch", "origin"], in: dir).status == 0 else { return false } // offline

        let remote = "origin/\(branch)"
        if run(["rev-parse", "--verify", remote], in: dir).status == 0 {
            // 2. try a clean merge first
            if run(["merge", "--no-edit", remote], in: dir).status != 0 {
                run(["merge", "--abort"], in: dir)
                // 3. real conflict: preserve remote versions as copies, then merge preferring local
                let conflicted = run(["diff", "--name-only", "HEAD", remote], in: dir).out
                    .split(separator: "\n").map(String.init)
                let date = DateFormatter()
                date.dateFormat = "yyyy-MM-dd HHmm"
                for file in conflicted where file.hasSuffix(".md") {
                    let show = run(["show", "\(remote):\(file)"], in: dir)
                    guard show.status == 0 else { continue }
                    let copy = file.replacingOccurrences(
                        of: ".md", with: " (conflict \(date.string(from: Date()))).md")
                    try? show.out.write(to: dir.appendingPathComponent(copy),
                                        atomically: true, encoding: .utf8)
                }
                run(["add", "-A"], in: dir)
                run(["commit", "-m", "conflict copies"], in: dir)
                // ponytail: -X ours keeps local hunks; remote hunks live on in the copies
                guard run(["merge", "--no-edit", "-X", "ours", remote], in: dir).status == 0 else {
                    run(["merge", "--abort"], in: dir)
                    return false
                }
            }
        }

        // 4. push
        return run(["push", "-u", "origin", branch], in: dir).status == 0
    }
}
