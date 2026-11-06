import Foundation
import TVPrototypeKit
#if os(macOS)
import Darwin

/// LAN-only simulated purifier. Uses the same public fixture token and real UDP.
@main struct UDPFixtureHost {
    static func main() async throws {
        guard CommandLine.arguments.count >= 3 else {
            print("Usage: UDPFixtureHost MAC_LAN_IPV4 STATS_JSON [SECONDS]")
            return
        }
        let host = CommandLine.arguments[1]
        let statsURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let seconds = CommandLine.arguments.dropFirst(3).first.flatMap(Double.init) ?? 900
        guard (1...1800).contains(seconds) else { throw FixtureError.invalidDuration }
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw POSIXError(.ENOBUFS) }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(54321).bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { throw FixtureError.invalidAddress }
        let result = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) { setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size)) }
        let fixture = FixtureTransport()
        let deadline = Date().addingTimeInterval(seconds)
        var packets = 0
        FileHandle.standardOutput.write(Data("UDP simulated purifier listening on \(host):54321\n".utf8))
        while Date() < deadline {
            var bytes = [UInt8](repeating: 0, count: 65535)
            var peer = sockaddr_in()
            var peerSize = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = bytes.withUnsafeMutableBytes { buffer in
                withUnsafeMutablePointer(to: &peer) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.recvfrom(fd, buffer.baseAddress, buffer.count, 0, $0, &peerSize)
                    }
                }
            }
            guard count > 0 else { continue }
            guard let reply = try? await fixture.exchange(Data(bytes.prefix(count)), host: "127.0.0.1", port: 54321, timeout: .seconds(2)) else { continue }
            let sent = reply.withUnsafeBytes { buffer in
                withUnsafePointer(to: &peer) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.sendto(fd, buffer.baseAddress, buffer.count, 0, $0, peerSize)
                    }
                }
            }
            if sent == reply.count { packets += 1 }
            let stats: [String: Any] = ["fixture": true, "packetsReplied": packets,
                "updatedAtUnix": Date().timeIntervalSince1970, "processID": ProcessInfo.processInfo.processIdentifier]
            try JSONSerialization.data(withJSONObject: stats, options: [.sortedKeys]).write(to: statsURL, options: .atomic)
        }
    }
    enum FixtureError: Error { case invalidAddress, invalidDuration }
}
#else
@main struct UDPFixtureHost { static func main() { print("UDPFixtureHost runs on macOS only.") } }
#endif
