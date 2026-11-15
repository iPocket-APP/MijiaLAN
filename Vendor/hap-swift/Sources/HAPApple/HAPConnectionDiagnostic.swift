#if canImport(Network)
import Foundation
import HAPCore
import HAPTransport
import MijiaSupport
import Network

/// Bridge-side evidence for one TCP connection. The request names and error codes are allow-listed.
public struct HAPConnectionDiagnostic: Encodable, Sendable {
    public enum CloseReason: String, Encodable, Sendable {
        case peerClosed, networkError, cancelled, bridgeStopped
        case invalidFrame, requestTooLarge, invalidRequest, responseEncryptionFailed
    }

    public struct NetworkError: Encodable, Sendable {
        public let domain: String
        public let code: Int?

        init(_ error: NWError) {
            switch error {
            case .posix(let code): (domain, self.code) = ("posix", Int(code.rawValue))
            case .dns(let code): (domain, self.code) = ("dns", Int(code))
            case .tls(let code): (domain, self.code) = ("tls", Int(code))
            default: (domain, code) = ("other", nil)
            }
        }
    }

    public struct Close: Encodable, Sendable {
        public let at: Date
        public let reason: CloseReason
        public let error: NetworkError?
        public let pendingBytes: Int
    }

    public struct Request: Encodable, Sendable {
        public let receivedAt: Date
        public fileprivate(set) var responseAt: Date?
        public fileprivate(set) var status: Int?
        public fileprivate(set) var responseBodyBytes: Int?
        public fileprivate(set) var acceptedBySocketAt: Date?
        public fileprivate(set) var sendError: NetworkError?
        public fileprivate(set) var characteristicFailures: [String: Int]?
    }

    struct RequestID: Sendable {
        let kind: String
        let receivedAt: Date
    }

    public let connection: Int
    public let acceptedAt: Date
    public fileprivate(set) var readyAt: Date?
    public fileprivate(set) var encryptedAt: Date?
    public fileprivate(set) var pairSetup: HAPHandshakeEvent?
    public fileprivate(set) var completedPairSetup: HAPHandshakeEvent?
    public fileprivate(set) var pairVerify: HAPHandshakeEvent?
    /// References another connection in this listener only. Controller identifiers stay in memory.
    public fileprivate(set) var verifiesPairSetupOnConnection: Int?
    public fileprivate(set) var requests: [String: Request] = [:]
    public fileprivate(set) var close: Close?
    public fileprivate(set) var pendingBytes = 0
}

/// NWConnection callbacks and the connection actor update the same record. The lock covers synchronous
/// field updates only, and a closed record can still receive the result of an outstanding socket write.
final class HAPConnectionTrace: Sendable {
    private let state: LockedState<HAPConnectionDiagnostic>

    init(connection: Int) {
        state = LockedState(initialState: .init(connection: connection, acceptedAt: Date()))
    }

    func snapshot() -> HAPConnectionDiagnostic { state.withLock { $0 } }
    func ready() { state.withLock { $0.readyAt = Date() } }
    func encrypted() { state.withLock { $0.encryptedAt = Date() } }
    func linkToPairSetup(_ connection: Int?) { state.withLock { $0.verifiesPairSetupOnConnection = connection } }
    func buffering(_ bytes: Int) { state.withLock { $0.pendingBytes = bytes } }

    func handshake(_ event: HAPHandshakeEvent) {
        state.withLock {
            switch event.phase {
            case .setup:
                $0.pairSetup = event
                if event.outcome == .completed { $0.completedPairSetup = event }
            case .verify: $0.pairVerify = event
            }
        }
    }

    /// First request of each kind on a connection. Frequent polling cannot displace setup evidence.
    func receive(_ request: HTTPRequest) -> HAPConnectionDiagnostic.RequestID? {
        let kind: String
        switch (request.method, request.path) {
        case ("POST", "/pair-setup"): kind = "pairSetup"
        case ("POST", "/pair-verify"): kind = "pairVerify"
        case ("GET", "/accessories"): kind = "accessoryDatabase"
        case ("GET", let path) where path == "/characteristics" || path.hasPrefix("/characteristics?"):
            kind = "characteristicRead"
        case ("PUT", "/characteristics"):
            let bothRecorded = state.withLock {
                $0.requests["characteristicSubscription"] != nil && $0.requests["characteristicWrite"] != nil
            }
            guard !bothRecorded else { return nil }
            // The first subscription also represents a PUT that combines subscriptions and writes.
            let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
            let entries = body?["characteristics"] as? [[String: Any]]
            kind = entries?.contains(where: { $0["ev"] is Bool }) == true ? "characteristicSubscription" : "characteristicWrite"
        default: return nil
        }
        return state.withLock {
            // The response associated with the final setup/verify message is the one a support report needs.
            guard kind == "pairSetup" || kind == "pairVerify" || $0.requests[kind] == nil else { return nil }
            let id = HAPConnectionDiagnostic.RequestID(kind: kind, receivedAt: Date())
            $0.requests[kind] = .init(receivedAt: id.receivedAt)
            return id
        }
    }

    func response(_ id: HAPConnectionDiagnostic.RequestID, _ response: HTTPResponse) {
        var failures: [String: Int] = [:]
        if response.statusCode == 207,
           let body = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any],
           let entries = body["characteristics"] as? [[String: Any]] {
            for entry in entries {
                guard let status = entry["status"] as? Int, status != 0, HAPStatus(rawValue: status) != nil else { continue }
                failures[String(status), default: 0] += 1
            }
        }
        state.withLock {
            guard $0.requests[id.kind]?.receivedAt == id.receivedAt else { return }
            $0.requests[id.kind]?.responseAt = Date()
            $0.requests[id.kind]?.status = response.statusCode
            $0.requests[id.kind]?.responseBodyBytes = response.body.count
            $0.requests[id.kind]?.characteristicFailures = failures.isEmpty ? nil : failures
        }
    }

    func sent(_ id: HAPConnectionDiagnostic.RequestID, error: NWError?) {
        state.withLock {
            guard $0.requests[id.kind]?.receivedAt == id.receivedAt else { return }
            if let error { $0.requests[id.kind]?.sendError = .init(error) }
            else { $0.requests[id.kind]?.acceptedBySocketAt = Date() }
        }
    }

    func end(_ reason: HAPConnectionDiagnostic.CloseReason, error: NWError?) {
        state.withLock {
            guard $0.close == nil else { return }
            $0.close = .init(at: Date(), reason: reason, error: error.map(HAPConnectionDiagnostic.NetworkError.init),
                            pendingBytes: $0.pendingBytes)
        }
    }
}

/// Correlates a newly stored controller with its later Verify without putting any controller identity in an export.
final class HAPPairingConnectionIndex: Sendable {
    private struct Entry: Sendable {
        let identifier: String
        let connection: Int
    }
    private let recent = LockedState<[Entry]>(initialState: [])

    func record(_ identifier: String, connection: Int) {
        recent.withLock {
            $0.removeAll { $0.identifier == identifier }
            if $0.count >= 24 { $0.removeFirst() }
            $0.append(.init(identifier: identifier, connection: connection))
        }
    }

    func connection(for identifier: String) -> Int? {
        recent.withLock { $0.last { $0.identifier == identifier }?.connection }
    }
}
#endif
