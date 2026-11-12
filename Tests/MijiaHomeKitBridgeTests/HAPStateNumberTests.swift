import Foundation
import HAPCore
import HAPTransport
import MDNSCore
import MijiaSupport
import Testing

/// 2026-11-12: with no home hub, an iPhone that left kept showing 台灯 off for 45 minutes while the lamp was on, and
/// opening Home did not reconnect. The lamp's own HomeKit tile was right; it advertised `s#=39`, the bridge `s#=1`.
struct HAPStateNumberTests {
    @Test("A control's change moves s# once per departed controller; readings, repeats and forced refreshes do not")
    func bumps() async throws {
        let bridge = await Self.bridge()
        let seen = Numbers()
        await bridge.addStateNumberChangeHandler { await seen.append($0) }
        await bridge.restoreStateNumber(7)

        // Starting counts as a departure: whoever was paired has not seen these values.
        await bridge.updateCharacteristic(aid: 2, iid: 9, value: .bool(true))
        #expect(await bridge.currentStateNumber == 8)
        await bridge.updateCharacteristic(aid: 2, iid: 9, value: .bool(false))
        #expect(await bridge.currentStateNumber == 8)

        await bridge.unsubscribeAll(connectionID: 11)
        await bridge.updateCharacteristic(aid: 2, iid: 11, value: .float(44))
        await bridge.updateCharacteristic(aid: 2, iid: 9, value: .bool(false))
        await bridge.updateCharacteristic(aid: 2, iid: 9, value: .bool(false), forceNotify: true)
        #expect(await bridge.currentStateNumber == 8)
        await bridge.updateCharacteristic(aid: 2, iid: 10, value: .int32(30))
        #expect(await bridge.currentStateNumber == 9)

        // A control that stops answering is a change too, and so is its recovery after someone else leaves.
        await bridge.unsubscribeAll(connectionID: 22)
        await bridge.setReadStatus(aid: 2, iid: 9, status: .communicationFailure)
        #expect(await bridge.currentStateNumber == 10)
        await bridge.unsubscribeAll(connectionID: 22)
        await bridge.updateCharacteristic(aid: 2, iid: 9, value: .bool(false))
        #expect(await bridge.currentStateNumber == 11)

        try await seen.wait(for: [8, 9, 10, 11])
    }

    @Test("s# stays within 1...65535 when restored and wraps to 1")
    func range() async {
        let bridge = await Self.bridge()
        await bridge.restoreStateNumber(0)
        #expect(await bridge.currentStateNumber == 1)
        await bridge.restoreStateNumber(65_535)
        await bridge.updateCharacteristic(aid: 2, iid: 9, value: .bool(true))
        #expect(await bridge.currentStateNumber == 1)
    }

    @Test("A new s# replaces the TXT record in place, and is advertised whole where that is not possible")
    func advertisement() async throws {
        let inPlace = Discovery(updatesInPlace: true)
        let advertiser = HAPAdvertiser(discovery: inPlace, deviceID: "2D:10:B9:59:C2:DD")
        try await advertiser.advertise(name: "MijiaLAN Bridge", port: 60010, category: .bridge, configNumber: 37, stateNumber: 4, isPaired: true)
        try await advertiser.updateStateNumber(name: "MijiaLAN Bridge", port: 60010, category: .bridge, configNumber: 37, stateNumber: 5, isPaired: true)
        #expect(await inPlace.advertised.map { $0["s#"] } == ["4"])
        let update = try #require(await inPlace.updated.first)
        #expect(update["s#"] == "5")
        #expect(update["c#"] == "37" && update["sf"] == "0" && update["id"] == "2D:10:B9:59:C2:DD")

        let whole = Discovery(updatesInPlace: false)
        try await HAPAdvertiser(discovery: whole, deviceID: "2D:10:B9:59:C2:DD")
            .updateStateNumber(name: "MijiaLAN Bridge", port: 60010, category: .bridge, configNumber: 37, stateNumber: 6, isPaired: true)
        #expect(await whole.advertised.map { $0["s#"] } == ["6"])
    }

    private static func bridge() async -> HAPBridge {
        let info = AccessoryInfo(name: "test", manufacturer: "test", model: "test", serialNumber: "test", firmwareRevision: "1")
        let bridge = HAPBridge(info: info)
        await bridge.addAccessory(info: info, services: [
            HAPService(iid: 8, type: .lightbulb, characteristics: [
                HAPCharacteristic(iid: 9, type: .on, value: .bool(false), permissions: [.read, .write, .notify], format: .bool),
                HAPCharacteristic(iid: 10, type: .brightness, value: .int32(50), permissions: [.read, .write, .notify],
                                  format: .int, minValue: 0, maxValue: 100),
            ]),
            HAPService(iid: 20, type: .temperatureSensor, characteristics: [
                HAPCharacteristic(iid: 11, type: .currentTemperature, value: .float(30), permissions: [.read, .notify],
                                  format: .float, minValue: -40, maxValue: 100),
            ]),
        ], aid: 2, servicesHaveStableIIDs: true)
        return bridge
    }

    private actor Numbers {
        var values: [Int] = []
        func append(_ n: Int) { values.append(n) }
        func wait(for expected: [Int]) async throws {
            for _ in 0..<200 where values.count < expected.count { try await MonotonicClock.sleep(for: .milliseconds(2)) }
            #expect(values == expected)
        }
    }

    private actor Discovery: ServiceDiscovery {
        let updatesInPlace: Bool
        var advertised: [[String: String]] = []
        var updated: [[String: String]] = []
        init(updatesInPlace: Bool) { self.updatesInPlace = updatesInPlace }
        func advertise(service: ServiceRecord) async throws { advertised.append(service.txtRecords) }
        func updateTXT(name: String, serviceType: ServiceType, txtRecords: [String: String]) async -> Bool {
            guard updatesInPlace else { return false }
            updated.append(txtRecords)
            return true
        }
        nonisolated func browse(serviceType: ServiceType) -> AsyncStream<ServiceRecord> { AsyncStream { $0.finish() } }
        func resolve(_ record: ServiceRecord) async throws -> NetworkAddress { throw CancellationError() }
        func stopAdvertising() async {}
    }
}
