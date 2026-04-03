import Foundation

class FallbackPerception {
    private let topology: DesktopTopology

    init(topology: DesktopTopology) {
        self.topology = topology
    }

    func snapshot() -> ContextSnapshot {
        let active = topology.currentSnapshot?.activeWindow
        return ContextSnapshot(
            appName: active?.appName ?? "None",
            windowTitle: active?.title ?? "",
            visibleText: "",
            timestamp: Date(),
            source: .windowList
        )
    }
}
