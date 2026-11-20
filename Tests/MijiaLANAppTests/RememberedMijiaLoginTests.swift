#if DEBUG
import Foundation
import MijiaCore
import MijiaLAN
import Testing
@testable import MijiaLANApp

@MainActor
@Suite(.serialized)
struct RememberedMijiaLoginTests {
    private let suite = "test.mijialan.remembered-login.\(UUID().uuidString)"

    @Test("A QR login is saved only on request and survives recreating the app model")
    func consentAndRelaunch() async throws {
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let storage = SecretVault.Storage.memory()
        let transport = ImportTransport()
        let first = makeModel(storage, transport)
        defer { first.devices.shutdown() }

        await first.startCloudImport().value
        #expect(first.canRememberImportedLogin)
        #expect(SecretVault(storage: storage).lookup(AppModel.rememberedSessionAccount) == .missing)

        first.cancelImport()
        #expect(!first.canRememberImportedLogin)
        first.rememberImportedLogin()
        #expect(SecretVault(storage: storage).lookup(AppModel.rememberedSessionAccount) == .missing)

        await first.startCloudImport().value
        first.rememberImportedLogin()
        #expect(first.rememberedLogin?.maskedAccount == "12****89")
        #expect(first.rememberedLogin?.region == "de")
        #expect(!first.canRememberImportedLogin)

        let reopened = makeModel(storage, transport)
        defer { reopened.devices.shutdown() }
        #expect(reopened.importRegion == "de")
        #expect(reopened.canReuseRememberedLogin)

        await transport.clearRequests()
        await reopened.startCloudImport().value
        expectCompleted(reopened)
        #expect(!reopened.canRememberImportedLogin)
        let requests = await transport.requests
        #expect(requests.first?.host == "de.api.io.mi.com")
        #expect(requests.filter { $0.path.hasSuffix("/device_list") }.count == 1)
        #expect(!requests.contains { $0.path == "/longPolling/loginUrl" })

        let rememberedLogin = SecretVault(storage: storage).lookup(AppModel.rememberedSessionAccount)
        await transport.clearRequests()
        await reopened.startCloudImport(requiresQRCode: true).value
        expectCompleted(reopened)
        #expect(await transport.requests.first?.path == "/longPolling/loginUrl")
        #expect(reopened.canRememberImportedLogin)
        #expect(SecretVault(storage: storage).lookup(AppModel.rememberedSessionAccount) == rememberedLogin)

        reopened.importRegion = "sg"
        #expect(!reopened.canReuseRememberedLogin)
        await transport.clearRequests()
        await reopened.startCloudImport().value
        #expect(await transport.requests.first?.path == "/longPolling/loginUrl")
        #expect(reopened.rememberedLogin?.region == "de")

        reopened.cancelImport()
        let config = SecretVault(storage: storage).lookup(AppModel.configAccount)
        reopened.forgetRememberedLogin()
        #expect(reopened.rememberedLogin == nil)
        #expect(SecretVault(storage: storage).lookup(AppModel.rememberedSessionAccount) == .missing)
        #expect(SecretVault(storage: storage).lookup(AppModel.configAccount) == config)
    }

    private func saveLogin(in storage: SecretVault.Storage) throws -> Data {
        let session = MiSession(userId: "123456789", cUserId: "fixture", ssecurity: "AAAAAAAAAAAAAAAAAAAAAA==",
                                serviceToken: "remembered-session", region: "de")
        let bytes = try JSONEncoder().encode(session)
        try #require(SecretVault(storage: storage).set(bytes, for: AppModel.rememberedSessionAccount))
        return bytes
    }

    @Test("Timeouts and malformed device lists preserve the remembered login and last import",
          arguments: [ImportTransport.DeviceListResponse.timeout, .missingList])
    func retryableFailures(response: ImportTransport.DeviceListResponse) async throws {
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let storage = SecretVault.Storage.memory()
        let saved = try saveLogin(in: storage)
        let vault = SecretVault(storage: storage)
        let original = LocalHomeConfig(importedAt: Date(timeIntervalSince1970: 10))
        let bytes = try #require(original.encoded())
        try #require(vault.set(bytes, for: AppModel.configAccount))
        let transport = ImportTransport(devices: [])
        let model = makeModel(storage, transport)
        defer { model.devices.shutdown() }

        await transport.respondToDeviceLists(with: [response])
        await model.startCloudImport().value
        guard case .failed = model.importState else {
            Issue.record("Expected a retryable import failure")
            return
        }
        #expect(model.canReuseRememberedLogin)
        let persisted = SecretVault(storage: storage)
        #expect(persisted.lookup(AppModel.rememberedSessionAccount) == .value(saved))
        #expect(persisted.lookup(AppModel.configAccount) == .value(bytes))
        #expect(model.config == original)

        await model.startCloudImport().value
        expectCompleted(model)
        #expect(await transport.requests.allSatisfy { $0.host == "de.api.io.mi.com" })
    }

    @Test("One re-import updates the saved and running device, requesting a QR code only for an expired login",
          arguments: [ImportTransport.DeviceListResponse.valid, .expired, .unauthorized])
    func refreshDeviceToken(response: ImportTransport.DeviceListResponse) async throws {
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let storage = SecretVault.Storage.memory()
        let saved = try saveLogin(in: storage)
        let vault = SecretVault(storage: storage)
        let purifier = LocalDevice(did: "123", name: "Purifier", model: "zhimi.airpurifier.rma1", host: "192.0.2.4",
                                   token: String(repeating: "1", count: 32), roomName: "Bedroom")
        let plug = LocalDevice(did: "456", name: "Plug", model: "cuco.plug.v3", host: "192.0.2.6", token: purifier.token)
        let original = LocalHomeConfig(devices: [purifier, plug], importedAt: Date(timeIntervalSince1970: 10))
        try #require(vault.set(original.encoded(), for: AppModel.configAccount))
        let freshToken = String(repeating: "a", count: 32)
        let transport = ImportTransport(devices: [.object([
            "did": .string(purifier.did), "name": .string(purifier.name), "model": .string(purifier.model),
            "localip": .string(purifier.host), "token": .string(freshToken.uppercased())
        ])])
        await transport.respondToDeviceLists(with: [response])
        let model = makeModel(storage, transport)
        defer { model.devices.shutdown() }
        var displayedQR = 0
        let observation = model.$importState.sink { state in
            if case .waitingForScan(_, _, let renewingLogin) = state {
                displayedQR += 1
                #expect(renewingLogin)
                #expect(model.config == original)
            }
        }
        defer { observation.cancel() }

        await model.startCloudImport().value
        guard case .completed(1, _) = model.importState else { Issue.record("The re-import did not complete"); return }
        let usedQR = response != .valid
        #expect(displayedQR == (usedQR ? 1 : 0))
        #expect(await transport.usedScannedLogin == (usedQR ? [false, true] : [false]))
        #expect(await transport.requests.filter { $0.path == "/longPolling/loginUrl" }.count == displayedQR)
        #expect(model.canRememberImportedLogin == usedQR)
        #expect(SecretVault(storage: storage).lookup(AppModel.rememberedSessionAccount) == (usedQR ? .missing : .value(saved)))
        var refreshed = purifier
        refreshed.token = freshToken
        #expect(model.config.devices == [refreshed, plug])
        #expect(model.devices.snapshots[purifier.did]?.device.token == freshToken)
        guard case .value(let data) = SecretVault(storage: storage).lookup(AppModel.configAccount) else {
            Issue.record("Missing saved device list"); return
        }
        #expect(LocalHomeConfig.decode(data) == model.config)
    }

    @Test("Cancelling the expired-login QR ignores a late scan confirmation")
    func cancelWhileScanning() async throws {
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let storage = SecretVault.Storage.memory()
        _ = try saveLogin(in: storage)
        let original = LocalHomeConfig(importedAt: Date(timeIntervalSince1970: 10))
        let bytes = try #require(original.encoded())
        try #require(SecretVault(storage: storage).set(bytes, for: AppModel.configAccount))
        let transport = ImportTransport()
        await transport.respondToDeviceLists(with: [.expired])
        let model = makeModel(storage, transport)
        defer { model.devices.shutdown() }
        await transport.onScanConfirmation { @MainActor [weak model] in
            guard let model, case .waitingForScan = model.importState else {
                Issue.record("The confirmation arrived before the QR was shown"); return
            }
            model.cancelImport()
        }
        await model.startCloudImport().value
        #expect(model.importState == .idle)
        #expect(model.config == original)
        #expect(SecretVault(storage: storage).lookup(AppModel.configAccount) == .value(bytes))
        #expect(await transport.usedScannedLogin == [false])
        #expect(!model.canRememberImportedLogin)
    }

    @Test("A rejected new QR session does not start another automatic scan")
    func rejectedScannedSession() async throws {
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let storage = SecretVault.Storage.memory()
        _ = try saveLogin(in: storage)
        let transport = ImportTransport()
        await transport.respondToDeviceLists(with: [.expired, .expired])
        let model = makeModel(storage, transport)
        defer { model.devices.shutdown() }
        await model.startCloudImport().value
        #expect(model.importState == .needsScan)
        #expect(model.config.importedAt == nil)
        #expect(!model.canRememberImportedLogin)
        #expect(await transport.usedScannedLogin == [false, true])
        #expect(await transport.requests.filter { $0.path == "/longPolling/loginUrl" }.count == 1)
    }

    private func makeModel(_ storage: SecretVault.Storage, _ transport: ImportTransport) -> AppModel {
        AppModel(environment: ["MIJIALAN_UI_PREVIEW": "1"], secretStorage: storage, cloudTransport: transport,
                 ephemeralDefaultsSuite: suite)
    }

    private func expectCompleted(_ model: AppModel) {
        guard case .completed(let count, let summary) = model.importState else {
            Issue.record("Expected an import result after fetching the device list")
            return
        }
        #expect(count == 0)
        #expect(!summary.isEmpty)
    }
}

actor ImportTransport: MiHTTPTransport {
    enum DeviceListResponse: Sendable { case valid, timeout, expired, unauthorized, missingList }

    private(set) var requests: [URL] = []
    private(set) var usedScannedLogin: [Bool] = []
    private var responses: [DeviceListResponse] = []
    private let devices: [JSONValue]
    private var scanConfirmation: (@Sendable () async -> Void)?

    init(devices: [JSONValue] = [.object(["did": .string("blt.fixture"), "model": .string("fixture.sensor"), "name": .string("Fixture Sensor")])]) {
        self.devices = devices
    }

    func clearRequests() { requests.removeAll() }
    func respondToDeviceLists(with responses: [DeviceListResponse]) { self.responses = responses }
    func onScanConfirmation(_ action: @escaping @Sendable () async -> Void) { scanConfirmation = action }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        requests.append(url)
        let status: Int
        let body: String
        var headers: [String: String] = [:]

        switch url.path {
        case "/longPolling/loginUrl":
            status = 200
            body = #"{"qr":"https://example.invalid/qr","loginUrl":"https://example.invalid/login","lp":"https://example.invalid/confirm","timeout":300}"#
        case "/confirm":
            await scanConfirmation?()
            status = 200
            body = #"{"userId":"123456789","cUserId":"fixture","ssecurity":"AAAAAAAAAAAAAAAAAAAAAA==","location":"https://example.invalid/session"}"#
        case "/session":
            status = 200
            headers["Set-Cookie"] = "serviceToken=fixture-session; Path=/; Secure"
            body = ""
        case "/app/home/device_list":
            let cookies = request.value(forHTTPHeaderField: "Cookie")?.components(separatedBy: "; ") ?? []
            let scanned = cookies.contains("serviceToken=fixture-session")
            #expect(scanned || cookies.contains("serviceToken=remembered-session"))
            usedScannedLogin.append(scanned)
            switch responses.isEmpty ? .valid : responses.removeFirst() {
            case .timeout:
                throw URLError(.timedOut)
            case .expired:
                status = 426
                body = #"{"code":0,"message":"SERVICETOKEN_EXPIRED"}"#
            case .unauthorized:
                status = 401
                body = "{}"
            case .missingList:
                status = 200
                body = #"{"code":0,"result":{}}"#
            case .valid:
                status = 200
                let list = url.host == "de.api.io.mi.com" ? devices : []
                body = JSONValue.object(["code": .number(0), "result": .object(["list": .array(list)])]).compactJSONString
            }
        default:
            status = 200
            body = #"{"code":0,"result":{"homelist":[]}}"#
        }
        let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers))
        return (Data(body.utf8), response)
    }
}
#endif
