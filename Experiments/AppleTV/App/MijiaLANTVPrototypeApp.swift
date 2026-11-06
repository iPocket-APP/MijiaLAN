import SwiftUI
import TVPrototypeKit

@main
struct MijiaLANPrototypeApp: App {
    @Environment(\.scenePhase) private var phase
    @State private var model = TunnelModel(preview: PrototypeLaunch.designPreview)

    var body: some Scene {
        WindowGroup {
            rootScreen
                .task {
                    if PrototypeLaunch.designPreview { return }
                    #if DEBUG
                    let arguments = ProcessInfo.processInfo.arguments
                    if arguments.contains("--diagnose-extension-network") {
                        await model.update()
                        await model.stop()
                        await model.waitForDisconnection()
                        model.selectFixture()
                        await model.startExtension(networkDiagnostics: true)
                    } else if let index = arguments.firstIndex(of: "--start-extension-udp-fixture") ?? arguments.firstIndex(of: "--start-extension-udp-self-test"), arguments.indices.contains(index + 1) {
                        await model.update()
                        await model.stop()
                        await model.selectUDPFixture(host: arguments[index + 1], selfTestWrites: arguments[index] == "--start-extension-udp-self-test")
                        await model.startExtension()
                    } else if arguments.contains("--stop-extension") {
                        await model.update()
                        await model.stop()
                    } else if arguments.contains("--start-extension-fixture") {
                        model.selectFixture()
                        await model.startExtension()
                    }
                    #if targetEnvironment(simulator)
                    if arguments.contains("--simulator-fixture") && !arguments.contains("--start-extension-fixture")
                        && !arguments.contains("--stop-extension") {
                        model.selectFixture()
                        await model.startSimulatorForeground()
                    }
                    #elseif os(iOS)
                    if arguments.contains("--device-foreground-fixture") || arguments.contains("--diagnose-foreground-network") {
                        await model.update()
                        await model.stop()
                        model.selectFixture()
                        await model.startDeviceForegroundControl(networkDiagnostics: arguments.contains("--diagnose-foreground-network"))
                    }
                    #endif
                    #endif
                    while !Task.isCancelled {
                        // Read the live model, rather than the scene phase captured when
                        // this long-lived task was created during launch.
                        if model.phase == "active" { await model.update() }
                        do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    }
                }
                .onChange(of: phase) {
                    let value = switch phase {
                    case .active: "active"
                    case .inactive: "inactive"
                    case .background: "background"
                    @unknown default: "unknown"
                    }
                    model.lifecycle(value)
                }
        }
    }

    @ViewBuilder private var rootScreen: some View {
        #if os(tvOS)
        TVBridgeShell(model: model, isDesignPreview: PrototypeLaunch.designPreview)
        #else
        PrototypeScreen(model: model)
        #endif
    }
}

enum PrototypeLaunch {
    static var designPreview: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--design-preview")
        #else
        false
        #endif
    }
}

private struct PrototypeScreen: View {
    @Bindable var model: TunnelModel
    @State private var host = ""
    @State private var token = ""
    @State private var name = ""
    @State private var showingDevice = false

    private var outerPadding: CGFloat {
        #if os(tvOS)
        64
        #else
        20
        #endif
    }

    private var platformTitle: String {
        #if os(tvOS)
        "Apple TV"
        #else
        "iOS"
        #endif
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack {
                    #if os(tvOS)
                    Image(systemName: "appletv").font(.system(size: 46))
                    #else
                    Image(systemName: "iphone.gen3").font(.largeTitle)
                    #endif
                    VStack(alignment: .leading, spacing: 8) {
                        Text("MijiaLAN · \(platformTitle) 实验").font(.title2.bold())
                        Text("Network Extension / 米家局域网 / HomeKit").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Text(model.configuration.fixture ? "模拟设备" : "真实设备")
                    .font(.callout).padding(10).background(.thinMaterial, in: Capsule())
                Text(model.message).font(.callout).foregroundStyle(.secondary)
                serviceControls.disabled(model.busy)
                if let evidence = model.evidence {
                    EvidencePanel(evidence: evidence, vpn: model.vpnStatus, pairingCode: model.pairingCode)
                    ForEach(evidence.devices) { device in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(device.name).font(.headline)
                                Text(device.online ? "设备在线" : "设备离线").foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let on = device.isOn {
                                Button(on ? "关闭" : "开启") { Task { await model.request(.power(did: device.id, on: !on)) } }
                                    .disabled(model.busy)
                            }
                        }.padding(24).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 24) { configurationButtons }
                    VStack(alignment: .leading, spacing: 16) { configurationButtons }
                }.disabled(model.busy || model.hasRunningService)
                Toggle("下次启动扩展时自动重连（真机实验）", isOn: $model.autoReconnect)
                    .disabled(model.busy || model.hasRunningService)
                if showingDevice {
                    VStack(spacing: 18) {
                        TextField("设备 IP，例如 192.168.1.50", text: $host)
                        SecureField("32 位局域网 token", text: $token)
                        TextField("设备名称", text: $name)
                        Button("认证并保存") {
                            Task { await model.configureDevice(host: host, token: token, name: name); token = "" }
                        }.disabled(model.busy)
                    }
                }
                Text("测试方法：扩展启动后返回主屏，再使用另一台设备的「家庭」或独立 HAP 客户端控制实验桥；重新打开此 App 查看后台认证读写次数。iOS 需要分别测试切后台与锁屏，tvOS 需要另外验收。模拟器前台测试会在进入后台时停止。")
                    .font(.footnote).foregroundStyle(.secondary)
            }.padding(outerPadding)
        }
        #if os(iOS)
        .buttonStyle(.bordered)
        .textFieldStyle(.roundedBorder)
        #endif
    }

    @ViewBuilder private var configurationButtons: some View {
        Button("选择模拟设备") { model.selectFixture() }
        Button("配置真实设备") { showingDevice.toggle() }
    }

    @ViewBuilder private var serviceButtons: some View {
        Button("启动扩展", systemImage: "network") { Task { await model.startExtension() } }
        #if targetEnvironment(simulator)
        Button("前台测试", systemImage: "play") { Task { await model.startSimulatorForeground() } }
        #elseif DEBUG && os(iOS)
        Button("前台对照", systemImage: "play") { Task { await model.startDeviceForegroundControl() } }
        #endif
        Button("停止", systemImage: "stop") { Task { await model.stop() } }
        Button("刷新", systemImage: "arrow.clockwise") { Task { await model.request(.refresh) } }
    }

    @ViewBuilder private var serviceControls: some View {
        #if os(tvOS)
        HStack(spacing: 24) { serviceButtons }
        #else
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), alignment: .leading)], alignment: .leading, spacing: 12) {
            serviceButtons
        }
        #endif
    }
}

private struct EvidencePanel: View {
    let evidence: PrototypeEvidence
    let vpn: String
    let pairingCode: String?
    private var panelPadding: CGFloat {
        #if os(tvOS)
        28
        #else
        16
        #endif
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(evidence.executor == .networkExtension ? "扩展进程" : "前台进程 · 不构成保活证据").font(.headline)
            if Date().timeIntervalSince(evidence.updatedAt) > 15 {
                Text("此记录已超过 15 秒未更新，请检查服务是否仍在运行。").font(.footnote).foregroundStyle(.orange)
            }
            Grid(alignment: .leading, horizontalSpacing: 48, verticalSpacing: 14) {
                GridRow { Text("平台"); Text(evidence.platform ?? "旧版记录") }
                GridRow { Text("VPN / 进程"); Text("\(vpn) / PID \(evidence.processID)") }
                GridRow { Text("设备通信"); Text("认证读取 \(evidence.authenticatedReads) · 确认写入 \(evidence.acknowledgedWrites)") }
                GridRow { Text("后台设备通信"); Text("读取 \(evidence.backgroundReads) · 写入 \(evidence.backgroundWrites)") }
                GridRow { Text("HomeKit"); Text("\(evidence.bridgeStatus) · TCP \(evidence.bridgePort.map(String.init) ?? "—") · \(evidence.paired ? "已配对" : "未配对")") }
                if let settings = evidence.networkSettings {
                    GridRow { Text("扩展路由"); Text("IPv4 \(settings.includedIPv4RouteCount) · IPv6 \(settings.includedIPv6RouteCount) 条接管路由") }
                }
                if let transport = evidence.transportKind {
                    GridRow { Text("通信路径"); Text(transport) }
                }
                GridRow { Text("运行状态"); Text(evidence.stoppedAt == nil ? "心跳 \(evidence.heartbeat) · 最大间隔 \(Int(evidence.largestHeartbeatGap)) 秒" : "服务已停止") }
                GridRow { Text("更新时间"); Text(evidence.updatedAt, style: .time) }
                if let pairingCode, !evidence.paired {
                    GridRow { Text("家庭手动配对码"); Text(pairingCode).monospaced() }
                }
            }.font(.callout)
            if evidence.fixture {
                Text(evidence.fixtureSelfTestWrites == true ? "局域网 UDP 模拟器：后台写入由自测定时器产生，不是外部 HomeKit 控制。这不代表真实米家设备验收。" : "当前通信对象为模拟设备；自测定时写入关闭。这不代表真实米家设备验收。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.padding(panelPadding).frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}
