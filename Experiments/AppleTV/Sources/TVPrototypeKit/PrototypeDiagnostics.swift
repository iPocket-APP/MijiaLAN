import Foundation
import MijiaCore
import MijiaHomeKitBridge
import MijiaLAN

/// Portable counterpart of the desktop DiagnosticReport's explicit allow-list.
/// LocalDevice, endpoints, tokens, identities and setup codes are never serialized.
public struct PrototypeDiagnostics: Codable, Sendable, Identifiable {
    public enum Source: String, Codable, Sendable {
        case liveRuntime, savedRuntime, notRunning, designPreview
    }
    public struct App: Codable, Sendable {
        public var version: String
        public var build: String
        public init() {
            version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        }
    }
    public struct Reading: Codable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var value: String?
        public var code: Int?
        public var error: String?
        public var updatedAt: Date?
        public var available: Bool
        public init(id: String, name: String, value: String? = nil, code: Int? = nil,
                    error: String? = nil, updatedAt: Date? = nil, available: Bool = false) {
            self.id = id; self.name = name; self.value = value; self.code = code
            self.error = error; self.updatedAt = updatedAt; self.available = available
        }
    }
    public struct HomeKitFailure: Codable, Sendable, Identifiable {
        public var id = UUID()
        public var service: String
        public var characteristic: String
        public var source: String
        public var status: Int
    }
    public struct Device: Codable, Sendable, Identifiable {
        public var did: String
        public var name: String
        public var model: String
        public var health: String
        public var homeIncluded = true
        public var specType: String?
        public var lastError: String?
        public var lastSeen: Date?
        public var retryFailures: Int?
        public var nextRetryAt: Date?
        public var isProbing: Bool?
        public var readings: [Reading]
        public var homeKitReadFailures: [HomeKitFailure] = []
        public var id: String { did }
        public var online: Bool { health == "online" }
        public var failedReadings: Int { readings.filter { !$0.available }.count }
        public init(did: String, name: String, model: String, health: String, readings: [Reading] = []) {
            self.did = did; self.name = name; self.model = model; self.health = health; self.readings = readings
        }
    }
    public struct Runtime: Codable, Sendable {
        public var sessionID: UUID
        public var executor: PrototypeExecutor
        public var transportKind: String?
        public var startedAt: Date
        public var updatedAt: Date
        public var stoppedAt: Date?
        public var authenticatedReads: UInt64
        public var acknowledgedWrites: UInt64
        public var backgroundReads: UInt64
        public var backgroundWrites: UInt64
        public var transportFailures: UInt64
        public var networkSettings: TunnelNetworkSummary?
        init(_ evidence: PrototypeEvidence) {
            sessionID = evidence.sessionID; executor = evidence.executor; transportKind = evidence.transportKind
            startedAt = evidence.startedAt; updatedAt = evidence.updatedAt; stoppedAt = evidence.stoppedAt
            authenticatedReads = evidence.authenticatedReads; acknowledgedWrites = evidence.acknowledgedWrites
            backgroundReads = evidence.backgroundReads; backgroundWrites = evidence.backgroundWrites
            transportFailures = evidence.transportFailures; networkSettings = evidence.networkSettings
        }
    }

    public var schemaVersion = 1
    public var id: UUID
    public var recordedAt: Date
    public var exportedAt: Date?
    public var platform = Self.currentPlatform
    public var operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
    public var app = App()
    public var source: Source
    public var fixture: Bool
    public var bridge: String
    public var bridgePort: UInt16?
    public var paired: Bool
    public var accessories: Int
    public var structureRevision: UInt64?
    public var valuesRevision: UInt64?
    public var runtime: Runtime?
    public var activation: PrototypeActivationSummary?
    public var collectionError: String?
    public var devices: [Device]
    public var onlineCount: Int { devices.filter(\.online).count }
    public var failedReadingCount: Int { devices.reduce(0) { $0 + $1.failedReadings } }
    public var homeKitFailureCount: Int { devices.reduce(0) { $0 + $1.homeKitReadFailures.count } }

    public init(id: UUID = UUID(), recordedAt: Date = Date(), source: Source, fixture: Bool,
                bridge: String, paired: Bool, accessories: Int, devices: [Device]) {
        self.id = id; self.recordedAt = recordedAt; self.source = source; self.fixture = fixture
        self.bridge = bridge; self.paired = paired; self.accessories = accessories; self.devices = devices
    }

    @MainActor
    public static func capture(id: UUID, configuration: PrototypeConfiguration, evidence: PrototypeEvidence,
                               snapshots: [DeviceSnapshot], retries: [String: ProbeRetryState],
                               failures: [HomeKitBridgeController.ReadFailure], accessories: Int,
                               revisions: (structure: UInt64, values: UInt64), pairingCode: String?, now: Date = Date()) -> Self {
        let redact = DiagnosticsRedactor(configuration: configuration, pairingCode: pairingCode)
        let byID = Dictionary(snapshots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let failedByID = Dictionary(grouping: failures, by: \.deviceID)
        let rows = configuration.home.devices.sorted { $0.did < $1.did }.map { device -> Device in
            let snapshot = byID[device.did]
            var row = Device(did: redact.clean(device.did), name: redact.clean(device.name),
                model: redact.clean(device.model), health: snapshot.map { String(describing: $0.health.state) } ?? "notChecked")
            row.specType = (snapshot?.schema.type).map(redact.clean)
            row.lastError = snapshot?.health.lastError.map(redact.clean)
            row.lastSeen = snapshot?.health.lastSeen
            if let retry = retries[device.did] {
                row.retryFailures = retry.consecutiveFailures; row.nextRetryAt = retry.nextRetryAt; row.isProbing = retry.isProbing
            }
            row.readings = snapshot?.capabilities.filter(\.readable).sorted { $0.id < $1.id }.map { capability in
                let reading = snapshot?.readings[capability.id]
                return Reading(id: capability.id, name: redact.clean(capability.title),
                    value: reading?.value.map { redact.clean($0.compactJSONString) }, code: reading?.code,
                    error: reading?.error.map(redact.clean), updatedAt: reading?.updatedAt, available: reading?.isAvailable == true)
            } ?? []
            row.homeKitReadFailures = (failedByID[device.did] ?? []).map {
                HomeKitFailure(service: $0.service, characteristic: $0.characteristic, source: redact.clean($0.source), status: $0.status)
            }
            return row
        }
        var report = Self(id: id, recordedAt: now, source: evidence.stoppedAt == nil ? .liveRuntime : .savedRuntime,
            fixture: configuration.fixture, bridge: redact.clean(evidence.bridgeStatus), paired: evidence.paired,
            accessories: accessories, devices: rows)
        report.runtime = Runtime(evidence)
        report.bridgePort = evidence.bridgeStatus == "running" ? evidence.bridgePort : nil
        report.structureRevision = revisions.structure; report.valuesRevision = revisions.values
        return report
    }

    public static func unavailable(configuration: PrototypeConfiguration, evidence: PrototypeEvidence?) -> Self {
        let redact = DiagnosticsRedactor(configuration: configuration)
        var report = Self(source: .notRunning, fixture: configuration.fixture, bridge: "stopped", paired: false,
            accessories: 0, devices: configuration.home.devices.map {
                Device(did: redact.clean($0.did), name: redact.clean($0.name), model: redact.clean($0.model), health: "notChecked")
            })
        report.runtime = evidence.map(Runtime.init)
        return report
    }

    public mutating func markCollectionFailure(_ message: String, configuration: PrototypeConfiguration, pairingCode: String?) {
        collectionError = DiagnosticsRedactor(configuration: configuration, pairingCode: pairingCode).clean(message)
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    private static var currentPlatform: String {
        #if os(tvOS)
        "tvOS"
        #elseif os(iOS)
        "iOS"
        #else
        "macOS"
        #endif
    }
}

/// Even errors and string-valued readings are checked, not just dictionary keys.
struct DiagnosticsRedactor {
    private let secrets: [String]
    init(configuration: PrototypeConfiguration, pairingCode: String? = nil) {
        secrets = (configuration.home.devices.flatMap { [$0.token, $0.host, $0.mac ?? ""] } + [pairingCode ?? ""])
            .filter { !$0.isEmpty }.sorted { $0.count > $1.count }
    }
    func clean(_ text: String) -> String {
        var value = text
        for secret in secrets { value = value.replacingOccurrences(of: secret, with: "[redacted]", options: .caseInsensitive) }
        for pattern in [
            #"(?i)\b[0-9a-f]{32}\b"#,
            #"\b\d{3}-\d{2}-\d{3}\b"#,
            #"(?i)\b(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}\b"#,
            #"(?<![A-Za-z0-9])(?:\d{1,3}\.){3}\d{1,3}(?![A-Za-z0-9])"#,
            #"(?i)(?<![a-z0-9])(?:[0-9a-f]{0,4}:){2,}[0-9a-f]{0,4}(?:%[a-z0-9]+)?(?![a-z0-9])"#
        ] { value = value.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression) }
        return value
    }
}

/// Omits the arbitrary localized message in activation.json; domain/code/stage locate NE failures.
public struct PrototypeActivationSummary: Codable, Sendable {
    public var at: Date
    public var stage: String
    public var errorDomain: String?
    public var errorCode: Int?
}
