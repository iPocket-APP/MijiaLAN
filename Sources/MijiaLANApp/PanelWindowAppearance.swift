import AppKit
import SwiftUI

/// Applies the panel's appearance to the AppKit window hosting SwiftUI.
struct PanelWindowAppearance: NSViewRepresentable {
    let preference: String

    func makeNSView(context: Context) -> AppearanceView {
        let view = AppearanceView()
        view.setPreference(preference)
        return view
    }

    func updateNSView(_ view: AppearanceView, context: Context) {
        view.setPreference(preference)
    }

    final class AppearanceView: NSView {
        private var overrideName: NSAppearance.Name?

        func setPreference(_ preference: String) {
            let name: NSAppearance.Name? = switch preference {
            case "light": .aqua
            case "dark": .darkAqua
            default: nil
            }
            guard name != overrideName else { return }
            overrideName = name
            applyAfterLayout()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyAfterLayout()
        }

        private func applyAfterLayout() {
            // Changing the native appearance invalidates the hosting view's environment.
            DispatchQueue.main.async { [weak self] in
                guard let self, let window, window.appearance?.name != overrideName else { return }
                window.appearance = overrideName.flatMap { NSAppearance(named: $0) }
            }
        }
    }
}
