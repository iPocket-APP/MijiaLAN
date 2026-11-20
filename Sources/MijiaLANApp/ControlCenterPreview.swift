#if DEBUG
import Foundation
import MijiaSupport
import MijiaCore
import MijiaLAN

/// Isolated native UI preview. No Keychain, Home bridge, discovery broadcast or real device traffic.
/// Addresses use the RFC 5737 TEST-NET-1 documentation range; names, rooms and tokens are fixtures.
enum ControlCenterPreview {
    static let config: LocalHomeConfig = {
        let rows = [
            ("plug", "插座", "chuangmi.plug.m3", "卧室", "192.0.2.1"),
            ("purifier", "米家空气净化器 4 Lite", "zhimi.airpurifier.rma1", "卧室", "192.0.2.2"),
            ("lamp", "台灯", "yeelink.light.lamp4", "卧室", "192.0.2.3"),
            ("blender", "米家智能破壁料理机", "chunmi.juicer.a1", "厨房", "192.0.2.4"),
            ("kettle", "米家智能多功能养生壶", "chunmi.health_pot.a1", "客厅", "192.0.2.5"),
            ("ac", "空调插座", "lumi.acpartner.mcn02", "卧室", "192.0.2.6"),
            ("fryer", "米家智能空气炸锅 5.5L 可视版", "careli.fryer.maf07c", "厨房", "192.0.2.7"),
            ("cooker", "米家智能微压 IH 电饭煲 3L", "chunmi.cooker.cmwy3", "厨房", "192.0.2.8"),
            ("fan", "米家智能直流变频循环扇 落地式", "dmaker.fan.p28", "卧室", "192.0.2.9"),
            ("plug3", "客厅-米家智能插座 3", "cuco.plug.v3", "客厅", "192.0.2.10"),
            ("plug2", "米家智能插座 3", "cuco.plug.v3", "卧室", "192.0.2.11")
        ]
        return LocalHomeConfig(devices: rows.map { LocalDevice(did: $0.0, name: $0.1, model: $0.2, host: $0.4, token: String(repeating: "0", count: 32), roomName: $0.3) })
    }()
}

actor ControlCenterPreviewTransport: MiioTransport {
    private let token = Data(repeating: 0, count: 16)
    private let latency: TimeSpan
    private var values: [String: [String: JSONValue]] = [
        "192.0.2.2": [
            "2.1": .bool(false), "2.2": .number(0), "2.4": .number(1),
            "3.1": .number(52), "3.4": .number(8), "3.7": .number(23.4),
            "4.1": .number(76), "4.3": .number(44), "4.4": .number(137),
            "6.1": .bool(true), "8.1": .bool(false), "9.1": .number(0), "9.2": .number(14),
            "13.2": .number(1)
        ],
        "192.0.2.3": ["power": .string("on"), "bright": .number(71), "ct": .number(3500)],
        "192.0.2.6": ["power": .string("off"), "mode": .string("auto"), "tar_temp": .number(29),
                          "fan_level": .string("auto_fan"), "ver_swing": .string("on"), "load_power": .number(1)]
    ]

    init() {
        let milliseconds = Int(ProcessInfo.processInfo.environment["MIJIALAN_UI_PREVIEW_DELAY_MS"] ?? "") ?? 0
        latency = .milliseconds(max(0, milliseconds))
    }

    func exchange(_ packet: Data, host: String, port: UInt16, timeout: TimeSpan) async throws -> Data {
        guard values[host] != nil else { throw MiioError.hostUnreachable }
        if packet == MiioPacket.hello {
            var hello: [UInt8] = [0x21, 0x31, 0, 32, 0, 0, 0, 0]
            hello += [0, 0, 0, 123, 0, 0, 0x13, 0x88]
            return Data(hello + [UInt8](repeating: 255, count: 16))
        }
        let (_, payload) = try MiioPacket.decode(packet, token: token)
        guard case .object(let request) = try JSONDecoder().decode(JSONValue.self, from: payload.prefix { $0 != 0 }) else { throw MiioError.timeout }
        let method = request["method"]?.stringValue ?? ""
        if latency > .zero { try await MonotonicClock.sleep(for: latency) }
        let args: [JSONValue]
        if case .array(let array) = request["params"] { args = array } else { args = [] }
        let result: JSONValue
        if method == "miIO.info" {
            guard let device = ControlCenterPreview.config.devices.first(where: { $0.host == host }) else { throw MiioError.hostUnreachable }
            result = .object(["model": .string(device.model)])
        } else if host == "192.0.2.2", method == "get_properties" || method == "set_properties" {
            result = .array(args.map { item in
                guard case .object(var reply) = item, let service = reply["siid"]?.integer,
                      let property = reply["piid"]?.integer else { return .object(["code": .number(-4003)]) }
                let key = "\(service).\(property)"
                let written = reply.removeValue(forKey: "value")
                guard let current = values[host]?[key] else {
                    reply["code"] = .number(-4003)
                    return .object(reply)
                }
                reply["code"] = .number(0)
                if method == "get_properties" { reply["value"] = current }
                else if let written { values[host]?[key] = written }
                return .object(reply)
            })
        } else if method == "get_prop" {
            result = .array(args.map { values[host]?[$0.stringValue ?? ""] ?? .null })
        } else if method.hasPrefix("set_"), let value = args.first {
            values[host]?[method == "set_ct_abx" ? "ct" : String(method.dropFirst(4))] = value
            result = .array([.string("ok")])
        } else { throw MiioError.unsupportedByLegacyDevice }
        let reply = JSONValue.object(["id": request["id"] ?? .number(0), "result": result])
        return try MiioPacket.encode(Data(reply.compactJSONString.utf8) + [0], token: token, deviceID: 123, stamp: 5000)
    }

    func broadcast(_ packet: Data, port: UInt16, duration: TimeSpan, rounds: Int) async throws -> [MiioDatagram] { [] }
}
#endif
