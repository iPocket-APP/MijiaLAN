import Foundation
import MijiaLAN

public struct PrototypeConfiguration: Codable, Sendable, Equatable {
    public var home: LocalHomeConfig
    public var fixture: Bool
    public var pollSeconds: Int
    public var fixtureUDPHost: String?
    /// Nil/false keeps background writes exclusively under the external controller.
    public var fixtureSelfTestWrites: Bool?

    public init(home: LocalHomeConfig, fixture: Bool = false, pollSeconds: Int = 5) {
        self.home = home
        self.fixture = fixture
        self.pollSeconds = pollSeconds
        self.fixtureUDPHost = nil
        self.fixtureSelfTestWrites = nil
    }

    public func validated() throws -> Self {
        guard (2...60).contains(pollSeconds), !home.devices.isEmpty, home.devices.count <= 4 else {
            throw PrototypeError.invalidConfiguration
        }
        var identifiers = Set<String>()
        for device in home.devices {
            guard !device.did.isEmpty, !device.model.isEmpty, !device.name.isEmpty,
                  !device.host.isEmpty, MiioToken.parse(device.token) != nil,
                  identifiers.insert(device.did).inserted else { throw PrototypeError.invalidConfiguration }
        }
        if let fixtureUDPHost {
            let octets = fixtureUDPHost.split(separator: ".").compactMap { UInt8($0) }
            guard fixture, octets.count == 4,
                  octets.map(String.init).joined(separator: ".") == fixtureUDPHost,
                  octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1])) ||
                    (octets[0] == 192 && octets[1] == 168) else { throw PrototypeError.invalidConfiguration }
        }
        if fixtureSelfTestWrites == true && (!fixture || fixtureUDPHost == nil) {
            throw PrototypeError.invalidConfiguration
        }
        if fixture {
            var expected = Self.fixtureConfiguration.home
            expected.devices[0].host = fixtureUDPHost ?? "127.0.0.1"
            guard home == expected else { throw PrototypeError.invalidConfiguration }
        }
        return self
    }

    public static let fixtureConfiguration = PrototypeConfiguration(home: LocalHomeConfig(devices: [
        LocalDevice(did: "77", name: "实验净化器", model: "zhimi.airpurifier.rma1", host: "127.0.0.1",
                    token: "00112233445566778899aabbccddeeff")
    ]), fixture: true)

    public static func udpFixture(host: String, selfTestWrites: Bool = false) throws -> Self {
        var value = fixtureConfiguration
        value.fixtureUDPHost = host
        value.fixtureSelfTestWrites = selfTestWrites
        value.home.devices[0].host = host
        return try value.validated()
    }
}

public enum PrototypeError: Error, LocalizedError, Sendable {
    case invalidConfiguration, keychainUnavailable, sharedContainerUnavailable, noRuntime, timedOut, diagnosticsTimedOut, noPower
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "设备配置无效；原型支持 1–4 台设备，轮询间隔 2–60 秒。"
        case .keychainUnavailable: "无法访问实验钥匙串，请检查共享 Keychain 签名配置。"
        case .sharedContainerUnavailable: "无法访问实验 App Group，请检查签名配置。"
        case .noRuntime: "服务尚未启动。"
        case .timedOut: "扩展未在 5 秒内回复。"
        case .diagnosticsTimedOut: "扩展未在 30 秒内完成诊断。"
        case .noPower: "该设备没有可写的电源属性。"
        }
    }
}

public enum PrototypeExecutor: String, Codable, Sendable {
    case networkExtension, simulatorForeground, deviceForeground, hostTest
}

public struct LifecycleMarker: Codable, Sendable {
    public var phase: String
    public var at: Date
    public init(phase: String, at: Date = Date()) { self.phase = phase; self.at = at }
}

public struct DeviceEvidence: Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var online: Bool
    public var isOn: Bool?
    public var lastReadingAt: Date?
}

/// Redacted diagnostics. A heartbeat alone is deliberately not counted as device connectivity.
public struct PrototypeEvidence: Codable, Sendable {
    public var sessionID = UUID()
    public var executor: PrototypeExecutor
    public var platform: String? = Self.currentPlatform
    public var fixture: Bool
    public var processID = ProcessInfo.processInfo.processIdentifier
    public var startedAt = Date()
    public var updatedAt = Date()
    public var stoppedAt: Date?
    public var heartbeat: UInt64 = 0
    public var largestHeartbeatGap: Double = 0
    public var appPhase = "unknown"
    public var authenticatedReads: UInt64 = 0
    public var acknowledgedWrites: UInt64 = 0
    public var backgroundReads: UInt64 = 0
    public var backgroundWrites: UInt64 = 0
    public var transportFailures: UInt64 = 0
    public var lastAuthenticatedReadAt: Date?
    public var lastAcknowledgedWriteAt: Date?
    public var bridgeStatus = "waiting"
    public var bridgePort: UInt16?
    public var paired = false
    public var devices: [DeviceEvidence] = []
    public var lastSystemEvent: String?
    public var networkSettings: TunnelNetworkSummary?
    public var transportKind: String?
    public var fixtureSelfTestWrites: Bool?

    public init(executor: PrototypeExecutor, fixture: Bool) { self.executor = executor; self.fixture = fixture }

    private static var currentPlatform: String {
        #if os(iOS)
        "iOS"
        #elseif os(tvOS)
        "tvOS"
        #elseif os(macOS)
        "macOS"
        #else
        "unknown"
        #endif
    }
}

public enum PrototypeRequest: Codable, Sendable {
    case status
    case refresh
    case power(did: String, on: Bool)
    case diagnostics(id: UUID)
}

public struct PrototypeReply: Codable, Sendable {
    public var evidence: PrototypeEvidence?
    public var error: String?
    public init(evidence: PrototypeEvidence? = nil, error: String? = nil) { self.evidence = evidence; self.error = error }
}
