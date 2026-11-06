import Foundation
import Testing
@testable import TVPrototypeKit

struct SigningTests {
    private let appID = "example.sideload.AccountSuffix"
    private var tunnelID: String { appID + ".RenamedProvider" }
    private func grants(_ id: String, team: String = "TESTTEAM00", groups: [String] = ["group.example.remapped.AccountSuffix"],
                        keychain: [String] = ["PREFIX0000.example.remapped.shared"], ne: Bool = true) -> SignedEntitlements {
        .init(applicationIdentifier: "PREFIX0000." + id, teamIdentifier: team, appGroups: groups,
              keychainGroups: keychain, networkExtensions: ne ? ["packet-tunnel-provider"] : [])
    }

    @Test func renamedIdentitiesIgnoreStaleBuildSettings() throws {
        let identity = try SigningIdentity.resolve(app: grants(appID), tunnel: grants(tunnelID), appID: appID, tunnelID: tunnelID,
            preferredAppGroup: "group.com.ipocket.old", preferredKeychain: "OLDPREFIX0.com.ipocket.old.shared")
        #expect(identity.providerBundleIdentifier == tunnelID)
        #expect(identity.appGroup == "group.example.remapped.AccountSuffix")
        #expect(identity.keychainGroup == "PREFIX0000.example.remapped.shared")
        try identity.requireNetworkExtension()
        // App ID prefixes can differ from the team's identifier; never invent a keychain prefix from the team.
        #expect(!identity.keychainGroup.hasPrefix("TESTTEAM00."))
    }

    @Test func droppedPermissionsAndMixedTeamsFailClearly() throws {
        #expect(throws: SigningIssue.self) {
            try SigningIdentity.resolve(app: grants(appID), tunnel: grants(tunnelID, team: "OTHERTEAM0"), appID: appID, tunnelID: tunnelID)
        }
        #expect(throws: SigningIssue.self) {
            try SigningIdentity.resolve(app: grants(appID), tunnel: grants(tunnelID, groups: []), appID: appID, tunnelID: tunnelID)
        }
        #expect(throws: SigningIssue.self) {
            try SigningIdentity.resolve(app: grants(appID), tunnel: grants(tunnelID, keychain: ["PREFIX0000.*"]), appID: appID, tunnelID: tunnelID)
        }
        let missingNE = try SigningIdentity.resolve(app: grants(appID), tunnel: grants(tunnelID, ne: false), appID: appID, tunnelID: tunnelID)
        #expect(throws: SigningIssue.self) { try missingNE.requireNetworkExtension() }
        #expect(throws: SigningIssue.self) {
            try SigningIdentity.resolve(app: grants(appID, team: "UNSIGNED00"), tunnel: grants(tunnelID, team: "UNSIGNED00"), appID: appID, tunnelID: tunnelID)
        }
    }

    @Test func multipleGroupsNeverSelectAnUnrelatedVault() throws {
        let groups = ["group.example.old", "group.example.other"]
        #expect(throws: SigningIssue.self) {
            try SigningIdentity.resolve(app: grants(appID, groups: groups), tunnel: grants(tunnelID, groups: groups), appID: appID, tunnelID: tunnelID)
        }
        let same = try SigningIdentity.resolve(app: grants(appID, groups: groups), tunnel: grants(tunnelID, groups: groups),
            appID: appID, tunnelID: tunnelID, preferredAppGroup: "group.example.old")
        #expect(same.appGroup == "group.example.old")
    }

    @Test func providerAcceptsOnlyBindingsPresentInItsOwnFinalSignature() throws {
        let signed = grants(tunnelID)
        let identity = try SigningIdentity.resolveProvider(grants: signed, providerID: tunnelID,
            appGroup: signed.appGroups[0], keychainGroup: signed.keychainGroups[0])
        #expect(identity.providerBundleIdentifier == tunnelID)
        #expect(throws: SigningIssue.self) {
            try SigningIdentity.resolveProvider(grants: signed, providerID: tunnelID,
                appGroup: "group.other-team", keychainGroup: signed.keychainGroups[0])
        }
        #expect(throws: SigningIssue.self) {
            try SigningIdentity.resolveProvider(grants: signed, providerID: tunnelID,
                appGroup: signed.appGroups[0], keychainGroup: "UNAUTHORIZED.other.shared")
        }
        #expect(throws: SigningIssue.self) {
            try SigningIdentity.resolveProvider(grants: grants(tunnelID, ne: false), providerID: tunnelID,
                appGroup: signed.appGroups[0], keychainGroup: signed.keychainGroups[0])
        }
    }

    @Test func malformedExecutablesNeverBecomeEmptySuccessfulPermissions() {
        for data in [Data(), Data([0xcf, 0xfa, 0xed, 0xfe]), Data(repeating: 0xff, count: 512)] {
            #expect(throws: (any Error).self) { try SignedEntitlements.decodeExecutable(data) }
        }
    }

    #if os(macOS)
    @Test func realCodeSignaturesAndRenamedEmbeddedProvidersResolveTogether() throws {
        let fixture = try SignedFixture(appID: appID, tunnelID: tunnelID)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let app = try #require(Bundle(url: fixture.app)), provider = try #require(Bundle(url: fixture.provider))
        #expect(try SigningIdentity.providerIdentifier(bundle: app) == tunnelID)
        let main = try SigningIdentity.live(bundle: app)
        let extensionView = try SigningIdentity.live(bundle: provider)
        #expect(main == extensionView)
        #expect(main.appGroup == "group.example.remapped.AccountSuffix")
        #expect(main.keychainGroup == "PREFIX0000.example.remapped.shared")
        try main.requireNetworkExtension()
        // Read the real DER-only code signature too, as used by modern signing implementations.
        let executable = try #require(app.executableURL)
        var binary = try Data(contentsOf: executable)
        try fixture.hideXMLSlot(in: &binary)
        let der = try SignedEntitlements.decodeExecutable(binary)
        let both = try SignedEntitlements.read(executable: executable)
        #expect(der == both)
    }

    @Test func strippedOrDuplicatedPacketTunnelIsRejected() throws {
        let fixture = try SignedFixture(appID: appID, tunnelID: tunnelID)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let app = try #require(Bundle(url: fixture.app))
        let extra = fixture.provider.deletingLastPathComponent().appendingPathComponent("Extra.appex")
        try FileManager.default.copyItem(at: fixture.provider, to: extra)
        #expect(throws: SigningIssue.self) { try SigningIdentity.providerIdentifier(bundle: app) }
        try FileManager.default.removeItem(at: extra)
        try FileManager.default.removeItem(at: fixture.provider)
        #expect(throws: SigningIssue.self) { try SigningIdentity.providerIdentifier(bundle: app) }
    }
    #endif
}

#if os(macOS)
/// Real Apple codesign fixtures, made without a certificate or developer portal changes.
private struct SignedFixture {
    let directory: URL
    let app: URL
    let provider: URL

    init(appID: String, tunnelID: String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MijiaSigning-" + UUID().uuidString)
        app = directory.appendingPathComponent("Renamed.app")
        provider = app.appendingPathComponent("PlugIns/Anything.appex")
        do {
            for (bundle, id, extensionPoint) in [(provider, tunnelID, true), (app, appID, false)] {
                try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
                let executable = bundle.appendingPathComponent("Fixture")
                try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
                var info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleExecutable": "Fixture", "CFBundleName": "Fixture",
                    "CFBundlePackageType": extensionPoint ? "XPC!" : "APPL", "CFBundleSupportedPlatforms": ["AppleTVOS"],
                    "PrototypeAppGroup": "group.stale.value", "PrototypeKeychainGroup": "WRONGTEAM0.stale.value"]
                if extensionPoint { info["NSExtension"] = ["NSExtensionPointIdentifier": "com.apple.networkextension.packet-tunnel"] }
                try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: bundle.appendingPathComponent("Info.plist"))
                let entitlements: [String: Any] = ["application-identifier": "PREFIX0000." + id,
                    "com.apple.developer.team-identifier": "TESTTEAM00",
                    "com.apple.security.application-groups": ["group.example.remapped.AccountSuffix"],
                    "keychain-access-groups": ["PREFIX0000.example.remapped.shared"],
                    "com.apple.developer.networking.networkextension": ["packet-tunnel-provider"]]
                let path = directory.appendingPathComponent(bundle.lastPathComponent + ".entitlements")
                try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0).write(to: path)
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
                process.arguments = ["--force", "--sign", "-", "--generate-entitlement-der", "--entitlements", path.path, bundle.path]
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try process.run(); process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw SigningIssue.invalidSignature }
            }
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }

    func hideXMLSlot(in data: inout Data) throws {
        // Apple /usr/bin/true is universal. Alter only the slot index, leaving the real DER payload intact.
        func u32(_ p: Int, be: Bool = true) -> Int {
            (0..<4).reduce(0) { $0 | Int(data[p + $1]) << ((be ? 3 - $1 : $1) * 8) }
        }
        let base: Int
        if u32(0) == 0xcafebabe {
            let count = u32(4)
            let index = try #require((0..<count).first { u32(8 + $0 * 20) == 0x0100000c })
            base = u32(8 + index * 20 + 8)
        } else { base = 0 }
        var cursor = base + 32
        for _ in 0..<u32(base + 16, be: false) {
            let cmd = u32(cursor, be: false), size = u32(cursor + 4, be: false)
            if cmd == 0x1d {
                let blob = base + u32(cursor + 8, be: false)
                for i in 0..<u32(blob + 8) where u32(blob + 12 + i * 8) == 5 {
                    data[blob + 15 + i * 8] = 99
                }
                return
            }
            cursor += size
        }
        throw SigningIssue.missingSignature
    }
}
#endif
