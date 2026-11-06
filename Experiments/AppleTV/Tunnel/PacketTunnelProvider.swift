import Foundation
@preconcurrency import NetworkExtension
import TVPrototypeKit

/// Private experiment: no VPN server and no general Internet routing. This is intentionally
/// outside TN3120's supported use cases; successful activation is not evidence of HAP reachability.
final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    @MainActor private var runtime: PrototypeRuntime?
    @MainActor private var generation = UUID()
    #if DEBUG
    @MainActor private var networkProbe: NetworkDiagnosticProbe?
    #endif

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let callback = Callback(completionHandler)
        let runNetworkDiagnostics = (options?["networkDiagnostics"] as? NSNumber)?.boolValue == true
        Task { @MainActor in
            let current = UUID()
            generation = current
            var diagnostics: PrototypeStorage?
            var stage = "providerLoadingConfiguration"
            do {
                let storage = try PrototypeStorage.live()
                diagnostics = storage
                try storage.saveActivation(stage: stage)
                let config = try storage.configuration()
                let settings = ExperimentalTunnelNetwork.makeSettings()
                stage = "providerApplyingNetworkSettings"
                try storage.saveActivation(stage: stage)
                try await setTunnelNetworkSettings(settings)
                guard generation == current else { throw CancellationError() }
                #if DEBUG
                if runNetworkDiagnostics && config.fixture {
                    networkProbe?.stop()
                    let probe = NetworkDiagnosticProbe(storage: storage)
                    networkProbe = probe
                    probe.start()
                }
                #endif
                let defaults = UserDefaults(suiteName: storage.namespace + ".bridge")!
                stage = "providerStartingRuntime"
                try storage.saveActivation(stage: stage)
                let service = try PrototypeRuntime(configuration: config, executor: .networkExtension,
                    storage: storage, defaults: defaults,
                    networkSettings: ExperimentalTunnelNetwork.summary(of: settings))
                runtime = service
                try await service.start()
                guard generation == current else { await service.stop(); throw CancellationError() }
                try storage.saveActivation(stage: "providerReady")
                callback.call(nil)
            } catch {
                try? diagnostics?.saveActivation(stage: stage, error: error as NSError)
                if generation == current { await runtime?.stop(); runtime = nil }
                callback.call(error)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        let callback = Callback<Void> { _ in completionHandler() }
        Task { @MainActor in
            generation = UUID()
            #if DEBUG
            networkProbe?.stop(); networkProbe = nil
            #endif
            await runtime?.systemEvent("stop:\(reason.rawValue)")
            await runtime?.stop()
            runtime = nil
            callback.call(())
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        let callback = Callback<Data?> { completionHandler?($0) }
        Task { @MainActor in
            let reply: PrototypeReply
            do {
                let request = try JSONDecoder().decode(PrototypeRequest.self, from: messageData)
                if let runtime { reply = await runtime.handle(request) }
                else { reply = PrototypeReply(error: PrototypeError.noRuntime.localizedDescription) }
            } catch { reply = PrototypeReply(error: "无法识别扩展请求。") }
            callback.call(try? JSONEncoder().encode(reply))
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        let callback = Callback<Void> { _ in completionHandler() }
        Task { @MainActor in await runtime?.systemEvent("sleep"); callback.call(()) }
    }

    override func wake() {
        Task { @MainActor in await runtime?.systemEvent("wake") }
    }
}

/// Objective-C completion blocks are called once, from the runtime's actor.
private final class Callback<Value>: @unchecked Sendable {
    private let body: (Value) -> Void
    init(_ body: @escaping (Value) -> Void) { self.body = body }
    func call(_ value: Value) { body(value) }
}
