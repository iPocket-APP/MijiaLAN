// HAPAdvertiser.swift
// Copyright 2026 Monagle Pty Ltd

import Foundation
import HAPCore
import HAPCrypto
import MDNSCore

// MARK: - ServiceType Extension

extension ServiceType {
    public static let hapAccessory = ServiceType("_hap._tcp")
}

// MARK: - HAPAdvertiser

public struct HAPAdvertiser: Sendable {
    private let discovery: any ServiceDiscovery
    private let deviceID: String

    public init(discovery: any ServiceDiscovery, deviceID: String) {
        self.discovery = discovery
        self.deviceID = deviceID
    }

    public func advertise(
        name: String,
        port: UInt16,
        category: HAPCategory,
        setupID: String = "ACMN",
        configNumber: Int = 1,
        stateNumber: Int = 1,
        isPaired: Bool = false
    ) async throws {
        let record = ServiceRecord(
            name: name,
            serviceType: .hapAccessory,
            host: "",
            port: port,
            txtRecords: txtRecords(name: name, category: category, setupID: setupID, configNumber: configNumber,
                                   stateNumber: stateNumber, isPaired: isPaired),
            advertiseOnAllInterfaces: true
        )
        try await discovery.advertise(service: record)
    }

    /// Publishes a new `s#` by replacing the TXT record of the running advertisement. Withdrawing and re-registering
    /// the service, as a `c#` change does, would make controllers see the bridge leave the network.
    public func updateStateNumber(
        name: String,
        port: UInt16,
        category: HAPCategory,
        setupID: String = "ACMN",
        configNumber: Int,
        stateNumber: Int,
        isPaired: Bool
    ) async throws {
        let txt = txtRecords(name: name, category: category, setupID: setupID, configNumber: configNumber,
                             stateNumber: stateNumber, isPaired: isPaired)
        if await discovery.updateTXT(name: name, serviceType: .hapAccessory, txtRecords: txt) { return }
        try await advertise(name: name, port: port, category: category, setupID: setupID, configNumber: configNumber,
                            stateNumber: stateNumber, isPaired: isPaired)
    }

    public func txtRecords(name: String, category: HAPCategory, setupID: String, configNumber: Int,
                           stateNumber: Int, isPaired: Bool) -> [String: String] {
        [
            "c#": String(configNumber),
            "ff": "0",
            "id": deviceID,
            "md": name,
            "pv": "1.1",
            "s#": String(stateNumber),
            "sf": isPaired ? "0" : "1",
            "ci": String(category.rawValue),
            "sh": HAPKeyDerivation.setupHash(setupID: setupID, deviceID: deviceID),
        ]
    }

    public func stopAdvertising() async {
        await discovery.stopAdvertising()
    }
}
