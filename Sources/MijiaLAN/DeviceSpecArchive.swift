import Foundation
import MijiaCore
import os

/// The raw MIoT definitions used by installed devices must survive eviction of the download cache.
public struct DeviceSpecArchive: Sendable {
    public let directory: URL
    public let cacheDirectory: URL

    public init(directory: URL, cacheDirectory: URL) {
        self.directory = directory
        self.cacheDirectory = cacheDirectory
    }

    public static let standard = DeviceSpecArchive(
        directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MijiaLAN/specs", isDirectory: true),
        cacheDirectory: LocalHomeProvider.specCacheDirectory
    )

    public struct Request: Hashable, Sendable {
        public let model: String
        public let type: String?

        public init(_ device: LocalDevice) {
            model = device.model
            type = device.specType.flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    /// On an older installation the first device load promotes its cached definition.
    func schema(for type: String) -> DeviceSchema? { load(type, preserve: true) }

    private func load(_ type: String, preserve: Bool) -> DeviceSchema? {
        guard let name = MiotSpecStore.instanceFileName(for: type) else { return nil }
        let archived = directory.appendingPathComponent(name)
        let cached = cacheDirectory.appendingPathComponent("instances").appendingPathComponent(name)
        for file in [archived, cached] {
            guard let data = try? Data(contentsOf: file), let schema = decode(data, for: type) else { continue }
            if preserve && file == cached { _ = save(data, to: archived) }
            return schema
        }
        return nil
    }

    private func decode(_ data: Data, for type: String) -> DeviceSchema? {
        guard let schema = try? JSONDecoder().decode(DeviceSchema.self, from: data), schema.type == type else { return nil }
        return schema
    }

    private func save(_ data: Data, to file: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            return true
        } catch {
            Logger(subsystem: "com.mijialan.MijiaLAN", category: "Specs").error("Could not archive device specification: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func restore(_ type: String, using source: MiotSpecStore) async -> Bool {
        if load(type, preserve: true) != nil { return true }
        guard let name = MiotSpecStore.instanceFileName(for: type),
              let data = try? await source.downloadInstance(for: type), decode(data, for: type) != nil else { return false }
        return save(data, to: directory.appendingPathComponent(name)) || load(type, preserve: false) != nil
    }

    /// A failed index lookup is shared across this batch. The next explicit or scheduled retry gets a fresh attempt.
    public func resolve(_ requests: Set<Request>, using source: MiotSpecStore) async -> [Request: String] {
        var modelTypes: [String: String]?
        var available: [String: Bool] = [:]
        var resolved: [Request: String] = [:]
        for request in requests where !DeviceSchema.bundledModels.contains(request.model) {
            guard !Task.isCancelled else { break }
            if request.type == nil && modelTypes == nil { modelTypes = (try? await source.typeIndex()) ?? [:] }
            guard let type = request.type ?? modelTypes?[request.model] else { continue }
            if available[type] == nil { available[type] = await restore(type, using: source) }
            if available[type] == true { resolved[request] = type }
        }
        return resolved
    }
}
