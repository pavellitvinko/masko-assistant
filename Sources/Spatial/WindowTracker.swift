import Foundation
import CoreGraphics

enum WindowEventType {
    case appSwitch(from: String?, to: String)
    case windowMoved(WindowInfo, delta: CGFloat)
    case windowAppeared(WindowInfo)
    case windowDisappeared(WindowInfo)
}

class WindowTracker {
    private var lastSnapshot: DesktopSnapshot?
    var onEvent: ((WindowEventType) -> Void)?

    func update(with snapshot: DesktopSnapshot) {
        defer { lastSnapshot = snapshot }
        guard let last = lastSnapshot else { return }

        // 1. App Switch
        if last.activeWindow?.appName != snapshot.activeWindow?.appName,
           let to = snapshot.activeWindow?.appName {
            onEvent?(.appSwitch(from: last.activeWindow?.appName, to: to))
        }

        // 2. Window diffs
        let lastIDs = Set(last.windows.map { $0.id })
        let currentIDs = Set(snapshot.windows.map { $0.id })

        // 2.1 Appeared
        for id in currentIDs.subtracting(lastIDs) {
            if let window = snapshot.windows.first(where: { $0.id == id }) {
                onEvent?(.windowAppeared(window))
            }
        }

        // 2.2 Disappeared
        for id in lastIDs.subtracting(currentIDs) {
            if let window = last.windows.first(where: { $0.id == id }) {
                onEvent?(.windowDisappeared(window))
            }
        }

        // 2.3 Moved
        for id in currentIDs.intersection(lastIDs) {
            if let lastWin = last.windows.first(where: { $0.id == id }),
               let currentWin = snapshot.windows.first(where: { $0.id == id }) {
                
                let dx = currentWin.bounds.origin.x - lastWin.bounds.origin.x
                let dy = currentWin.bounds.origin.y - lastWin.bounds.origin.y
                let distance = sqrt(dx*dx + dy*dy)
                
                if distance > 20 {
                    onEvent?(.windowMoved(currentWin, delta: distance))
                }
            }
        }
    }
}
