import Foundation

enum Behavior: Int, Codable, CaseIterable {
    // Locomotion
    case walk_on_surface, jump_to_window, climb_window_edge, slide_down, fall_to_dock
    // Idle
    case stand_idle, sit_down, look_around, fidget, yawn, nod_off
    // Play
    case peek_behind_window, hang_from_edge, balance_on_edge, inspect_window, tap_on_window
    // React
    case startle, wave, duck, celebrate
    // Verbal
    case comment, mutter, emote
}

struct BehaviorWeights {
    static func weights(for mood: Mood) -> [Behavior: Float] {
        switch mood {
        case .sleepy:
            return [
                .sit_down: 30, .nod_off: 25, .yawn: 20,
                .stand_idle: 15, .look_around: 5,
                .mutter: 3, .emote: 2
            ]
        case .playful:
            return [
                .walk_on_surface: 15, .jump_to_window: 15, 
                .climb_window_edge: 10, .peek_behind_window: 12,
                .hang_from_edge: 10, .balance_on_edge: 8,
                .tap_on_window: 8, .inspect_window: 5,
                .fidget: 5, .sit_down: 2,
                .comment: 5, .mutter: 3, .emote: 2
            ]
        case .nervous:
            return [
                .look_around: 25, .fidget: 20, .walk_on_surface: 15,
                .peek_behind_window: 10, .duck: 5,
                .stand_idle: 10,
                .comment: 8, .mutter: 5, .emote: 2
            ]
        case .excited:
            return [
                .jump_to_window: 20, .climb_window_edge: 15,
                .walk_on_surface: 10, .celebrate: 5,
                .inspect_window: 15, .tap_on_window: 10,
                .hang_from_edge: 5, .balance_on_edge: 5,
                .comment: 8, .mutter: 5, .emote: 2
            ]
        case .content:
            return [
                .sit_down: 30, .stand_idle: 20, .look_around: 15,
                .walk_on_surface: 10, .mutter: 5, .comment: 3, .emote: 2
            ]
        case .neutral:
            return [
                .walk_on_surface: 20, .stand_idle: 15,
                .sit_down: 15, .look_around: 10,
                .jump_to_window: 8, .fidget: 8,
                .peek_behind_window: 5, .inspect_window: 5,
                .climb_window_edge: 4,
                .comment: 4, .mutter: 3, .emote: 3
            ]
        }
    }
}
