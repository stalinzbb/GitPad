import Foundation

enum Screen { case onboarding, capture, library }

final class NoteStore: ObservableObject {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/GitPad")

    @Published var notes: [URL] = []
    @Published var selected: URL? { didSet { loadSelected() } }
    @Published var text = "" {
        didSet { if !loading { scheduleSave() } }
    }
    @Published var compact = false
    @Published var screen: Screen = .capture

    var onSaved: (() -> Void)?
    private var loading = false
    private var saveWork: DispatchWorkItem?
    private var titleCache: [URL: (title: String, mtime: Date)] = [:]

    init() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        refresh()
        if !UserDefaults.standard.bool(forKey: "onboarded") { screen = .onboarding }
        selected = dailyNote()
    }

    func refresh() {
        let urls = ((try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "md" }
        notes = urls.sorted { modified($0) > modified($1) }
        if let sel = selected, !notes.contains(sel) { selected = notes.first }
    }

    /// One note per day; ⌥Space always lands here.
    func dailyNote() -> URL {
        let name = DateFormatter()
        name.dateFormat = "yyyy-MM-dd"
        let url = dir.appendingPathComponent(name.string(from: Date()) + ".md")
        if !FileManager.default.fileExists(atPath: url.path) {
            let header = DateFormatter()
            header.dateFormat = "EEE, MMM d"
            try? "# \(header.string(from: Date()))\n\n".write(to: url, atomically: true, encoding: .utf8)
            refresh()
        }
        return url
    }

    @discardableResult
    func newNote() -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("note-\(stamp).md")
        try? "".write(to: url, atomically: true, encoding: .utf8)
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

    private func loadSelected() {
        loading = true
        text = selected.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
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
        try? text.write(to: url, atomically: true, encoding: .utf8)
        onSaved?()
    }
}
