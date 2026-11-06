import Foundation

/// Version announcements only. This API never downloads or installs executable code.
public struct TVUpdateFeed: Codable, Sendable {
    public static let address = URL(string: "https://mijialan-updates.ipocket.xyz/tvos/releases.json")!
    public static let githubAddress = URL(string: "https://api.github.com/repos/iPocket-APP/MijiaLAN/releases?per_page=100")!
    public static let bundleID = "com.ipocket.MijiaLAN.TVPrototype"
    public var schemaVersion = 1
    public var platform = "tvOS"
    public var bundleIdentifier = Self.bundleID
    public var channel = "selfSigned"
    public var releases: [Release]

    public struct Release: Codable, Sendable, Equatable {
        public var version: String
        public var build: Int
        public var tag: String
        public var notes: String
        public var publishedAt: String
        public var releaseURL: URL
        public init(version: String, build: Int, notes: String, publishedAt: String) {
            self.version = version; self.build = build; self.notes = notes; self.publishedAt = publishedAt
            tag = "tvos-v\(version)-b\(build)"
            releaseURL = URL(string: "https://github.com/iPocket-APP/MijiaLAN/releases/tag/\(tag)")!
        }
    }

    public init(releases: [Release]) { self.releases = releases }

    public func validated() throws -> Self {
        guard schemaVersion == 1, platform == "tvOS", bundleIdentifier == Self.bundleID,
              channel == "selfSigned", releases.count <= 100 else { throw TVUpdateError.invalidFeed }
        var builds = Set<Int>()
        for release in releases {
            guard Self.versionParts(release.version) != nil, (1...2_147_483_647).contains(release.build),
                  builds.insert(release.build).inserted,
                  release.tag == "tvos-v\(release.version)-b\(release.build)",
                  release.releaseURL.absoluteString == "https://github.com/iPocket-APP/MijiaLAN/releases/tag/\(release.tag)",
                  release.notes.utf8.count <= 24_000,
                  ISO8601DateFormatter().date(from: release.publishedAt) != nil else { throw TVUpdateError.invalidFeed }
        }
        return self
    }

    /// Build numbers are globally increasing within this tvOS bundle and channel.
    public func newest(after build: Int) -> Release? {
        releases.filter { $0.build > build }.max { $0.build < $1.build }
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 1024 * 1024 else { throw TVUpdateError.invalidFeed }
        return try JSONDecoder().decode(Self.self, from: data).validated()
    }

    public static func fromGitHub(_ data: Data) throws -> Self {
        struct Asset: Decodable { var name: String; var size: Int }
        struct Item: Decodable {
            var tag_name: String; var draft: Bool; var published_at: String?
            var body: String?; var assets: [Asset]
        }
        guard data.count <= 4 * 1024 * 1024 else { throw TVUpdateError.invalidFeed }
        let items = try JSONDecoder().decode([Item].self, from: data)
        let releases = items.compactMap { item -> Release? in
            guard !item.draft, item.tag_name.hasPrefix("tvos-v"), let at = item.published_at else { return nil }
            let parts = item.tag_name.dropFirst(6).components(separatedBy: "-b")
            guard parts.count == 2, Self.versionParts(parts[0]) != nil,
                  let build = Int(parts[1]), String(build) == parts[1],
                  item.assets.contains(where: { $0.name == "MijiaLAN-tvOS-\(parts[0])-b\(build).ipa" && $0.size > 0 }) else { return nil }
            // Truncate by characters to keep valid Unicode, then enforce the byte limit in validated().
            return Release(version: parts[0], build: build, notes: String((item.body ?? "").prefix(6_000)), publishedAt: at)
        }
        return try Self(releases: releases).validated()
    }

    private static func versionParts(_ value: String) -> [Int]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let values = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let n = Int(part), (0...999_999).contains(n), String(n) == part else { return nil }
            return n
        }
        return values.count == 3 ? values : nil
    }

    /// A missing dedicated endpoint can fall back to the same public release rules.
    /// Neither request includes device configuration, HomeKit identity or credentials.
    public static func fetch(address: URL = Self.address, session: URLSession = .shared) async throws -> (Self, String) {
        func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw TVUpdateError.invalidFeed }
            return (data, http)
        }
        let (data, response) = try await get(address)
        if response.statusCode == 404, address == Self.address {
            let (github, result) = try await get(githubAddress)
            guard result.statusCode == 200 else { throw TVUpdateError.http(result.statusCode) }
            return (try fromGitHub(github), "GitHub 公开发行记录")
        }
        guard response.statusCode == 200 else { throw TVUpdateError.http(response.statusCode) }
        return (try decode(data), "TV 更新服务")
    }
}

public enum TVUpdateError: Error, LocalizedError {
    case invalidFeed, http(Int)
    public var errorDescription: String? {
        switch self {
        case .invalidFeed: "TV 版本信息格式不正确。"
        case .http(let code): "更新服务暂时不可用（HTTP \(code)）。"
        }
    }
}
