import Foundation
import CoreGraphics

enum SurfaceType: String {
    case windowTop
    case dockTop
    case menuBarBottom
    case screenBottom
}

struct Surface {
    let rect: CGRect
    let type: SurfaceType
    let windowID: CGWindowID?
    let appName: String?
}

class SurfaceGraph {
    private(set) var surfaces: [Surface] = []

    func update(with snapshot: DesktopSnapshot) {
        var newSurfaces: [Surface] = []

        // 1. Menu bar bottom edge
        let menuBarRect = CGRect(x: snapshot.screenFrame.origin.x, y: snapshot.screenFrame.origin.y + snapshot.screenFrame.height - snapshot.menuBarHeight, width: snapshot.screenFrame.width, height: 1)
        newSurfaces.append(Surface(rect: menuBarRect, type: .menuBarBottom, windowID: nil, appName: "System"))

        // 2. Window top edges
        for window in snapshot.windows {
            // Only consider windows with a decent title or known app
            // A walkable surfaces is the top edge (title bar area)
            let topEdge = CGRect(x: window.bounds.origin.x, y: window.bounds.origin.y + window.bounds.height - 2, width: window.bounds.width, height: 2)
            newSurfaces.append(Surface(rect: topEdge, type: .windowTop, windowID: window.id, appName: window.appName))
        }

        // 3. Dock top edge
        if snapshot.dockPosition != .hidden {
            let dockTop = CGRect(x: snapshot.dockRect.origin.x, y: snapshot.dockRect.origin.y + snapshot.dockRect.height - 2, width: snapshot.dockRect.width, height: 2)
            newSurfaces.append(Surface(rect: dockTop, type: .dockTop, windowID: nil, appName: "Dock"))
        }

        // 4. Screen bottom
        let screenBottom = CGRect(x: snapshot.screenFrame.origin.x, y: snapshot.screenFrame.origin.y, width: snapshot.screenFrame.width, height: 2)
        newSurfaces.append(Surface(rect: screenBottom, type: .screenBottom, windowID: nil, appName: "Desktop"))

        // Sort by Y coordinate (bottom to top)
        self.surfaces = newSurfaces.sorted { $0.rect.origin.y < $1.rect.origin.y }
    }

    func findSurface(at point: CGPoint) -> Surface? {
        // Return the first surface that contains the X coordinate and is directly below the Y coordinate
        // This is a simplified search
        for surface in surfaces.reversed() {
            if point.x >= surface.rect.origin.x && point.x <= surface.rect.maxX && surface.rect.origin.y <= point.y + 5 {
                return surface
            }
        }
        return nil
    }
}
