import AppKit
import SwiftUI

final class PanelWindow: NSPanel {
    private let store: NoteStore

    init(store: NoteStore) {
        self.store = store
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 560),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered, defer: false)
        isMovableByWindowBackground = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        let host = NSHostingView(rootView: EditorView(store: store))
        host.wantsLayer = true
        host.layer?.cornerRadius = 14
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true
        contentView = host
        setFrameAutosaveName("GitPad.panel")
        if frame.width < 300 { center() } // first launch, no saved frame
    }

    override var canBecomeKey: Bool { true }

    // Esc steps back through the hierarchy: gitSetup → settings → library → capture → hide
    override func cancelOperation(_ sender: Any?) {
        switch store.screen {
        case .gitSetup: store.screen = .settings
        case .settings: store.screen = .library
        case .library: store.screen = .capture
        default: orderOut(nil)
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
