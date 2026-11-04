import SwiftUI

/// The Haptics switch in Settings, read as each tick is about to play, so turning it off stops
/// every one at once.
enum Haptics {
    static var isOn = true
}

extension View {
    /// `sensoryFeedback`, silent while Haptics is off.
    func haptic<T: Equatable>(_ feedback: SensoryFeedback, trigger: T) -> some View {
        sensoryFeedback(feedback, trigger: trigger) { _, _ in Haptics.isOn }
    }

    func haptic<T: Equatable>(
        _ feedback: SensoryFeedback, trigger: T, condition: @escaping (T, T) -> Bool
    ) -> some View {
        sensoryFeedback(feedback, trigger: trigger) { old, new in Haptics.isOn && condition(old, new) }
    }
}
