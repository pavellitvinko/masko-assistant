import Foundation

struct BehaviorPolicy {
    let commentCooldown: TimeInterval
    let interestThreshold: Float
    let errorBoost: Float
    let successBoost: Float
    let dedupeOutput: Bool
    let suppressRepeatedContext: Bool
    let requireScreenpipeContext: Bool
    let requireOllamaHealth: Bool

    static let defaultCommentCooldown: TimeInterval = 45
    static let defaultInterestThreshold: Float = 3
    static let defaultErrorBoost: Float = 1.5
    static let defaultSuccessBoost: Float = 0.5

    static func make(
        debugCommentInterestThresholdOverride: Double? = nil
    ) -> BehaviorPolicy {
        let threshold: Float
        if let override = debugCommentInterestThresholdOverride {
            threshold = Float(max(0, min(20, override)))
        } else {
            threshold = defaultInterestThreshold
        }

        return BehaviorPolicy(
            commentCooldown: defaultCommentCooldown,
            interestThreshold: threshold,
            errorBoost: defaultErrorBoost,
            successBoost: defaultSuccessBoost,
            dedupeOutput: true,
            suppressRepeatedContext: true,
            requireScreenpipeContext: true,
            requireOllamaHealth: true
        )
    }
}
