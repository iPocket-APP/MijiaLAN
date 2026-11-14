import Foundation

/// Allow-listed pairing evidence. This contains no TLV payloads, peer addresses, or controller identifiers.
public struct HAPHandshakeEvent: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case setup, verify }
    public enum Outcome: String, Codable, Sendable { case advanced, completed, rejected }
    public enum Reason: String, Codable, Sendable {
        case alreadyPaired, malformedTLV, invalidSequence, unsupportedMethod, missingFields
        case proofRejected, decryptionFailed, controllerUnknown, signatureRejected, pairingStoreFailed, internalError
    }

    public let at: Date
    public let phase: Phase
    public let message: UInt8?
    public let outcome: Outcome
    public let reason: Reason?
    public let tlvErrorCode: UInt8?

    public init(_ phase: Phase, message: UInt8?, outcome: Outcome, reason: Reason? = nil, tlvErrorCode: UInt8? = nil) {
        self.at = Date()
        self.phase = phase
        self.message = message
        self.outcome = outcome
        self.reason = reason
        self.tlvErrorCode = tlvErrorCode
    }
}
