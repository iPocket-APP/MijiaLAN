import Combine
import Foundation
import MijiaCore
import Testing
@testable import MijiaLAN

@MainActor
struct DeviceCapabilityTests {
    private let token = "00112233445566778899aabbccddeeff"

    @Test("Repeated services, properties and actions keep the first capability definition")
    func duplicateSchemaEntries() throws {
        var schema = try #require(DeviceSchema.bundled(model: "careli.fryer.maf07c"))
        let original = DeviceCapabilityCatalog.capabilities(schema: schema, model: "careli.fryer.maf07c")
        schema.services += schema.services
        let repeated = DeviceCapabilityCatalog.capabilities(schema: schema, model: "careli.fryer.maf07c")
        #expect(repeated == original)
        #expect(Set(repeated.map(\.id)).count == repeated.count)
    }

    @Test("Every enabled MIoT property routes to its exact service and property", arguments: DeviceSchema.bundledModels.filter { LegacyMiioProfile.forModel($0) == nil })
    func everyProperty(model: String) async throws {
        let (controller, fake, _) = try makeController(model: model)
        await controller.refreshNow()
        let snapshot = try #require(controller.snapshots["123"])
        for c in snapshot.controls where c.kind == .property && !c.prepared {
            let value: JSONValue = c.format == "bool" ? .bool(true) : .number(c.options.last.map { Double($0.value) } ?? c.max ?? 0)
            try await controller.execute(did: "123", .set(c.id, value))
            let packet = try #require(fake.receivedWrites.last)
            #expect(packet["siid"]?.intValue == c.siid)
            #expect(packet["piid"]?.intValue == c.iid)
            #expect(packet["value"] == value)
        }
    }

    @Test("A mode the spec does not list is still a reading, kept out of MijiaCore; wrong types, out-of-range numbers and writes are refused")
    func unlistedOption() async throws {
        let (controller, fake, _) = try makeController(model: "dmaker.fan.p28")
        fake.props["2.3"] = .number(9)
        await controller.refreshNow()
        let s = try #require(controller.snapshots["123"])
        let mode = try #require(s.capabilitiesByID["p:2:3"])
        #expect(s.value("p:2:3") == .number(9))
        #expect(s.readings["p:2:3"]?.error == nil)
        #expect(!mode.lists(.number(9)) && mode.lists(.number(1)))
        let home = controller.synthesizedHome()
        #expect(home.devices.first { $0.id == "123" } != nil)
        #expect(throws: DeviceControlError.self) { try mode.validatedReading(.string("smart")) }
        #expect(throws: DeviceControlError.self) { try mode.validated(.number(9)) }
        let speed = try #require(s.capabilitiesByID["p:8:1"])
        #expect(throws: DeviceControlError.self) { try speed.validatedReading(.number(101)) }
    }

    @Test("Firmware-quantized values are retained, never overwritten with the requested number")
    func quantization() async throws {
        let (controller, fake, _) = try makeController(model: "dmaker.fan.p28")
        await controller.refreshNow()
        fake.quantizeSpeed = true
        await #expect(throws: DeviceControlError.notConfirmed) { try await controller.execute(did: "123", .set("p:8:1", .number(43))) }
        #expect(controller.snapshots["123"]?.value("p:8:1") == .number(40))
        #expect(controller.snapshots["123"]?.commandReceipt?.acceptedAt != nil)
        #expect(controller.snapshots["123"]?.commandReceipt?.confirmedAt == nil)
    }

    @Test("A write reply without a return code is rejected")
    func missingCode() async throws {
        let (controller, fake, _) = try makeController(model: "dmaker.fan.p28")
        await controller.refreshNow()
        fake.omitWriteCode = true
        await #expect(throws: (any Error).self) { try await controller.execute(did: "123", .set("p:8:1", .number(43))) }
        #expect(controller.snapshots["123"]?.commandReceipt?.acceptedAt == nil)
        #expect(controller.snapshots["123"]?.value("p:8:1") == .number(1))
    }

    @Test("All ten pinned schemas retain service IDs, enum comments and ordered action arguments", arguments: DeviceSchema.bundledModels)
    func schema(model: String) throws {
        let schema = try #require(DeviceSchema.bundled(model: model))
        #expect(schema.model == model)
        #expect(schema.coreSpec != nil)
        let caps = DeviceCapabilityCatalog.capabilities(schema: schema, model: model)
        #expect(Set(caps.map(\.id)).count == caps.count)
        #expect(!caps.filter { $0.control != .reading && $0.control != .unsupported }.isEmpty)
        for c in caps where c.control == .number || c.control == .choice {
            if let value = c.options.first?.value { #expect(try c.validated(.number(Double(value))) == .number(Double(value))) }
            if let min = c.min { #expect(throws: DeviceControlError.self) { try c.validated(.number(min - c.step)) } }
            if let max = c.max { #expect(throws: DeviceControlError.self) { try c.validated(.number(max + c.step)) } }
        }
        if model == "dmaker.fan.p28" {
            #expect(caps.first { $0.id == "p:8:1" }?.range == [1, 100, 1])
            #expect(caps.first { $0.id == "p:2:2" }?.options.map(\.value) == [1, 2, 3, 4])
            #expect(caps.first { $0.id == "p:2:3" }?.options.map(\.title) == ["直吹风", "自然风", "智能风", "睡眠风"])
            #expect(caps.first { $0.id == "p:8:2" }?.control == .unsupported)
        }
        if model == "careli.fryer.maf07c" {
            #expect(schema.services.first { $0.iid == 2 }?.actions.first { $0.iid == 5 }?.inputs == [3, 4, 7, 10, 11, 13, 16, 17, 18])
            #expect(caps.first { $0.id == "a:2:5" }?.control == .unsupported)
        }
        if model == "cuco.plug.v3" {
            #expect(caps.first { $0.id == "p:2:2" }?.options.map(\.title) == ["恢复断电前状态", "上电打开", "上电关闭"])
            #expect(caps.first { $0.id == "p:4:2" }?.range == [2, 10, 1])
            #expect(caps.first { $0.id == "p:14:1" }?.range == [2, 600, 1])
            #expect(caps.first { $0.id == "p:5:1" }?.writable == false)
        }
    }

    @Test("Kitchen menu selection sends nothing and start uses the schema's exact input parameter", arguments: ["chunmi.cooker.cmwy3", "chunmi.health_pot.a1", "chunmi.juicer.a1", "careli.fryer.maf07c"])
    func kitchen(model: String) async throws {
        let (controller, fake, _) = try makeController(model: model)
        await controller.refreshNow()
        let snapshot = try #require(controller.snapshots["123"])
        let menu = try #require(snapshot.capabilities.first { $0.prepared && ["mode", "cook-mode"].contains($0.name) })
        #expect(throws: DeviceControlError.self) { try controller.actionInputs(snapshot: snapshot, action: #require(snapshot.capabilities.first { $0.id == "a:2:1" })) }
        let option = try #require(menu.options.first)
        try await controller.execute(did: "123", .set(menu.id, .number(Double(option.value))))
        #expect(fake.receivedWrites.isEmpty)
        #expect(controller.snapshots["123"]?.value(menu.id) == snapshot.value(menu.id))
        try await controller.execute(did: "123", .invoke("a:2:1"))
        let action = try #require(fake.receivedWrites.last)
        #expect(action["aiid"]?.intValue == 1)
        #expect(action["siid"]?.intValue == 2)
        // LAN firmware takes each argument as {"piid", "value"}; a bare value is dropped without a reply.
        #expect(action["in"] == .array(model == "careli.fryer.maf07c" ? [] : [
            .object(["piid": .number(Double(menu.iid)), "value": .number(Double(option.value))]),
        ]))
        if !menu.writable { #expect(fake.receivedMethods.filter { $0 == "set_properties" }.isEmpty) }
    }

    @Test("Partial property errors stay local; missing readings never become zero or false")
    func partialErrors() async throws {
        let (controller, fake, _) = try makeController(model: "dmaker.fan.p28")
        fake.props["9.1"] = nil
        await controller.refreshNow()
        let s = try #require(controller.snapshots["123"])
        #expect(s.isOnline)
        #expect(s.value("p:2:1") == .bool(false))
        #expect(s.value("p:9:1") == nil)
        #expect(s.readings["p:9:1"]?.code == -4003)
        #expect(s.readings["p:9:1"]?.error != nil)
        let requested = try fake.receivedPayloads.compactMap { data -> Int? in
            let json = try JSONDecoder().decode(JSONValue.self, from: data.prefix { $0 != 0 })
            return json["method"]?.stringValue == "get_properties" ? json["params"]?.arrayValue?.count : nil
        }
        #expect(!requested.isEmpty && requested.allSatisfy { $0 <= 15 })
    }

    @Test("Health kettle controls use its reported status and a separately selected menu")
    func healthPotControls() async throws {
        let (controller, _, _) = try makeController(model: "chunmi.health_pot.a1")
        defer { controller.shutdown() }
        await controller.refreshNow()
        var snapshot = try #require(controller.snapshots["123"])
        let start = try #require(snapshot.capabilitiesByID["a:2:1"])
        let stop = try #require(snapshot.capabilitiesByID["a:2:2"])
        let status = try #require(snapshot.capabilitiesByID["p:2:1"])
        let menu = try #require(snapshot.capabilitiesByID["p:2:3"])
        #expect(!snapshot.permitsHealthPotAction(start))
        #expect(!snapshot.permitsHealthPotAction(stop))

        try await controller.execute(did: "123", .set(menu.id, .number(5)))
        snapshot = try #require(controller.snapshots["123"])
        #expect(snapshot.permitsHealthPotAction(start))
        #expect(!snapshot.permitsHealthPotAction(stop))
        L10n.$overrideLanguage.withValue(.en) {
            #expect(menu.formatted(snapshot.controlValue(menu)) == "Keep Warm")
            #expect(status.formatted(.number(4)) == "Keeping Warm")
        }

        snapshot.readings[status.id] = DeviceReading(value: .number(4), code: 0)
        #expect(!snapshot.permitsHealthPotAction(start))
        #expect(snapshot.permitsHealthPotAction(stop))

        snapshot.readings[status.id] = DeviceReading(value: .number(5), code: 0)
        #expect(!snapshot.permitsHealthPotAction(start))
        #expect(!snapshot.permitsHealthPotAction(stop))

        // A failed read cannot rule out that the kettle has already started.
        snapshot.readings[status.id] = DeviceReading(value: .number(1), error: "no reply")
        #expect(!snapshot.permitsHealthPotAction(start))
        #expect(snapshot.permitsHealthPotAction(stop))
    }

    @Test("A kettle menu can stop a confirmed local start even when the device cannot read back its menu ID")
    func healthPotMenuStop() async throws {
        let (controller, fake, _) = try makeController(model: HealthPotStatus.model)
        defer { controller.shutdown() }
        fake.props["5.1"] = nil
        await controller.refreshNow()
        let stopWarm = CapabilityCommand.stopHealthPotMenu(action: "a:2:2", menu: 5)
        let stopBoil = CapabilityCommand.stopHealthPotMenu(action: "a:2:2", menu: 4)

        try await controller.execute(did: "123", .batch([.set("p:2:3", .number(5)), .invoke("a:2:1")]))
        #expect(controller.snapshots["123"]?.healthPotMenu == nil)
        #expect(controller.snapshots["123"]?.activeHealthPotMenu == 5)
        try await controller.execute(did: "123", .set("p:2:3", .number(4)))
        try await controller.execute(did: "123", stopBoil)
        #expect(fake.receivedWrites.compactMap { $0["aiid"]?.integer } == [1])

        // Recover a missing status at the moment the corresponding switch is turned off.
        fake.props["2.1"] = nil
        await controller.refreshNow()
        #expect(controller.snapshots["123"]?.healthPotStatus == nil)
        fake.props["2.1"] = .number(4)
        try await controller.execute(did: "123", stopWarm)
        #expect(controller.snapshots["123"]?.healthPotStatus == .idle)
        #expect(fake.receivedWrites.compactMap { $0["aiid"]?.integer } == [1, 2])

        // An unidentified run after the kettle stopped must not use the last menu from this Mac.
        fake.props["2.1"] = .number(2)
        await controller.refreshNow()
        #expect(controller.snapshots["123"]?.activeHealthPotMenu == nil)
        await #expect(throws: DeviceControlError.self) { try await controller.execute(did: "123", stopWarm) }
        fake.props["5.1"] = .number(5)
        fake.props["5.9"] = .number(2)
        await controller.refreshNow()
        try await controller.execute(did: "123", stopBoil)
        #expect(fake.receivedWrites.compactMap { $0["aiid"]?.integer } == [1, 2])

        fake.props["5.9"] = .number(0)
        await controller.refreshNow()
        // A fresh read must catch a change of menu since the last poll.
        #expect(controller.snapshots["123"]?.activeHealthPotMenu == 4)
        fake.props["5.1"] = .number(6)
        try await controller.execute(did: "123", stopBoil)
        #expect(fake.receivedWrites.compactMap { $0["aiid"]?.integer } == [1, 2])
        try await controller.execute(did: "123", stopWarm)
        #expect(fake.receivedWrites.compactMap { $0["aiid"]?.integer } == [1, 2, 2])
    }

    @Test("A timed-out kettle start changes from sending to reading state before releasing the action")
    func healthPotTimeoutFeedback() async throws {
        let (controller, fake, _) = try makeController(model: "chunmi.health_pot.a1")
        defer { controller.shutdown() }
        await controller.refreshNow()
        try await controller.execute(did: "123", .set("p:2:3", .number(5)))
        fake.actionTimeout = true
        var sawSending = false
        var sawReadback = false
        let observation = controller.objectWillChange.sink {
            guard controller.isActionPending(for: "123"),
                  let receipt = controller.snapshots["123"]?.commandReceipt,
                  receipt.capabilityID == "a:2:1", receipt.error == nil else { return }
            if receipt.checkingStateAfterFailure { sawReadback = true }
            else if receipt.acceptedAt == nil { sawSending = true }
        }
        defer { observation.cancel() }

        // Reads still answer, so the person is told the command went unanswered rather than "may be offline".
        await #expect(throws: DeviceControlError.unanswered) { try await controller.execute(did: "123", .invoke("a:2:1")) }
        #expect(controller.snapshots["123"]?.isOnline == true)
        #expect(sawSending)
        #expect(sawReadback)
        #expect(!controller.isActionPending(for: "123"))
        #expect(controller.snapshots["123"]?.commandReceipt?.error != nil)
        #expect(fake.receivedMethods.filter { $0 == "action" }.count == 1)
    }

    @Test("Diagnostics log each command with its source, the request as sent and how it ended")
    func commandLog() async throws {
        let (controller, fake, _) = try makeController(model: "chunmi.health_pot.a1")
        defer { controller.shutdown() }
        await controller.refreshNow()
        try await controller.execute(did: "123", .set("p:2:3", .number(5)))
        try await controller.execute(did: "123", .invoke("a:2:1"))
        fake.actionTimeout = true
        await #expect(throws: DeviceControlError.unanswered) {
            try await DeviceController.$commandSource.withValue(.appleHome) { try await controller.execute(did: "123", .invoke("a:2:2")) }
        }
        var log = try #require(controller.commandLog["123"])
        #expect(log.map(\.outcome) == [.prepared, .confirmed, .failed])
        #expect(log.map(\.source) == [.mac, .mac, .appleHome])
        // A held next-menu setting sends nothing.
        #expect(log[0].request == nil)
        #expect(log[1].request == #"action {"aiid":1,"did":"123","in":[{"piid":3,"value":5}],"siid":2}"#)
        #expect(log[1].statusBefore == 1 && log[1].statusAfter == 2)
        #expect(log[2].request == #"action {"aiid":2,"did":"123","in":[],"siid":2}"#)
        #expect(log[2].errorCode == "unanswered" && log[2].onlineAfter)

        for _ in 0..<DeviceController.commandLogLimit { try await controller.execute(did: "123", .set("p:2:3", .number(4))) }
        log = try #require(controller.commandLog["123"])
        #expect(log.count == DeviceController.commandLogLimit && log.allSatisfy { $0.outcome == .prepared })

        // Refused before sending (no menu selected): recorded, without a request.
        let (fresh, freshDevice, _) = try makeController(model: "chunmi.health_pot.a1")
        defer { fresh.shutdown() }
        await fresh.refreshNow()
        await #expect(throws: DeviceControlError.self) { try await fresh.execute(did: "123", .invoke("a:2:1")) }
        let refused = try #require(fresh.commandLog["123"]?.last)
        #expect(refused.request == nil && refused.outcome == .failed && refused.errorCode?.hasPrefix("missingInput") == true)
        #expect(freshDevice.receivedMethods.filter { $0 == "action" }.isEmpty)
    }

    @Test("Coalescing sends the latest speed once and never updates from the requested value")
    func coalescing() async throws {
        let (controller, fake, _) = try makeController(model: "dmaker.fan.p28")
        await controller.refreshNow()
        let one = Task { try await controller.execute(did: "123", .set("p:8:1", .number(30)), coalesce: true) }
        let two = Task { try await controller.execute(did: "123", .set("p:8:1", .number(60)), coalesce: true) }
        let three = Task { try await controller.execute(did: "123", .set("p:8:1", .number(75)), coalesce: true) }
        try await one.value; try await two.value; try await three.value
        #expect(fake.receivedWrites.count == 1)
        #expect(fake.receivedWrites.first?["value"] == .number(75))
        #expect(controller.snapshots["123"]?.value("p:8:1") == .number(75))
        #expect(fake.receivedMethods.last == "get_properties")
        fake.offline = true
        await #expect(throws: (any Error).self) { try await controller.execute(did: "123", .set("p:8:1", .number(90))) }
        #expect(controller.snapshots["123"]?.readings["p:8:1"]?.value == .number(75))
    }

    @Test("Offline commands reject without claiming success; pending menus are allowed offline")
    func offline() async throws {
        let (controller, fake, _) = try makeController(model: "chunmi.juicer.a1")
        fake.offline = true
        await controller.refreshNow()
        try await controller.execute(did: "123", .set("p:2:2", .number(3)))
        await #expect(throws: DeviceControlError.offline) { try await controller.execute(did: "123", .invoke("a:2:1")) }
        #expect(fake.receivedWrites.isEmpty)
    }

    @Test("A timed-out cooking action is not resent")
    func actionTimeout() async throws {
        let network = FakeMiioNetwork()
        let fake = network.add(host: "test", token: token, deviceID: 123)
        fake.actionTimeout = true
        let client = MiioClient(host: "test", token: MiioToken.parse(token)!, transport: network, retries: 3)
        await #expect(throws: (any Error).self) { try await client.action(MiotActionCall(did: "123", siid: 2, aiid: 1, inputs: [.number(1)]), inputIDs: [3]) }
        #expect(fake.receivedMethods.filter { $0 == "action" }.count == 1)
    }

    @Test("LAN actions send each argument as piid and value; unpaired arguments are never sent")
    func actionArguments() async throws {
        let network = FakeMiioNetwork()
        let fake = network.add(host: "test", token: token, deviceID: 123)
        let client = MiioClient(host: "test", token: MiioToken.parse(token)!, transport: network)
        try await client.action(MiotActionCall(did: "123", siid: 2, aiid: 1, inputs: [.number(5)]), inputIDs: [3])
        #expect(fake.receivedWrites.last?["in"] == .array([.object(["piid": .number(3), "value": .number(5)])]))
        await #expect(throws: DeviceControlError.argumentMismatch) {
            try await client.action(MiotActionCall(did: "123", siid: 2, aiid: 1, inputs: [.number(5)]))
        }
        #expect(fake.receivedMethods.filter { $0 == "action" }.count == 1)
    }

    @Test("An explicit reconnect bypasses offline backoff and only reads device state")
    func manualReconnect() async throws {
        let (controller, fake, _) = try makeController(model: "dmaker.fan.p28")
        fake.offline = true
        await controller.refreshNow()
        #expect(controller.snapshots["123"]?.health.state == .offline)
        fake.offline = false
        await controller.retry(did: "123")
        #expect(controller.snapshots["123"]?.health.state == .online)
        #expect(controller.snapshots["123"]?.value("p:8:1") == .number(1))
        #expect(fake.receivedWrites.isEmpty)
        #expect(fake.receivedMethods.contains("miIO.info"))
    }

    private func makeController(model: String) throws -> (DeviceController, FakeMiioNetwork.Device, LANMiotAPI) {
        let schema = try #require(DeviceSchema.bundled(model: model))
        let caps = DeviceCapabilityCatalog.capabilities(schema: schema, model: model)
        let values = Dictionary(uniqueKeysWithValues: caps.filter(\.readable).map { c in
            let value: JSONValue = c.format == "bool" ? .bool(false) : .number(c.options.first.map { Double($0.value) } ?? c.min ?? 0)
            return ("\(c.siid).\(c.iid)", value)
        })
        let network = FakeMiioNetwork()
        let fake = network.add(host: "test", token: token, deviceID: 123, props: values)
        fake.model = model
        let device = LocalDevice(did: "123", name: "Test", model: model, host: "test", token: token)
        let config = LocalHomeConfig(devices: [device])
        let api = LANMiotAPI(config: { config }, transport: network)
        return (DeviceController(api: api, config: { config }), fake, api)
    }
}
