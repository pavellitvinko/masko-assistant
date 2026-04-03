import Foundation

struct InterestScorer {
    static func score(context: ContextSnapshot) -> Float {
        var score: Float = 0.0
        
        let app = context.appName.lowercased()
        let text = context.visibleText.lowercased()

        // 0. Baseline for substantial on-screen content
        if text.count >= 40 { score += 1.0 }
        
        // 1. App-based interest
        if app.contains("code")
            || app.contains("codex")
            || app.contains("cursor")
            || app.contains("xcode")
            || app.contains("terminal")
            || app.contains("iterm")
            || app.contains("warp")
            || app.contains("vscode")
            || app.contains("visual studio") {
            score += 4.0
        }
        if app.contains("browser") || app.contains("chrome") || app.contains("safari") { score += 2.0 }
        if app.contains("slack") || app.contains("discord") || app.contains("imessage") { score += 1.0 }
        
        // 2. Content-based interest
        if text.contains("error")
            || text.contains("fail")
            || text.contains("exception")
            || text.contains("traceback")
            || text.contains("fatal") {
            score += 4.0
        }
        if text.contains("todo") || text.contains("fixme") { score += 2.0 }
        if text.contains("merge")
            || text.contains("pull request")
            || text.contains("commit")
            || text.contains("branch") {
            score += 2.0
        }
        if text.contains("test")
            || text.contains("build")
            || text.contains("warning")
            || text.contains("lint") {
            score += 2.0
        }
        if text.contains("func ")
            || text.contains("class ")
            || text.contains("import ")
            || text.contains(" let ")
            || text.contains(" var ")
            || text.contains("{")
            || text.contains("}") {
            score += 2.0
        }
        
        // 3. Scale 0-10
        return max(0, min(10, score))
    }
}
