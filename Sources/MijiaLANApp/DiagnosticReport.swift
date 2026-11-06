import AppKit
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

    static func json(model: AppModel) -> Data? {
        json(snapshots: Array(model.devices.snapshots.values), retryStates: model.devices.retryStates,
             hidden: model.store.hiddenDeviceIds, failures: model.bridge.readFailures,
             bridge: Bridge(status: String(describing: model.bridge.status), paired: model.bridge.isPaired,
                            accessories: model.bridge.exposedDeviceCount, keepsMacAwake: model.bridge.keepsMacAwake),
             revisions: (model.devices.structureRevision, model.devices.valuesRevision))
    }

    static func json(snapshots: [DeviceSnapshot], retryStates: [String: ProbeRetryState], hidden: Set<String>,
                     failures: [HomeKitBridgeController.ReadFailure], bridge: Bridge,
                     revisions: (structure: UInt64, values: UInt64), now: Date = Date()) -> Data? {
        let failuresByDevice = Dictionary(grouping: failures, by: \.deviceID)
        let rows: [[String: Any]] = snapshots.sorted { $0.id < $1.id }.map { s in
            var row: [String: Any] = [
                "did": s.id, "model": s.device.model, "name": s.device.name, "health": String(describing: s.health.state),
                "homeIncluded": !hidden.contains(s.id),
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
            "devices": rows,
        ]
        return try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
    }

    /// Reads every device once more, then saves the report where the user can pick it up. `~/Library/Logs` needs no
    /// file-access prompt, unlike the Desktop or Downloads.
    static func export(model: AppModel) async throws -> URL {
        await model.devices.refreshNow()
        // Let the bridge publish what that read found before its read statuses are collected.
        try? await Task.sleep(for: .milliseconds(300))
        guard let data = json(model: model) else { throw CocoaError(.fileWriteUnknown) }
        let directory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/MijiaLAN", isDirectory: true)
        let stamp = Date().formatted(.verbatim("\(year: .defaultDigits)\(month: .twoDigits)\(day: .twoDigits)-\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)",
                                               timeZone: .current, calendar: Calendar(identifier: .gregorian)))
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
