import Foundation
import AppKit

enum Screen { case onboarding, capture, library, settings, gitSetup, conflicts }

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
    @Published var pill = false
    @Published var screen: Screen = .capture
    // ponytail: per-Mac pins (paths relative to `dir`); move to a .pinned file in the repo if cross-Mac requested
    @Published var pinned: [String] = UserDefaults.standard.stringArray(forKey: "pinned") ?? []
    /// Set by `delete`, cleared by `undoDelete` — drives the "Note deleted — Undo" banner.
    @Published var lastDeleted: (original: URL, trashed: URL, pinned: Bool)?
    private var settingsReturn: Screen = .capture

    /// Open Settings from any screen, remembering where to return.
    func openSettings() {
        if screen != .settings && screen != .gitSetup { settingsReturn = screen }
        screen = .settings
    }

    /// ⌘L: flip between the note and the library (no-op during onboarding).
    func toggleLibrary() {
        switch screen {
        case .library: screen = .capture
        case .onboarding: break
        default: screen = .library
        }
    }

    /// One step back for Esc / the back chevron.
    func goBack() {
        switch screen {
        case .gitSetup: screen = .settings
        case .settings: screen = settingsReturn
        case .library, .conflicts: screen = .capture
        default: onHide?() // capture / onboarding: nothing above → hide
        }
    }

    var onSaved: (() -> Void)?
    var onHide: (() -> Void)?
    var requestSync: (() -> Void)?
    var setPill: ((Bool) -> Void)?
    var pillDrag: (() -> Void)?      // fires on each drag tick; AppDelegate reads the mouse
    var pillDragEnded: (() -> Void)?
    var applyAppearance: ((NSAppearance.Name?) -> Void)?
    @Published var syncStatus: SyncStatus = .unknown
    @Published var syncing = false
    private var loading = false
    private var saveWork: DispatchWorkItem?
    private var titleCache: [URL: (title: String, mtime: Date)] = [:]
    // ponytail: main-thread reads; background index only if libraries hit thousands of notes
    private var contentCache: [URL: (text: String, mtime: Date)] = [:]
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
        // first conflict ever: show the explainer once, and only from Capture so it
        // can't yank the screen out from under someone mid-task
        if !conflicts.isEmpty, screen == .capture,
           !UserDefaults.standard.bool(forKey: "sawConflictIntro") {
            UserDefaults.standard.set(true, forKey: "sawConflictIntro")
            screen = .conflicts
        }
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

    func renameFolder(_ name: String, to newName: String) {
        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        guard !clean.isEmpty, clean != name else { return }
        let fm = FileManager.default
        let dst = dir.appendingPathComponent(clean)
        guard !fm.fileExists(atPath: dst.path) else { return }
        let sel = selected
        try? fm.moveItem(at: dir.appendingPathComponent(name), to: dst)
        titleCache.removeAll(); contentCache.removeAll()
        refresh()
        if let s = sel, s.deletingLastPathComponent().lastPathComponent == name {
            selected = dst.appendingPathComponent(s.lastPathComponent)
        }
    }

    /// Non-destructive: move the folder's notes to the root Inbox, then remove it.
    func deleteFolder(_ name: String) {
        let fm = FileManager.default
        let folder = dir.appendingPathComponent(name)
        for item in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            where item.pathExtension == "md" {
            var dest = dir.appendingPathComponent(item.lastPathComponent)
            if fm.fileExists(atPath: dest.path) {
                dest = dir.appendingPathComponent(name + "-" + item.lastPathComponent)
            }
            try? fm.moveItem(at: item, to: dest)
        }
        try? fm.removeItem(at: folder)
        titleCache.removeAll(); contentCache.removeAll()
        refresh()
    }

    func move(_ url: URL, to folder: String?) {
        let dest = (folder.map { dir.appendingPathComponent($0) } ?? dir)
            .appendingPathComponent(url.lastPathComponent)
        guard dest.path != url.path else { return }
        try? FileManager.default.moveItem(at: url, to: dest)
        titleCache[url] = nil; contentCache[url] = nil
        if let i = pinned.firstIndex(of: rel(url)) { // keep the pin pointing at the new path
            pinned[i] = rel(dest)
            UserDefaults.standard.set(pinned, forKey: "pinned")
        }
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
            header.dateFormat = "EEEE, d MMMM yyyy" // fixed, date-based title (full date for the day it's created)
            try? "# \(header.string(from: Date()))\n\n"
                .write(to: url, atomically: true, encoding: .utf8)
            refresh()
        }
        return url
    }

    /// Create a new note in `folder` (nil = Inbox / repo root). ⌘N passes nil; the
    /// Library's New Note button passes the folder you're browsing.
    @discardableResult
    func newNote(in folder: String? = nil) -> URL {
        // debounce: reuse a still-empty scratch note *in the same folder*, or ignore rapid presses
        if let sel = selected, sel.lastPathComponent.hasPrefix("note-"),
           self.folder(of: sel) == folder,
           text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            screen = .capture
            return sel
        }
        if Date().timeIntervalSince(lastNew) < 0.7, let sel = selected { return sel }
        lastNew = Date()
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let base = folder.map { dir.appendingPathComponent($0) } ?? dir
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent("note-\(stamp).md")
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

    /// Append text to today's note — used by the clipboard menu item and
    /// `gitpad://daily?append=`. If the daily note is open, append into the live
    /// editor buffer so in-flight edits aren't clobbered.
    func appendToDaily(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let url = dailyNote()
        if selected?.path == url.path {
            if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
            text += trimmed + "\n"
            saveNow()
        } else {
            let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let sep = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
            try? (existing + sep + trimmed + "\n").write(to: url, atomically: true, encoding: .utf8)
            contentCache[url] = nil; titleCache[url] = nil
            onSaved?()
            refresh()
        }
    }

    // MARK: pinning

    private func rel(_ url: URL) -> String {
        url.path.hasPrefix(dir.path + "/") ? String(url.path.dropFirst(dir.path.count + 1)) : url.lastPathComponent
    }

    func isPinned(_ url: URL) -> Bool { pinned.contains(rel(url)) }

    func togglePin(_ url: URL) {
        let r = rel(url)
        if let i = pinned.firstIndex(of: r) { pinned.remove(at: i) } else { pinned.append(r) }
        UserDefaults.standard.set(pinned, forKey: "pinned")
    }

    /// Currently-pinned notes that still exist, in pin order.
    func pinnedNotes() -> [URL] {
        pinned.compactMap { r in
            let u = dir.appendingPathComponent(r)
            return notes.contains { $0.path == u.path } ? u : nil
        }
    }

    /// Delete = move to the macOS Trash (already recoverable), and remember where it went
    /// so `undoDelete()` can put it straight back. That's why there's no confirmation
    /// dialog: the slip to protect against is an accidental ⌘⌫, and undo covers it
    /// without taxing every intentional delete.
    func delete(_ url: URL) {
        let wasPinned = isPinned(url)
        var trashed: NSURL?
        try? FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
        if let t = trashed as URL? { lastDeleted = (original: url, trashed: t, pinned: wasPinned) }
        if wasPinned { togglePin(url) } // drop the stale pin; undo restores it
        titleCache[url] = nil; contentCache[url] = nil
        refresh()
    }

    /// Put the last trashed note back where it came from.
    func undoDelete() {
        guard let d = lastDeleted else { return }
        lastDeleted = nil
        let parent = d.original.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        guard (try? FileManager.default.moveItem(at: d.trashed, to: d.original)) != nil else { return }
        if d.pinned, !isPinned(d.original) { togglePin(d.original) }
        refresh()
        selected = d.original
        screen = .capture
        onSaved?() // commit the restore
    }

    // MARK: conflict copies (created by GitSync when both machines edit the same note)

    var conflicts: [URL] {
        notes.filter { $0.lastPathComponent.contains(" (conflict ") }
    }

    /// "…(conflict from Studio 2026-07-23 1200).md" → "Studio". Copies written by
    /// older builds have no device in the name, hence the fallback.
    func conflictDevice(_ conflictCopy: URL) -> String {
        let name = conflictCopy.deletingPathExtension().lastPathComponent
        guard let tail = name.components(separatedBy: " (conflict from ").dropFirst().first
        else { return "another device" }
        let parts = tail.split(separator: " ") // <device…> yyyy-MM-dd HHmm)
        let device = parts.dropLast(2).joined(separator: " ")
        return device.isEmpty ? "another device" : device
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

    /// Keep both versions: rename the copy so it stops reading as a conflict.
    func resolveKeepBoth(_ conflictCopy: URL) {
        let fm = FileManager.default
        let base = conflictCopy.deletingPathExtension().lastPathComponent
            .components(separatedBy: " (conflict").first ?? "note"
        let folder = conflictCopy.deletingLastPathComponent()
        var dest = folder.appendingPathComponent("\(base) (from \(conflictDevice(conflictCopy))).md")
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = folder.appendingPathComponent("\(base) (from \(conflictDevice(conflictCopy)) \(n)).md")
            n += 1
        }
        try? fm.moveItem(at: conflictCopy, to: dest)
        titleCache[conflictCopy] = nil; contentCache[conflictCopy] = nil
        refresh()
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
            (q.count >= 2 && content(of: $0).contains(q))
        }
    }

    /// Lowercased file body, mtime-validated (mirrors `titleCache`) so search
    /// doesn't re-read every file on each keystroke.
    private func content(of url: URL) -> String {
        let mt = modified(url)
        if let c = contentCache[url], c.mtime == mt { return c.text }
        let text = (try? String(contentsOf: url, encoding: .utf8))?.lowercased() ?? ""
        contentCache[url] = (text, mt)
        return text
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
        contentCache[url] = nil // body changed → search re-reads next time
        onSaved?()
    }
}
