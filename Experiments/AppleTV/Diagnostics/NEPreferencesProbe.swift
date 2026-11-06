import Foundation
import NetworkExtension
import SwiftUI

/// Independent, read-only repro: no Mijia libraries, provider, App Group, Keychain or VPN configuration.
@main
struct NEPreferencesProbe: App {
    @State private var summary = "Reading VPN preferences…"
    var body: some Scene {
        WindowGroup {
            Text(summary).padding(60)
                .task {
                    var results: [ProbeResult] = []
                    do {
                        let configurations = try await NETunnelProviderManager.loadAllFromPreferences()
                        results.append(ProbeResult(api: "NETunnelProviderManager.loadAllFromPreferences", count: configurations.count))
                    } catch {
                        results.append(ProbeResult(api: "NETunnelProviderManager.loadAllFromPreferences", error: error as NSError))
                    }
                    do {
                        try await NEVPNManager.shared().loadFromPreferences()
                        results.append(ProbeResult(api: "NEVPNManager.loadFromPreferences", count: nil))
                    } catch {
                        results.append(ProbeResult(api: "NEVPNManager.loadFromPreferences", error: error as NSError))
                    }
                    do {
                        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        try JSONEncoder().encode(results).write(to: directory.appendingPathComponent("ne-probe.json"), options: .atomic)
                        summary = results.map { "\($0.api): \($0.errorDomain ?? "success") / \($0.errorCode ?? 0)" }.joined(separator: "\n")
                    } catch { summary = "Could not write probe result: \(error.localizedDescription)" }
                }
        }
    }
}

private struct ProbeResult: Encodable {
    var api: String
    var count: Int?
    var errorDomain: String?
    var errorCode: Int?
    var message: String?
    init(api: String, count: Int?) { self.api = api; self.count = count }
    init(api: String, error: NSError) {
        self.api = api; errorDomain = error.domain; errorCode = error.code; message = error.localizedDescription
    }
}
