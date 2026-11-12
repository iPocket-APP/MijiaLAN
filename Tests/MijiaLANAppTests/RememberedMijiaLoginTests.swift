#if DEBUG
import Foundation
import MijiaCore
import MijiaLAN
import Testing
@testable import MijiaLANApp

@MainActor
@Suite(.serialized)
struct RememberedMijiaLoginTests {
    @Test("A QR login is saved only on request and survives recreating the app model")
    func consentAndRelaunch() async throws {
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
        #expect(reopened.lastImportSummary != nil)
        #expect(!reopened.canRememberImportedLogin)
        let requests = await transport.requests
        #expect(requests.first?.host == "de.api.io.mi.com")
        #expect(requests.filter { $0.path.hasSuffix("/device_list") }.count == 1)
        #expect(!requests.contains { $0.path == "/longPolling/loginUrl" })

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

    @Test("A network timeout can be retried, and an expired session returns to QR sign-in")
    func timeoutAndExpiration() async throws {
        let storage = SecretVault.Storage.memory()
        let session = MiSession(userId: "123456789", cUserId: "fixture", ssecurity: "AAAAAAAAAAAAAAAAAAAAAA==",
                                serviceToken: "fixture-session", region: "de")
        let saved = try JSONEncoder().encode(session)
        try #require(SecretVault(storage: storage).set(saved, for: AppModel.rememberedSessionAccount))
        let transport = ImportTransport()
        let model = makeModel(storage, transport)
        defer { model.devices.shutdown() }

        await transport.setDeviceListResponse(.timeout)
        await model.startCloudImport().value
        guard case .failed = model.importState else {
            Issue.record("Expected a retryable import failure after the timeout")
            return
        }
        #expect(model.canReuseRememberedLogin)
        #expect(SecretVault(storage: storage).lookup(AppModel.rememberedSessionAccount) == .value(saved))

        await transport.setDeviceListResponse(.valid)
        await model.startCloudImport().value
        #expect(model.lastImportSummary != nil)
        #expect(await transport.requests.allSatisfy { $0.host == "de.api.io.mi.com" })

        await transport.setDeviceListResponse(.expired)
        await model.startCloudImport().value
        #expect(model.importState == .needsScan)
        #expect(!model.canReuseRememberedLogin)
        #expect(SecretVault(storage: storage).lookup(AppModel.rememberedSessionAccount) == .missing)

        await transport.clearRequests()
        await transport.setDeviceListResponse(.valid)
        await model.startCloudImport().value
        #expect(await transport.requests.first?.path == "/longPolling/loginUrl")
        #expect(model.canRememberImportedLogin)
    }

    private func makeModel(_ storage: SecretVault.Storage, _ transport: ImportTransport) -> AppModel {
        AppModel(environment: ["MIJIALAN_UI_PREVIEW": "1"], secretStorage: storage, cloudTransport: transport)
    }
}

private actor ImportTransport: MiHTTPTransport {
    enum DeviceListResponse { case valid, timeout, expired }

    private(set) var requests: [URL] = []
    private var deviceListResponse = DeviceListResponse.valid

    func clearRequests() { requests.removeAll() }
    func setDeviceListResponse(_ response: DeviceListResponse) { deviceListResponse = response }

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
            status = 200
            body = #"{"userId":"123456789","cUserId":"fixture","ssecurity":"AAAAAAAAAAAAAAAAAAAAAA==","location":"https://example.invalid/session"}"#
        case "/session":
            status = 200
            headers["Set-Cookie"] = "serviceToken=fixture-session; Path=/; Secure"
            body = ""
        case "/app/home/device_list":
            #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("serviceToken=fixture-session") == true)
            switch deviceListResponse {
            case .timeout:
                throw URLError(.timedOut)
            case .expired:
                status = 401
                body = "{}"
            case .valid:
                status = 200
                // The fixture is skipped as a Bluetooth device, so import needs no external MIoT specification.
                body = url.host == "de.api.io.mi.com"
                    ? #"{"code":0,"result":{"list":[{"did":"blt.fixture","model":"fixture.sensor","name":"Fixture Sensor"}]}}"#
                    : #"{"code":0,"result":{"list":[]}}"#
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
