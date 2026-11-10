import QuartzCore
import SwiftUI

/// One motion language for page navigation and the menu-bar panel itself.
enum PanelMotion {
    static let duration: TimeInterval = 0.24
    static let animation = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: duration)
    static var timingFunction: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
    }

    @MainActor
    static func animate(reducedMotion: Bool, _ changes: () -> Void, completion: @escaping @MainActor () -> Void) {
        let animation = reducedMotion ? nil : Self.animation
        if #available(macOS 14.0, *) {
            withAnimation(animation, completionCriteria: .logicallyComplete, changes) { completion() }
        } else {
            withAnimation(animation, changes)
            // Completions only record diagnostics. The view state changes in the transaction above.
            if reducedMotion { completion() }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: completion) }
        }
    }
}

private struct PanelPresentedKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var panelPresented: Bool {
        get { self[PanelPresentedKey.self] }
        set { self[PanelPresentedKey.self] = newValue }
    }
}
