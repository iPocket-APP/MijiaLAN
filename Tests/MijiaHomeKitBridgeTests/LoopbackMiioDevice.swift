import Foundation
import MijiaCore
import Synchronization
@testable import MijiaLAN

/// A real UDP miIO peer, bound only to 127.0.0.1:0. The blocking descriptor is confined to its
/// dispatch queue; Mutex protects the small state shared with async test code. No device API is mocked.
final class LoopbackMiioDevice: Sendable {
    static let token = "00112233445566778899aabbccddeeff"
    static let model = "zhimi.airpurifier.rma1"
    private struct State: Sendable {
        var phase = 0
        var stopped = false
        var encryptedRequests = 0
        var writes = 0
        var error: String?
    }
    private final class Storage: Sendable { let state = Mutex(State()) }
    private let storage = Storage()
    private let queue = DispatchQueue(label: "test.mijialan.miio-device")
    let port: UInt16

    init() throws {
        let socket = try UDPSocket(bindHost: "127.0.0.1", bindPort: 0)
        port = socket.localPort
        let schema = DeviceSchema.bundled(model: Self.model)!
        var values: [String: JSONValue] = [:]
        for c in DeviceCapabilityCatalog.capabilities(schema: schema, model: Self.model) where c.readable {
            values["\(c.siid).\(c.iid)"] = c.format == "bool" ? .bool(false) : .number(c.options.first.map { Double($0.value) } ?? c.min ?? 0)
        }
        values["2.1"] = .bool(true)
        values["3.1"] = .number(45)
        values["3.7"] = .number(21.56)
        let initialValues = values
        let storage = storage
        queue.async {
            while !storage.state.withLock({ $0.stopped }) {
                do {
                    guard let datagram = try socket.receive(timeout: 0.1) else { continue }
                    let response: Data
                    if datagram.data == MiioPacket.hello {
                        response = Data([0x21, 0x31, 0, 32, 0, 0, 0, 0, 0, 0, 0, 77, 0, 0, 0x13, 0x88] + [UInt8](repeating: 255, count: 16))
                    } else {
                        let token = MiioToken.parse(Self.token)!
                        let (_, bytes) = try MiioPacket.decode(datagram.data, token: token)
                        let request = try JSONDecoder().decode(JSONValue.self, from: bytes.prefix { $0 != 0 })
                        let method = request["method"]?.stringValue ?? ""
                        let phase = storage.state.withLock { state in
                            state.encryptedRequests += 1
                            if method.hasPrefix("set_") || method == "action" { state.writes += 1 }
                            return state.phase
                        }
                        var values = initialValues
                        if phase == 1 {
                            values["2.1"] = .string("on")
                            values["3.1"] = .number(123)
                            values["3.7"] = .number(-3276.8)
                        } else if phase == 2 { values["3.1"] = .number(55) }
                        let result: JSONValue
                        if method == "miIO.info" { result = .object(["model": .string(Self.model)]) }
                        else if method == "get_properties" {
                            result = .array((request["params"]?.arrayValue ?? []).map { p in
                                let key = "\(p["siid"]?.intValue ?? 0).\(p["piid"]?.intValue ?? 0)"
                                return .object(["siid": p["siid"] ?? .null, "piid": p["piid"] ?? .null,
                                    "value": values[key] ?? .null, "code": .number(values[key] == nil ? -4003 : 0)])
                            })
                        } else { result = .array([.object(["code": .number(-4004)])]) }
                        let body = JSONValue.object(["id": request["id"] ?? .null, "result": result])
                        response = try MiioPacket.encode(Data(body.compactJSONString.utf8) + [0], token: token, deviceID: 77, stamp: 5000)
                    }
                    try socket.send(response, to: datagram.host, port: datagram.port)
                } catch { storage.state.withLock { $0.error = String(describing: error) } }
            }
        }
    }

    func setPhase(_ phase: Int) { storage.state.withLock { $0.phase = phase } }
    var encryptedRequests: Int { storage.state.withLock { $0.encryptedRequests } }
    var writes: Int { storage.state.withLock { $0.writes } }
    var error: String? { storage.state.withLock { $0.error } }
    func stop() async {
        storage.state.withLock { $0.stopped = true }
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
}

/// Redirect only the fixed miIO port to the isolated fixture's ephemeral port. Every byte still
/// travels through production UDPMiioTransport and the production miIO encryption codec.
struct LoopbackMiioTransport: MiioTransport {
    let port: UInt16
    func exchange(_ packet: Data, host: String, port: UInt16, timeout: Duration) async throws -> Data {
        guard host == "127.0.0.1" else { throw MiioError.hostUnreachable }
        return try await UDPMiioTransport().exchange(packet, host: host, port: self.port, timeout: timeout)
    }
    func broadcast(_ packet: Data, port: UInt16, duration: Duration, rounds: Int) async throws -> [MiioDatagram] { [] }
}
