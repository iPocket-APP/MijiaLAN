import Foundation
import Testing
@testable import MijiaLAN
import MijiaCore

struct PropertyBatchTests {
    private static let token = "00112233445566778899aabbccddeeff"

    @Test("One rejected first property preserves later values and is skipped until retry")
    func partialFallback() async throws {
        let network = FakeMiioNetwork()
        let device = network.add(host: "192.0.2.1", token: Self.token, deviceID: 1, props: ["2.2": .bool(true)])
        device.rejectedProperties = ["2.1"]
        let client = MiioClient(host: device.host, token: device.token, transport: network, retries: 0)
        let first = MiotPropKey(did: "1", siid: 2, piid: 1)
        let second = MiotPropKey(did: "1", siid: 2, piid: 2)
        let props = [(siid: 2, piid: 1), (siid: 2, piid: 2)]

        let readings = try await client.readProperties(did: "1", props)
        #expect(readings[first]?.code == -9999)
        #expect(readings[second]?.value == .bool(true))
        let evidence = await client.diagnosticEvidence()
        #expect(evidence.lastFallback?.singleAckTimeouts == 1)
        #expect(evidence.lastFallback?.availableProperties == 1)
        #expect(evidence.suppressedProperties == 1)
        _ = try await client.readProperties(did: "1", props)
        #expect(device.propertyBatchSizes == [2, 1, 1, 1])

        await client.resetPropertyReadBackoff()
        _ = try await client.readProperties(did: "1", props)
        #expect(device.propertyBatchSizes.suffix(3) == [2, 1, 1])
    }

    @Test("An oversized request that works in singles lowers the batch size for this endpoint")
    func shorterBatches() async throws {
        let network = FakeMiioNetwork()
        let properties = (1...4).map { (siid: 2, piid: $0) }
        let device = network.add(host: "192.0.2.2", token: Self.token, deviceID: 2,
                                 props: Dictionary(uniqueKeysWithValues: properties.map { ("2.\($0.piid)", .bool(true)) }))
        device.maxPropertiesPerRequest = 2
        let client = MiioClient(host: device.host, token: device.token, transport: network, retries: 0)

        #expect(try await client.getProperties(did: "2", properties).count == 4)
        #expect(await client.diagnosticEvidence().batchLimit == 2)
        #expect(try await client.getProperties(did: "2", properties).count == 4)
        #expect(device.propertyBatchSizes == [4, 1, 1, 1, 1, 2, 2])
    }

    @Test("A device that replies to info but refuses property reads stays reachable and skips repeated wire attempts")
    func allRejected() async throws {
        let network = FakeMiioNetwork()
        let device = network.add(host: "192.0.2.3", token: Self.token, deviceID: 3)
        device.maxPropertiesPerRequest = 0
        let config = LocalHomeConfig(devices: [LocalDevice(did: "3", name: "test", model: device.model,
                                                           host: device.host, token: Self.token)])
        let api = LANMiotAPI(config: { config }, transport: network)
        _ = try await api.deviceList()
        let keys = [MiotPropKey(did: "3", siid: 2, piid: 1), MiotPropKey(did: "3", siid: 2, piid: 2)]
        #expect(try await api.getProps(keys).isEmpty)
        let attempts = device.propertyBatchSizes
        let lastSeen = await api.currentHealth()["3"]?.lastSeen
        #expect(try await api.getProps(keys).isEmpty)
        #expect(device.propertyBatchSizes == attempts)
        #expect(await api.currentHealth()["3"]?.state == .online)
        #expect(await api.currentHealth()["3"]?.lastSeen == lastSeen)
        let evidence = await api.diagnostics()["3"]
        #expect(evidence?.lastProbe?.failure == nil)
        #expect(evidence?.link?.reads == 1)
        #expect(evidence?.link?.lastFailureEvidence?.deviceCode == -9999)
        #expect(evidence?.endpoint?.lastFallback?.singleAckTimeouts == 2)
        #expect((evidence?.endpoint?.backoffSeconds ?? 0) > 0)
        await api.retryDevice(did: "3")
        #expect(try await api.getProps(keys).isEmpty)
        #expect(device.propertyBatchSizes.count > attempts.count)
        await api.shutdown()
    }
}
