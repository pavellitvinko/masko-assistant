import Foundation

struct ContextNudger {
    static func nudge(state: inout InnerState, with context: ContextSnapshot) {
        let text = context.visibleText.lowercased()
        let app = context.appName.lowercased()
        
        // Errors -> comfort drops, curiosity spikes
        if text.contains("error") || text.contains("fail") || text.contains("exception") {
            state.comfort -= 0.15
            state.curiosity += 0.2
        }
        
        // Meetings/Zoom -> energy drops
        if app.contains("zoom") || app.contains("meet") || app.contains("teams") {
            state.energy -= 0.05
        }
        
        // Creative apps (Figma, music) -> comfort rises
        let creativeApps = ["figma", "sketch", "logic", "ableton", "illustrator", "photoshop"]
        if creativeApps.contains(where: { app.contains($0) }) {
            state.comfort += 0.05
        }
        
        // Browsing fun stuff -> energy rises
        if text.contains("youtube") || text.contains("reddit") || text.contains("twitter") || text.contains("x.com") {
            state.energy += 0.1
            state.curiosity += 0.1
        }
        
        // Natural energy decay
        state.energy -= 0.01
        
        // Late night nudge
        let hour = Calendar.current.component(.hour, from: Date())
        if hour >= 22 || hour <= 4 {
            state.energy -= 0.03
        }
        
        state.clamp()
    }
}
