import Foundation
import MijiaCore
import Security

/// A separate Keychain namespace and App Group; the production Mac vault is never read.
public struct PrototypeStorage: Sendable {
    public let directory: URL
    private let accessGroup: String?
    private let service: String
    private let storesPairingCode: Bool
    public var namespace: String { service }

    public init(directory: URL, accessGroup: String? = nil, service: String = "com.ipocket.MijiaLAN.TVPrototype", storesPairingCode: Bool = true) {
        self.directory = directory; self.accessGroup = accessGroup; self.service = service
        self.storesPairingCode = storesPairingCode
    }

    public static func live(identity: SigningIdentity? = nil) throws -> Self {
        #if targetEnvironment(simulator)
        guard let group = Bundle.main.object(forInfoDictionaryKey: "PrototypeAppGroup") as? String,
              !group.isEmpty else {
            throw PrototypeError.sharedContainerUnavailable
        }
        let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(group)
        // Simulator Keychain does not enforce the device provisioning profile's shared access group.
        return Self(directory: directory, service: group)
        #else
        let identity = try identity ?? SigningIdentity.live()
        guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identity.appGroup) else {
            throw PrototypeError.sharedContainerUnavailable
        }
        return Self(directory: directory, accessGroup: identity.keychainGroup, service: identity.appGroup)
        #endif
    }

    public func readSecret(_ account: String) -> CredentialVault.Lookup {
        var query = keychainQuery(account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess: return (result as? Data).map(CredentialVault.Lookup.value) ?? .unavailable
        case errSecItemNotFound: return .missing
        default: return .unavailable
        }
    }

    public func writeSecret(_ data: Data?, account: String) -> Bool {
        let query = keychainQuery(account)
        guard let data else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var addition = query
        addition[kSecValueData] = data
        addition[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(addition as CFDictionary, nil) == errSecSuccess
    }

    private func keychainQuery(_ account: String) -> [CFString: Any] {
        var query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        if let accessGroup { query[kSecAttrAccessGroup] = accessGroup }
        return query
    }

    public func configuration() throws -> PrototypeConfiguration {
        guard case .value(let data) = readSecret("configuration") else { throw PrototypeError.keychainUnavailable }
        return try JSONDecoder().decode(PrototypeConfiguration.self, from: data).validated()
    }

    public func saveConfiguration(_ config: PrototypeConfiguration) throws {
        let data = try JSONEncoder().encode(config.validated())
        guard writeSecret(data, account: "configuration") else { throw PrototypeError.keychainUnavailable }
    }

    public func markLifecycle(_ phase: String) throws { try write(LifecycleMarker(phase: phase), name: "app-lifecycle.json") }
    public func lifecycle() -> LifecycleMarker? { read(LifecycleMarker.self, name: "app-lifecycle.json") }
    public func saveEvidence(_ evidence: PrototypeEvidence) throws { try write(evidence, name: "evidence.json") }
    public func evidence() -> PrototypeEvidence? { read(PrototypeEvidence.self, name: "evidence.json") }
    public func saveDiagnostics(_ report: PrototypeDiagnostics) throws { try write(report, name: "runtime-diagnostics.json") }
    public func diagnostics() -> PrototypeDiagnostics? { read(PrototypeDiagnostics.self, name: "runtime-diagnostics.json") }
    public func activationSummary() -> PrototypeActivationSummary? { read(PrototypeActivationSummary.self, name: "activation.json") }

    public func saveActivation(stage: String, error: NSError? = nil) throws {
        struct Activation: Encodable {
            var at: Date
            var stage: String
            var errorDomain: String?
            var errorCode: Int?
            var message: String?
        }
        try write(Activation(at: Date(), stage: stage, errorDomain: error?.domain,
            errorCode: error?.code, message: error?.localizedDescription), name: "activation.json")
    }

    /// Pairing material is deliberately separate from redacted evidence and diagnostic files.
    public func savePairingCode(_ code: String?) throws {
        guard storesPairingCode else { return }
        guard writeSecret(code.map { Data($0.utf8) }, account: "pairing-code") else { throw PrototypeError.keychainUnavailable }
    }
    public func pairingCode() -> String? {
        if case .value(let data) = readSecret("pairing-code") { return String(data: data, encoding: .utf8) }
        return nil
    }

    private func write<T: Encodable>(_ value: T, name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: directory.appendingPathComponent(name), options: .atomic)
    }
    private func read<T: Decodable>(_ type: T.Type, name: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
