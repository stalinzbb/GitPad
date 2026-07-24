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

    /// Double-click the header → minimize to the pill (title-bar convention). Handled at
    /// the window level on purpose: a SwiftUI gesture wide enough to catch the empty
    /// header space would consume mouse-down and kill `isMovableByWindowBackground`
    /// dragging. Events only reach here when no control took them, so the chrome
    /// glyphs keep their own clicks.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, !store.pill, event.locationInWindow.y > frame.height - 42 {
            store.setPill?(true)
            return
        }
        super.mouseDown(with: event)
    }

    // Esc steps back one level; the store owns the hierarchy.
    override func cancelOperation(_ sender: Any?) { store.goBack() }

    private var expandedFrame: NSRect?

    /// Collapse to a 240×40 lozenge (saving the expanded frame) or restore it.
    func applyPill(_ pill: Bool) {
        isMovableByWindowBackground = !pill // pill drags via its own gesture (double-tap = expand)
        let target: NSRect
        let radius: CGFloat
        if pill {
            expandedFrame = frame
            target = NSRect(x: frame.midX - 120, y: frame.maxY - 40, width: 240, height: 40)
            radius = 20 // → height/2
        } else {
            target = expandedFrame ?? NSRect(x: frame.midX - 200, y: frame.midY - 280, width: 400, height: 560)
            radius = 14
        }
        // Order the window first: expanding straight into key means typing works the moment
        // the animation starts, and key state never flips mid-flight.
        if pill { orderFront(nil) } else { makeKeyAndOrderFront(nil) }

        guard !Motion.reduce else {
            contentView?.layer?.cornerRadius = radius
            setFrame(target, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            // snappy: strong ease-out (fast start = responsive), not the mushy built-in
            // easeInEaseOut. The pill toggles often, so it must feel instant.
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            // One CA transaction drives the window AND its content. Previously the full UI was
            // jammed into the 240×40 frame instantly and NSHostingView re-solved layout every
            // frame while animator() grew the window — that re-wrap was the jitter. Laying out
            // once at the target size lets CA interpolate the result instead.
            ctx.allowsImplicitAnimation = true
            contentView?.layer?.cornerRadius = radius
            setFrame(target, display: true)
            contentView?.layoutSubtreeIfNeeded()
        }
    }
}
