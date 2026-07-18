import AppKit
import SwiftUI

final class PanelWindow: NSPanel {
    private let store: NoteStore

    init(store: NoteStore) {
        self.store = store
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 560),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .resizable],
            backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        [.closeButton, .miniaturizeButton, .zoomButton].forEach {
            standardWindowButton($0)?.isHidden = true
        }
        let host = NSHostingView(rootView: EditorView(store: store))
        host.wantsLayer = true
        host.layer?.cornerRadius = 14
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true
        contentView = host
        center()
    }

    override var canBecomeKey: Bool { true }

    // Esc steps back: library/settings → capture, then hide
    override func cancelOperation(_ sender: Any?) {
        if store.screen == .library || store.screen == .settings {
            store.screen = .capture
        } else {
            orderOut(nil)
        }
    }

    func applyCompact(_ compact: Bool) {
        var frame = self.frame
        if compact {
            let screen = NSScreen.main?.visibleFrame ?? .zero
            frame = NSRect(x: screen.maxX - 320, y: screen.maxY - 240, width: 300, height: 220)
        } else {
            frame = NSRect(x: frame.midX - 200, y: frame.midY - 280, width: 400, height: 560)
        }
        setFrame(frame, display: true, animate: true)
        if compact { orderFront(nil) } else { makeKeyAndOrderFront(nil) }
    }
}
