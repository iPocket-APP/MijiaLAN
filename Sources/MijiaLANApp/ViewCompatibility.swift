import AppKit
import SwiftUI

extension View {
    @ViewBuilder
    func onValueChange<Value: Equatable>(of value: Value, initial: Bool = false, _ action: @escaping (Value) -> Void) -> some View {
        if #available(macOS 14.0, *) {
            onChange(of: value, initial: initial) { _, newValue in action(newValue) }
        } else if initial {
            modifier(InitialValueChange(value: value, action: action))
        } else {
            onChange(of: value, perform: action)
        }
    }

    @ViewBuilder
    func onHorizontalMove(_ adjust: @escaping (Double) -> Void) -> some View {
        if #available(macOS 14.0, *) {
            onKeyPress(.leftArrow) { adjust(-1); return .handled }
                .onKeyPress(.rightArrow) { adjust(1); return .handled }
        } else {
            onMoveCommand { direction in
                switch direction {
                case .left: adjust(-1)
                case .right: adjust(1)
                default: break
                }
            }
        }
    }

    @ViewBuilder
    func panelWindowBackground(_ color: Color) -> some View {
        if #available(macOS 15.0, *) {
            containerBackground(color, for: .window)
        } else {
            self
        }
    }
}

private struct InitialValueChange<Value: Equatable>: ViewModifier {
    let value: Value
    let action: (Value) -> Void
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard !appeared else { return }
                appeared = true
                action(value)
            }
            .onChange(of: value, perform: action)
    }
}

extension NSApplication {
    func activateForUserAction() {
        if #available(macOS 14.0, *) {
            activate()
        } else {
            activate(ignoringOtherApps: true)
        }
    }
}
