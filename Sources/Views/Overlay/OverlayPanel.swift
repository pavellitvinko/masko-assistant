import AppKit

/// A transparent, always-on-top, non-focus-stealing panel for the mascot overlay.
/// Stays visible across fullscreen apps, Mission Control, Space switches, and Cmd+Tab.
class OverlayPanel: NSPanel {
    var onRightClick: ((NSPoint) -> Void)?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        titlebarAppearsTransparent = true
        titleVisibility = .hidden

        isFloatingPanel = true
        level = .screenSaver  // level 1000 — above fullscreen apps
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        animationBehavior = .none

        collectionBehavior = [
            .canJoinAllSpaces,           // visible in every Space/desktop
            .fullScreenAuxiliary,        // allowed into fullscreen app Spaces
            .stationary,                 // stay fixed during Mission Control
            .ignoresCycle,               // skip Cmd+` window cycling
            .fullScreenDisallowsTiling,  // prevent macOS 13+ tiling
        ]
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .rightMouseDown, let onRightClick {
            let screenPoint = convertPoint(toScreen: event.locationInWindow)
            onRightClick(screenPoint)
            return
        }
        super.sendEvent(event)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var isExcludedFromWindowsMenu: Bool {
        get { true }
        set { }
    }
}
