import AppKit
import SwiftUI
import Carbon.HIToolbox

private var hotkeyHandler: (() -> Void)?

func registerHotkey(_ handler: @escaping () -> Void) {
    hotkeyHandler = handler
    var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
        hotkeyHandler?()
        return noErr
    }, 1, &eventType, nil, nil)
    var ref: EventHotKeyRef?
    let id = EventHotKeyID(signature: OSType(0x47504144), id: 1) // "GPAD"
    let status = RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), id, GetApplicationEventTarget(), 0, &ref)
    NSLog("GitPad: hotkey register status=%d", status)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = NoteStore()
    var panel: PanelWindow!
    var statusItem: NSStatusItem!
    var syncTimer: Timer?
    private let syncQueue = DispatchQueue(label: "gitpad.sync")

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = PanelWindow(store: store)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "GitPad")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open  (⌥Space)", action: #selector(togglePanel), keyEquivalent: "")
        menu.addItem(withTitle: "Compact Mode", action: #selector(toggleCompact), keyEquivalent: "")
        menu.addItem(withTitle: "Sync Now", action: #selector(syncNow), keyEquivalent: "")
        menu.addItem(withTitle: "Set Remote…", action: #selector(setRemote), keyEquivalent: "")
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit GitPad", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu

        registerHotkey { [weak self] in self?.togglePanel() }

        store.onSaved = { [weak self] in self?.backgroundSync() }
        store.onHide = { [weak self] in self?.panel.orderOut(nil) }
        store.requestSync = { [weak self] in self?.backgroundSync() }
        syncTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.backgroundSync() }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(syncNow), name: NSWorkspace.didWakeNotification, object: nil)
        backgroundSync()

        // show the panel on first launch so opening the app isn't a no-op
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // double-clicking the app (or `open`) while running shows the panel
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return false
    }

    @objc func togglePanel() {
        if panel.isKeyWindow {
            panel.orderOut(nil)
        } else {
            if store.screen != .onboarding {
                store.screen = .capture
                store.selected = store.dailyNote() // ⌥Space always lands on today
            }
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc func toggleCompact() {
        store.compact.toggle()
        panel.applyCompact(store.compact)
    }

    @objc func syncNow() { backgroundSync() }

    @objc func showSettings() {
        store.screen = .settings
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func backgroundSync() {
        let dir = store.dir
        syncQueue.async { [weak self] in
            let hasRemote = GitSync.run(["remote", "get-url", "origin"], in: dir).status == 0
            let ok = GitSync.sync(dir: dir)
            DispatchQueue.main.async {
                self?.statusItem.button?.contentTintColor = (ok || !hasRemote) ? nil : .systemOrange
                self?.store.syncStatus = !hasRemote ? .noRemote : ok ? .synced(Date()) : .offline
                self?.store.refresh() // pick up files pulled from remote
            }
        }
    }

    @objc func setRemote() {
        let alert = NSAlert()
        alert.messageText = "Git remote URL"
        alert.informativeText = "SSH URL of your private notes repo, e.g. git@github.com:you/notes.git"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.stringValue = GitSync.run(["remote", "get-url", "origin"], in: store.dir).out
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            GitSync.setRemote(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), in: store.dir)
            backgroundSync()
        }
    }
}
