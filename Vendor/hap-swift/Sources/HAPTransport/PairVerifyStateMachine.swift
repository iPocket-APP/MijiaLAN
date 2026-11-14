// PairVerifyStateMachine.swift
// Modified for MijiaLAN; see Vendor/hap-swift/README.md for the changes.
// Copyright 2026 Monagle Pty Ltd

import Foundation
import Crypto
import HAPCore
import HAPCrypto

// MARK: - PairVerifyStateMachine

public actor PairVerifyStateMachine {
    public private(set) var verifiedControllerIdentifier: String?
    private let identity: HAPIdentity
    private let pairingStore: any PairingStore
    private let deviceID: String
    private let onHandshake: (@Sendable (HAPHandshakeEvent) -> Void)?
    private var state: State = .idle

    private enum State {
        case idle
        case awaitingM3(sharedSecret: Data, accessoryEphemeralPublicKey: Data, controllerEphemeralPublicKey: Data)
        case verified(readKey: SymmetricKey, writeKey: SymmetricKey)
    }

    public init(identity: HAPIdentity, pairingStore: any PairingStore, deviceID: String,
                onHandshake: (@Sendable (HAPHandshakeEvent) -> Void)? = nil) {
        self.identity = identity
        self.pairingStore = pairingStore
        self.deviceID = deviceID
        self.onHandshake = onHandshake
    }

    public func handleRequest(_ data: Data) async throws -> Data {
        let items: [TLV8.Item]
        do {
            items = try TLV8.decode(data)
        } catch {
            onHandshake?(.init(.verify, message: nil, outcome: .rejected, reason: .malformedTLV))
            throw error
        }

        guard let stateItem = items.first(where: { $0.type == TLV8Type.state.rawValue }),
              let stateValue = stateItem.value.first else {
            onHandshake?(.init(.verify, message: nil, outcome: .rejected, reason: .missingFields))
            throw HAPPairingError.invalidState
        }

        switch stateValue {
        case 1:
            do {
                let response = try handleVerifyM1(items)
                onHandshake?(.init(.verify, message: 1, outcome: .advanced))
                return response
            } catch {
                onHandshake?(.init(.verify, message: 1, outcome: .rejected,
                                  reason: error is HAPPairingError ? .missingFields : .internalError))
                throw error
            }
        case 3: return try await handleVerifyM3(items)
        default:
            onHandshake?(.init(.verify, message: stateValue, outcome: .rejected, reason: .invalidSequence))
            throw HAPPairingError.invalidState
        }
    }

    public func sessionKeys() -> (readKey: SymmetricKey, writeKey: SymmetricKey)? {
        if case .verified(let readKey, let writeKey) = state {
            return (readKey: readKey, writeKey: writeKey)
        }
        return nil
    }

    // MARK: - Verify M1 → M2

    private func handleVerifyM1(_ items: [TLV8.Item]) throws -> Data {
        guard let controllerEphemeralPublicKey = items.first(where: { $0.type == TLV8Type.publicKey.rawValue })?.value else {
            throw HAPPairingError.invalidState
        }

        // Generate accessory ephemeral key pair
        let accessoryEphemeralPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let accessoryEphemeralPublicKey = Data(accessoryEphemeralPrivateKey.publicKey.rawRepresentation)

        // Perform ECDH
        let controllerKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: controllerEphemeralPublicKey)
        let sharedSecret = try accessoryEphemeralPrivateKey.sharedSecretFromKeyAgreement(with: controllerKey)
        let sharedSecretData = sharedSecret.withUnsafeBytes { Data($0) }

        // Derive encryption key
        let encKey = HAPKeyDerivation.derivePairVerifyEncryptionKey(from: sharedSecretData)

        // Build accessory info for signing
        var accessoryInfo = Data()
        accessoryInfo.append(accessoryEphemeralPublicKey)
        accessoryInfo.append(Data(deviceID.utf8))
        accessoryInfo.append(controllerEphemeralPublicKey)

        // Sign
        let signature = try identity.sign(accessoryInfo)

        // Build sub-TLV
        let subTLV = TLV8.encode([
            (type: TLV8Type.identifier.rawValue, value: Data(deviceID.utf8)),
            (type: TLV8Type.signature.rawValue, value: signature),
        ])

        // Encrypt sub-TLV
        let nonce = HAPEncryption.buildNonce(from: "PV-Msg02")
        let encrypted = try HAPEncryption.encrypt(plaintext: subTLV, key: encKey, nonce: nonce)

        self.state = .awaitingM3(
            sharedSecret: sharedSecretData,
            accessoryEphemeralPublicKey: accessoryEphemeralPublicKey,
            controllerEphemeralPublicKey: controllerEphemeralPublicKey
        )

        return TLV8.encode([
            (type: TLV8Type.state.rawValue, value: Data([0x02])),
            (type: TLV8Type.publicKey.rawValue, value: accessoryEphemeralPublicKey),
            (type: TLV8Type.encryptedData.rawValue, value: encrypted),
        ])
    }

    // MARK: - Verify M3 → M4

    private func handleVerifyM3(_ items: [TLV8.Item]) async throws -> Data {
        guard case .awaitingM3(let sharedSecret, let accessoryEphemeralPublicKey, let controllerEphemeralPublicKey) = state else {
            return authenticationError(.invalidSequence)
        }

        guard let encryptedData = items.first(where: { $0.type == TLV8Type.encryptedData.rawValue })?.value else {
            self.state = .idle
            return authenticationError(.missingFields)
        }

        // Decrypt
        let encKey = HAPKeyDerivation.derivePairVerifyEncryptionKey(from: sharedSecret)
        let nonce = HAPEncryption.buildNonce(from: "PV-Msg03")

        let decrypted: Data
        do {
            decrypted = try HAPEncryption.decrypt(ciphertext: encryptedData, key: encKey, nonce: nonce)
        } catch {
            self.state = .idle
            return authenticationError(.decryptionFailed)
        }

        // Parse sub-TLV
        guard let subItems = try? TLV8.decode(decrypted) else {
            self.state = .idle
            return authenticationError(.malformedTLV)
        }

        guard let controllerIdentifier = subItems.first(where: { $0.type == TLV8Type.identifier.rawValue })?.value,
              let controllerSignature = subItems.first(where: { $0.type == TLV8Type.signature.rawValue })?.value else {
            self.state = .idle
            return authenticationError(.missingFields)
        }

        // Look up controller public key
        let identifierString = String(data: controllerIdentifier, encoding: .utf8) ?? ""
        let knownKey: Data?
        do {
            knownKey = try await pairingStore.publicKey(for: identifierString)
        } catch {
            self.state = .idle
            onHandshake?(.init(.verify, message: 3, outcome: .rejected, reason: .pairingStoreFailed))
            throw error
        }
        guard let controllerPublicKey = knownKey else {
            self.state = .idle
            return authenticationError(.controllerUnknown)
        }

        // Build controller info for verification.
        // HAP spec: iOSDeviceInfo = iOSDeviceEphemeralPublicKey || iOSDevicePairingID || AccessoryEphemeralPublicKey
        var controllerInfo = Data()
        controllerInfo.append(controllerEphemeralPublicKey)
        controllerInfo.append(controllerIdentifier)
        controllerInfo.append(accessoryEphemeralPublicKey)

        // Verify signature
        let valid = (try? HAPIdentity.verify(
            signature: controllerSignature,
            data: controllerInfo,
            publicKey: controllerPublicKey
        )) == true

        guard valid else {
            self.state = .idle
            return authenticationError(.signatureRejected)
        }

        // Derive session keys.
        // deriveSessionKeys returns keys named from the CONTROLLER's perspective:
        //   .writeKey = "Control-Write-Encryption-Key" — controller encrypts, accessory decrypts
        //   .readKey  = "Control-Read-Encryption-Key"  — accessory encrypts, controller decrypts
        // For the ACCESSORY's HAPSession we therefore swap them:
        //   session.readKey  (incoming data to decrypt) = Control-Write = derived.writeKey
        //   session.writeKey (outgoing data to encrypt) = Control-Read  = derived.readKey
        let derived = HAPKeyDerivation.deriveSessionKeys(from: sharedSecret)

        self.state = .verified(readKey: derived.writeKey, writeKey: derived.readKey)
        self.verifiedControllerIdentifier = identifierString
        onHandshake?(.init(.verify, message: 3, outcome: .completed))

        return TLV8.encode([
            (type: TLV8Type.state.rawValue, value: Data([0x04])),
        ])
    }

    // MARK: - Helpers

    private func authenticationError(_ reason: HAPHandshakeEvent.Reason) -> Data {
        let code = TLV8ErrorCode.authentication.rawValue
        onHandshake?(.init(.verify, message: 3, outcome: .rejected, reason: reason, tlvErrorCode: code))
        return TLV8.encode([
            (type: TLV8Type.state.rawValue, value: Data([4])),
            (type: TLV8Type.error.rawValue, value: Data([code])),
        ])
    }
}
