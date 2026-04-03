import Foundation
import CoreGraphics

class PathPlanner {
    private let surfaces: SurfaceGraph
    private let topology: DesktopTopology

    init(surfaces: SurfaceGraph, topology: DesktopTopology) {
        self.surfaces = surfaces
        self.topology = topology
    }

    func computeRoute(from start: CGPoint, to goal: CGPoint) -> [MovementCommand] {
        // Very simple for now: jump to a target surface and walk
        if let targetSurface = surfaces.findSurface(at: goal) {
            return [.jump(to: targetSurface), .walk(direction: (goal.x > start.x) ? 1 : -1)]
        }
        return [.walk(direction: (goal.x > start.x) ? 1 : -1)]
    }
}
