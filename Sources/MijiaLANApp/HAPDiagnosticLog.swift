import Foundation
import MijiaSupport

/// Opt-in local capture for intermittent HomeKit failures. Both queued memory and disk use are bounded.
/// The mutex owns the queue; a single serial worker owns file operations, outside the main/cooperative executors.
final class HAPDiagnosticLog: Sendable {
    private struct State {
        var pending: [Data] = []
        var bytes = 0
        var dropped = 0
        var running = false
    }
    private let state = LockedState(initialState: State())
    private let queue = DispatchQueue(label: "MijiaLAN.hap-diagnostic-file", qos: .utility)
    private let url: URL
    private let byteLimit: Int
    private let pendingLimit = 128 * 1024

    init(url: URL, byteLimit: Int = 4 * 1024 * 1024) {
        precondition(byteLimit >= 128)
        self.url = url
        self.byteLimit = byteLimit
    }

    func append(_ line: String) {
        let terminated = line.hasSuffix("\n") ? line : line + "\n"
        let data = terminated.utf8.count <= min(byteLimit, 16 * 1024)
            ? Data(terminated.utf8) : Data("[oversized diagnostic entry omitted]\n".utf8)
        state.withLock { state in
            while state.bytes + data.count > pendingLimit, !state.pending.isEmpty {
                state.bytes -= state.pending.removeFirst().count
                state.dropped += 1
            }
            state.pending.append(data)
            state.bytes += data.count
            guard !state.running else { return }
            state.running = true
            queue.async { self.drain() }
        }
    }

    /// Wait for submitted records; callers stop submitting before using this to inspect a complete capture.
    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    private func drain() {
        while let records = state.withLock({ state -> [Data]? in
            guard !state.pending.isEmpty else { state.running = false; return nil }
            let notice = state.dropped > 0 ? [Data("[\(state.dropped) diagnostic entries dropped while writer was busy]\n".utf8)] : []
            let records = notice + state.pending
            state.pending.removeAll(keepingCapacity: true)
            state.bytes = 0
            state.dropped = 0
            return records
        }) {
            // A logging failure must not block HomeKit traffic or recursively generate more diagnostics.
            try? write(records)
        }
    }

    private func write(_ records: [Data]) throws {
        let files = FileManager.default
        let previous = url.appendingPathExtension("previous")
        try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        if files.fileExists(atPath: previous.path) {
            let previousSize = (try files.attributesOfItem(atPath: previous.path)[.size] as? NSNumber)?.intValue ?? 0
            if previousSize > byteLimit { try files.removeItem(at: previous) }
            else { try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: previous.path) }
        }
        var handle: FileHandle?
        defer { try? handle?.close() }
        var size = (try? files.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        for data in records {
            if size + data.count > byteLimit {
                try handle?.close()
                handle = nil
                if files.fileExists(atPath: previous.path) { try files.removeItem(at: previous) }
                // An oversized file from an earlier launch is discarded instead of exceeding the disk bound.
                if files.fileExists(atPath: url.path) {
                    if size <= byteLimit { try files.moveItem(at: url, to: previous) }
                    else { try files.removeItem(at: url) }
                }
                size = 0
            }
            if handle == nil {
                if !files.fileExists(atPath: url.path) {
                    guard files.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                }
                try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                handle = try FileHandle(forWritingTo: url)
                try handle?.seekToEnd()
            }
            try handle?.write(contentsOf: data)
            size += data.count
        }
    }
}
