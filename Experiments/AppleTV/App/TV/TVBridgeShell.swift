#if os(tvOS)
import SwiftUI

enum TVDestination: String, CaseIterable, Identifiable {
    case overview = "总览", devices = "设备", bridge = "家庭桥接", settings = "设置"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .overview: "house"; case .devices: "square.grid.2x2"; case .bridge: "homekit"; case .settings: "gearshape" }
    }
    var accessibilityID: String {
        switch self { case .overview: "overview"; case .devices: "devices"; case .bridge: "bridge"; case .settings: "settings" }
    }
}

enum TVSheet: Identifiable {
    case device(String), pairing, configuration
    var id: String {
        switch self { case .device(let id): "device.\(id)"; case .pairing: "pairing"; case .configuration: "configuration" }
    }
}

struct TVBridgeShell: View {
    @State private var home: TVHomePresentation
    @State private var updates: TVUpdateModel
    @State private var destination = TVDestination.overview
    @State private var sheet: TVSheet?
    @State private var showingDiagnostics = false
    @State private var showingUpdates = false
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var focus: Focus?
    private enum Focus: Hashable { case navigation(TVDestination), manageBridge, bridgeAction }

    init(model: TunnelModel, isDesignPreview: Bool = false) {
        _home = State(initialValue: TVHomePresentation(tunnel: model, isDesignPreview: isDesignPreview))
        _updates = State(initialValue: TVUpdateModel(preview: isDesignPreview))
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                sidebar.frame(width: min(360, geometry.size.width * 0.19))
                Group {
                    switch destination {
                    case .overview: overview
                    case .devices:
                        TVDevicesPage(home: home, openDevice: { sheet = .device($0) }, configure: { sheet = .configuration })
                    case .bridge:
                        TVBridgePage(home: home, actionFocus: $focus, actionValue: .bridgeAction,
                                     pair: { sheet = .pairing }, diagnostics: { showingDiagnostics = true })
                    case .settings:
                        TVSettingsPage(home: home, configure: { sheet = .configuration }, diagnostics: { showingDiagnostics = true },
                                       updates: { showingUpdates = true }, updateAvailable: updates.release != nil)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }.background(TVTheme.background).ignoresSafeArea()
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .defaultFocus($focus, .manageBridge)
        .onChange(of: destination) {
            if destination == .overview { focus = .manageBridge }
            if destination == .bridge { focus = .bridgeAction }
        }
        .onExitCommand(perform: destination == .overview && !home.isDesignPreview ? nil : { destination = .overview })
        .onOpenURL { url in
            #if DEBUG
            // Local preview navigation is limited to the explicit sample-data mode.
            // It cannot configure devices, control live devices, or start a VPN.
            guard home.isDesignPreview, url.scheme == "mijialantv-preview", url.host == "navigate" else { return }
            if url.path == "/diagnostics" { sheet = nil; showingUpdates = false; showingDiagnostics = true; return }
            if url.path == "/updates" { sheet = nil; showingDiagnostics = false; showingUpdates = true; return }
            guard let page = TVDestination.allCases.first(where: { "/" + $0.accessibilityID == url.path }) else { return }
            showingDiagnostics = false
            showingUpdates = false
            sheet = nil
            destination = page
            focus = page == .overview ? .manageBridge : (page == .bridge ? .bridgeAction : .navigation(page))
            #endif
        }
        .sheet(item: $sheet) { item in
            Group {
                switch item {
                case .device(let id): TVDeviceDetail(home: home, deviceID: id)
                case .pairing: TVPairingSheet(home: home)
                case .configuration: TVConfigurationSheet(home: home)
                }
            }.preferredColorScheme(.dark)
        }
        .fullScreenCover(isPresented: $showingDiagnostics) { TVDiagnosticsView(home: home) }
        .fullScreenCover(isPresented: $showingUpdates) { TVUpdateView(model: updates) }
        .task(id: scenePhase) { if scenePhase == .active { await updates.checkIfNeeded() } }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 18) {
                Image(systemName: "house").font(.system(size: 42, weight: .light))
                Text("MijiaLAN").font(.system(size: 38, weight: .semibold))
            }.padding(.horizontal, 34).padding(.top, 74).padding(.bottom, 70)
            VStack(spacing: 12) {
                ForEach(TVDestination.allCases) { item in
                    Button { destination = item } label: {
                        HStack(spacing: 28) {
                            Image(systemName: item.symbol).font(.system(size: 34, weight: .regular)).frame(width: 42)
                            Text(item.rawValue).font(.system(size: 36, weight: .medium))
                            Spacer(minLength: 0)
                        }.padding(.vertical, 26).padding(.horizontal, 30).contentShape(Rectangle())
                    }
                    .buttonStyle(TVFocusStyle(kind: .navigation(selected: destination == item)))
                    .focusEffectDisabled()
                    .focused($focus, equals: .navigation(item))
                    .accessibilityIdentifier("navigation.\(item.accessibilityID)")
                }
            }.padding(.horizontal, 24)
            Spacer(minLength: 30)
            if let label = home.contextLabel {
                Text(label).font(.system(size: 23)).foregroundStyle(TVTheme.secondary)
                    .padding(.horizontal, 38).padding(.bottom, 56)
                    .accessibilityIdentifier("home.context")
            }
        }.frame(maxHeight: .infinity).background(TVTheme.sidebar).focusSection()
    }

    private var overview: some View {
        GeometryReader { geometry in
            HStack(alignment: .top, spacing: 76) {
                VStack(alignment: .leading, spacing: 0) {
                    TVBridgeGlyph(running: home.bridgeRunning, size: 200).padding(.bottom, 36)
                    Text(home.title).font(.system(size: 92, weight: .bold)).lineLimit(2)
                        .accessibilityIdentifier("overview.status")
                    Text(home.subtitle).font(.system(size: 36)).foregroundStyle(TVTheme.secondary)
                        .padding(.top, 8).fixedSize(horizontal: false, vertical: true)
                    Text(home.countText).font(.system(size: 36)).foregroundStyle(TVTheme.secondary).padding(.top, 56)
                    Button { destination = .bridge } label: { TVActionLabel(title: "管理桥接") }
                        .buttonStyle(TVFocusStyle(kind: .primary)).focusEffectDisabled()
                        .frame(width: 460).padding(.top, 72)
                        .focused($focus, equals: .manageBridge).accessibilityIdentifier("overview.manageBridge")
                    Button { sheet = .pairing } label: {
                        Text("查看配对信息").font(.system(size: 30)).padding(.vertical, 18).padding(.horizontal, 10)
                    }.buttonStyle(TVFocusStyle()).focusEffectDisabled().padding(.top, 30)
                        .disabled(!home.pairingAvailable).accessibilityIdentifier("overview.pairing")
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).focusSection()
                overviewDevices.frame(width: min(590, geometry.size.width * 0.39))
                    .frame(maxHeight: .infinity, alignment: .top).focusSection()
            }.padding(.leading, 100).padding(.trailing, 70).padding(.top, 150).padding(.bottom, 60)
        }
    }

    private var overviewDevices: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("设备状态").font(.system(size: 50, weight: .semibold)).padding(.bottom, 18).padding(.leading, 18)
            ForEach(Array(home.items.prefix(3))) { item in
                Button { sheet = .device(item.id) } label: { TVDeviceRow(item: item) }
                    .buttonStyle(TVFocusStyle()).focusEffectDisabled().accessibilityIdentifier("overview.device.\(item.id)")
                Divider().overlay(Color.white.opacity(0.1))
            }
            Button { destination = .devices } label: {
                HStack {
                    Text("查看全部 \(home.items.count) 台设备")
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 24))
                }.font(.system(size: 34)).padding(.vertical, 26).padding(.horizontal, 18)
            }.buttonStyle(TVFocusStyle()).focusEffectDisabled().accessibilityIdentifier("overview.allDevices")
            if home.offlineCount > 0 && (home.isDesignPreview || home.tunnel.hasRunningService) {
                HStack(spacing: 18) {
                    Circle().fill(TVTheme.warning).frame(width: 14, height: 14)
                    Text("\(home.offlineCount) 台设备暂时离线").font(.system(size: 27)).foregroundStyle(TVTheme.secondary)
                }.padding(.top, 34).padding(.horizontal, 18)
            }
        }
    }
}

#Preview("桥接中心 · 示例数据", traits: .fixedLayout(width: 1920, height: 1080)) {
    TVBridgeShell(model: TunnelModel(preview: true), isDesignPreview: true)
}
#endif
