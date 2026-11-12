import Foundation
import MijiaSupport
import MijiaCore
import MijiaHomeKitBridge
import MijiaLAN
import Combine
import os

/// Owns the app's Keychain item, the device config, the LAN API and the HomeKit bridge.
/// Xiaomi account sessions are used for device import and saved only on request.
@MainActor
final class AppModel: ObservableObject {
    nonisolated static let keychainService = "com.mijialan.MijiaLAN"
    nonisolated static let configAccount = "home_config_v1"
    nonisolated static let bridgeAccount = "homekit_bridge_v1"
    nonisolated static let rememberedSessionAccount = "mijia_session_v1"
    /// DHCP leases move devices around; a broadcast hello finds them again by device ID.
    static let rediscoveryInterval: TimeSpan = .seconds(300)

    enum ImportState: Equatable {
        case idle
        case loadingQR
        case waitingForScan(QRLoginTicket, expiresAt: Date)
        case fetching
        case needsScan
        case failed(String)
    }

    @Published private(set) var config: LocalHomeConfig
    /// The Keychain item exists but could not be read (prompt declined); nothing is saved until it can be.
    @Published private(set) var vaultUnavailable: Bool
    /// Climate devices' power draw in watts, which MijiaCore does not carry.
    var powerWatts: [String: Double] { devices.snapshots.compactMapValues { s in
        s.capabilities.first { $0.name == "electric-power" }.flatMap { s.value($0.id)?.doubleValue }
    } }
    let devices: DeviceController
    @Published private(set) var importState: ImportState = .idle
    @Published private(set) var lastImportSummary: String?
    @Published var importRegion: String = "cn"
    @Published private(set) var loginStorageError: String?
    @Published private var rememberedSession: MiSession?
    @Published private var sessionToRemember: MiSession?
    @Published private var rememberedSessionExpired = false
    var canRememberImportedLogin: Bool { sessionToRemember != nil }
    var canReuseRememberedLogin: Bool { reusableSession != nil }
    var rememberedLogin: (maskedAccount: String, region: String, expired: Bool)? {
        rememberedSession.map { ($0.maskedUserId, $0.region, rememberedSessionExpired) }
    }
    @Published private(set) var manualAddError: String?
    @Published private(set) var isAddingManually = false
    @Published private(set) var isRediscovering = false
    @Published private(set) var lastRediscoveryNote: String?
    @Published private(set) var lastRediscoveryAt: Date?
    @Published private(set) var retryingDeviceIDs: Set<String> = []

    enum DiagnosticsExport: Equatable {
        case idle
        case collecting
        case exported(URL)
        case failed(String)
    }
    @Published private(set) var diagnosticsExport: DiagnosticsExport = .idle

    let store: HomeStore
    let bridge: HomeKitBridgeController
    private let vault: SecretVault
    private let cloudTransport: (any MiHTTPTransport)?
    private let configBox: ConfigBox
    private let api: LANMiotAPI
    private var importTask: Task<Void, Never>?
    private var rediscoveryTask: Task<Void, Never>?
    private var bridgeAttached = false
    private var homeKitSelectionObservation: AnyCancellable?
    private var homeKitSupport: (revision: UInt64, devices: [String: Bool]) = (0, [:])
    private var homeKitServiceLists: (revision: UInt64, names: Int, devices: [String: [CapabilityHomeKitService]]) = (0, 0, [:])
    private let usesPreviewDevices: Bool
    private let logger = Logger(subsystem: "com.mijialan.MijiaLAN", category: "App")

    /// `MIJIALAN_EPHEMERAL=1` (development): secrets in memory and separate defaults, so a test run never touches
    /// the Keychain item or the real pairing. `MIJIALAN_SEED_CONFIG=<file>` then supplies the device config as JSON.
    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        secretStorage: SecretVault.Storage? = nil,
        cloudTransport: (any MiHTTPTransport)? = nil
    ) {
        #if DEBUG
        let preview = environment["MIJIALAN_UI_PREVIEW"] == "1"
        #else
        let preview = false
        #endif
        usesPreviewDevices = preview
        let ephemeral = preview || environment["MIJIALAN_EPHEMERAL"] == "1"
        let vault = SecretVault(storage: secretStorage ?? (ephemeral ? .memory() : .keychain(service: Self.keychainService, account: "secrets")))
        if ephemeral, let seed = environment["MIJIALAN_SEED_CONFIG"], let data = FileManager.default.contents(atPath: seed) {
            vault.set(data, for: Self.configAccount)
        }
        #if DEBUG
        if preview, let seed = ControlCenterPreview.config.encoded() { vault.set(seed, for: Self.configAccount) }
        #endif
        let defaultsSuite = ephemeral ? "com.mijialan.MijiaLAN.dev" : "com.mijialan.MijiaLAN.home"
        if ephemeral { UserDefaults.standard.removePersistentDomain(forName: defaultsSuite) }
        let bridgeDefaults = ephemeral ? (UserDefaults(suiteName: defaultsSuite) ?? .standard) : .standard
        self.vault = vault
        self.cloudTransport = cloudTransport
        var loaded = LocalHomeConfig()
        var unavailable = false
        switch vault.lookup(Self.configAccount) {
        case .value(let data): loaded = LocalHomeConfig.decode(data) ?? LocalHomeConfig()
        case .missing: break
        case .unavailable: unavailable = true
        }
        config = loaded
        vaultUnavailable = unavailable
        let box = ConfigBox(loaded)
        configBox = box
        let api: LANMiotAPI
        #if DEBUG
        api = preview ? LANMiotAPI(config: { box.value }, transport: ControlCenterPreviewTransport()) : LANMiotAPI(config: { box.value })
        #else
        api = LANMiotAPI(config: { box.value })
        #endif
        self.api = api
        let controller = DeviceController(api: api, config: { box.value })
        devices = controller
        let provider = CapabilityHomeProvider(controller: controller)
        store = HomeStore(provider: provider, defaultsSuiteName: defaultsSuite)
        bridge = HomeKitBridgeController(vault: HomeKitBridgeVault(
            load: { vault.lookup(AppModel.bridgeAccount) },
            save: { vault.set($0, for: AppModel.bridgeAccount) }
        ), defaults: bridgeDefaults)
        if !unavailable, case .value(let data) = vault.lookup(Self.rememberedSessionAccount),
           let session = try? JSONDecoder().decode(MiSession.self, from: data) {
            rememberedSession = session
            importRegion = session.region
        }

        // The Home selection helpers also depend on state owned by these three objects.
        homeKitSelectionObservation = Publishers.CombineLatest4(
            devices.$structureRevision, store.$hiddenDeviceIds.removeDuplicates(),
            bridge.$excludedServices, bridge.$serviceNamesRevision
        )
        .dropFirst()
        .sink { [weak self] _ in self?.objectWillChange.send() }

        if preview || (ephemeral && environment["MIJIALAN_SNAPSHOT"] != nil) { bridge.isEnabled = false }
        attachBridgeIfNeeded()
        if !preview { startRediscoveryLoop() }
    }

    // MARK: Devices

    func smartDevice(for device: LocalDevice) -> SmartDevice? {
        store.devices.first { $0.id == device.did }
    }

    func togglePower(_ device: LocalDevice) {
        guard let snapshot = devices.snapshots[device.did],
              let power = snapshot.primaryPower, let on = snapshot.value(power.id)?.boolValue else { return }
        Task { try? await devices.execute(did: device.did, .set(power.id, .bool(!on))) }
    }

    func retryDevices(_ ids: [String]) {
        let pending = Set(ids).subtracting(retryingDeviceIDs)
        retryingDeviceIDs.formUnion(pending)
        for did in pending {
            Task {
                await devices.retry(did: did)
                retryingDeviceIDs.remove(did)
            }
        }
    }

    /// A device kept out of Apple Home (say, one that is HomeKit-native already) is hidden in the store, which the
    /// bridge leaves out. The choice is per device ID, so it survives a re-import.
    func isInHomeKit(_ device: LocalDevice) -> Bool { !store.hiddenDeviceIds.contains(device.did) }

    func setInHomeKit(_ device: LocalDevice, _ included: Bool) {
        if included {
            // A device that left Home with its last service comes back whole.
            if homeKitServices(device).allSatisfy({ !isInHomeKit(device, service: $0) }) { bridge.setExcludedServices([], for: device.did) }
            store.unhideDevice(device.did)
        } else {
            store.hideDevice(device.did)
        }
    }

    /// What the device can publish to Apple Home, service by service and under the names Home shows, the main service
    /// first. Excluded services are listed too.
    func homeKitServices(_ device: LocalDevice) -> [CapabilityHomeKitService] {
        guard let snapshot = devices.snapshots[device.did] else { return [] }
        // Called for every row on every render, like `homeKitSupports`; renaming a service in Home changes the names.
        let revision = devices.structureRevision, names = bridge.serviceNamesRevision
        if homeKitServiceLists.revision != revision || homeKitServiceLists.names != names { homeKitServiceLists = (revision, names, [:]) }
        if let known = homeKitServiceLists.devices[device.did] { return known }
        let legacy = devices.synthesizedHome().devices.first { $0.id == device.did }
        let services = bridge.homeServices(for: snapshot, legacyDevice: legacy)
        homeKitServiceLists.devices[device.did] = services
        return services
    }

    func isInHomeKit(_ device: LocalDevice, service: CapabilityHomeKitService) -> Bool {
        bridge.excludedServices[device.did]?.contains(service.key) != true
    }

    /// Leaves one service out of Apple Home, or brings it back. An accessory needs a service, so leaving out the last
    /// one keeps the whole device out instead.
    func setInHomeKit(_ device: LocalDevice, service: CapabilityHomeKitService, _ included: Bool) {
        var excluded = bridge.excludedServices[device.did] ?? []
        if included { excluded.remove(service.key) } else { excluded.insert(service.key) }
        bridge.setExcludedServices(excluded, for: device.did)
        if !included, homeKitServices(device).allSatisfy({ excluded.contains($0.key) }) { store.hideDevice(device.did) }
    }

    /// Whether Apple Home gets an accessory for this device at all. Having controls is not enough: the bridge leaves
    /// out a device none of whose controls maps to a Home service, such as a bed with only vendor-defined motors.
    func homeKitSupports(_ device: LocalDevice) -> Bool {
        guard let snapshot = devices.snapshots[device.did] else { return false }
        // Called for every row on every render; the answer only changes with the device's spec.
        let revision = devices.structureRevision
        if homeKitSupport.revision != revision { homeKitSupport = (revision, [:]) }
        if let known = homeKitSupport.devices[device.did] { return known }
        let supported = CapabilityHomeKitMapper.mapsToHome(snapshot)
        homeKitSupport.devices[device.did] = supported
        return supported
    }

    func remove(_ device: LocalDevice) {
        var next = config
        next.remove(did: device.did)
        apply(next)
    }

    // MARK: Cloud Import

    private var reusableSession: MiSession? {
        guard !rememberedSessionExpired, rememberedSession?.region == importRegion else { return nil }
        return rememberedSession
    }

    @discardableResult
    func startCloudImport() -> Task<Void, Never> {
        cancelImport()
        lastImportSummary = nil
        loginStorageError = nil
        let savedSession = reusableSession
        let region = importRegion
        importState = savedSession == nil ? .loadingQR : .fetching
        let task = Task { [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled { importTask = nil } }
            do {
                try Task.checkCancellation()
                let transport = cloudTransport ?? URLSessionMiTransport()
                let session: MiSession
                if let savedSession {
                    session = savedSession
                } else {
                    let login = MiAccountLogin(transport: transport, redirectlessTransport: cloudTransport, region: region)
                    let ticket = try await login.start()
                    try Task.checkCancellation()
                    importState = .waitingForScan(ticket, expiresAt: Date().addingTimeInterval(ticket.timeout))
                    session = try await login.waitForScan(ticket)
                    try Task.checkCancellation()
                    importState = .fetching
                }
                let result = try await CloudTokenImport.fetch(session: session, transport: transport, tryOtherRegions: savedSession == nil)
                try await finishImport(result, scannedSession: savedSession == nil ? session : nil)
            } catch MiCloudError.sessionExpired where savedSession != nil {
                guard !Task.isCancelled else { return }
                forgetRememberedLogin()
                rememberedSessionExpired = rememberedSession != nil
                importState = .needsScan
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                importState = .failed(Self.describe(error))
            }
        }
        importTask = task
        return task
    }

    func cancelImport() {
        importTask?.cancel()
        importTask = nil
        sessionToRemember = nil
        importState = .idle
    }

    func rememberImportedLogin() {
        guard let sessionToRemember else { return }
        guard let data = try? JSONEncoder().encode(sessionToRemember),
              vault.set(data, for: Self.rememberedSessionAccount) else {
            loginStorageError = L10n.tr("无法将米家登录保存到钥匙串。", "Could not save the Xiaomi Home login to Keychain.")
            return
        }
        rememberedSession = sessionToRemember
        rememberedSessionExpired = false
        importRegion = sessionToRemember.region
        self.sessionToRemember = nil
        loginStorageError = nil
    }

    func forgetRememberedLogin() {
        guard rememberedSession != nil else { return }
        guard vault.set(nil, for: Self.rememberedSessionAccount) else {
            loginStorageError = L10n.tr("无法从钥匙串移除米家登录。", "Could not remove the Xiaomi Home login from Keychain.")
            return
        }
        rememberedSession = nil
        rememberedSessionExpired = false
        loginStorageError = nil
    }

    private func finishImport(_ result: CloudImportResult, scannedSession: MiSession?) async throws {
        try Task.checkCancellation()
        var devices = result.devices
        await resolveSpecTypes(&devices)
        try Task.checkCancellation()
        var next = config
        next.merge(devices)
        let imported = Set(next.devices.map(\.did))
        next.skipped = result.skipped.filter { !imported.contains($0.did) }
        next.importedAt = Date()
        guard apply(next) else {
            importState = .failed(L10n.tr("无法将设备资料保存到钥匙串。", "Could not save the devices to Keychain."))
            return
        }
        if var scannedSession {
            scannedSession.region = result.region
            sessionToRemember = scannedSession
        }
        lastImportSummary = L10n.tr("导入 \(result.devices.count) 台可走局域网的设备", "Imported LAN devices: \(result.devices.count)") +
            (result.skipped.isEmpty ? "" : L10n.tr("，\(result.skipped.count) 台不能（见下方）", "; skipped: \(result.skipped.count) (see device details)")) +
            (result.region == "cn" ? "" : L10n.tr("（服务器：\(result.region)）", " (server: \(result.region))"))
        importState = .idle
        logger.info("Imported \(result.devices.count, privacy: .public) devices, skipped \(result.skipped.count, privacy: .public)")
    }

    /// Looks each model's MIoT spec up once (miot-spec.org, no account) so later starts never need the internet.
    private func resolveSpecTypes(_ devices: inout [LocalDevice]) async {
        let source = MiotSpecStore(cacheDirectory: LocalHomeProvider.specCacheDirectory)
        for index in devices.indices {
            guard !Task.isCancelled else { return }
            let device = devices[index]
            if let spec = try? await source.spec(model: device.model, specType: device.specType) {
                devices[index].specType = spec.type
            }
        }
    }

    // MARK: Manual Add

    func addManually(host: String, token: String, name: String) {
        guard !isAddingManually else { return }
        isAddingManually = true
        manualAddError = nil
        Task { [weak self] in
            do {
                let device = try await ManualDeviceProbe.probe(
                    host: host, token: token, name: name,
                    specSource: MiotSpecStore(cacheDirectory: LocalHomeProvider.specCacheDirectory)
                )
                guard let self else { return }
                var next = self.config
                next.merge([device])
                self.apply(next)
                self.lastImportSummary = L10n.tr("已添加 \(device.name)（\(device.model)）", "Added \(device.name) (\(device.model)).")
            } catch {
                self?.manualAddError = Self.describe(error)
            }
            self?.isAddingManually = false
        }
    }

    // MARK: Diagnostics

    /// Owned here rather than by the settings view: Finder or Mail taking focus closes the menu-bar panel.
    func exportDiagnostics() {
        export { DiagnosticReport.reveal($0) }
    }

    /// Opens a mail draft with the report attached, exporting one first if there is none yet.
    func emailDiagnostics() {
        if case .exported(let url) = diagnosticsExport { DiagnosticReport.email(url); return }
        export { DiagnosticReport.email($0) }
    }

    private func export(then deliver: @escaping @MainActor (URL) -> Void) {
        guard diagnosticsExport != .collecting else { return }
        diagnosticsExport = .collecting
        Task {
            do {
                let url = try await DiagnosticReport.export(model: self)
                diagnosticsExport = .exported(url)
                deliver(url)
            } catch {
                diagnosticsExport = .failed(Self.describe(error))
            }
        }
    }

    // MARK: Rediscovery

    func rediscoverNow() {
        Task { await rediscover() }
    }

    private func startRediscoveryLoop() {
        rediscoveryTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.rediscover()
                try? await MonotonicClock.sleep(for: Self.rediscoveryInterval)
            }
        }
    }

    private func rediscover() async {
        if usesPreviewDevices {
            lastRediscoveryAt = Date()
            lastRediscoveryNote = L10n.tr("预览环境使用模拟设备", "The preview uses simulated devices.")
            return
        }
        guard !isRediscovering else { return }
        isRediscovering = true
        defer { isRediscovering = false }
        do {
            let found = try await MiioDiscovery.discover()
            lastRediscoveryAt = Date()
            var next = config
            let moved = next.updateHosts(from: found)
            let known = Set(config.devices.map(\.did))
            let unknown = found.filter { !known.contains($0.did) }.count
            lastRediscoveryNote = found.isEmpty
                ? L10n.tr("局域网广播暂时没有设备回应（路由器的设备隔离也会拦住广播）", "No devices responded to the LAN broadcast. Router client isolation can also block discovery.")
                : L10n.tr("局域网里找到 \(found.count) 台 miIO 设备", "miIO devices found on the LAN: \(found.count)") + (unknown > 0 ? L10n.tr("，其中 \(unknown) 台还没有 token", "; without a token: \(unknown)") : "")
            if moved {
                logger.info("Device IPs changed; saving")
                apply(next)
            }
            await api.retryDiscoveredDevices(Set(found.map(\.did)).intersection(known))
        } catch {
            lastRediscoveryNote = Self.describe(error)
        }
    }

    // MARK: Persistence

    @discardableResult
    private func apply(_ next: LocalHomeConfig) -> Bool {
        guard let data = next.encoded(), vault.set(data, for: Self.configAccount) else {
            vaultUnavailable = true
            logger.error("Could not save the device config to the Keychain")
            return false
        }
        vaultUnavailable = false
        config = next
        configBox.value = next
        devices.reconcileConfiguration(force: true)
        store.refreshNow()
        attachBridgeIfNeeded()
        return true
    }

    /// The bridge waits for the first imported device, so a fresh install does not advertise an empty bridge.
    private func attachBridgeIfNeeded() {
        guard !bridgeAttached, !config.devices.isEmpty else { return }
        bridgeAttached = true
        bridge.attach(to: store, capabilities: devices)
    }

    static func describe(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// The config as the LAN API's actor reads it, off the main actor.
final class ConfigBox: @unchecked Sendable {
    private let lock = NSLock()
    private var config: LocalHomeConfig

    init(_ config: LocalHomeConfig) { self.config = config }

    var value: LocalHomeConfig {
        get { lock.withLock { config } }
        set { lock.withLock { config = newValue } }
    }
}
