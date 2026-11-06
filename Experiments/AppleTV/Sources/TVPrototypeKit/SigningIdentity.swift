import Foundation

public enum SigningIssue: Error, LocalizedError, Sendable {
    case invalidSignature, missingSignature, inconsistentEntitlements, missingTunnel, ambiguousTunnels
    case identityMismatch, requiresResigning, missingAppGroup, ambiguousAppGroup, missingKeychain, ambiguousKeychain, missingNetworkExtension
    public var errorDescription: String? {
        switch self {
        case .invalidSignature, .missingSignature, .inconsistentEntitlements:
            "无法确认重签后的权限。请同时重签 App 和扩展，并保留一致的 XML / DER 权限。"
        case .missingTunnel: "未找到网络扩展。请在侧载工具中保留 App Extensions / PlugIns，再重新安装。"
        case .ambiguousTunnels: "发现多个 Packet Tunnel 扩展，无法确定桥接服务。请使用完整的原始安装包。"
        case .identityMismatch: "App 与扩展的签名团队或标识不一致，请将二者一起重签。"
        case .requiresResigning: "当前仅有分发权限模板。请用支持所需权限的开发团队重签后安装。"
        case .missingAppGroup: "App 与扩展没有共同的 App Group 权限。请保留共享权限并同时重签二者。"
        case .ambiguousAppGroup: "存在多个共享 App Group，无法确定实验数据位置。请检查重签配置。"
        case .missingKeychain: "App 与扩展没有共同的共享 Keychain 权限。请保留共享权限并同时重签二者。"
        case .ambiguousKeychain: "存在多个共享 Keychain 组，无法确定实验钥匙串。请检查重签配置。"
        case .missingNetworkExtension:
            "重签未授予 Packet Tunnel 权限。请使用能授权 Network Extensions 的开发团队，并保留网络扩展；侧载工具无法补授系统权限。"
        }
    }
}

public struct SigningIdentity: Equatable, Sendable {
    public let appGroup: String
    public let keychainGroup: String
    public let providerBundleIdentifier: String
    public let packetTunnelAllowed: Bool

    /// Used by both processes: intersect the actual signatures, never a build-time team prefix.
    public static func live(bundle: Bundle = .main) throws -> Self {
        let app = try applicationBundle(containing: bundle)
        let provider = try tunnel(in: app)
        guard let executable = app.executableURL, let providerExecutable = provider.executableURL,
              let appID = app.bundleIdentifier, let providerID = provider.bundleIdentifier else { throw SigningIssue.identityMismatch }
        let identity = try resolve(app: SignedEntitlements.read(executable: executable),
            tunnel: SignedEntitlements.read(executable: providerExecutable), appID: appID, tunnelID: providerID,
            preferredAppGroup: app.object(forInfoDictionaryKey: "PrototypeAppGroup") as? String,
            preferredKeychain: app.object(forInfoDictionaryKey: "PrototypeKeychainGroup") as? String)
        return identity
    }

    public static func providerIdentifier(bundle: Bundle = .main) throws -> String {
        let app = try applicationBundle(containing: bundle)
        guard let appID = app.bundleIdentifier, let id = try tunnel(in: app).bundleIdentifier,
              id.hasPrefix(appID + ".") else { throw SigningIssue.identityMismatch }
        return id
    }

    public func requireNetworkExtension() throws {
        guard packetTunnelAllowed else { throw SigningIssue.missingNetworkExtension }
    }

    /// The containing app passes its already-intersected selection through NE's provider configuration.
    /// The provider rechecks its own signature, without depending on sandbox access to the host executable.
    public static func providerBinding(appGroup: String, keychainGroup: String, bundle: Bundle = .main) throws -> Self {
        guard bundle.bundleURL.pathExtension == "appex", let id = bundle.bundleIdentifier,
              let executable = bundle.executableURL else { throw SigningIssue.identityMismatch }
        return try resolveProvider(grants: SignedEntitlements.read(executable: executable),
            providerID: id, appGroup: appGroup, keychainGroup: keychainGroup)
    }

    static func resolveProvider(grants: SignedEntitlements, providerID: String, appGroup: String, keychainGroup: String) throws -> Self {
        guard let team = grants.teamIdentifier, !team.isEmpty, matches(grants.applicationIdentifier, bundleID: providerID) else {
            throw SigningIssue.identityMismatch
        }
        guard team != "UNSIGNED00" else { throw SigningIssue.requiresResigning }
        guard appGroup.hasPrefix("group."), !appGroup.contains("*"), grants.appGroups.contains(appGroup) else {
            throw SigningIssue.missingAppGroup
        }
        guard !keychainGroup.contains("*"), grants.keychainGroups.contains(keychainGroup) else { throw SigningIssue.missingKeychain }
        let identity = Self(appGroup: appGroup, keychainGroup: keychainGroup, providerBundleIdentifier: providerID,
                            packetTunnelAllowed: grants.networkExtensions.contains("packet-tunnel-provider"))
        try identity.requireNetworkExtension()
        return identity
    }

    static func resolve(app: SignedEntitlements, tunnel: SignedEntitlements, appID: String, tunnelID: String,
                        preferredAppGroup: String? = nil, preferredKeychain: String? = nil) throws -> Self {
        guard tunnelID.hasPrefix(appID + "."), let team = app.teamIdentifier, !team.isEmpty,
              team == tunnel.teamIdentifier, matches(app.applicationIdentifier, bundleID: appID),
              matches(tunnel.applicationIdentifier, bundleID: tunnelID) else { throw SigningIssue.identityMismatch }
        guard team != "UNSIGNED00" else { throw SigningIssue.requiresResigning }
        let groups = Set(app.appGroups).intersection(tunnel.appGroups).filter { $0.hasPrefix("group.") && !$0.contains("*") }
        let shared = Set(app.keychainGroups).intersection(tunnel.keychainGroups).filter { !$0.contains("*") && $0.contains(".") }
        let group = try select(groups, preferred: preferredAppGroup, suffix: nil,
                               missing: .missingAppGroup, ambiguous: .ambiguousAppGroup)
        let keychain = try select(shared, preferred: preferredKeychain, suffix: ".shared",
                                  missing: .missingKeychain, ambiguous: .ambiguousKeychain)
        return Self(appGroup: group, keychainGroup: keychain, providerBundleIdentifier: tunnelID,
            packetTunnelAllowed: app.networkExtensions.contains("packet-tunnel-provider") && tunnel.networkExtensions.contains("packet-tunnel-provider"))
    }

    private static func select(_ values: Set<String>, preferred: String?, suffix: String?,
                               missing: SigningIssue, ambiguous: SigningIssue) throws -> String {
        if let preferred, values.contains(preferred) { return preferred }
        if values.count == 1, let only = values.first { return only }
        if let preferred {
            let renamed = values.filter { $0.hasPrefix(preferred + ".") }
            if renamed.count == 1, let only = renamed.first { return only }
        }
        if let suffix {
            let named = values.filter { $0.hasSuffix(suffix) }
            if named.count == 1, let only = named.first { return only }
        }
        throw values.isEmpty ? missing : ambiguous
    }

    private static func matches(_ identifier: String?, bundleID: String) -> Bool {
        guard let identifier, identifier.hasSuffix("." + bundleID), !identifier.contains("*") else { return false }
        let prefix = identifier.dropLast(bundleID.count + 1)
        return !prefix.isEmpty && !prefix.contains(".")
    }

    private static func applicationBundle(containing bundle: Bundle) throws -> Bundle {
        if bundle.bundleURL.pathExtension == "appex" {
            let url = bundle.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            guard url.pathExtension == "app", let app = Bundle(url: url) else { throw SigningIssue.missingTunnel }
            return app
        }
        return bundle
    }

    private static func tunnel(in app: Bundle) throws -> Bundle {
        let directory = app.bundleURL.appendingPathComponent("PlugIns", isDirectory: true)
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let providers = urls.filter { $0.pathExtension == "appex" }.compactMap(Bundle.init(url:)).filter {
            ($0.object(forInfoDictionaryKey: "NSExtension") as? [String: Any])?["NSExtensionPointIdentifier"] as? String == "com.apple.networkextension.packet-tunnel"
        }
        guard providers.count == 1, let provider = providers.first else {
            throw providers.isEmpty ? SigningIssue.missingTunnel : SigningIssue.ambiguousTunnels
        }
        return provider
    }
}
