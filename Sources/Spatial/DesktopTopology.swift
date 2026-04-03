import Foundation
import CoreGraphics
import AppKit

enum DockPosition {
    case bottom, left, right, hidden
}

struct WindowInfo: Identifiable {
    let id: CGWindowID
    let title: String
    let appName: String
    let bounds: CGRect
    let isOnScreen: Bool
    let windowLevel: Int32
    let ownerPID: pid_t
}

struct DesktopSnapshot {
    let windows: [WindowInfo]
    let activeWindow: WindowInfo?
    let dockRect: CGRect
    let dockPosition: DockPosition
    let menuBarHeight: CGFloat
    let screenFrame: CGRect
    let visibleFrame: CGRect
    let timestamp: Date
}

class DesktopTopology {
    private(set) var currentSnapshot: DesktopSnapshot?
    private var timer: Timer?

    func startPolling() {
        stopPolling()
        timer = Timer.scheduledTimer(withTimeInterval: Constants.topologyPollInterval, repeats: true) { [weak self] _ in
            self?.update()
        }
        update()
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func update() {
        let snapshot = captureSnapshot()
        self.currentSnapshot = snapshot
    }

    private func captureSnapshot() -> DesktopSnapshot {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let menuBarHeight = NSApplication.shared.mainMenu?.menuBarHeight ?? 24

        // 1. Get window list
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []

        var windows: [WindowInfo] = []
        var activeWindow: WindowInfo?

        // Get the active application PID
        let activeAppPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        for dict in windowList {
            guard let id = dict[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = dict[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  let windowLevel = dict[kCGWindowLayer as String] as? Int32,
                  let ownerPID = dict[kCGWindowOwnerPID as String] as? pid_t else {
                continue
            }

            // Exclude small windows or non-standard levels
            // Level 0 is normal windows.
            if windowLevel != 0 && windowLevel != 3 { continue } // 3 is usually for ToolTips or other small stuff, but let's stick to 0 for now
            if bounds.width < 50 || bounds.height < 50 { continue }

            let title = dict[kCGWindowName as String] as? String ?? ""
            let appName = dict[kCGWindowOwnerName as String] as? String ?? "Unknown"

            let info = WindowInfo(
                id: id,
                title: title,
                appName: appName,
                bounds: bounds,
                isOnScreen: true,
                windowLevel: windowLevel,
                ownerPID: ownerPID
            )

            windows.append(info)

            if ownerPID == activeAppPID && activeWindow == nil {
                activeWindow = info
            }
        }

        // 2. Detect Dock
        let (dockRect, dockPos) = detectDock(screenFrame: screenFrame, visibleFrame: visibleFrame)

        return DesktopSnapshot(
            windows: windows,
            activeWindow: activeWindow,
            dockRect: dockRect,
            dockPosition: dockPos,
            menuBarHeight: menuBarHeight,
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            timestamp: Date()
        )
    }

    private func detectDock(screenFrame: CGRect, visibleFrame: CGRect) -> (CGRect, DockPosition) {
        // Simple heuristic: compare full frame with visible frame
        if visibleFrame.origin.y > screenFrame.origin.y {
            let height = visibleFrame.origin.y - screenFrame.origin.y
            return (CGRect(x: screenFrame.origin.x, y: screenFrame.origin.y, width: screenFrame.width, height: height), .bottom)
        } else if visibleFrame.origin.x > screenFrame.origin.x {
            let width = visibleFrame.origin.x - screenFrame.origin.x
            return (CGRect(x: screenFrame.origin.x, y: screenFrame.origin.y, width: width, height: screenFrame.height), .left)
        } else if visibleFrame.width < screenFrame.width {
            let width = screenFrame.width - visibleFrame.width
            return (CGRect(x: visibleFrame.maxX, y: screenFrame.origin.y, width: width, height: screenFrame.height), .right)
        }
        return (.zero, .hidden)
    }
}
