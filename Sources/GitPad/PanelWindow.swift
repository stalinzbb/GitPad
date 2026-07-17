import AppKit
import SwiftUI

final class PanelWindow: NSPanel {
    init(store: NoteStore) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 420),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .resizable],
            backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        contentView = NSHostingView(rootView: EditorView(store: store))
        center()
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }

    func applyCompact(_ compact: Bool) {
        var frame = self.frame
        if compact {
            // pin to top-right corner as a small sticky
            let screen = NSScreen.main?.visibleFrame ?? .zero
            frame = NSRect(x: screen.maxX - 320, y: screen.maxY - 240, width: 300, height: 220)
        } else {
            frame = NSRect(x: frame.midX - 340, y: frame.midY - 210, width: 680, height: 420)
        }
        setFrame(frame, display: true, animate: true)
        if compact { orderFront(nil) } else { makeKeyAndOrderFront(nil) }
    }
}
