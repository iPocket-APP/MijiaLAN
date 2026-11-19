import Foundation
import MijiaCore
import Testing
@testable import MijiaLAN

@MainActor
struct DeviceSpecArchiveTests {
    private static let type = "urn:miot-spec-v2:device:light:0000A001:archive-test:1"
    private static let lamp = LocalDevice(did: "1", name: "Lamp", model: "archive.light.one", host: "10.0.0.1",
                                          token: String(repeating: "ab", count: 16), specType: type)
    private static let definition = Data(#"{"type":"\#(type)","description":"Light","services":[{"iid":2,"type":"urn:miot-spec-v2:service:light:00007802:test:1","description":"Light","properties":[{"iid":1,"type":"urn:miot-spec-v2:property:on:00000006:test:1","description":"Power","format":"bool","access":["read","write"],"comment":"original vendor metadata"}]}]}"#.utf8)

    private func temporaryArchive() -> DeviceSpecArchive {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return DeviceSpecArchive(directory: root.appendingPathComponent("support"), cacheDirectory: root.appendingPathComponent("cache"))
    }

    @Test("An upgrade archives the original cached definition and a new controller reads the lamp after cache eviction")
    func existingInstallation() async throws {
        let archive = temporaryArchive()
        defer { try? FileManager.default.removeItem(at: archive.directory.deletingLastPathComponent()) }
        let name = try #require(MiotSpecStore.instanceFileName(for: Self.type))
        let cached = archive.cacheDirectory.appendingPathComponent("instances").appendingPathComponent(name)
        try FileManager.default.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.definition.write(to: cached)
        // An interrupted or obsolete copy must not mask a valid download.
        try FileManager.default.createDirectory(at: archive.directory, withIntermediateDirectories: true)
        try Data("invalid".utf8).write(to: archive.directory.appendingPathComponent(name))
        let config = LocalHomeConfig(devices: [Self.lamp])
        #expect(DeviceSchema.load(model: Self.lamp.model, specType: Self.type, archive: archive)?.category == "light")
        #expect(try Data(contentsOf: archive.directory.appendingPathComponent(name)) == Self.definition)
        try FileManager.default.removeItem(at: archive.cacheDirectory)

        let network = FakeMiioNetwork()
        network.add(host: Self.lamp.host, token: Self.lamp.token, deviceID: 1, props: ["2.1": .bool(true)]).model = Self.lamp.model
        let api = LANMiotAPI(config: { config }, transport: network, specs: archive)
        let devices = DeviceController(api: api, config: { config })
        defer { devices.shutdown() }
        await devices.refreshNow()
        #expect(devices.snapshots["1"]?.isOnline == true)
        #expect(devices.snapshots["1"]?.value("p:2:1") == .bool(true))
    }

    @Test("A known type downloads directly into Application Support when the cache is unwritable")
    func unwritableDownloadCache() async throws {
        let archive = temporaryArchive()
        let root = archive.directory.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: archive.cacheDirectory)
        let server = SpecServer(type: Self.type, definition: Self.definition)
        await server.goOnline()
        let request = DeviceSpecArchive.Request(Self.lamp)
        let source = MiotSpecStore(transport: server, cacheDirectory: archive.cacheDirectory)
        #expect(await archive.resolve([request], using: source)[request] == Self.type)
        #expect(await server.paths == ["instance"])
        let name = try #require(MiotSpecStore.instanceFileName(for: Self.type))
        #expect(try Data(contentsOf: archive.directory.appendingPathComponent(name)) == Self.definition)
    }

    @Test("Bundled devices skip the network, each batch shares index failures and aliases download a type once")
    func batchedLookups() async throws {
        let archive = temporaryArchive()
        defer { try? FileManager.default.removeItem(at: archive.directory.deletingLastPathComponent()) }
        let server = SpecServer(type: Self.type, definition: Self.definition)
        func source() -> MiotSpecStore { MiotSpecStore(transport: server, cacheDirectory: archive.cacheDirectory) }
        var builtIn = Self.lamp
        builtIn.model = "yeelink.light.lamp4"
        builtIn.specType = nil
        let builtIns = (1...5).map { id in
            var device = builtIn
            device.did = String(id)
            return DeviceSpecArchive.Request(device)
        }
        _ = await archive.resolve(Set(builtIns), using: source())
        #expect(await server.paths.isEmpty)

        var first = Self.lamp
        first.specType = nil
        var second = first
        second.model = "archive.light.two"
        let requests = Set([first, second].map(DeviceSpecArchive.Request.init))
        #expect(await archive.resolve(requests, using: source()).isEmpty)
        #expect(await server.paths == ["instances"])

        await server.goOnline()
        var known = Self.lamp
        known.did = "3"
        let allRequests = requests.union([.init(known)])
        let result = await archive.resolve(allRequests, using: source())
        #expect(result.count == allRequests.count)
        #expect(Set(result.values) == [Self.type])
        #expect(await server.paths.filter { $0 == "instances" }.count == 2)
        #expect(await server.paths.filter { $0 == "instance" }.count == 1)
        try FileManager.default.removeItem(at: archive.cacheDirectory)
        #expect(archive.schema(for: Self.type)?.category == "light")
    }
}

private actor SpecServer: MiHTTPTransport {
    let type: String
    let definition: Data
    private(set) var paths: [String] = []
    private var online = false

    init(type: String, definition: Data) { self.type = type; self.definition = definition }
    func goOnline() { online = true }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        paths.append(url.lastPathComponent)
        guard online else { throw URLError(.timedOut) }
        let index = ["instances": ["archive.light.one", "archive.light.two"].map { ["type": type, "model": $0, "version": 1] }]
        let data = url.lastPathComponent == "instances" ? try JSONSerialization.data(withJSONObject: index) : definition
        return (data, try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
    }
}
