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

/// What a Library row needs beyond the title: a preview line and the checklist tally.
struct NoteMeta {
    var snippet = ""
    var done = 0
    var total = 0
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

    /// ⌘K: the command palette overlay (see `CommandPalette`). Rendered above every screen.
    @Published var paletteOpen = false

    /// Library with the search field focused — the palette's "Search Library" command.
    /// The counter is the signal, so it also re-focuses when the Library is already open
    /// (where `onAppear` won't fire again).
    @Published var searchRequest = 0
    func searchNotes() {
        screen = .library
        searchRequest += 1
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
    /// Returns true if the pill was actually dragged. The gesture can't tell: the window
    /// tracks the mouse, so the cursor never moves relative to the pill and the gesture's
    /// own translation stays ~0. Only the AppDelegate sees the screen-space delta.
    var pillDragEnded: (() -> Bool)?
    var applyAppearance: ((NSAppearance.Name?) -> Void)?
    @Published var syncStatus: SyncStatus = .unknown
    @Published var syncing = false
    private var loading = false
    private var saveWork: DispatchWorkItem?
    private var titleCache: [URL: (title: String, mtime: Date)] = [:]
    // ponytail: main-thread reads; background index only if libraries hit thousands of notes
    private var contentCache: [URL: (text: String, mtime: Date)] = [:]
    private var metaCache: [URL: (meta: NoteMeta, mtime: Date)] = [:]
    private var mtimeCache: [URL: Date] = [:]
    private var lastNew = Date.distantPast

    init() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        backfillDailyTitles() // before refresh()/dailyNote(): nothing is loaded yet, so no buffer to clobber
        refresh()
        if !UserDefaults.standard.bool(forKey: "onboarded") { screen = .onboarding }
        selected = dailyNote()
    }

    /// Give every daily note the same date heading, derived from the FILENAME (not today)
    /// so a historical note gets its real day.
    ///
    /// Two cases get rewritten: a note with no heading at all, and one still carrying a
    /// heading an OLDER BUILD generated (`Thursday, 23 July`, `23 July` — no year). Those
    /// stale forms are re-generated from the date and compared as strings, so we only ever
    /// touch text this app wrote itself; a title the user typed can't collide by
    /// construction and is left alone. Idempotent — changed files ride out on the next sync.
    // ponytail: re-reads every Daily file each launch — tiny files; gate behind a flag if launch measurably slows.
    private func backfillDailyTitles() {
        let fm = FileManager.default
        let daily = dir.appendingPathComponent("Daily")
        let parse = DateFormatter()
        parse.dateFormat = "yyyy-MM-dd"
        parse.locale = Locale(identifier: "en_US_POSIX") // filenames are machine-written, never localised
        // display formatters keep the current locale — that's what the old builds wrote in
        let canonical = DateFormatter(); canonical.dateFormat = "EEEE, d MMMM yyyy"
        let staleFmts: [DateFormatter] = ["EEEE, d MMMM", "d MMMM"].map {
            let df = DateFormatter(); df.dateFormat = $0; return df
        }

        for url in (try? fm.contentsOfDirectory(at: daily, includingPropertiesForKeys: nil)) ?? []
            where url.pathExtension == "md" {
            guard let date = parse.date(from: url.deletingPathExtension().lastPathComponent),
                  let body = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let want = "# " + canonical.string(from: date)
            let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
            let firstIdx = lines.firstIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let first = firstIdx.map { lines[$0].trimmingCharacters(in: .whitespaces) }

            let updated: String
            if first == want {
                continue                                   // already canonical
            } else if let first, first.hasPrefix("# ") {
                let stale = staleFmts.map { "# " + $0.string(from: date) }
                guard stale.contains(first), let i = firstIdx else { continue } // user's own title
                var out = lines
                out[i] = Substring(want)
                updated = out.joined(separator: "\n")
            } else {
                updated = want + "\n\n" + body             // no heading at all → prepend one
            }
            try? updated.write(to: url, atomically: true, encoding: .utf8)
            uncache(url)
        }
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
        // stat once per file, not once per sort comparison; a whole rebuild also picks up
        // sync pulls and external edits that the cache would otherwise hold stale
        var stamps: [URL: Date] = [:]
        for u in found { stamps[u] = Self.stat(u) }
        mtimeCache = stamps
        notes = found.sorted { (stamps[$0] ?? .distantPast) > (stamps[$1] ?? .distantPast) }
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
        uncacheAll()
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
        uncacheAll()
        refresh()
    }

    func move(_ url: URL, to folder: String?) {
        let dest = (folder.map { dir.appendingPathComponent($0) } ?? dir)
            .appendingPathComponent(url.lastPathComponent)
        guard dest.path != url.path else { return }
        try? FileManager.default.moveItem(at: url, to: dest)
        uncache(url)
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
            uncache(url)
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
        uncache(url)
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
        uncache(orig) // the original's body just changed — every cached read of it is stale
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
        uncache(conflictCopy)
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

    /// Library row data: first body line + checklist tally, mtime-validated like
    /// `titleCache` (one read on a miss, none while the file is unchanged).
    func meta(for url: URL) -> NoteMeta {
        let mt = modified(url)
        if let c = metaCache[url], c.mtime == mt { return c.meta }
        let m = Self.parseMeta((try? String(contentsOf: url, encoding: .utf8)) ?? "")
        metaCache[url] = (m, mt)
        return m
    }

    /// Pure so `GitPad --selftest` can check it without touching the notes directory.
    static func parseMeta(_ body: String) -> NoteMeta {
        var m = NoteMeta()
        for raw in body.split(separator: "\n").dropFirst() { // first non-empty line is the title
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- [x] ") { m.done += 1; m.total += 1 }
            else if line.hasPrefix("- [ ] ") { m.total += 1 }
            guard m.snippet.isEmpty else { continue }
            line = line.trimmingCharacters(in: CharacterSet(charactersIn: "#-*+> "))
            if line.hasPrefix("[x] ") || line.hasPrefix("[ ] ") { line.removeFirst(4) }
            if !line.isEmpty { m.snippet = line }
        }
        return m
    }

    /// Drop every cached read of `url` — call wherever a file moves or is rewritten.
    private func uncache(_ url: URL) {
        titleCache[url] = nil; contentCache[url] = nil; metaCache[url] = nil; mtimeCache[url] = nil
    }

    private func uncacheAll() {
        titleCache.removeAll(); contentCache.removeAll(); metaCache.removeAll(); mtimeCache.removeAll()
    }

    /// Case- and diacritic-insensitive, so "cafe" finds "Café" and "Cafe".
    static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }

    /// Smart-lite search: split the query on whitespace and keep a note only if EVERY token
    /// hits its title or its body — so "groc milk" finds the note titled "Groceries" that
    /// mentions milk. Results rank title matches above body-only ones; within a tier the
    /// caller's mtime order survives.
    func matches(_ query: String) -> [URL] {
        let q = Self.fold(query.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return notes }
        let tokens = q.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return notes }

        var ranked: [(url: URL, tier: Int)] = []
        for url in notes {
            let t = Self.fold(title(for: url))
            if tokens.allSatisfy({ t.contains($0) }) {
                ranked.append((url, t.contains(q) ? 0 : 1)) // whole phrase in title beats scattered tokens
            } else {
                // a 1-char token is too noisy to run against whole bodies (the original guard)
                let body = content(of: url)
                guard tokens.allSatisfy({ t.contains($0) || ($0.count >= 2 && body.contains($0)) })
                else { continue }
                ranked.append((url, 2))
            }
        }
        // pair with the original index so equal tiers keep `notes` order (sorted isn't stable)
        return ranked.enumerated()
            .sorted { ($0.element.tier, $0.offset) < ($1.element.tier, $1.offset) }
            .map(\.element.url)
    }

    /// Folded file body, mtime-validated (mirrors `titleCache`) so search
    /// doesn't re-read every file on each keystroke.
    private func content(of url: URL) -> String {
        let mt = modified(url)
        if let c = contentCache[url], c.mtime == mt { return c.text }
        let text = Self.fold((try? String(contentsOf: url, encoding: .utf8)) ?? "")
        contentCache[url] = (text, mt)
        return text
    }

    /// Stat once, then serve from memory. `refresh()`'s sort and every Library render call
    /// this dozens of times per pass, and it also gates the title/content/meta caches.
    // ponytail: an external edit stays stale until the next refresh(), which re-stats everything.
    func modified(_ url: URL) -> Date {
        if let d = mtimeCache[url] { return d }
        let d = Self.stat(url)
        mtimeCache[url] = d
        return d
    }

    private static func stat(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    // MARK: load/save — files keep standard markdown; the editor shows ☐/☑ glyphs

    static func fromMarkdown(_ s: String) -> String {
        // tolerant on read (`* [X]` from other editors); toMarkdown writes canonical `- [ ]`/`- [x]`
        s.replacingOccurrences(of: #"(?m)^(\s*)[-*+] \[ \] "#, with: "$1☐ ", options: .regularExpression)
         .replacingOccurrences(of: #"(?m)^(\s*)[-*+] \[[xX]\] "#, with: "$1☑ ", options: .regularExpression)
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
        uncache(url) // body changed → search/snippet re-read next time
        onSaved?()
    }
}
