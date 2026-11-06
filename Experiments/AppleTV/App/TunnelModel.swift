import Foundation
import MijiaLAN
@preconcurrency import NetworkExtension
import Observation
import TVPrototypeKit

@Observable @MainActor
final class TunnelModel {
    var evidence: PrototypeEvidence?
    var pairingCode: String?
    var message = "请选择模拟设备或填写真实设备。"
    var busy = false
    var vpnStatus = "未连接"
    var phase = "active"
    var diagnosticsReport: PrototypeDiagnostics?
    var diagnosticsFileURL: URL?
    var diagnosticsBusy = false
    var diagnosticsMessage = "生成报告时会重新读取设备，仅保存脱敏诊断数据。"
    var autoReconnect = false {
        didSet { UserDefaults.standard.set(autoReconnect, forKey: "experimental_auto_reconnect") }
    }
    var configuration = PrototypeConfiguration.fixtureConfiguration
    var storage: PrototypeStorage?
    private var manager: NETunnelProviderManager?
    private var localRuntime: PrototypeRuntime?
    #if DEBUG
    private var localNetworkProbe: NetworkDiagnosticProbe?
    #endif
    private var activationStage = "idle"
    private var hasRestoredManager = false
    var hasRunningService: Bool {
        if localRuntime != nil { return true }
        guard let status = manager?.connection.status else { return false }
        return status != .disconnected && status != .invalid
    }

    init(preview: Bool = false) {
        // Design previews never open a shared container, Keychain or VPN preferences.
        if preview { return }
        autoReconnect = UserDefaults.standard.bool(forKey: "experimental_auto_reconnect")
        do {
            let store = try PrototypeStorage.live()
            storage = store
            if let saved = try? store.configuration() { configuration = saved }
            evidence = store.evidence()
            pairingCode = store.pairingCode()
            try store.markLifecycle("active")
        } catch { message = error.localizedDescription }
    }

    @discardableResult
    func configureDevice(host: String, token: String, name: String, room: String = "", append: Bool = false) async -> Bool {
        await perform {
            guard !hasRunningService else {
                throw NSError(domain: "TVPrototype", code: 2, userInfo: [NSLocalizedDescriptionKey: "请先停止当前服务，再更改设备配置。"])
            }
            guard let secret = MiioToken.parse(token) else { throw PrototypeError.invalidConfiguration }
            let client = MiioClient(host: host.trimmingCharacters(in: .whitespacesAndNewlines), token: secret)
            let header = try await client.handshake()
            let info = try await client.info()
            try Task.checkCancellation()
            let roomName = room.trimmingCharacters(in: .whitespacesAndNewlines)
            let device = LocalDevice(did: String(header.deviceID), name: name.isEmpty ? "实验设备" : name,
                model: info.model, host: host.trimmingCharacters(in: .whitespacesAndNewlines), token: MiioToken.hex(secret),
                roomName: roomName.isEmpty ? nil : roomName)
            var home = append && !configuration.fixture ? configuration.home : LocalHomeConfig()
            home.merge([device])
            let config = PrototypeConfiguration(home: home, pollSeconds: configuration.pollSeconds)
            guard let storage else { throw PrototypeError.keychainUnavailable }
            try storage.saveConfiguration(config)
            configuration = config
            message = "真实设备已认证。停止服务后重新启动以应用配置。"
        }
    }

    func selectFixture() {
        guard !busy else { return }
        guard !hasRunningService else { message = "请先停止当前服务，再切换模拟设备。"; return }
        do {
            guard let storage else { throw PrototypeError.keychainUnavailable }
            try storage.saveConfiguration(.fixtureConfiguration)
            configuration = .fixtureConfiguration
            message = "已选择模拟设备；不会向真实米家设备发送命令。"
        } catch { message = error.localizedDescription }
    }

    #if DEBUG
    func waitForDisconnection() async {
        if let manager, manager.connection.status == .disconnecting {
            let deadline = Date().addingTimeInterval(10)
            while manager.connection.status == .disconnecting && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }
    func selectUDPFixture(host: String, selfTestWrites: Bool = false) async {
        await waitForDisconnection()
        guard !hasRunningService else { message = "请先停止服务，再切换 UDP 模拟器。"; return }
        do {
            guard let storage else { throw PrototypeError.sharedContainerUnavailable }
            let config = try PrototypeConfiguration.udpFixture(host: host, selfTestWrites: selfTestWrites)
            try storage.saveConfiguration(config)
            configuration = config
            message = selfTestWrites ? "已选择局域网 UDP 模拟器；后台开关由自测定时器产生。" : "已选择局域网 UDP 模拟器；自测定时写入已关闭。"
        } catch { message = error.localizedDescription }
    }
    #endif

    func startExtension(networkDiagnostics: Bool = false) async {
        await perform(activation: true) {
            activationStage = "preparing"
            await stopLocal()
            guard let storage else { throw PrototypeError.keychainUnavailable }
            try storage.saveConfiguration(configuration)
            let bundleID = Bundle.main.bundleIdentifier! + ".Tunnel"
            activationStage = "loadingPreferences"
            let saved = try await NETunnelProviderManager.loadAllFromPreferences()
            let selected = saved.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == bundleID }
                ?? NETunnelProviderManager()
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = bundleID
            proto.serverAddress = "MijiaLAN private experiment"
            proto.disconnectOnSleep = false
            selected.protocolConfiguration = proto
            selected.localizedDescription = "MijiaLAN NE 实验"
            selected.isEnabled = true
            if autoReconnect {
                let rule = NEOnDemandRuleConnect()
                rule.interfaceTypeMatch = .any
                selected.onDemandRules = [rule]
            } else { selected.onDemandRules = [] }
            selected.isOnDemandEnabled = autoReconnect
            activationStage = "savingPreferences"
            try await selected.saveToPreferences()
            activationStage = "reloadingPreferences"
            try await selected.loadFromPreferences()
            manager = selected
            if selected.connection.status == .disconnecting {
                activationStage = "waitingForDisconnect"
                try storage.saveActivation(stage: activationStage)
                let deadline = Date().addingTimeInterval(10)
                while selected.connection.status == .disconnecting && Date() < deadline {
                    try await Task.sleep(for: .milliseconds(200))
                }
                guard selected.connection.status != .disconnecting else { throw PrototypeError.timedOut }
            }
            activationStage = "startingTunnel"
            if selected.connection.status == .disconnected || selected.connection.status == .invalid {
                try selected.connection.startVPNTunnel(options: networkDiagnostics ? ["networkDiagnostics": NSNumber(value: true)] : nil)
            }
            activationStage = "requested"
            try storage.saveActivation(stage: activationStage)
            message = "已请求启动扩展；等待扩展返回实际连接证据。"
        }
    }

    #if targetEnvironment(simulator)
    func startSimulatorForeground() async {
        await startForeground(executor: .simulatorForeground)
    }
    #elseif DEBUG && os(iOS)
    func startDeviceForegroundControl(networkDiagnostics: Bool = false) async {
        await startForeground(executor: .deviceForeground, networkDiagnostics: networkDiagnostics)
    }
    #endif

    private func startForeground(executor: PrototypeExecutor, networkDiagnostics: Bool = false) async {
        await perform {
            if let manager, manager.connection.status == .disconnecting {
                let deadline = Date().addingTimeInterval(10)
                while manager.connection.status == .disconnecting && Date() < deadline {
                    try await Task.sleep(for: .milliseconds(200))
                }
            }
            if let manager, manager.connection.status != .disconnected && manager.connection.status != .invalid {
                throw NSError(domain: "TVPrototype", code: 1, userInfo: [NSLocalizedDescriptionKey: "请先停止 VPN，再启动前台测试。"])
            }
            await stopLocal()
            guard let storage else { throw PrototypeError.sharedContainerUnavailable }
            #if DEBUG
            if networkDiagnostics && configuration.fixture {
                let probe = NetworkDiagnosticProbe(storage: storage)
                localNetworkProbe = probe
                probe.start()
            }
            #endif
            try storage.saveConfiguration(configuration)
            let defaults = UserDefaults(suiteName: storage.namespace + ".foreground." + executor.rawValue + ".bridge")!
            let service = try PrototypeRuntime(configuration: configuration, executor: executor,
                storage: storage, defaults: defaults)
            localRuntime = service
            do { try await service.start() }
            catch { await service.stop(); localRuntime = nil; throw error }
            evidence = service.evidence
            pairingCode = storage.pairingCode()
            message = "前台对照测试正在运行；切入后台会停止此测试。"
        }
    }

    func stop() async {
        await perform {
            await stopLocal()
            if let manager {
                // Persist the disabled policy first, so stopping a session does not immediately
                // trigger an on-demand restart. Still request stop if preferences cannot save.
                defer { manager.connection.stopVPNTunnel() }
                manager.isOnDemandEnabled = false
                manager.onDemandRules = []
                manager.isEnabled = false
                do { try await manager.saveToPreferences() }
                catch {
                    let detail = error as NSError
                    try? storage?.saveActivation(stage: "disableAutoReconnect", error: detail)
                    throw NSError(domain: "TVPrototype", code: 3, userInfo: [
                        NSLocalizedDescriptionKey: "已请求停止，但系统未能保存关闭自动重连的设置：\(detail.localizedDescription)",
                        NSUnderlyingErrorKey: detail
                    ])
                }
            }
            evidence = storage?.evidence()
            message = manager == nil ? "前台测试已停止。" : "已请求停止服务，并关闭该 VPN 配置的自动重连。"
        }
    }
    private func stopLocal() async {
        #if DEBUG
        localNetworkProbe?.stop(); localNetworkProbe = nil
        #endif
        await localRuntime?.stop(); localRuntime = nil
    }

    func lifecycle(_ phase: String) {
        self.phase = phase
        do { try storage?.markLifecycle(phase) } catch { message = error.localizedDescription }
        if phase == "background", localRuntime != nil {
            Task {
                await stopLocal()
                evidence = storage?.evidence()
                message = "前台对照测试已随 App 进入后台而停止。"
            }
        }
    }

    func update() async {
        if manager == nil && !hasRestoredManager {
            hasRestoredManager = true
            let bundleID = Bundle.main.bundleIdentifier! + ".Tunnel"
            manager = try? await NETunnelProviderManager.loadAllFromPreferences().first {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == bundleID
            }
        }
        if let manager {
            vpnStatus = switch manager.connection.status {
            case .invalid: "无配置"
            case .disconnected: "已断开"
            case .connecting: "连接中"
            case .connected: "已连接"
            case .reasserting: "重连中"
            case .disconnecting: "断开中"
            @unknown default: "未知"
            }
        }
        if localRuntime != nil || manager?.connection.status == .connected { await request(.status) }
        else { evidence = storage?.evidence() }
        pairingCode = storage?.pairingCode()
        exportDiagnostics()
    }

    @discardableResult
    func request(_ request: PrototypeRequest) async -> Bool {
        do {
            let reply: PrototypeReply
            if let localRuntime { reply = await localRuntime.handle(request) }
            else {
                guard let session = manager?.connection as? NETunnelProviderSession, session.status == .connected else {
                    throw PrototypeError.noRuntime
                }
                let data = try JSONEncoder().encode(request)
                let response: Data = try await withCheckedThrowingContinuation { continuation in
                    let box = ResponseBox(continuation)
                    do {
                        try session.sendProviderMessage(data) { reply in
                            if let reply { box.finish(.success(reply)) }
                            else { box.finish(.failure(PrototypeError.noRuntime)) }
                        }
                        Task {
                            let diagnostic: Bool = if case .diagnostics = request { true } else { false }
                            try? await Task.sleep(for: .seconds(diagnostic ? 30 : 5))
                            box.finish(.failure(diagnostic ? PrototypeError.diagnosticsTimedOut : PrototypeError.timedOut))
                        }
                    } catch { box.finish(.failure(error)) }
                }
                reply = try JSONDecoder().decode(PrototypeReply.self, from: response)
            }
            if let evidence = reply.evidence { self.evidence = evidence }
            if let error = reply.error { message = error; return false }
            return true
        } catch { message = error.localizedDescription; return false }
    }

    /// Collection is owned by the model, so closing the TV page does not discard its result.
    func collectDiagnostics(preview: PrototypeDiagnostics? = nil) async {
        guard !diagnosticsBusy, !busy else { return }
        diagnosticsBusy = true
        diagnosticsMessage = preview == nil ? "正在重新读取设备与 HomeKit 状态…" : "正在生成示例报告…"
        defer { diagnosticsBusy = false }
        do {
            var report: PrototypeDiagnostics
            if let preview {
                report = preview
            } else {
                let requestID = UUID()
                let running = hasRunningService
                let succeeded = running ? await request(.diagnostics(id: requestID)) : false
                if succeeded, let collected = storage?.diagnostics(), collected.id == requestID {
                    report = collected
                } else if var saved = storage?.diagnostics(), saved.fixture == configuration.fixture,
                          saved.runtime?.sessionID == evidence?.sessionID,
                          Set(saved.devices.map(\.did)) == Set(configuration.home.devices.map(\.did)) {
                    saved.source = .savedRuntime
                    report = saved
                } else {
                    report = .unavailable(configuration: configuration, evidence: evidence)
                }
                if running && !succeeded {
                    report.markCollectionFailure(message, configuration: configuration, pairingCode: pairingCode)
                } else if running && report.id != requestID {
                    report.markCollectionFailure("未读取到与本次请求匹配的诊断快照，当前展示可用的历史记录。",
                        configuration: configuration, pairingCode: pairingCode)
                }
                report.activation = storage?.activationSummary()
            }
            report.exportedAt = Date()
            report.app = .init()
            let output = report
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            let url = caches.appendingPathComponent("Diagnostics/MijiaLAN-Diagnostics.json")
            try await Task.detached(priority: .utility) {
                let data = try output.jsonData()
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            }.value
            diagnosticsReport = output
            diagnosticsFileURL = url
            diagnosticsMessage = switch report.source {
            case .designPreview: "示例报告已生成；没有发起设备通信。"
            case .liveRuntime: "诊断报告已生成，可在本机预览下载。"
            case .savedRuntime: "报告已生成，包含历史记录；请核对采集时间。"
            case .notRunning: "报告已生成；服务未运行，设备属性尚未检查。"
            }
        } catch {
            diagnosticsMessage = "报告生成失败：\(error.localizedDescription)"
        }
    }

    /// Device file services may refuse the shared container even when the app can read it.
    /// Stage only the redacted JSON files in the host app's Documents directory while active.
    /// No configuration, identity, token, or pairing-code export is performed.
    private func exportDiagnostics() {
        #if os(iOS)
        guard let storage,
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let destination = documents.appendingPathComponent("Diagnostics", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for name in ["evidence.json", "app-lifecycle.json", "activation.json", "network-diagnostics.json"] {
                let source = storage.directory.appendingPathComponent(name)
                if let data = try? Data(contentsOf: source) {
                    try data.write(to: destination.appendingPathComponent(name), options: .atomic)
                }
            }
        } catch { message = "诊断文件暂时无法导出：\(error.localizedDescription)" }
        #endif
    }

    @discardableResult
    private func perform(activation: Bool = false, _ operation: () async throws -> Void) async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false; exportDiagnostics() }
        do { try await operation(); return true }
        catch {
            let detail = error as NSError
            if activation { try? storage?.saveActivation(stage: activationStage, error: detail) }
            #if targetEnvironment(simulator)
            if activation && detail.domain == NEVPNErrorDomain && detail.code == NEVPNError.configurationReadWriteFailed.rawValue
                && detail.localizedDescription.localizedCaseInsensitiveContains("IPC failed") {
                vpnStatus = "模拟器服务不可用"
                message = "此模拟器无法连接 VPN 系统服务（IPC failed / 5），扩展尚未启动。可用「前台测试」验证设备控制；后台桥接需要对应平台的真机验证。"
                return false
            }
            #endif
            message = "\(error.localizedDescription)（\(detail.domain) / \(detail.code)）"
            return false
        }
    }
}

private final class ResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, any Error>?
    init(_ continuation: CheckedContinuation<Data, any Error>) { self.continuation = continuation }
    func finish(_ result: Result<Data, any Error>) {
        let pending = lock.withLock { let value = continuation; continuation = nil; return value }
        pending?.resume(with: result)
    }
}
