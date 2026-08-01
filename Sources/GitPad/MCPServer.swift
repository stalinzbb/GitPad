import Foundation
import AppKit

/// `GitPad --mcp` — a Model Context Protocol server over stdio, so Claude (and any other
/// MCP client) can read, search and add to your notes.
///
/// Hand-rolled newline-delimited JSON-RPC 2.0. The official Swift SDK would be this app's
/// first third-party dependency (see CLAUDE.md invariants) and the slice of MCP we need is
/// four methods. stdout is the protocol channel — every log line goes to stderr.
///
/// Everything routes through `NoteStore`/`GitSync` instead of re-reading the notes folder,
/// so search folding, daily-note naming and titles can't drift from the app.
/// Git is READ-ONLY here (`log`/`show`): committing from a second process would race the
/// GUI's sync. `--allow-sync` opts into the one exception.
enum MCPServer {
    /// Pinned: we track no SDK, so we declare one version and degrade gracefully above it.
    private static let protocolVersion = "2024-11-05"
    private static var store: NoteStore!
    private static var exclude: Set<String> = []
    private static var allowSync = false

    private static let iso = ISO8601DateFormatter()
    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX") // filenames are machine-written
        return f
    }()

    private enum Fail: Error { case msg(String) }

    // MARK: run loop

    static func run() {
        let args = CommandLine.arguments
        allowSync = args.contains("--allow-sync")
        for (i, a) in args.enumerated() where a == "--exclude" && i + 1 < args.count {
            exclude.insert(args[i + 1])
        }
        if let env = ProcessInfo.processInfo.environment["GITPAD_MCP_EXCLUDE"] {
            exclude.formUnion(env.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        }
        exclude = exclude.filter { !$0.isEmpty }

        // Same side effect as launching the app: creates the notes dir and today's daily note.
        store = NoteStore()
        log("gitpad mcp ready — notes: \(store.dir.path)" +
            (exclude.isEmpty ? "" : ", excluding: \(exclude.sorted().joined(separator: ", "))"))

        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            handle(line)
        }
    }

    private static func handle(_ line: String) {
        guard let data = line.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log("parse error: \(line.prefix(200))")
            return
        }
        // A missing (or null) id means a notification — JSON-RPC forbids answering those.
        let id = msg["id"].flatMap { $0 is NSNull ? nil : $0 }
        let method = msg["method"] as? String ?? ""
        let params = msg["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            send(result: ["protocolVersion": protocolVersion,
                          "capabilities": ["tools": [String: Any]()],
                          "serverInfo": ["name": "gitpad", "version": appVersion]], id: id)
        case "ping":
            send(result: [String: Any](), id: id)
        case "tools/list":
            send(result: ["tools": tools], id: id)
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                let payload = try call(name, arguments)
                send(result: ["content": [["type": "text", "text": json(payload)]]], id: id)
            } catch Fail.msg(let m) {
                // Tool failures are results, not protocol errors — the model reads and retries.
                send(result: ["content": [["type": "text", "text": "Error: " + m]], "isError": true], id: id)
            } catch {
                send(result: ["content": [["type": "text", "text": "Error: \(error)"]], "isError": true], id: id)
            }
        default:
            send(error: -32601, "Unknown method: \(method)", id: id) // no-op for notifications
        }
    }

    // MARK: tools

    private static var tools: [[String: Any]] {
        var list: [[String: Any]] = [
            tool("list_notes", "List the user's GitPad notes, newest first.",
                 ["folder": str("Only notes in this folder (omit for all).")]),
            tool("read_note", "Read one note's full Markdown by its path from list_notes/search_notes.",
                 ["path": str("Note path relative to the notes folder, e.g. Daily/2026-07-31.md.")],
                 required: ["path"]),
            tool("search_notes", "Search notes by title and body — same matching the app's search uses.",
                 ["query": str("Words to look for; every word must match."),
                  "limit": int("Max results (default 20).")],
                 required: ["query"]),
            tool("create_note", "Create a new note in the user's GitPad.",
                 ["content": str("Markdown body."),
                  "title": str("Optional title, written as a leading '# ' heading."),
                  "folder": str("Optional folder; omit for the root Inbox.")],
                 required: ["content"]),
            tool("append_daily", "Append a line to today's daily note (the app's ⌥Space note).",
                 ["text": str("Text to append; Markdown allowed.")],
                 required: ["text"]),
            tool("read_daily", "Read daily notes — today by default, or one date / a date range.",
                 ["date": str("A single day, yyyy-MM-dd."),
                  "from": str("Range start, yyyy-MM-dd."),
                  "to": str("Range end, yyyy-MM-dd.")]),
            tool("list_open_todos", "List unchecked to-do items across the notes.",
                 ["folder": str("Only notes in this folder (omit for all).")]),
            tool("note_history", "Git history for one note: who changed it, when, on which device.",
                 ["path": str("Note path relative to the notes folder."),
                  "limit": int("Max commits (default 10).")],
                 required: ["path"]),
        ]
        if allowSync {
            list.append(tool("sync_notes", "Commit local note changes and sync with the git remote.", [:]))
        }
        return list
    }

    private static func call(_ name: String, _ a: [String: Any]) throws -> Any {
        switch name {
        case "list_notes":
            return visible(folder: a["folder"] as? String).map(brief)

        case "read_note":
            let url = try resolve(try string(a, "path"))
            return ["path": store.rel(url), "title": store.title(for: url),
                    "content": (try? String(contentsOf: url, encoding: .utf8)) ?? ""]

        case "search_notes":
            let limit = a["limit"] as? Int ?? 20
            return store.matches(try string(a, "query"))
                .filter(allowed).prefix(max(1, limit)).map(brief)

        case "create_note":
            return try createNote(content: try string(a, "content"),
                                  title: a["title"] as? String, folder: a["folder"] as? String)

        case "append_daily":
            return try appendDaily(try string(a, "text"))

        case "read_daily":
            return try readDaily(a)

        case "list_open_todos":
            return openTodos(folder: a["folder"] as? String)

        case "note_history":
            return try history(try resolve(try string(a, "path")), limit: a["limit"] as? Int ?? 10)

        case "sync_notes":
            guard allowSync else { throw Fail.msg("sync is disabled — start the server with --allow-sync") }
            let ok = GitSync.sync(dir: store.dir)
            store.refresh()
            return ["synced": ok]

        default:
            throw Fail.msg("unknown tool: \(name)")
        }
    }

    // MARK: tool bodies

    private static func createNote(content: String, title: String?, folder: String?) throws -> Any {
        if let folder {
            guard !exclude.contains(folder) else { throw Fail.msg("folder '\(folder)' is excluded") }
            guard !folder.contains("/"), !folder.hasPrefix(".") else { throw Fail.msg("invalid folder name") }
        }
        let base = folder.map { store.dir.appendingPathComponent($0) } ?? store.dir
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-") // mirrors NoteStore.newNote
        var url = base.appendingPathComponent("note-\(stamp).md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) { // never overwrite
            url = base.appendingPathComponent("note-\(stamp)-\(n).md")
            n += 1
        }
        let heading = title.map { "# \($0)\n\n" } ?? ""
        try (heading + content).write(to: url, atomically: true, encoding: .utf8)
        store.refresh()
        return ["path": store.rel(url), "title": store.title(for: url)]
    }

    /// The GUI is a separate process with a 1s debounced autosave, so writing today's note
    /// behind its back can be clobbered. When it's running, hand the text to the app's own
    /// live-buffer append over `gitpad://`; otherwise write the file ourselves.
    // ponytail: pgrep gate; upgrade to real IPC only if the un-onboarded no-op ever bites.
    private static func appendDaily(_ text: String) throws -> Any {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Fail.msg("nothing to append") }
        let url = store.dailyNote()

        if guiOwnsOurNotes,
           let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
           let link = URL(string: "gitpad://daily?append=" + encoded),
           NSWorkspace.shared.open(link) {
            return ["path": store.rel(url), "method": "app"]
        }
        // `selected` is today's note (NoteStore.init picks it) but this process' buffer goes
        // stale the moment the GUI or a sync writes; clear it so appendToDaily re-reads the file.
        store.selected = nil
        store.appendToDaily(trimmed)
        return ["path": store.rel(url), "method": "file"]
    }

    private static var guiOwnsOurNotes: Bool {
        // `gitpad://` lands in whatever folder the running app opened. If we were pointed
        // somewhere else with GITPAD_DIR, that's not our folder — write the file ourselves.
        guard ProcessInfo.processInfo.environment["GITPAD_DIR"] == nil else { return false }
        let out = GitSync.exec("/usr/bin/pgrep", ["-x", "GitPad"]).out
        let mine = String(ProcessInfo.processInfo.processIdentifier)
        return out.split(separator: "\n").contains { $0 != mine } // our own --mcp process is a GitPad too
    }

    private static func readDaily(_ a: [String: Any]) throws -> Any {
        if exclude.contains("Daily") { throw Fail.msg("the Daily folder is excluded") }
        let today = day.string(from: Date())
        var lo = today, hi = today
        if let d = a["date"] as? String { lo = d; hi = d }
        else if a["from"] != nil || a["to"] != nil {
            lo = a["from"] as? String ?? "0000-01-01"
            hi = a["to"] as? String ?? "9999-12-31"
        }
        let folder = store.dir.appendingPathComponent("Daily")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(".md") }
            .map { String($0.dropLast(3)) }
            .filter { $0 >= lo && $0 <= hi } // yyyy-MM-dd sorts lexically
            .sorted()
        return names.map { name -> [String: Any] in
            let url = folder.appendingPathComponent(name + ".md")
            return ["date": name, "path": store.rel(url),
                    "content": (try? String(contentsOf: url, encoding: .utf8)) ?? ""]
        }
    }

    private static func openTodos(folder: String?) -> Any {
        var out: [[String: Any]] = []
        for url in visible(folder: folder) {
            let body = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            for (i, raw) in body.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                // tolerant on read, like NoteStore.fromMarkdown: `- [ ]`, `* [ ]`, `+ [ ]`
                guard let marker = ["- [ ] ", "* [ ] ", "+ [ ] "].first(where: line.hasPrefix) else { continue }
                out.append(["path": store.rel(url), "title": store.title(for: url),
                            "line": i + 1, "text": String(line.dropFirst(marker.count))])
            }
        }
        return out
    }

    private static func history(_ url: URL, limit: Int) throws -> Any {
        let r = GitSync.run(["log", "-n", String(max(1, limit)),
                             "--format=%H%x09%an%x09%aI%x09%s", "--", store.rel(url)], in: store.dir)
        guard r.status == 0 else { throw Fail.msg("no git history — this notes folder isn't a repo yet") }
        return r.out.split(separator: "\n").compactMap { line -> [String: Any]? in
            let f = line.components(separatedBy: "\t")
            guard f.count == 4 else { return nil }
            return ["sha": f[0], "device": f[1], "date": f[2], "subject": f[3]]
        }
    }

    // MARK: helpers

    /// Notes the client is allowed to see: `--exclude`d folders never leave this process.
    private static func allowed(_ url: URL) -> Bool {
        store.folder(of: url).map { !exclude.contains($0) } ?? true
    }

    private static func visible(folder: String?) -> [URL] {
        store.notes.filter { allowed($0) && (folder == nil || store.folder(of: $0) == folder) }
    }

    private static func brief(_ url: URL) -> [String: Any] {
        ["path": store.rel(url), "title": store.title(for: url),
         "folder": store.folder(of: url) ?? "", "modified": iso.string(from: store.modified(url))]
    }

    /// Resolve a client-supplied path inside the notes folder — `..` and absolute paths
    /// land outside it and are refused.
    private static func resolve(_ path: String) throws -> URL {
        let root = store.dir.standardizedFileURL.path
        let url = URL(fileURLWithPath: path, relativeTo: store.dir).standardizedFileURL
        guard url.path.hasPrefix(root + "/") else { throw Fail.msg("path is outside the notes folder") }
        if let f = store.folder(of: url), exclude.contains(f) { throw Fail.msg("folder '\(f)' is excluded") }
        guard FileManager.default.fileExists(atPath: url.path) else { throw Fail.msg("no such note: \(path)") }
        return url
    }

    private static func string(_ a: [String: Any], _ key: String) throws -> String {
        guard let s = a[key] as? String, !s.isEmpty else { throw Fail.msg("missing '\(key)'") }
        return s
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    // MARK: JSON-RPC plumbing

    private static func tool(_ name: String, _ desc: String,
                             _ props: [String: Any], required: [String] = []) -> [String: Any] {
        ["name": name, "description": desc,
         "inputSchema": ["type": "object", "properties": props, "required": required]]
    }
    private static func str(_ d: String) -> [String: Any] { ["type": "string", "description": d] }
    private static func int(_ d: String) -> [String: Any] { ["type": "integer", "description": d] }

    private static func send(result: Any, id: Any?) {
        guard let id else { return }
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func send(error code: Int, _ message: String, id: Any?) {
        guard let id else { return }
        send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private static func send(_ payload: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: payload,
                                                  options: [.sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: d, encoding: .utf8) else { return }
        print(s)
        fflush(stdout) // stdout is a pipe here — block-buffered, so the client would hang
    }

    private static func json(_ value: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: value,
                                                  options: [.fragmentsAllowed, .sortedKeys,
                                                            .withoutEscapingSlashes]),
              let s = String(data: d, encoding: .utf8) else { return "null" }
        return s
    }

    private static func log(_ s: String) {
        FileHandle.standardError.write(("gitpad-mcp: " + s + "\n").data(using: .utf8)!)
    }
}
