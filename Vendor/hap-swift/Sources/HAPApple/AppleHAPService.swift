// AppleHAPService.swift
// Modified for MijiaLAN; see Vendor/hap-swift/README.md.
// Copyright 2026 Monagle Pty Ltd

#if canImport(Network)
import Foundation
import Logging
import MijiaSupport
import MDNSApple
import Network
import dnssd
import HAPCore
import HAPCrypto
import HAPTransport

// MARK: - AppleHAPService

/// High-level HAP service for Apple platforms. Combines TCP server, mDNS advertisement, and bridge management.
public actor AppleHAPService {
    private let bridge: HAPBridge
    private let server: AppleTCPServer
    private let advertiser: HAPAdvertiser
    private let discovery: AppleServiceDiscovery
    private let identity: HAPIdentity
    private let pairingStore: any PairingStore
    private let deviceID: String
    private let setupID: String
    private let logger: Logger
    private var advertising = false
    private var publication: Task<Void, Error>?
    private var lastAcceptedPublication: BonjourPublication?
    private var lastFailedPublication: BonjourPublication?
    private var lastPairingPublication: BonjourPublication?

    public struct BonjourPublication: Encodable, Sendable {
        public enum Operation: String, Encodable, Sendable { case start, pairing, configuration, state, refresh }
        public let at: Date
        public let operation: Operation
        let port: UInt16
        public let sf: Int
        let configurationNumber: Int
        let stateNumber: Int
        let dnsServiceError: Int?
    }

    public struct BonjourDiagnostics: Encodable, Sendable {
        let publishingEnabled: Bool
        public let lastAccepted: BonjourPublication?
        public let lastFailure: BonjourPublication?
        public let lastPairingPublication: BonjourPublication?
    }

    public struct BonjourObservation: Encodable, Sendable {
        public struct Record: Encodable, Sendable {
            public let sf: Int?
            let configurationNumber: Int?
            let stateNumber: Int?
            public let setupHashMatches: Bool?
            let interfaces: [String]
            public fileprivate(set) var resolvedPort: UInt16?
        }
        let at: Date
        public let browserState: String
        public let dnsError: Int?
        public let posixError: Int?
        public let listenerPort: UInt16
        public let matchingInstances: Int
        public let previousBridgeVisible: Bool?
        public let records: [Record]
        public let otherMijiaLANInstances: Int
        public let otherInstancesMatchingSetupHash: Int
    }

    public init(
        info: AccessoryInfo,
        setupCode: String,
        deviceID: String,
        setupID: String = "ACMN",
        identity: HAPIdentity? = nil,
        pairingStore: (any PairingStore)? = nil,
        logger: Logger = Logger(label: "hap.apple"),
        onHandshake: (@Sendable (Int, HAPHandshakeEvent) -> Void)? = nil
    ) {
        let identity = identity ?? HAPIdentity()
        let pairingStore = pairingStore ?? InMemoryPairingStore()
        let bridge = HAPBridge(info: info)
        let discovery = AppleServiceDiscovery(logger: logger)

        self.bridge = bridge
        self.identity = identity
        self.pairingStore = pairingStore
        self.deviceID = deviceID
        self.setupID = setupID
        self.logger = logger
        self.discovery = discovery
        self.advertiser = HAPAdvertiser(discovery: discovery, deviceID: deviceID)
        self.server = AppleTCPServer(
            bridge: bridge,
            setupCode: setupCode,
            identity: identity,
            pairingStore: pairingStore,
            deviceID: deviceID,
            logger: logger,
            onHandshake: onHandshake
        )
    }

    /// Create a HAP service using an existing bridge that already has accessories provisioned.
    public init(
        bridge: HAPBridge,
        setupCode: String,
        deviceID: String,
        setupID: String = "ACMN",
        identity: HAPIdentity? = nil,
        pairingStore: (any PairingStore)? = nil,
        logger: Logger = Logger(label: "hap.apple"),
        onHandshake: (@Sendable (Int, HAPHandshakeEvent) -> Void)? = nil
    ) {
        let identity = identity ?? HAPIdentity()
        let pairingStore = pairingStore ?? InMemoryPairingStore()
        let discovery = AppleServiceDiscovery(logger: logger)

        self.bridge = bridge
        self.identity = identity
        self.pairingStore = pairingStore
        self.deviceID = deviceID
        self.setupID = setupID
        self.logger = logger
        self.discovery = discovery

        let advertiser = HAPAdvertiser(discovery: discovery, deviceID: deviceID)
        self.advertiser = advertiser

        self.server = AppleTCPServer(
            bridge: bridge,
            setupCode: setupCode,
            identity: identity,
            pairingStore: pairingStore,
            deviceID: deviceID,
            logger: logger,
            onHandshake: onHandshake
        )
    }

    // MARK: - Port

    /// The TCP port the server is listening on. Zero until ``start(port:)`` completes.
    public nonisolated var port: UInt16 { server.port }

    public nonisolated func diagnosticConnections() -> [HAPConnectionDiagnostic] {
        server.diagnosticConnections()
    }

    // MARK: - Lifecycle

    public func start(port: UInt16 = 0, loopbackOnly: Bool = false) async throws {
        server.onPairingChange = { [weak self] in try? await self?.publish(.pairing) }

        // Wire up event notifications — when characteristics change, the bridge
        // sends encrypted EVENT/1.0 messages to subscribed connections.
        await bridge.setCharacteristicChangeHandler { [server] subscribers, eventData in
            for connectionID in subscribers {
                await server.sendEvent(eventData, to: connectionID)
            }
        }

        try await server.start(port: port, loopbackOnly: loopbackOnly)
        if !loopbackOnly {
            advertising = true
            do {
                try await publish(.start)
            } catch {
                await stop()
                throw error
            }
            // Install these only after a successful start. A discarded port candidate must not publish later.
            await bridge.addAccessoryChangeHandler { [weak self] _ in try? await self?.publish(.configuration) }
            await bridge.addStateNumberChangeHandler { [weak self] _ in try? await self?.publish(.state) }
        }

        logger.info("HAP service started on port \(server.port), device ID: \(deviceID)")
    }

    public func stop() async {
        advertising = false
        _ = try? await publication?.value
        await advertiser.stopAdvertising()
        await server.stop()
        logger.info("HAP service stopped")
    }

    // MARK: - Accessory Management

    @discardableResult
    public func addAccessory(info: AccessoryInfo, services: [HAPService], aid: UInt64? = nil) async -> UInt64 {
        await bridge.addAccessory(info: info, services: services, aid: aid)
    }

    public func removeAccessory(aid: UInt64) async {
        await bridge.removeAccessory(aid: aid)
    }

    // MARK: - Re-advertisement

    /// Re-advertise the service with current state.
    ///
    /// Call after externally modifying the pairing store (e.g., clearing all
    /// pairings via an admin flow) so the mDNS TXT record reflects the new
    /// pairing status (`sf` flag) without restarting.
    public func reAdvertise() async throws {
        try await publish(.refresh)
    }

    private func publish(_ operation: BonjourPublication.Operation) async throws {
        guard advertising else { return }
        let previous = publication
        let next = Task {
            _ = try? await previous?.value
            try await publishCurrentTXT(operation)
        }
        publication = next
        defer {
            if publication == next { publication = nil }
        }
        try await next.value
    }

    private func publishCurrentTXT(_ operation: BonjourPublication.Operation) async throws {
        guard advertising else { return }
        let name = await bridge.accessoryDatabase().first?.name ?? "HAP Bridge"
        let category = await bridge.category
        let configNumber = await bridge.currentConfigurationNumber
        let stateNumber = await bridge.currentStateNumber
        let isPaired = await pairingStore.isPaired
        let port = server.port
        let sf = isPaired ? 0 : 1
        do {
            // A c# change still re-registers the service so Home re-reads /accessories. A pairing or s# change
            // updates in place, so the controller does not see the bridge disappear mid-handshake.
            switch operation {
            case .pairing, .state:
                try await advertiser.updateStateNumber(name: name, port: port, category: category, setupID: setupID,
                    configNumber: configNumber, stateNumber: stateNumber, isPaired: isPaired)
            case .start, .configuration, .refresh:
                try await advertiser.advertise(name: name, port: port, category: category, setupID: setupID,
                    configNumber: configNumber, stateNumber: stateNumber, isPaired: isPaired)
            }
            lastAcceptedPublication = .init(at: Date(), operation: operation, port: port, sf: sf,
                configurationNumber: configNumber, stateNumber: stateNumber, dnsServiceError: nil)
            if operation == .pairing { lastPairingPublication = lastAcceptedPublication }
        } catch {
            let code: Int?
            if case ServiceDiscoveryError.registrationFailed(let value) = error { code = value } else { code = nil }
            lastFailedPublication = .init(at: Date(), operation: operation, port: port, sf: sf,
                configurationNumber: configNumber, stateNumber: stateNumber, dnsServiceError: code)
            logger.warning("Could not publish HAP Bonjour record for \(operation.rawValue): \(error)")
            throw error
        }
    }

    public func bonjourDiagnostics() -> BonjourDiagnostics {
        .init(publishingEnabled: advertising, lastAccepted: lastAcceptedPublication, lastFailure: lastFailedPublication,
              lastPairingPublication: lastPairingPublication)
    }

    /// A bounded snapshot of the local Mac's browse results, only on diagnostic export.
    /// Bonjour names, addresses and TXT fields for neighboring devices stay out of the report.
    public func observeBonjour(previousDeviceID: String? = nil) async -> BonjourObservation? {
        guard advertising else { return nil }
        let name = await bridge.accessoryDatabase().first?.name ?? "HAP Bridge"
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_hap._tcp", domain: "local."), using: .tcp)
        browser.start(queue: DispatchQueue(label: "hap.diagnostic.bonjour"))
        defer { browser.cancel() }
        let deadline = MonotonicClock.now + .seconds(5)
        do {
            try await MonotonicClock.sleep(for: .milliseconds(1500))
            // A new registration or a name conflict can take longer than a single browse interval.
            while MonotonicClock.now < deadline && !browser.browseResults.contains(where: { result in
                guard case .bonjour(let txt) = result.metadata else { return false }
                return txt["id"]?.caseInsensitiveCompare(deviceID) == .orderedSame
            }) {
                if case .failed = browser.state { break }
                try await MonotonicClock.sleep(for: .milliseconds(150))
            }
        } catch { return nil }
        let state: String
        let error: NWError?
        switch browser.state {
        case .ready: (state, error) = ("ready", nil)
        case .waiting(let reason): (state, error) = ("waiting", reason)
        case .failed(let reason): (state, error) = ("failed", reason)
        case .cancelled: (state, error) = ("cancelled", nil)
        default: (state, error) = ("setup", nil)
        }
        let dnsError: Int? = if case .dns(let code) = error { Int(code) } else { nil }
        let posixError: Int? = if case .posix(let code) = error { Int(code.rawValue) } else { nil }

        var matching = Set<String>()
        var other = Set<String>()
        var otherWithSameSetupHash = Set<String>()
        var previousBridgeVisible = false
        var ownRecords: [(name: String, type: String, domain: String, index: UInt32, record: BonjourObservation.Record)] = []
        let listenerPort = server.port
        let expectedSetupHash = HAPKeyDerivation.setupHash(setupID: setupID, deviceID: deviceID)
        for result in browser.browseResults {
            guard case .service(let instance, let type, let domain, let interface) = result.endpoint,
                  case .bonjour(let txt) = result.metadata else { continue }
            let service = instance + "." + domain
            let setupHashMatches = txt["sh"].map { $0 == expectedSetupHash }
            if txt["id"]?.caseInsensitiveCompare(deviceID) == .orderedSame {
                matching.insert(service)
                if ownRecords.count < 8 {
                    let sf = txt["sf"].flatMap { Int($0) }
                    let configurationNumber = txt["c#"].flatMap { Int($0) }
                    let stateNumber = txt["s#"].flatMap { Int($0) }
                    let interfaces = Set(result.interfaces.map { String(describing: $0.type) }).sorted()
                    let record = BonjourObservation.Record(sf: sf, configurationNumber: configurationNumber,
                        stateNumber: stateNumber, setupHashMatches: setupHashMatches, interfaces: interfaces)
                    ownRecords.append((instance, type, domain, UInt32(interface?.index ?? 0), record))
                }
            } else {
                if let previousDeviceID, txt["id"]?.caseInsensitiveCompare(previousDeviceID) == .orderedSame {
                    previousBridgeVisible = true
                }
                if txt["md"] == name { other.insert(service) }
                if setupHashMatches == true { otherWithSameSetupHash.insert(service) }
            }
        }
        let observedAt = Date()
        let records = await withTaskGroup(of: BonjourObservation.Record.self, returning: [BonjourObservation.Record].self) { group in
            for item in ownRecords {
                group.addTask { [discovery] in
                    var record = item.record
                    record.resolvedPort = try? await discovery.resolveServicePort(name: item.name, type: item.type,
                        domain: item.domain, interfaceIndex: item.index)
                    return record
                }
            }
            var result: [BonjourObservation.Record] = []
            for await record in group { result.append(record) }
            return result
        }
        return .init(at: observedAt, browserState: state, dnsError: dnsError, posixError: posixError,
                     listenerPort: listenerPort, matchingInstances: matching.count,
                     previousBridgeVisible: previousDeviceID != nil && state == "ready" ? previousBridgeVisible : nil,
                     records: records, otherMijiaLANInstances: other.count,
                     otherInstancesMatchingSetupHash: otherWithSameSetupHash.count)
    }

    // MARK: - Batch Updates

    /// Begin a batch update — suppresses re-advertisement until ``endBatchUpdate()`` is called.
    public func beginBatchUpdate() async {
        await bridge.beginBatchUpdate()
    }

    /// End a batch update — re-advertises once with updated configuration number.
    public func endBatchUpdate() async {
        await bridge.endBatchUpdate()
    }
}
#endif
