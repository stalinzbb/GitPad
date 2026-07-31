import AppKit
import SwiftUI

final class PanelWindow: NSPanel {
    private let store: NoteStore

    init(store: NoteStore) {
        self.store = store
        super.init(
            contentRect: NSRect(origin: .zero, size: PanelMetrics.size),
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
        host.layer?.cornerRadius = Radius.panel
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true
        contentView = host
        setFrameAutosaveName("GitPad.panel")
        // first launch, or a saved pill-sized frame → restore a sane full size
        if frame.width < 300 {
            setContentSize(PanelMetrics.size)
            center()
        }
        // Unplugging a display leaves the panel offscreen, or lets the OS resize a
        // borderless window it thinks it's restoring. Never removed: the panel lives
        // for the app lifetime (isReleasedWhenClosed = false).
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    /// Nudge `r` back inside the current screen's visible area, keeping its size.
    private func clamped(_ r: NSRect) -> NSRect {
        guard let v = (screen ?? NSScreen.main)?.visibleFrame else { return r }
        return NSRect(x: max(v.minX, min(r.minX, v.maxX - r.width)),
                      y: max(v.minY, min(r.minY, v.maxY - r.height)),
                      width: r.width, height: r.height)
    }

    /// Screens changed → put the window back where it belongs. Idempotent and
    /// unanimated: this is a correction, not a gesture, and it can fire several times
    /// per plug/unplug. Never routes through `applyPill` — that would cache the
    /// mangled frame as the expanded one.
    @objc private func screensChanged() {
        if let e = expandedFrame { expandedFrame = clamped(e) }
        if store.pill {
            // the OS may have resized the pill; re-derive its rect from the current position
            setFrame(clamped(pillRect()), display: true)
        } else {
            setFrame(clamped(frame), display: true)
        }
    }

    override var canBecomeKey: Bool { true }

    /// Double-click the header → minimize to the pill (title-bar convention). Handled at
    /// the window level on purpose: a SwiftUI gesture wide enough to catch the empty
    /// header space would consume mouse-down and kill `isMovableByWindowBackground`
    /// dragging. Events only reach here when no control took them, so the chrome
    /// glyphs keep their own clicks.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, !store.pill, event.locationInWindow.y > frame.height - PanelMetrics.headerHeight {
            store.setPill?(true)
            return
        }
        super.mouseDown(with: event)
    }

    // Esc steps back one level; the store owns the hierarchy.
    override func cancelOperation(_ sender: Any?) { store.goBack() }

    private var expandedFrame: NSRect?

    /// The pill, hung from the current window's top edge and horizontally centred on it.
    private func pillRect() -> NSRect {
        NSRect(x: frame.midX - PanelMetrics.pillSize.width / 2,
               y: frame.maxY - PanelMetrics.pillSize.height,
               width: PanelMetrics.pillSize.width, height: PanelMetrics.pillSize.height)
    }

    /// Collapse to a 240×40 lozenge (saving the expanded frame) or restore it.
    func applyPill(_ pill: Bool) {
        isMovableByWindowBackground = !pill // pill drags via its own gesture (double-tap = expand)
        let target: NSRect
        let radius: CGFloat
        if pill {
            expandedFrame = frame
            target = clamped(pillRect())
            radius = Radius.pill // → height/2
        } else {
            target = clamped(expandedFrame ?? NSRect(x: frame.midX - PanelMetrics.size.width / 2,
                                                     y: frame.midY - PanelMetrics.size.height / 2,
                                                     width: PanelMetrics.size.width,
                                                     height: PanelMetrics.size.height))
            radius = Radius.panel
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
            ctx.duration = Motion.pillDuration
            ctx.timingFunction = Motion.pillCA
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
