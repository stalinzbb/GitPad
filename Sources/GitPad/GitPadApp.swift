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
    RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), id, GetApplicationEventTarget(), 0, &ref)
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
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit GitPad", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu

        registerHotkey { [weak self] in self?.togglePanel() }

        store.onSaved = { [weak self] in self?.backgroundSync() }
        syncTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.backgroundSync() }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(syncNow), name: NSWorkspace.didWakeNotification, object: nil)
        backgroundSync()
    }

    @objc func togglePanel() {
        if panel.isKeyWindow {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc func toggleCompact() {
        store.compact.toggle()
        panel.applyCompact(store.compact)
    }

    @objc func syncNow() { backgroundSync() }

    func backgroundSync() {
        let dir = store.dir
        syncQueue.async { [weak self] in
            let ok = GitSync.sync(dir: dir)
            DispatchQueue.main.async {
                self?.statusItem.button?.contentTintColor = ok ? nil : .systemOrange
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
