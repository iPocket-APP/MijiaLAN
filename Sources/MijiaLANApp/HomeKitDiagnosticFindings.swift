import Foundation
import MijiaHomeKitBridge

extension DiagnosticReport {
    static func homeKitFindings(_ pairing: HomeKitBridgeController.PairingDiagnostics, paired: Bool) -> [[String: Any]] {
        var findings = bonjourFindings(pairing, expectedSF: (pairing.pairedControllerCount.map { $0 > 0 } ?? paired) ? 0 : 1)
        if let failure = pairing.startupFailure {
            findings.append(["kind": "homeKitBridgeStartFailed", "reason": failure.rawValue])
        }
        if pairing.resetFailed { findings.append(["kind": "homeKitResetFailed"]) }
        if let reset = pairing.lastReset {
            findings.append(["kind": "homeKitResetOutcome", "outcome": reset.outcome.rawValue, "newIdentitySaved": reset.newBridgeID != nil])
        }
        if pairing.listenerChangedDuringBrowse { findings.append(["kind": "homeKitListenerChangedDuringBonjourBrowse"]) }

        let attempt = pairing.setupAttempt
        let since = attempt?.startedAt ?? pairing.sessionStartedAt
        let connections = pairing.recentConnections.filter { item in
            item.deviceID == pairing.deviceID || (attempt != nil && item.listener >= (attempt?.listenerAtStart ?? 0))
        }
        for item in connections {
            let connection = item.transport
            let label: [String: Any] = ["listener": item.listener, "connection": connection.connection]
            for event in [connection.pairSetup, connection.pairVerify].compactMap({ $0 }) where event.at >= since {
                var finding = label
                finding["phase"] = event.phase.rawValue
                finding["message"] = event.message
                finding["tlvErrorCode"] = event.tlvErrorCode
                if event.outcome == .rejected {
                    finding["kind"] = "homeKitHandshakeRejected"
                    finding["reason"] = event.reason?.rawValue
                    findings.append(finding)
                } else if event.outcome == .advanced, let close = connection.close {
                    finding["kind"] = "homeKitHandshakeInterrupted"
                    finding["closeReason"] = close.reason.rawValue
                    findings.append(finding)
                }
            }
            if let close = connection.close, close.at >= since,
               [.invalidFrame, .requestTooLarge, .invalidRequest, .responseEncryptionFailed].contains(close.reason) {
                findings.append(label.merging(["kind": "homeKitTransportStopped", "reason": close.reason.rawValue]) { $1 })
            }
            if let close = connection.close, close.at >= since, close.pendingBytes > 0,
               close.reason == .peerClosed || close.reason == .networkError {
                findings.append(label.merging(["kind": "homeKitTransportEndedWithPartialRequest",
                                               "reason": close.reason.rawValue, "pendingBytes": close.pendingBytes]) { $1 })
            }
            for (kind, request) in connection.requests.sorted(by: { $0.key < $1.key }) where request.receivedAt >= since {
                let failed = request.sendError != nil || (request.status ?? 0) >= 400
                    || (connection.close != nil && request.acceptedBySocketAt == nil)
                    || (kind == "accessoryDatabase" && request.responseBodyBytes == 0)
                if failed || request.characteristicFailures != nil {
                    var failure = label
                    failure["kind"] = "homeKitResponseFailed"
                    failure["request"] = kind
                    failure["httpStatus"] = request.status
                    failure["socketError"] = request.sendError?.code
                    failure["characteristicFailures"] = request.characteristicFailures
                    failure["closeReason"] = connection.close?.reason.rawValue
                    findings.append(failure)
                }
            }
        }

        guard let attempt else { return findings }
        let matching = connections.filter { $0.deviceID == pairing.deviceID && $0.listener >= (attempt.listenerAtStart ?? 0) }
        let relevant = matching.map(\.transport)
        let setups = relevant.compactMap(\.pairSetup).filter { $0.at >= since }
        let setupReceived = !setups.isEmpty || relevant.contains { ($0.requests["pairSetup"]?.receivedAt ?? .distantPast) >= since }
        let completed = matching.filter { ($0.transport.completedPairSetup?.at ?? .distantPast) >= since }
        let setupCompleted = completed.max {
            ($0.transport.completedPairSetup?.at ?? .distantPast) < ($1.transport.completedPairSetup?.at ?? .distantPast)
        }
        let verified = matching.filter { item in
            guard (item.transport.encryptedAt ?? .distantPast) >= since else { return false }
            guard let setupCompleted else { return true }
            return item.listener == setupCompleted.listener
                && item.transport.verifiesPairSetupOnConnection == setupCompleted.transport.connection
        }.map(\.transport)
        let listRequests = verified.compactMap { $0.requests["accessoryDatabase"] }.filter { $0.receivedAt >= since }
        let listSent = listRequests.contains { $0.status == 200 && ($0.responseBodyBytes ?? 0) > 0 && $0.acceptedBySocketAt != nil }
        let tcpSeen = relevant.filter { $0.acceptedAt >= since }.count
        let stage: String
        if attempt.bridgeID != pairing.deviceID || attempt.listenerAtStart != pairing.listenerAtExport {
            stage = "bridgeChangedDuringAttempt"
        } else if !setupReceived {
            let verifySeen = relevant.contains { ($0.pairVerify?.at ?? .distantPast) >= since }
            if verifySeen {
                stage = verified.isEmpty ? "pairVerifyObservedWithoutPairSetup" : "verifiedWithoutNewPairSetup"
            } else {
                stage = tcpSeen == 0 ? "noSetupOrNewTCPObserved" : "tcpObservedWithoutPairSetup"
            }
        } else if setupCompleted == nil {
            stage = "pairSetupDidNotComplete"
        } else if verified.isEmpty {
            stage = "setupCompletedWithoutVerifiedSession"
        } else if listRequests.isEmpty {
            stage = "verifiedWithoutAccessoryDatabaseRequest"
        } else {
            stage = listSent ? "accessoryDatabaseSubmittedToSocket" : "accessoryDatabaseNotSubmitted"
        }
        var result: [String: Any] = ["kind": "homeKitPairingAttempt", "stage": stage,
                                     "newTCPConnectionsSeen": tcpSeen, "pairedAtStart": attempt.pairedAtStart,
                                     "setupCodeAvailable": attempt.setupCodeAvailable]
        result["homeResult"] = attempt.homeResult?.rawValue
        findings.append(result)
        return findings
    }

    private static func bonjourFindings(_ pairing: HomeKitBridgeController.PairingDiagnostics, expectedSF: Int) -> [[String: Any]] {
        var findings: [[String: Any]] = []
        if let accepted = pairing.bonjour?.lastAccepted, (accepted.sf & 1) != expectedSF {
            findings.append(["kind": "bonjourPublishedPairingFlagMismatch", "expectedSF": expectedSF, "publishedSF": accepted.sf])
        }
        if let observed = pairing.localBonjourObservation {
            if observed.browserState != "ready" {
                var finding: [String: Any] = ["kind": "bonjourBrowseUnavailable", "browserState": observed.browserState]
                finding["dnsError"] = observed.dnsError
                finding["posixError"] = observed.posixError
                findings.append(finding)
            } else if observed.matchingInstances == 0 {
                findings.append(["kind": "bridgeNotFoundInLocalBonjour"])
            }
            if observed.previousBridgeVisible == true { findings.append(["kind": "previousBridgeStillInLocalBonjour"]) }
            if observed.matchingInstances > 1 || observed.otherMijiaLANInstances > 0 {
                findings.append(["kind": "multipleBonjourBridgeInstances", "matching": observed.matchingInstances,
                                 "other": observed.otherMijiaLANInstances])
            }
            let flags = Set(observed.records.compactMap(\.sf))
            if observed.records.contains(where: { $0.sf == nil }) {
                findings.append(["kind": "bonjourPairingFlagMissing"])
            }
            if flags.contains(where: { $0 < 0 || $0 > 255 || ($0 & 1) != expectedSF }) {
                findings.append(["kind": "bonjourPairingFlagMismatch", "expectedSF": expectedSF, "observedSF": flags.sorted()])
            }
            if observed.records.contains(where: { $0.setupHashMatches == nil }) {
                findings.append(["kind": "bonjourSetupHashMissing"])
            }
            if observed.records.contains(where: { $0.setupHashMatches == false }) || observed.otherInstancesMatchingSetupHash > 0 {
                findings.append(["kind": "bonjourSetupHashConflict", "otherMatchingInstances": observed.otherInstancesMatchingSetupHash])
            }
            let ports = Set(observed.records.compactMap(\.resolvedPort))
            if observed.records.contains(where: { $0.resolvedPort == nil }) {
                findings.append(["kind": "bonjourServicePortNotResolved"])
            }
            if ports.contains(where: { $0 != observed.listenerPort }) {
                findings.append(["kind": "bonjourServicePortMismatch", "listenerPort": observed.listenerPort, "observedPorts": ports.sorted()])
            }
        }
        if let bonjour = pairing.bonjour, let failure = bonjour.lastFailure {
            findings.append(["kind": "bonjourPublicationFailed", "operation": failure.operation.rawValue,
                             "newerPublicationAccepted": (bonjour.lastAccepted?.at ?? .distantPast) >= failure.at])
        }
        return findings
    }
}
