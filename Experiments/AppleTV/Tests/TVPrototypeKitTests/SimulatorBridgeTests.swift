import Foundation
import HAPCore
import MijiaCore
@testable import MijiaLAN
import Testing

struct SimulatorBridgeTests {
    /// Opt-in: connects to a dedicated fixture bridge on Simulator or a physical device.
    /// The private endpoint file contains its optional LAN host, port and displayed setup code.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MIJIALAN_TV_EXTERNAL_FIXTURE"] != nil))
    func simulatorBridge() async throws {
        struct Endpoint: Decodable {
            var host: String?
            var port: UInt16
            var setupCode: String
            var observationSeconds: Int?
            var checkpointPath: String?
        }
        let path = try #require(ProcessInfo.processInfo.environment["MIJIALAN_TV_EXTERNAL_FIXTURE"])
        let endpoint = try JSONDecoder().decode(Endpoint.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let client = WireHAPController(host: endpoint.host ?? "127.0.0.1", port: endpoint.port)
        do {
            try await client.connect()
            try await client.pair(setupCode: endpoint.setupCode)
            try await client.verify()
            let reply = try await client.request("GET", "/accessories")
            let json = try JSONDecoder().decode(JSONValue.self, from: reply.body)
            let accessory = try #require(json["accessories"]?.arrayValue?.first { $0["aid"]?.intValue == 2 })
            let chars = accessory["services"]?.arrayValue?.flatMap { $0["characteristics"]?.arrayValue ?? [] } ?? []
            // Refuse writes unless the peer is the dedicated fixture accessory.
            let fixture = chars.contains { $0["type"]?.stringValue == "23" && $0["value"]?.stringValue == "实验净化器" }
            guard fixture else { throw WireHAPController.Failure.invalidPairing }
            let active = try #require(chars.first { $0["type"]?.stringValue == "B0" }?["iid"]?.intValue)
            func control(_ on: Bool) async throws {
                let write = JSONValue.object(["characteristics": .array([.object([
                    "aid": .number(2), "iid": .number(Double(active)), "value": .number(on ? 1 : 0)
                ])])])
                let acknowledgement = try await client.request("PUT", "/characteristics", body: Data(write.compactJSONString.utf8))
                try #require(acknowledgement.status == 204)
                let read = try await client.request("GET", "/characteristics?id=2.\(active)")
                let result = try JSONDecoder().decode(JSONValue.self, from: read.body)
                try #require(result["characteristics"]?.arrayValue?.first?["value"]?.intValue == (on ? 1 : 0))
            }
            for on in [true, false] { try await control(on) }
            if let seconds = endpoint.observationSeconds, seconds > 0 {
                try #require((15...900).contains(seconds))
                let subscription = JSONValue.object(["characteristics": .array([.object([
                    "aid": .number(2), "iid": .number(Double(active)), "ev": .bool(true)
                ])])])
                #expect(try await client.request("PUT", "/characteristics", body: Data(subscription.compactJSONString.utf8)).status == 204)
                let started = Date()
                var commands = 0
                var notifications = 0
                var earlierEvents = 0
                func checkpoint(_ phase: String) throws {
                    guard let path = endpoint.checkpointPath else { return }
                    let values: [String: Any] = ["phase": phase, "fixture": true,
                        "startedAtUnix": started.timeIntervalSince1970, "atUnix": Date().timeIntervalSince1970,
                        "externalHAPWrites": commands, "confirmedEvents": notifications,
                        "earlierEventsDiscarded": earlierEvents]
                    try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
                        .write(to: URL(fileURLWithPath: path), options: .atomic)
                }
                try checkpoint("paired")
                var on = true
                while Date().timeIntervalSince(started) < Double(seconds) {
                    try await Task.sleep(for: .seconds(15))
                    // Subscribing sends an immediate cached-state EVENT. Drain earlier
                    // notifications behind a GET response before attributing a fresh one.
                    _ = try await client.request("GET", "/characteristics?id=2.\(active)")
                    earlierEvents += await client.discardQueuedEvents()
                    try await control(on)
                    commands += 1
                    var confirmed = false
                    for _ in 0..<12 {
                        let event = try await client.nextEvent()
                        let value = try JSONDecoder().decode(JSONValue.self, from: event.body)
                        if let reading = value["characteristics"]?.arrayValue?.first(where: {
                            $0["aid"]?.intValue == 2 && $0["iid"]?.intValue == active
                        }) {
                            if reading["value"]?.intValue == (on ? 1 : 0) {
                                confirmed = true
                                break
                            }
                            earlierEvents += 1
                        }
                    }
                    try #require(confirmed)
                    notifications += 1
                    try checkpoint("observing")
                    on.toggle()
                }
                try await control(false)
                try checkpoint("complete")
            }
            try await unpair(client)
            await client.close()
        } catch {
            try? await unpair(client)
            await client.close()
            throw error
        }
    }
    private func unpair(_ client: WireHAPController) async throws {
        let body = TLV8.encode([(6, Data([1])), (0, Data([4])), (1, Data(client.identifier.utf8))])
        _ = try await client.request("POST", "/pairings", body: body)
    }
}
