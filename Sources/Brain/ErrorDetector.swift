import Foundation

struct ErrorDetector {
    static func containsError(_ text: String) -> Bool {
        let patterns = ["error", "fail", "exception", "crash", "bug", "issue", "stack trace", "unhandled"]
        let lowerText = text.lowercased()
        return patterns.contains { lowerText.contains($0) }
    }
    
    static func containsSuccess(_ text: String) -> Bool {
        let patterns = ["success", "passed", "✓", "completed", "done", "fixed"]
        let lowerText = text.lowercased()
        return patterns.contains { lowerText.contains($0) }
    }
}
