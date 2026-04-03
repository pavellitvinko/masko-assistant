import Foundation

struct MutterLibrary {
    static let phrases: [String: [String]] = [
        "error": ["oof.", "yikes.", "hmm.", "that's not great.", "stack trace again?"],
        "todo": ["still?", "someday.", "we believe in you.", "ignore it?"],
        "stackoverflow": ["classic.", "the oracle.", "been there.", "copy-paste?"],
        "npm": ["here we go.", "patience.", "node_modules grows.", "dependency hell?"],
        "zoom": ["meeting?", "oh.", "here we go.", "...", "mute check!"],
        "slack": ["ping.", "another one.", "mhm.", "distraction?"],
        "youtube": ["research?", "sure.", "heh.", "enjoy the break."],
        "figma": ["ooh.", "pretty.", "nice.", "pixel perfect?"],
        "code": ["curious.", "nice code.", "what's this?", "thinking..."],
        "late_night": ["still?", "you sure?", "zzz.", "go to sleep."],
        "morning": ["morning.", "let's go.", "coffee?", "big day?"],
        "friday": ["weekend soon.", "wrapping up?", "done?"]
    ]
    
    static func lookup(for context: ContextSnapshot) -> String? {
        let text = context.visibleText.lowercased()
        let app = context.appName.lowercased()
        
        if text.contains("error") || text.contains("fail") { return phrases["error"]?.randomElement() }
        if text.contains("todo") { return phrases["todo"]?.randomElement() }
        if app.contains("slack") { return phrases["slack"]?.randomElement() }
        if app.contains("zoom") || app.contains("meet") { return phrases["zoom"]?.randomElement() }
        if app.contains("code") || app.contains("cursor") { return phrases["code"]?.randomElement() }
        
        return phrases.values.randomElement()?.randomElement()
    }
}
