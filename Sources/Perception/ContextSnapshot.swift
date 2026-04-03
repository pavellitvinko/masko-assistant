import Foundation

enum PerceptionSource: String, Codable {
    case screenpipe, windowList, none
}

enum ServiceHealth: String, Codable {
    case connected
    case degraded
    case offline

    var displayText: String {
        switch self {
        case .connected:
            return "Connected"
        case .degraded:
            return "Degraded"
        case .offline:
            return "Offline"
        }
    }
}

struct ContextSnapshot: Codable {
    let appName: String
    let windowTitle: String
    let visibleText: String  // truncated to 500 chars
    let timestamp: Date
    let source: PerceptionSource
}
