import Foundation

final class NoteStore: ObservableObject {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/GitPad")

    @Published var notes: [URL] = []
    @Published var selected: URL? { didSet { loadSelected() } }
    @Published var text = "" {
        didSet { if !loading { scheduleSave() } }
    }
    @Published var compact = false

    var onSaved: (() -> Void)?
    private var loading = false
    private var saveWork: DispatchWorkItem?

    init() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        refresh()
        selected = notes.first ?? newNote()
    }

    func refresh() {
        let urls = ((try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "md" }
        notes = urls.sorted { mtime($0) > mtime($1) }
        if let sel = selected, !notes.contains(sel) { selected = notes.first }
    }

    @discardableResult
    func newNote() -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("note-\(stamp).md")
        try? "".write(to: url, atomically: true, encoding: .utf8)
        refresh()
        selected = url
        return url
    }

    func delete(_ url: URL) {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        refresh()
    }

    func title(for url: URL) -> String {
        let first = (try? String(contentsOf: url, encoding: .utf8))?
            .split(separator: "\n").first.map(String.init) ?? ""
        let clean = first.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces))
        return clean.isEmpty ? url.deletingPathExtension().lastPathComponent : clean
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

    private func mtime(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
