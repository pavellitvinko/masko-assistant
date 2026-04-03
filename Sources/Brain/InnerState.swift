import Foundation

enum Mood: Int, Codable {
    case sleepy, nervous, neutral, content, playful, excited
}

struct InnerState: Codable {
    var energy: Float    // 0.0 to 1.0
    var curiosity: Float // 0.0 to 1.0
    var comfort: Float   // 0.0 to 1.0
    
    var mood: Mood {
        if energy < 0.2 { return .sleepy }
        if comfort < 0.3 { return .nervous }
        if curiosity > 0.7 && energy > 0.5 { return .excited }
        if energy > 0.7 { return .playful }
        if comfort > 0.7 { return .content }
        return .neutral
    }
    
    static func initial() -> InnerState {
        return InnerState(energy: 0.6, curiosity: 0.5, comfort: 0.6)
    }
    
    static func restore() -> InnerState {
        if let data = UserDefaults.standard.data(forKey: "mascot_inner_state"),
           let state = try? JSONDecoder().decode(InnerState.self, from: data) {
            return state
        }
        return .initial()
    }
    
    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "mascot_inner_state")
        }
    }
    
    mutating func clamp() {
        energy = max(0, min(1, energy))
        curiosity = max(0, min(1, curiosity))
        comfort = max(0, min(1, comfort))
    }
}
