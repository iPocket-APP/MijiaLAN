#if DEBUG
import Darwin
import dnssd
import Foundation
import Network

/// Opt-in fixture diagnostics. Listener readiness and Bonjour registration are deliberately
/// recorded separately; only an independent LAN client can establish reachability.
@MainActor
public final class NetworkDiagnosticProbe {
    struct Endpoint: Codable {
        var kind: String
        var port: UInt16
        var state: String
        var accepted = 0
        var serviceChanges: [String] = []
    }
    struct Registration: Codable {
        var kind: String
        var result: Int32
    }
    struct Snapshot: Codable {
        var at = Date()
        var processID = ProcessInfo.processInfo.processIdentifier
        var bundle = Bundle.main.bundleIdentifier
        var wifiIPv4: String?
        var endpoints: [Endpoint] = []
        var registrations: [Registration] = []
        var stopped = false
    }
    private let storage: PrototypeStorage
    private var snapshot = Snapshot()
    private var listeners: [NWListener] = []
    private var sources: [DispatchSourceRead] = []
    private var refs: [DNSServiceRef] = []
    private let queue = DispatchQueue(label: "mijialan.ne.network-probe")

    public init(storage: PrototypeStorage) { self.storage = storage }

    public func start() {
        snapshot.wifiIPv4 = Self.wifiIPv4()
        startBSD(kind: "bsdAny", address: "0.0.0.0", port: 61080)
        if let address = snapshot.wifiIPv4 { startBSD(kind: "bsdWiFiAddress", address: address, port: 61081) }
        startNW(kind: "nwAny", port: 61082)
        startNW(kind: "nwWiFi", port: 61083, wifi: true)
        startNW(kind: "nwBonjour", port: 61084, bonjour: true)
        if let address = snapshot.wifiIPv4 { startNW(kind: "nwWiFiAddress", port: 61085, address: address) }
        startNW(kind: "nwLoopback", port: 61086, address: "127.0.0.1")
        register(kind: "hapLocalAny", type: "_hap._tcp", domain: "local.", interface: 0)
        register(kind: "hapDefaultAny", type: "_hap._tcp", domain: nil, interface: 0)
        register(kind: "hapLocalWiFi", type: "_hap._tcp", domain: "local.", interface: if_nametoindex("en0"))
        register(kind: "miioLocalAny", type: "_miio._udp", domain: "local.", interface: 0)
        save()
    }

    public func stop() {
        listeners.forEach { $0.cancel() }; listeners.removeAll()
        sources.forEach { $0.cancel() }; sources.removeAll()
        refs.forEach { DNSServiceRefDeallocate($0) }; refs.removeAll()
        snapshot.stopped = true
        save()
    }

    private func startNW(kind: String, port: UInt16, wifi: Bool = false, address: String? = nil, bonjour: Bool = false) {
        snapshot.endpoints.append(Endpoint(kind: kind, port: port, state: "starting"))
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        if wifi { parameters.requiredInterfaceType = .wifi }
        if let address { parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: NWEndpoint.Port(rawValue: port)!) }
        do {
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
            if bonjour {
                listener.service = NWListener.Service(name: "MijiaLAN Network Probe", type: "_hap._tcp")
                listener.serviceRegistrationUpdateHandler = { @Sendable [weak self] change in
                    let text = String(describing: change)
                    Task { @MainActor in
                        guard let self, let i = self.snapshot.endpoints.firstIndex(where: { $0.kind == kind }) else { return }
                        self.snapshot.endpoints[i].serviceChanges.append(text); self.save()
                    }
                }
            }
            listener.stateUpdateHandler = { @Sendable [weak self] state in
                let text = String(describing: state)
                Task { @MainActor in self?.setState(kind: kind, state: text) }
            }
            listener.newConnectionHandler = { @Sendable [weak self] connection in
                Task { @MainActor in self?.accepted(kind: kind) }
                connection.start(queue: .global())
                connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Length: 8\r\nConnection: close\r\n\r\nNE probe".utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
            listeners.append(listener)
            listener.start(queue: queue)
        } catch { setState(kind: kind, state: "init: \(error)") }
    }

    private func startBSD(kind: String, address: String, port: UInt16) {
        snapshot.endpoints.append(Endpoint(kind: kind, port: port, state: "starting"))
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { setState(kind: kind, state: "socket errno=\(errno)"); return }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, address, &addr.sin_addr)
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { let code = errno; Darwin.close(fd); setState(kind: kind, state: "bind errno=\(code)"); return }
        guard Darwin.listen(fd, 8) == 0 else { let code = errno; Darwin.close(fd); setState(kind: kind, state: "listen errno=\(code)"); return }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { @Sendable [weak self] in
            while true {
                let peer = Darwin.accept(fd, nil, nil)
                guard peer >= 0 else { break }
                Darwin.close(peer)
                Task { @MainActor in self?.accepted(kind: kind) }
            }
        }
        source.setCancelHandler { @Sendable in Darwin.close(fd) }
        sources.append(source); source.resume()
        setState(kind: kind, state: "listening")
    }

    private func register(kind: String, type: String, domain: String?, interface: UInt32) {
        var ref: DNSServiceRef?
        // This probe measures the synchronous policy result, as the production advertiser
        // does. No C callback inherits the caller's MainActor isolation.
        let result = DNSServiceRegister(&ref, 0, interface, "MijiaLAN Network Probe", type, domain, nil,
            UInt16(61082).bigEndian, 0, nil, nil, nil)
        snapshot.registrations.append(Registration(kind: kind, result: result))
        if result == 0, let ref {
            refs.append(ref)
            let scheduled = DNSServiceSetDispatchQueue(ref, queue)
            if scheduled != 0 {
                snapshot.registrations.append(Registration(kind: kind + ".schedule", result: scheduled))
            }
        } else if let ref { DNSServiceRefDeallocate(ref) }
    }

    private func setState(kind: String, state: String) {
        guard let i = snapshot.endpoints.firstIndex(where: { $0.kind == kind }) else { return }
        snapshot.endpoints[i].state = state; save()
    }
    private func accepted(kind: String) {
        guard let i = snapshot.endpoints.firstIndex(where: { $0.kind == kind }) else { return }
        snapshot.endpoints[i].accepted += 1; save()
    }
    private func save() {
        snapshot.at = Date()
        try? JSONEncoder().encode(snapshot).write(to: storage.directory.appendingPathComponent("network-diagnostics.json"), options: .atomic)
    }
    private static func wifiIPv4() -> String? {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return nil }
        defer { freeifaddrs(first) }
        var cursor = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard String(cString: entry.pointee.ifa_name) == "en0", let addr = entry.pointee.ifa_addr,
                  addr.pointee.sa_family == AF_INET else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
        return nil
    }
}

#endif
