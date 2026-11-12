import AppKit
import MijiaSupport
import Foundation
import MijiaCore
import MijiaHomeKitBridge
import MijiaLAN

/// The file a user attaches to a problem report: each device's health and readings, and the characteristics Home
/// currently reads as failed, which are what put a warning on an accessory tile.
///
/// Explicit allow-list: never serialize LocalDevice, tokens, IP or MAC addresses, pairing keys or setup codes.
@MainActor
enum DiagnosticReport {
    struct Bridge {
        var status: String
        var paired: Bool
        var accessories: Int
        var keepsMacAwake: Bool
    }

    /// `lan` comes from `LANMiotAPI.diagnostics()`, which asks devices for their firmware and so is awaited first.
    static func json(model: AppModel, lan: [String: LANDeviceDiagnostics] = [:]) -> Data? {
        let snapshots = Array(model.devices.snapshots.values)
        return json(snapshots: snapshots, retryStates: model.devices.retryStates,
                    hidden: model.store.hiddenDeviceIds, failures: model.bridge.readFailures,
                    bridge: Bridge(status: String(describing: model.bridge.status), paired: model.bridge.isPaired,
                                   accessories: model.bridge.exposedDeviceCount, keepsMacAwake: model.bridge.keepsMacAwake),
                    revisions: (model.devices.structureRevision, model.devices.valuesRevision),
                    commands: model.devices.commandLog, lan: lan,
                    home: Dictionary(uniqueKeysWithValues: snapshots.compactMap { s in model.bridge.publishedServices(for: s.id).map { (s.id, $0) } }),
                    excludedServices: model.bridge.excludedServices)
    }

    static func json(snapshots: [DeviceSnapshot], retryStates: [String: ProbeRetryState], hidden: Set<String>,
                     failures: [HomeKitBridgeController.ReadFailure], bridge: Bridge,
                     revisions: (structure: UInt64, values: UInt64), now: Date = Date(),
                     commands: [String: [DeviceCommandRecord]] = [:], lan: [String: LANDeviceDiagnostics] = [:],
                     home: [String: [HomeKitBridgeController.PublishedService]] = [:],
                     excludedServices: [String: Set<String>] = [:]) -> Data? {
        let failuresByDevice = Dictionary(grouping: failures, by: \.deviceID)
        let rows: [[String: Any]] = snapshots.sorted { $0.id < $1.id }.map { s in
            var row: [String: Any] = [
                "did": s.id, "model": s.device.model, "name": s.device.name, "health": String(describing: s.health.state),
                "homeIncluded": !hidden.contains(s.id),
                // False: no control maps to a Home service, so the bridge leaves the device out whatever the switch says.
                "homeKitSupported": CapabilityHomeKitMapper.mapsToHome(s),
                "readings": s.capabilities.filter(\.readable).map { c -> [String: Any] in
                    var entry: [String: Any] = ["id": c.id, "name": c.title]
                    if let reading = s.readings[c.id] {
                        entry["value"] = reading.value?.compactJSONString
                        entry["code"] = reading.code
                        entry["error"] = reading.error
                        entry["updatedAt"] = reading.updatedAt?.ISO8601Format()
                    }
                    return entry
                },
                "homeKitReadFailures": (failuresByDevice[s.id] ?? []).map {
                    ["service": $0.service, "characteristic": $0.characteristic, "source": $0.source, "status": $0.status]
                },
            ]
            // The spec's public identifier, enough to reproduce the Home mapping for this model.
            row["specType"] = s.schema.type
            row["lastError"] = s.health.lastError
            row["lastSeen"] = s.health.lastSeen?.ISO8601Format()
            if let retry = retryStates[s.id] {
                row["retryFailures"] = retry.consecutiveFailures
                row["nextRetryAt"] = retry.nextRetryAt?.ISO8601Format()
                row["isProbing"] = retry.isProbing
            }
            // Settings selected on the Mac and not sent until an action runs, such as a kettle's next menu.
            row["prepared"] = Dictionary(uniqueKeysWithValues: s.prepared.map { ($0.key, $0.value.compactJSONString) })
            row["commands"] = (commands[s.id] ?? []).map(commandRow)
            if let device = lan[s.id] {
                row["firmware"] = device.firmware
                if let link = device.link { row["link"] = linkRow(link) }
            }
            if let services = home[s.id] {
                row["home"] = ["services": services.map(serviceRow), "excluded": (excludedServices[s.id] ?? []).sorted()]
            }
            return row
        }
        let info = Bundle.main.infoDictionary
        let output: [String: Any] = [
            "recordedAt": now.ISO8601Format(),
            "app": ["version": info?["CFBundleShortVersionString"] as? String ?? "", "build": info?["CFBundleVersion"] as? String ?? ""],
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "language": L10n.isEnglish ? "en" : "zh-Hans",
            "bridge": bridge.status, "accessories": bridge.accessories, "paired": bridge.paired,
            "keepsMacAwake": bridge.keepsMacAwake,
            "structureRevision": revisions.structure, "valuesRevision": revisions.values,
            "findings": findings(snapshots: snapshots, failures: failuresByDevice, commands: commands, lan: lan, home: home),
            "devices": rows,
        ]
        return try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
    }

    private static func commandRow(_ r: DeviceCommandRecord) -> [String: Any] {
        var row: [String: Any] = ["at": r.at.ISO8601Format(), "source": r.source.rawValue, "capability": r.capabilityID,
                                  "outcome": r.outcome.rawValue, "milliseconds": r.milliseconds, "onlineAfter": r.onlineAfter]
        row["request"] = r.request
        row["error"] = r.error
        row["errorCode"] = r.errorCode
        row["statusBefore"] = r.statusBefore
        row["statusAfter"] = r.statusAfter
        return row
    }

    private static func linkRow(_ link: LANLinkStats) -> [String: Any] {
        var row: [String: Any] = ["since": link.since.ISO8601Format(), "reads": link.reads, "failures": link.failures, "timeouts": link.timeouts]
        row["medianMilliseconds"] = link.medianMilliseconds
        row["p95Milliseconds"] = link.p95Milliseconds
        row["lastFailure"] = link.lastFailure
        row["lastFailureAt"] = link.lastFailureAt?.ISO8601Format()
        return row
    }

    private static func serviceRow(_ service: HomeKitBridgeController.PublishedService) -> [String: Any] {
        var row: [String: Any] = ["key": service.key, "type": service.type, "primary": service.isPrimary]
        row["name"] = service.name
        row["characteristics"] = service.characteristics.map { c -> [String: Any] in
            var entry: [String: Any] = ["type": c.type, "source": c.source]
            entry["value"] = c.value?.compactJSONString
            entry["status"] = c.status
            return entry
        }
        return row
    }

    /// Patterns worth a look before reading the rest, each traced to the field that shows it.
    static func findings(snapshots: [DeviceSnapshot], failures: [String: [HomeKitBridgeController.ReadFailure]],
                         commands: [String: [DeviceCommandRecord]], lan: [String: LANDeviceDiagnostics],
                         home: [String: [HomeKitBridgeController.PublishedService]]) -> [[String: Any]] {
        var found: [[String: Any]] = []
        for s in snapshots.sorted(by: { $0.id < $1.id }) {
            let base: [String: Any] = ["did": s.id, "model": s.device.model]
            if s.health.state != .online {
                found.append(base.merging(["kind": "deviceNotOnline", "health": String(describing: s.health.state),
                                           "detail": s.health.lastError ?? ""]) { $1 })
            }
            // Sent, unanswered, and the device still answered reads: it ignored this request, which points at the
            // request (its arguments, its method) rather than the network.
            for r in commands[s.id] ?? [] where r.outcome == .failed && r.request != nil && r.onlineAfter
                && ["unanswered", "timeout"].contains(r.errorCode) {
                var entry = base.merging(["kind": "commandUnansweredWhileOnline", "capability": r.capabilityID,
                                          "at": r.at.ISO8601Format()]) { $1 }
                entry["request"] = r.request
                found.append(entry)
            }
            if let link = lan[s.id]?.link, link.failures > 0 {
                found.append(base.merging(["kind": "readFailures", "reads": link.reads, "failures": link.failures,
                                           "timeouts": link.timeouts, "detail": link.lastFailure ?? ""]) { $1 })
            }
            if let services = home[s.id], !services.isEmpty {
                // Without a main service Home builds the tile from the others: a switch that is on can read as the
                // device being on, such as a kettle's selected next menu.
                if !services.contains(where: \.isPrimary) {
                    let on = services.filter { $0.characteristics.contains { $0.type == "On" && $0.value == .bool(true) } }
                    found.append(base.merging(["kind": "noPrimaryHomeService", "firstService": services[0].type,
                                               "switchesOn": on.map { $0.name ?? $0.key }]) { $1 })
                }
                if let count = failures[s.id]?.count, count > 0 {
                    found.append(base.merging(["kind": "homeReadFailures", "count": count]) { $1 })
                }
            }
        }
        return found
    }

    /// Reads every device once more, then saves the report where the user can pick it up. `~/Library/Logs` needs no
    /// file-access prompt, unlike the Desktop or Downloads.
    static func export(model: AppModel) async throws -> URL {
        await model.devices.refreshNow()
        let lan = await model.devices.lan.diagnostics()
        // Let the bridge publish what that read found before its read statuses are collected.
        try? await MonotonicClock.sleep(for: .milliseconds(300))
        guard let data = json(model: model, lan: lan) else { throw CocoaError(.fileWriteUnknown) }
        let directory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/MijiaLAN", isDirectory: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let url = directory.appendingPathComponent("MijiaLAN-Diagnostics-\(stamp).json")
        // Blocking filesystem access stays off the main actor.
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }.value
        return url
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static let supportAddress = "contact@ipocket.xyz"

    static var emailSubject: String {
        let info = Bundle.main.infoDictionary
        let version = [info?["CFBundleShortVersionString"] as? String, (info?["CFBundleVersion"] as? String).map { "(\($0))" }]
            .compactMap { $0 }.joined(separator: " ")
        return L10n.tr("MijiaLAN 诊断信息", "MijiaLAN Diagnostics") + (version.isEmpty ? "" : " · " + version)
    }

    static var emailBody: String {
        L10n.tr("请描述遇到的问题，例如哪台设备在「家庭」里显示感叹号：\n\n\n诊断文件已作为附件添加。",
                "Please describe the problem, such as which accessory shows a warning in Home:\n\n\nThe diagnostics file is attached.")
    }

    /// A plain mail link for when no mail app can take an attachment; the file is then attached by hand.
    static func mailtoURL(subject: String, body: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportAddress
        components.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
        return components.url
    }

    /// Opens a new message to support with the report attached. Nothing is sent until the user sends it.
    static func email(_ url: URL) {
        let body = emailBody
        if let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: [body, url]) {
            service.recipients = [supportAddress]
            service.subject = emailSubject
            service.perform(withItems: [body, url])
            return
        }
        if let mailto = mailtoURL(subject: emailSubject, body: body) { NSWorkspace.shared.open(mailto) }
        reveal(url)
    }
}
