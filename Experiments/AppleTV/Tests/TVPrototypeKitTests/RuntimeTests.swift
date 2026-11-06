import Foundation
import MijiaCore
import MijiaHomeKitBridge
@testable import MijiaLAN
import Synchronization
import Testing
@testable import TVPrototypeKit

struct ConfigurationTests {
    @Test func udpFixtureCannotMasqueradeAsARealDevice() throws {
        var config = try PrototypeConfiguration.udpFixture(host: "192.168.1.20")
        #expect(config.fixture)
        #expect(config.fixtureSelfTestWrites == false)
        #expect(config.home.devices[0].host == "192.168.1.20")
        config.fixture = false
        #expect(throws: PrototypeError.self) { try config.validated() }
        #expect(throws: PrototypeError.self) { try PrototypeConfiguration.udpFixture(host: "8.8.8.8") }
        #expect(throws: PrototypeError.self) { try PrototypeConfiguration.udpFixture(host: "192..168.1.20") }
    }
    @Test func rejectsInvalidSecretsAndDuplicateDevices() throws {
        var config = PrototypeConfiguration.fixtureConfiguration
        config.fixture = false
        config.home.devices[0].token = "invalid"
        #expect(throws: PrototypeError.self) { try config.validated() }
        config = .fixtureConfiguration
        config.fixture = false
        config.home.devices.append(config.home.devices[0])
        #expect(throws: PrototypeError.self) { try config.validated() }
    }
}

@MainActor struct RuntimeTests {
    @Test("Runtime bridges encrypted HAP TCP to real loopback miIO UDP and records post-background read/write evidence")
    func encryptedControlAndEvidence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mijialan-tv-test-\(UUID())")
        let storage = PrototypeStorage(directory: directory, storesPairingCode: false)
        let suite = "mijialan-tv-test-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let blob = Mutex<Data?>(nil)
        let vault = HomeKitBridgeVault(load: { blob.withLock { $0.map(CredentialVault.Lookup.value) ?? .missing } },
                                      save: { data in blob.withLock { $0 = data }; return true })
        let peer = try UDPFixture()
        var config = PrototypeConfiguration.fixtureConfiguration
        config.pollSeconds = 2
        let service = try PrototypeRuntime(configuration: config, executor: .hostTest, storage: storage, defaults: defaults,
            bridgeVault: vault, transport: FixtureUDPTransport(port: peer.port), loopbackOnly: true)
        var client: WireHAPController?
        do {
            try storage.markLifecycle("active")
            try await service.start()
            for _ in 0..<120 {
                _ = await service.handle(.status)
                if service.evidence.bridgePort != nil { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            let port = try #require(service.evidence.bridgePort)
            let code = try #require(service.bridge.setupCode)
            let wire = WireHAPController(port: port)
            client = wire
            try await wire.connect()
            try await wire.pair(setupCode: code)
            try await wire.verify()
            let response = try await wire.request("GET", "/accessories")
            let json = try JSONDecoder().decode(JSONValue.self, from: response.body)
            let accessory = try #require(json["accessories"]?.arrayValue?.first { $0["aid"]?.intValue == 2 })
            let chars = accessory["services"]?.arrayValue?.flatMap { $0["characteristics"]?.arrayValue ?? [] } ?? []
            let active = try #require(chars.first { $0["type"]?.stringValue == "B0" }?["iid"]?.intValue)
            try storage.markLifecycle("background")
            let write = JSONValue.object(["characteristics": .array([.object([
                "aid": .number(2), "iid": .number(Double(active)), "value": .number(1)
            ])])])
            #expect(try await wire.request("PUT", "/characteristics", body: Data(write.compactJSONString.utf8)).status == 204)
            for _ in 0..<80 {
                _ = await service.handle(.status)
                if service.evidence.backgroundReads > 0 && service.evidence.backgroundWrites > 0 { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let evidence = service.evidence
            #expect(evidence.executor == .hostTest)
            #expect(evidence.fixture)
            #expect(evidence.authenticatedReads > 0)
            #expect(evidence.backgroundReads > 0)
            #expect(evidence.backgroundWrites > 0)
            #expect(evidence.paired)
            #expect(evidence.devices.first?.isOn == true)
            #expect(evidence.transportFailures == 0)
            #expect(peer.requests > 0)
            // No explicit refresh or app request during this interval: the shared controller
            // must keep polling autonomously while the lifecycle marker remains background.
            let backgroundReads = evidence.backgroundReads
            try await Task.sleep(for: .seconds(6))
            _ = await service.handle(.status)
            #expect(service.evidence.backgroundReads > backgroundReads)
            let redacted = String(decoding: try Data(contentsOf: directory.appendingPathComponent("evidence.json")), as: UTF8.self)
            #expect(!redacted.contains(config.home.devices[0].token))
            #expect(!redacted.contains(code))
            await wire.close()
            await service.stop()
            #expect(storage.evidence()?.stoppedAt != nil)
            #expect(storage.evidence()?.bridgeStatus == "stopped")
        } catch {
            await client?.close(); await service.stop(); await peer.stop()
            throw error
        }
        await peer.stop()
    }
}

/// The fixture server speaks through a real UDP socket. The data model is simulated; the
/// production miIO codec, UDP transport, HomeKit pairing, verification and encrypted TCP are real.
private final class UDPFixture: Sendable {
    private struct State: Sendable { var stopped = false; var requests = 0 }
    private final class Storage: Sendable { let state = Mutex(State()) }
    private let storage = Storage()
    private let queue = DispatchQueue(label: "mijialan.tvprototype.udp-fixture")
    let port: UInt16
    var requests: Int { storage.state.withLock { $0.requests } }

    init() throws {
        let socket = try UDPSocket(bindHost: "127.0.0.1", bindPort: 0)
        port = socket.localPort
        let peer = FixtureTransport()
        let storage = storage
        queue.async {
            while !storage.state.withLock({ $0.stopped }) {
                guard let incoming = try? socket.receive(timeout: 0.1) else { continue }
                let result = Mutex<Result<Data, any Error>?>(nil)
                let semaphore = DispatchSemaphore(value: 0)
                Task.detached {
                    do {
                        let bytes = try await peer.exchange(incoming.data, host: "127.0.0.1", port: 54321, timeout: .seconds(2))
                        result.withLock { $0 = .success(bytes) }
                    } catch { result.withLock { $0 = .failure(error) } }
                    semaphore.signal()
                }
                semaphore.wait()
                if let response = try? result.withLock({ try $0?.get() }) {
                    try? socket.send(response, to: incoming.host, port: incoming.port)
                    storage.state.withLock { $0.requests += 1 }
                }
            }
        }
    }
    func stop() async {
        storage.state.withLock { $0.stopped = true }
        await withCheckedContinuation { reply in queue.async { reply.resume() } }
    }
}

private struct FixtureUDPTransport: MiioTransport {
    let port: UInt16
    func exchange(_ packet: Data, host: String, port: UInt16, timeout: Duration) async throws -> Data {
        try await UDPMiioTransport().exchange(packet, host: host, port: self.port, timeout: timeout)
    }
    func broadcast(_ packet: Data, port: UInt16, duration: Duration, rounds: Int) async throws -> [MiioDatagram] { [] }
}
