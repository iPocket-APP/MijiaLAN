import AppKit
import MijiaCore
import ServiceManagement

@MainActor
enum LaunchAtLogin {
    enum Status: Equatable {
        case enabled
        case disabled
        case requiresApproval
        case unavailable

        // A pending item is still registered and can be removed by the switch.
        var registered: Bool? {
            switch self {
            case .enabled, .requiresApproval: true
            case .disabled: false
            case .unavailable: nil
            }
        }
    }

    static var status: Status {
        if #available(macOS 13, *) {
            let mainStatus = SMAppService.mainApp.status
            let statuses = [mainStatus, legacyService?.status].compactMap { $0 }
            if statuses.contains(.enabled) { return .enabled }
            if statuses.contains(.requiresApproval) { return .requiresApproval }
            switch mainStatus {
            case .notFound, .notRegistered: return .disabled
            default: return .unavailable
            }
        }

        return montereyStatus
    }

    @available(macOS, deprecated: 13, message: "Use SMAppService on macOS 13 and later")
    private static var montereyStatus: Status {
        guard let identifier = helperIdentifier else { return .unavailable }
        let job = SMJobCopyDictionary(kSMDomainUserLaunchd, identifier as CFString)?.takeRetainedValue()
        return job == nil ? .disabled : .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if #available(macOS 13, *) {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                // After an OS upgrade, the helper may still own an existing registration.
                let services = [legacyService, SMAppService.mainApp].compactMap { $0 }
                for service in services where service.status == .enabled || service.status == .requiresApproval {
                    try service.unregister()
                }
            }
            return
        }

        guard let identifier = helperIdentifier, SMLoginItemSetEnabled(identifier as CFString, enabled) else {
            throw LoginItemError.registrationFailed
        }
    }

    static func openSystemSettings() {
        if #available(macOS 13, *) { SMAppService.openSystemSettingsLoginItems() }
    }

    @available(macOS 13, *)
    private static var legacyService: SMAppService? {
        helperIdentifier.map { SMAppService.loginItem(identifier: $0) }
    }

    private static var helperIdentifier: String? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LoginItems/MijiaLANLoginItem.app")
        return Bundle(url: url)?.bundleIdentifier
    }

    private enum LoginItemError: LocalizedError {
        case registrationFailed

        var errorDescription: String? {
            L10n.tr("macOS 未能更新登录项。", "macOS could not update the login item.")
        }
    }
}
