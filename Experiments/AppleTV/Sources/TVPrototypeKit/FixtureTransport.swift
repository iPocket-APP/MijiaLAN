import Foundation
import MijiaCore
import MijiaLAN

/// Deterministic fixture. It exercises real miIO framing/encryption, but performs no UDP I/O.
/// Every diagnostic and UI snapshot retains fixture=true, including when hosted by an extension.
public actor FixtureTransport: MiioTransport {
    private var values: [String: JSONValue] = [:]
    public init() {
        if let schema = DeviceSchema.bundled(model: "zhimi.airpurifier.rma1") {
            for capability in DeviceCapabilityCatalog.capabilities(schema: schema, model: "zhimi.airpurifier.rma1") where capability.readable {
                values["\(capability.siid).\(capability.iid)"] = capability.format == "bool" ? .bool(false)
                    : .number(capability.options.first.map { Double($0.value) } ?? capability.min ?? 0)
            }
        }
        values["2.1"] = .bool(false)
        values["3.1"] = .number(45)
        values["3.7"] = .number(22)
    }

    public func exchange(_ packet: Data, host: String, port: UInt16, timeout: Duration) async throws -> Data {
        guard host == "127.0.0.1" else { throw MiioError.hostUnreachable }
        if packet == MiioPacket.hello {
            return Data([0x21, 0x31, 0, 32, 0, 0, 0, 0, 0, 0, 0, 77, 0, 0, 0x13, 0x88] + [UInt8](repeating: 255, count: 16))
        }
        let token = MiioToken.parse("00112233445566778899aabbccddeeff")!
        let (_, bytes) = try MiioPacket.decode(packet, token: token)
        let request = try JSONDecoder().decode(JSONValue.self, from: bytes.prefix { $0 != 0 })
        let result: JSONValue
        switch request.field("method")?.stringValue {
        case "miIO.info": result = .object(["model": .string("zhimi.airpurifier.rma1")])
        case "get_properties", "set_properties":
            let writing = request.field("method")?.stringValue == "set_properties"
            result = .array((request.field("params")?.elements ?? []).map { property in
                let key = "\(property.field("siid")?.intValue ?? 0).\(property.field("piid")?.intValue ?? 0)"
                if writing, let value = property.field("value") { values[key] = value }
                var reply: [String: JSONValue] = ["did": property.field("did") ?? .string("77"),
                    "siid": property.field("siid") ?? .null, "piid": property.field("piid") ?? .null,
                    "code": .number(values[key] == nil ? -4003 : 0)]
                if !writing { reply["value"] = values[key] ?? .null }
                return .object(reply)
            })
        default: result = .array([.object(["code": .number(-4004)])])
        }
        let body = JSONValue.object(["id": request.field("id") ?? .null, "result": result])
        return try MiioPacket.encode(Data(body.compactJSONString.utf8) + [0], token: token, deviceID: 77, stamp: 5000)
    }
    public func broadcast(_ packet: Data, port: UInt16, duration: Duration, rounds: Int) async throws -> [MiioDatagram] { [] }
}
