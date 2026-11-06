import NetworkExtension

/// A private service-host experiment. No destination traffic is routed into packetFlow.
/// This does not turn the use case into a supported VPN or guarantee background execution.
public enum ExperimentalTunnelNetwork {
    public static func makeSettings() -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        // A host-only address avoids introducing a connected subnet for other destinations.
        let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.255.255"])
        ipv4.includedRoutes = []
        ipv4.excludedRoutes = []
        settings.ipv4Settings = ipv4
        settings.mtu = 1280
        return settings
    }

    public static func summary(of settings: NEPacketTunnelNetworkSettings) -> TunnelNetworkSummary {
        TunnelNetworkSummary(
            includedIPv4RouteCount: settings.ipv4Settings?.includedRoutes?.count ?? 0,
            includedIPv6RouteCount: settings.ipv6Settings?.includedRoutes?.count ?? 0,
            overridesDNS: settings.dnsSettings != nil,
            overridesProxy: settings.proxySettings != nil
        )
    }
}

public struct TunnelNetworkSummary: Codable, Sendable {
    public var includedIPv4RouteCount: Int
    public var includedIPv6RouteCount: Int
    public var overridesDNS: Bool
    public var overridesProxy: Bool
}
