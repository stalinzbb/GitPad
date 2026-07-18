import Foundation

enum Screen { case onboarding, capture, library, settings, gitSetup }

enum SyncStatus: Equatable {
    case unknown, noRemote, synced(Date), offline

    var label: String {
        switch self {
        case .unknown: return "—"
        case .noRemote: return "Local only — no remote set"
        case .synced(let d): return "Synced \(d.formatted(date: .omitted, time: .shortened))"
        case .offline: return "Can't reach remote — will retry"
        }
    }
}

final class NoteStore: ObservableObject {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/GitPad")

    @Published var notes: [URL] = []
    @Published var folders: [String] = []
    @Published var selected: URL? { didSet { loadSelected() } }
    @Published var text = "" {
        didSet { if !loading { scheduleSave() } }
    }
    @Published var compact = false
    @Published var screen: Screen = .capture

    var onSaved: (() -> Void)?
    var onHide: (() -> Void)?
    var requestSync: (() -> Void)?
    @Published var syncStatus: SyncStatus = .unknown
    private var loading = false
    private var saveWork: DispatchWorkItem?
    private var titleCache: [URL: (title: String, mtime: Date)] = [:]
    private var lastNew = Date.distantPast

    init() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        refresh()
        if !UserDefaults.standard.bool(forKey: "onboarded") { screen = .onboarding }
        selected = dailyNote()
    }

    func refresh() {
        let fm = FileManager.default
        var found: [URL] = []
        var dirs: [String] = []
        for item in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                guard item.lastPathComponent != ".git" else { continue }
                dirs.append(item.lastPathComponent)
                found += ((try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.pathExtension == "md" }
            } else if item.pathExtension == "md" {
                found.append(item)
            }
        }
        folders = dirs.sorted()
        notes = found.sorted { modified($0) > modified($1) }
        if let sel = selected, !notes.contains(where: { $0.path == sel.path }) { selected = notes.first }
    }

    // MARK: folders

    func folder(of url: URL) -> String? {
        let parent = url.deletingLastPathComponent()
        return parent.path == dir.path ? nil : parent.lastPathComponent
    }

    func createFolder(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        guard !clean.isEmpty else { return }
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent(clean),
                                                 withIntermediateDirectories: true)
        refresh()
    }

    func move(_ url: URL, to folder: String?) {
        let dest = (folder.map { dir.appendingPathComponent($0) } ?? dir)
            .appendingPathComponent(url.lastPathComponent)
        guard dest.path != url.path else { return }
        try? FileManager.default.moveItem(at: url, to: dest)
        titleCache[url] = nil
        let wasSelected = selected?.path == url.path
        refresh()
        if wasSelected { selected = dest }
    }

    // MARK: notes

    /// One note per day, kept in Daily/; ⌥Space always lands here.
    func dailyNote() -> URL {
        let daily = dir.appendingPathComponent("Daily")
        try? FileManager.default.createDirectory(at: daily, withIntermediateDirectories: true)
        let name = DateFormatter()
        name.dateFormat = "yyyy-MM-dd"
        let url = daily.appendingPathComponent(name.string(from: Date()) + ".md")
        if !FileManager.default.fileExists(atPath: url.path) {
            let header = DateFormatter()
            header.dateFormat = "d MMMM"
            let prefix = UserDefaults.standard.string(forKey: "dailyPrefix") ?? "Daily Notes"
            try? "# \(prefix): \(header.string(from: Date()))\n\n"
                .write(to: url, atomically: true, encoding: .utf8)
            refresh()
        }
        return url
    }

    @discardableResult
    func newNote() -> URL {
        // debounce: reuse a still-empty scratch note or ignore rapid presses
        if let sel = selected, sel.lastPathComponent.hasPrefix("note-"),
           text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            screen = .capture
            return sel
        }
        if Date().timeIntervalSince(lastNew) < 0.7, let sel = selected { return sel }
        lastNew = Date()
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("note-\(stamp).md")
        try? "# ".write(to: url, atomically: true, encoding: .utf8) // start typing the title
        refresh()
        selected = url
        screen = .capture
        return url
    }

    func open(_ url: URL) {
        selected = url
        screen = .capture
    }

    func delete(_ url: URL) {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        titleCache[url] = nil
        refresh()
    }

    // MARK: conflict copies (created by GitSync when both machines edit the same note)

    var conflicts: [URL] {
        notes.filter { $0.lastPathComponent.contains(" (conflict ") }
    }

    func original(for conflictCopy: URL) -> URL? {
        guard let base = conflictCopy.lastPathComponent.components(separatedBy: " (conflict ").first
        else { return nil }
        let url = conflictCopy.deletingLastPathComponent().appendingPathComponent(base + ".md")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Replace the original note with the conflict copy's content, then remove the copy.
    func resolveKeep(_ conflictCopy: URL) {
        guard let orig = original(for: conflictCopy),
              let content = try? String(contentsOf: conflictCopy, encoding: .utf8) else {
            delete(conflictCopy)
            return
        }
        try? content.write(to: orig, atomically: true, encoding: .utf8)
        if selected?.path == orig.path { selected = orig } // reload
        delete(conflictCopy)
        onSaved?()
    }

    /// Keep the original; trash the conflict copy.
    func resolveDiscard(_ conflictCopy: URL) {
        delete(conflictCopy)
        onSaved?()
    }

    func deleteCurrent() {
        if let sel = selected { delete(sel) }
        selected = dailyNote()
    }

    func title(for url: URL) -> String {
        let mt = modified(url)
        if let cached = titleCache[url], cached.mtime == mt { return cached.title }
        let first = (try? String(contentsOf: url, encoding: .utf8))?
            .split(separator: "\n").first.map(String.init) ?? ""
        let clean = first.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces))
        let title = clean.isEmpty ? url.deletingPathExtension().lastPathComponent : clean
        titleCache[url] = (title, mt)
        return title
    }

    func matches(_ query: String) -> [URL] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return notes }
        return notes.filter {
            title(for: $0).lowercased().contains(q) ||
            (q.count >= 2 && ((try? String(contentsOf: $0, encoding: .utf8))?.lowercased().contains(q) ?? false))
        }
    }

    func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    // MARK: load/save — files keep standard markdown; the editor shows ☐/☑ glyphs

    static func fromMarkdown(_ s: String) -> String {
        s.replacingOccurrences(of: #"(?m)^(\s*)- \[ \] "#, with: "$1☐ ", options: .regularExpression)
         .replacingOccurrences(of: #"(?m)^(\s*)- \[x\] "#, with: "$1☑ ", options: .regularExpression)
    }

    static func toMarkdown(_ s: String) -> String {
        s.replacingOccurrences(of: #"(?m)^(\s*)☐ "#, with: "$1- [ ] ", options: .regularExpression)
         .replacingOccurrences(of: #"(?m)^(\s*)☑ "#, with: "$1- [x] ", options: .regularExpression)
    }

    private func loadSelected() {
        loading = true
        let raw = selected.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        text = Self.fromMarkdown(raw)
        loading = false
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func saveNow() {
        guard let url = selected else { return }
        try? Self.toMarkdown(text).write(to: url, atomically: true, encoding: .utf8)
        onSaved?()
    }
}
