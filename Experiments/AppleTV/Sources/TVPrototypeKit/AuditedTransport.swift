import Foundation
import MijiaCore
import MijiaLAN

actor AuditedTransport: MiioTransport {
    struct Counts: Sendable {
        var reads: UInt64 = 0, writes: UInt64 = 0, backgroundReads: UInt64 = 0, backgroundWrites: UInt64 = 0, failures: UInt64 = 0
        var lastRead: Date?, lastWrite: Date?
    }
    private let inner: any MiioTransport
    private let tokens: [String: Data]
    private let storage: PrototypeStorage
    private(set) var counts = Counts()

    init(inner: any MiioTransport, config: PrototypeConfiguration, storage: PrototypeStorage) {
        self.inner = inner; self.storage = storage
        tokens = Dictionary(config.home.devices.compactMap { device in
            MiioToken.parse(device.token).map { (device.host, $0) }
        }, uniquingKeysWith: { first, _ in first })
    }

    func exchange(_ packet: Data, host: String, port: UInt16, timeout: Duration) async throws -> Data {
        do {
            let response = try await inner.exchange(packet, host: host, port: port, timeout: timeout)
            if packet != MiioPacket.hello, let token = tokens[host] {
                let request = try Self.json(packet, token: token)
                let reply = try Self.json(response, token: token)
                let method = request.field("method")?.stringValue ?? ""
                let values = reply.field("result")?.elements ?? []
                let matched = reply.field("id") == request.field("id") && reply.field("error") == nil
                let successful: Bool
                if method == "get_properties" { successful = values.contains { $0.field("code")?.intValue == 0 } }
                else if method == "get_prop" { successful = !values.isEmpty && values.contains { $0 != .null } }
                else { successful = !values.isEmpty && values.allSatisfy { $0.field("code")?.intValue == 0 || $0.stringValue == "ok" || $0 == .number(0) } }
                // Count confirmed property operations, not hellos, mere socket replies or heartbeats.
                if matched && successful {
                    let background = storage.lifecycle()?.phase == "background"
                    if method == "get_properties" || method == "get_prop" {
                        counts.reads += 1; counts.lastRead = Date()
                        if background { counts.backgroundReads += 1 }
                    } else if method.hasPrefix("set_") {
                        counts.writes += 1; counts.lastWrite = Date()
                        if background { counts.backgroundWrites += 1 }
                    }
                }
            }
            return response
        } catch { counts.failures += 1; throw error }
    }
    func broadcast(_ packet: Data, port: UInt16, duration: Duration, rounds: Int) async throws -> [MiioDatagram] {
        try await inner.broadcast(packet, port: port, duration: duration, rounds: rounds)
    }
    private static func json(_ packet: Data, token: Data) throws -> JSONValue {
        let (_, body) = try MiioPacket.decode(packet, token: token)
        return try JSONDecoder().decode(JSONValue.self, from: body.prefix { $0 != 0 })
    }
}
