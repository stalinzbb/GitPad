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
        // first launch, or a saved pill-sized frame → restore a sane full size
        if frame.width < 300 {
            setContentSize(NSSize(width: 400, height: 560))
            center()
        }
    }

    override var canBecomeKey: Bool { true }

    // Esc steps back one level; the store owns the hierarchy.
    override func cancelOperation(_ sender: Any?) { store.goBack() }

    private var expandedFrame: NSRect?

    /// Collapse to a 240×40 lozenge (saving the expanded frame) or restore it.
    func applyPill(_ pill: Bool) {
        if pill {
            expandedFrame = frame
            let f = NSRect(x: frame.midX - 120, y: frame.maxY - 40, width: 240, height: 40)
            contentView?.layer?.cornerRadius = 20 // → height/2
            setFrame(f, display: true, animate: true)
            orderFront(nil) // floats, but doesn't steal focus
        } else {
            let f = expandedFrame ?? NSRect(x: frame.midX - 200, y: frame.midY - 280, width: 400, height: 560)
            contentView?.layer?.cornerRadius = 14
            setFrame(f, display: true, animate: true)
            makeKeyAndOrderFront(nil)
        }
    }
}
