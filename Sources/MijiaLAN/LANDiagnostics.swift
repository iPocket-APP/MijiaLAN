import Foundation

public struct LANFailureEvidence: Equatable, Encodable, Sendable {
    public enum Kind: String, Encodable, Sendable {
        case timeout, hostUnreachable, unexpectedDevice, helloWithoutEncryptedReply, checksumMismatch
        case invalidToken, malformedPacket, badResponse, socket, unsupportedLegacyOperation, propertyReadBackoff, deviceError, other
    }
    public let kind: Kind
    public let deviceCode: Int?

    init(_ error: any Error) {
        let miio = error as? MiioError
        deviceCode = switch miio {
        case .deviceError(let code, _): code
        case .propertyReadBackoff: MiioClient.userAckTimeoutCode
        default: nil
        }
        kind = switch miio {
        case .timeout: .timeout
        case .hostUnreachable: .hostUnreachable
        case .unexpectedDevice: .unexpectedDevice
        case .propertyReadBackoff: .propertyReadBackoff
        case .noEncryptedReply: .helloWithoutEncryptedReply
        case .checksumMismatch: .checksumMismatch
        case .invalidToken: .invalidToken
        case .malformedPacket: .malformedPacket
        case .badResponse: .badResponse
        case .socket: .socket
        case .unsupportedByLegacyDevice: .unsupportedLegacyOperation
        case .deviceError: .deviceError
        case nil: .other
        }
    }
}

public struct LANProbeEvidence: Equatable, Encodable, Sendable {
    public let at: Date
    public let trigger: String
    public let failure: LANFailureEvidence?
}

public struct LANPropertyReadFallback: Equatable, Encodable, Sendable {
    public let at: Date
    public let requested: Int
    public let rejectedBatchSize: Int
    public internal(set) var singleAttempts = 0
    public internal(set) var singleReplies = 0
    public internal(set) var singleAckTimeouts = 0
    public internal(set) var availableProperties = 0
    public internal(set) var stoppedEarly = false
    public internal(set) var lastSingleFailure: LANFailureEvidence?
}

public struct LANClientEvidence: Equatable, Encodable, Sendable {
    public let lastHelloAt: Date?
    public let lastAuthenticatedReplyAt: Date?
    public let batchLimit: Int
    public let suppressedProperties: Int
    public let backoffSeconds: Int
    public let lastFallback: LANPropertyReadFallback?
}
