import Combine
import SwiftUI

enum ControlCenterRoute: Hashable {
    case home
    case device(String)
    case settings
    case settingsHomeKit
    case settingsDevices
    case settingsImport
    case settingsManualAdd

    var depth: Int {
        switch self {
        case .home: 0
        case .device, .settings: 1
        default: 2
        }
    }

    var diagnosticName: String {
        switch self {
        case .home: "home"
        case .device: "device"
        case .settings: "settings"
        case .settingsHomeKit: "homekit"
        case .settingsDevices: "devices"
        case .settingsImport: "import"
        case .settingsManualAdd: "manual"
        }
    }
}

/// Only small presentation values survive an idle panel. Never store a view,
/// hosting controller, command writer or closure capturing a view here.
@MainActor
final class PanelSession: ObservableObject {
    @Published var route: ControlCenterRoute
    @Published var selectedOffline: String?
    let manual = PanelManualDraft()
    @Published private var expanded: [String: Set<String>] = [:]
    var layouts: [ControlCenterRoute: PanelPageLayout] = [:]
    // Scroll updates must not invalidate the page or its layout while scrolling.
    var scrollOffsets: [ControlCenterRoute: CGFloat] = [:]
    private var numberDrafts: [String: [String: PanelNumberDraft]] = [:]

    init(route: ControlCenterRoute = .home) { self.route = route }

    func numberDraft(deviceID: String, capabilityID: String) -> PanelNumberDraft {
        if let existing = numberDrafts[deviceID]?[capabilityID] { return existing }
        let draft = PanelNumberDraft()
        numberDrafts[deviceID, default: [:]][capabilityID] = draft
        return draft
    }

    func expansion(deviceID: String, section: String) -> Binding<Bool> {
        Binding(get: { self.expanded[deviceID]?.contains(section) == true }, set: { value in
            if value { self.expanded[deviceID, default: []].insert(section) }
            else { self.expanded[deviceID]?.remove(section) }
        })
    }

    func prune(deviceIDs: Set<String>) {
        let valid: (ControlCenterRoute) -> Bool = {
            if case .device(let id) = $0 { return deviceIDs.contains(id) }
            return true
        }
        layouts = layouts.filter { valid($0.key) }
        scrollOffsets = scrollOffsets.filter { valid($0.key) }
        numberDrafts = numberDrafts.filter { deviceIDs.contains($0.key) }
        let retainedExpansions = expanded.filter { deviceIDs.contains($0.key) }
        if retainedExpansions != expanded { expanded = retainedExpansions }
        if let selectedOffline, !deviceIDs.contains(selectedOffline) { self.selectedOffline = nil }
        if !valid(route) { route = .home }
    }
}

@MainActor
final class PanelManualDraft: ObservableObject {
    @Published var host = ""
    @Published var token = ""
    @Published var name = ""
    @Published var submitted = false
    @Published var confirmation: String?
}

@MainActor
final class PanelNumberDraft: ObservableObject {
    @Published var text = ""
    @Published var isEditing = false
    @Published var validationError: String?
}

struct PanelPageLayout: Equatable {
    let contentHeight: CGFloat
    let headerHeight: CGFloat
    let footerHeight: CGFloat
    var viewportHeight: CGFloat {
        min(max(contentHeight, 90), max(90, PanelView.maxHeight - headerHeight - footerHeight))
    }
    var totalHeight: CGFloat { headerHeight + viewportHeight + footerHeight }
}

struct PanelDisclosure<Content: View>: View {
    let title: String
    let deviceID: String
    let section: String
    @ViewBuilder var content: () -> Content
    @EnvironmentObject private var session: PanelSession

    init(_ title: String, deviceID: String, section: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.deviceID = deviceID; self.section = section; self.content = content
    }

    var body: some View {
        DisclosureGroup(title, isExpanded: session.expansion(deviceID: deviceID, section: section),
                        content: content)
    }
}
