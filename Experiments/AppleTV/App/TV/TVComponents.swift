#if os(tvOS)
import SwiftUI

enum TVTheme {
    static let background = Color(red: 0.035, green: 0.043, blue: 0.051)
    static let sidebar = Color(red: 0.073, green: 0.082, blue: 0.094)
    static let secondary = Color(white: 0.69)
    static let sage = Color(red: 0.71, green: 0.84, blue: 0.62)
    static let warning = Color(red: 1, green: 0.72, blue: 0.27)
}

struct TVFocusStyle: ButtonStyle {
    enum Kind { case primary, row, navigation(selected: Bool), tile }
    var kind: Kind = .row
    func makeBody(configuration: Configuration) -> some View {
        TVFocusSurface(kind: kind, pressed: configuration.isPressed) { configuration.label }
    }
}

private struct TVFocusSurface<Content: View>: View {
    let kind: TVFocusStyle.Kind
    let pressed: Bool
    @ViewBuilder let content: () -> Content
    @Environment(\.isFocused) private var focused
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    private var base: Color {
        switch kind {
        case .primary, .tile: Color.white.opacity(0.075)
        case .navigation(let selected): selected ? Color.white.opacity(0.12) : .clear
        case .row: .clear
        }
    }
    var body: some View {
        content()
            .foregroundStyle(focused ? Color.black : Color.white)
            .background(focused ? Color.white : base, in: RoundedRectangle(cornerRadius: 22))
            .opacity(enabled ? 1 : 0.36)
            .scaleEffect(pressed ? 0.98 : (focused ? 1.025 : 1))
            .shadow(color: .black.opacity(focused ? 0.2 : 0), radius: 22, y: 10)
            .animation(reducedMotion ? nil : .easeOut(duration: 0.16), value: focused)
            .animation(reducedMotion ? nil : .easeOut(duration: 0.1), value: pressed)
    }
}

struct TVBridgeGlyph: View {
    let running: Bool
    var size: CGFloat = 220
    var body: some View {
        ZStack {
            Image(systemName: "homekit").font(.system(size: size, weight: .light))
            Image(systemName: running ? "checkmark.circle.fill" : "power.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.black, running ? TVTheme.sage : Color(white: 0.48))
                .font(.system(size: size * 0.36, weight: .regular))
                .background(TVTheme.background, in: Circle())
                .offset(x: size * 0.45, y: size * 0.32)
        }.foregroundStyle(.white).frame(width: size * 1.14, height: size * 1.1)
            .accessibilityHidden(true)
    }
}

struct TVActionLabel: View {
    let title: String
    var symbol: String? = nil
    var body: some View {
        HStack(spacing: 16) {
            if let symbol { Image(systemName: symbol) }
            Text(title).fontWeight(.semibold)
        }.font(.system(size: 40)).frame(maxWidth: .infinity).padding(.vertical, 28).padding(.horizontal, 30)
    }
}

struct TVDeviceRow: View {
    let item: TVDeviceItem
    var body: some View {
        HStack(spacing: 28) {
            Image(systemName: item.symbol).font(.system(size: 46, weight: .light)).frame(width: 60)
            VStack(alignment: .leading, spacing: 10) {
                Text(item.name).font(.system(size: 38, weight: .semibold))
                Text("\(item.room) · \(item.status)").font(.system(size: 28)).opacity(0.67)
            }
            Spacer(minLength: 12)
            Image(systemName: "chevron.right").font(.system(size: 24, weight: .medium)).opacity(0.7)
        }.padding(.vertical, 20).padding(.horizontal, 18).contentShape(Rectangle())
    }
}

struct TVInfoRow: View {
    let title: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 32) {
            Text(title).foregroundStyle(TVTheme.secondary)
            Spacer(minLength: 20)
            Text(value).multilineTextAlignment(.trailing)
        }.font(.system(size: 29)).padding(.vertical, 22)
    }
}

struct TVSheetHeading: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.system(size: 56, weight: .semibold))
            Text(subtitle).font(.system(size: 29)).foregroundStyle(TVTheme.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
