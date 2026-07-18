import Foundation

enum GitSync {
    /// Runs a subprocess with a FIXED argument array — never a shell string.
    /// SECURITY INVARIANT: no user input is ever interpolated into a shell;
    /// args go straight to execve, so note titles / remote URLs can't inject.
    private static func exec(_ exe: String, _ args: [String], cwd: URL? = nil) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
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

    @discardableResult
    static func run(_ args: [String], in dir: URL) -> (status: Int32, out: String) {
        exec("/usr/bin/git", ["-C", dir.path] + args)
    }

    static func remoteURL(in dir: URL) -> String {
        let r = run(["remote", "get-url", "origin"], in: dir)
        return r.status == 0 ? r.out : "" // never leak git's stderr ("fatal: …") into the UI
    }

    /// (unpushed, unpulled) commit counts vs origin, or nil if unknown.
    static func aheadBehind(in dir: URL) -> (ahead: Int, behind: Int)? {
        let branch = run(["rev-parse", "--abbrev-ref", "HEAD"], in: dir).out
        let r = run(["rev-list", "--left-right", "--count", "HEAD...origin/\(branch)"], in: dir)
        let parts = r.out.split(whereSeparator: { $0 == "\t" || $0 == " " }).compactMap { Int($0) }
        guard r.status == 0, parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    static func setRemote(_ url: String, in dir: URL) {
        guard !url.isEmpty else { return }
        if run(["remote", "get-url", "origin"], in: dir).status == 0 {
            run(["remote", "set-url", "origin", url], in: dir)
        } else {
            run(["remote", "add", "origin", url], in: dir)
        }
    }

    /// Turn raw git stderr into one friendly line — never shown verbatim.
    static func friendlyError(_ stderr: String) -> String {
        let s = stderr.lowercased()
        if s.contains("permission denied") || s.contains("publickey") {
            return "SSH key not authorized for this repo"
        }
        if s.contains("host key verification") {
            return "Host unknown — connect once in Terminal to trust it"
        }
        if s.contains("could not read from remote") || s.contains("not found")
            || s.contains("does not exist") || s.contains("repository") {
            return "Repository URL not found — check the address"
        }
        return "Can't reach the repo — check the URL and your SSH key"
    }

    // MARK: gh CLI (optional convenience)

    /// Homebrew installs gh outside the sandbox PATH, so probe the usual spots.
    private static var ghPath: String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func ghReady() -> Bool {
        guard let gh = ghPath else { return false }
        return exec(gh, ["auth", "status"]).status == 0
    }

    /// Create a private repo and return its SSH URL, or nil on any failure.
    static func ghCreateRepo(_ name: String) -> String? {
        guard let gh = ghPath else { return nil }
        guard exec(gh, ["repo", "create", name, "--private"]).status == 0 else { return nil }
        let u = exec(gh, ["repo", "view", name, "--json", "sshUrl", "-q", ".sshUrl"])
        return u.status == 0 && !u.out.isEmpty ? u.out : nil
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
            // 2. try a clean merge first (--allow-unrelated-histories: a repo created
            //    with a README has history unrelated to our fresh init)
            if run(["merge", "--no-edit", "--allow-unrelated-histories", remote], in: dir).status != 0 {
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
                guard run(["merge", "--no-edit", "--allow-unrelated-histories", "-X", "ours", remote], in: dir).status == 0 else {
                    run(["merge", "--abort"], in: dir)
                    return false
                }
            }
        }

        // 4. push
        return run(["push", "-u", "origin", branch], in: dir).status == 0
    }
}
