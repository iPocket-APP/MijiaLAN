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
    private let identity: HAPIdentity
    private let pairingStore: any PairingStore
    private let deviceID: String
    private let setupID: String
    private let logger: Logger
    private var advertising = false
    private var publication: Task<Void, Error>?
    private var lastAcceptedPublication: BonjourPublication?
    private var lastFailedPublication: BonjourPublication?

    public struct BonjourPublication: Encodable, Sendable {
        enum Operation: String, Encodable, Sendable { case start, pairing, configuration, state, refresh }
        let at: Date
        let operation: Operation
        let port: UInt16
        let sf: Int
        let configurationNumber: Int
        let stateNumber: Int
        let dnsServiceError: Int?
    }

    public struct BonjourDiagnostics: Encodable, Sendable {
        let publishingEnabled: Bool
        let lastAccepted: BonjourPublication?
        public let lastFailure: BonjourPublication?
    }

    public struct BonjourObservation: Encodable, Sendable {
        struct Record: Encodable, Sendable {
            let sf: Int?
            let configurationNumber: Int?
            let stateNumber: Int?
        }
        let at: Date
        let browserState: String
        let dnsError: Int?
        let posixError: Int?
        let matchingInstances: Int
        let records: [Record]
        let otherMijiaLANInstances: Int
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
        .init(publishingEnabled: advertising, lastAccepted: lastAcceptedPublication, lastFailure: lastFailedPublication)
    }

    /// A bounded snapshot of the local Mac's browse results, only on diagnostic export.
    /// Bonjour names, addresses and TXT fields for neighboring devices stay out of the report.
    public func observeBonjour() async -> BonjourObservation? {
        guard advertising else { return nil }
        let name = await bridge.accessoryDatabase().first?.name ?? "HAP Bridge"
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_hap._tcp", domain: "local."), using: .tcp)
        browser.start(queue: DispatchQueue(label: "hap.diagnostic.bonjour"))
        defer { browser.cancel() }
        do { try await MonotonicClock.sleep(for: .milliseconds(1500)) } catch { return nil }
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
        var records: [BonjourObservation.Record] = []
        for result in browser.browseResults {
            guard case .service(let instance, _, let domain, _) = result.endpoint,
                  case .bonjour(let txt) = result.metadata else { continue }
            let service = instance + "." + domain
            if txt["id"]?.caseInsensitiveCompare(deviceID) == .orderedSame {
                matching.insert(service)
                records.append(.init(sf: txt["sf"].flatMap { UInt8($0) }.map(Int.init),
                    configurationNumber: txt["c#"].flatMap { UInt16($0) }.map(Int.init),
                    stateNumber: txt["s#"].flatMap { UInt16($0) }.map(Int.init)))
            } else if txt["md"] == name {
                other.insert(service)
            }
        }
        return .init(at: Date(), browserState: state, dnsError: dnsError, posixError: posixError,
                     matchingInstances: matching.count,
                     records: Array(records.prefix(16)), otherMijiaLANInstances: other.count)
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
