import Foundation

/// Reads this installation's on-disk code signature using public file APIs.
/// The OS validates the signature/profile when installing; this reader does not grant permissions.
public struct SignedEntitlements: Equatable, Sendable {
    public var applicationIdentifier: String?
    public var teamIdentifier: String?
    public var appGroups: [String]
    public var keychainGroups: [String]
    public var networkExtensions: [String]

    public init(applicationIdentifier: String?, teamIdentifier: String?, appGroups: [String],
                keychainGroups: [String], networkExtensions: [String]) {
        self.applicationIdentifier = applicationIdentifier; self.teamIdentifier = teamIdentifier
        self.appGroups = appGroups; self.keychainGroups = keychainGroups; self.networkExtensions = networkExtensions
    }

    public static func read(executable: URL) throws -> Self {
        try decodeExecutable(Data(contentsOf: executable, options: .mappedIfSafe))
    }

    static func decodeExecutable(_ data: Data) throws -> Self {
        var file = SignatureBytes(data: data)
        let magic = try file.integer(0, bigEndian: true)
        if magic == 0xcafebabe || magic == 0xcafebabf {
            let count = try file.integer(4, bigEndian: true)
            guard (1...64).contains(count) else { throw SigningIssue.invalidSignature }
            let stride = magic == 0xcafebabe ? 20 : 32
            var selected: SignatureBytes?
            for index in 0..<count {
                let entry = 8 + index * stride
                let cpu = try file.integer(entry, bigEndian: true)
                if cpu == 0x0100000c || (selected == nil && cpu == 0x01000007) {
                    let offset = try file.integer(entry + 8, width: stride == 20 ? 4 : 8, bigEndian: true)
                    let length = try file.integer(entry + (stride == 20 ? 12 : 16), width: stride == 20 ? 4 : 8, bigEndian: true)
                    selected = try file.slice(offset, length)
                    if cpu == 0x0100000c { break }
                }
            }
            guard let selected else { throw SigningIssue.invalidSignature }
            file = selected
        }
        guard try file.integer(0) == 0xfeedfacf else { throw SigningIssue.invalidSignature }
        let count = try file.integer(16), commandsSize = try file.integer(20)
        guard count <= 4096, commandsSize <= file.count - 32 else { throw SigningIssue.invalidSignature }
        var cursor = 32
        for _ in 0..<count {
            let command = try file.integer(cursor), size = try file.integer(cursor + 4)
            guard size >= 8, cursor <= 32 + commandsSize - size else { throw SigningIssue.invalidSignature }
            if command == 0x1d {
                guard size >= 16 else { throw SigningIssue.invalidSignature }
                let offset = try file.integer(cursor + 8), length = try file.integer(cursor + 12)
                return try decodeSignature(file.slice(offset, length))
            }
            cursor += size
        }
        throw SigningIssue.missingSignature
    }

    private static func decodeSignature(_ bytes: SignatureBytes) throws -> Self {
        guard try bytes.integer(0, bigEndian: true) == 0xfade0cc0 else { throw SigningIssue.invalidSignature }
        let length = try bytes.integer(4, bigEndian: true), count = try bytes.integer(8, bigEndian: true)
        guard length <= bytes.count, length <= 16 * 1024 * 1024, count <= 128,
              12 + count * 8 <= length else { throw SigningIssue.invalidSignature }
        let blob = try bytes.slice(0, length)
        var xml: Data?, der: Data?
        for index in 0..<count {
            let slot = try blob.integer(12 + index * 8, bigEndian: true)
            guard slot == 5 || slot == 7 else { continue }
            let offset = try blob.integer(16 + index * 8, bigEndian: true)
            guard offset >= 12 + count * 8 else { throw SigningIssue.invalidSignature }
            let magic = try blob.integer(offset, bigEndian: true)
            let size = try blob.integer(offset + 4, bigEndian: true)
            guard size >= 8, size <= 1024 * 1024 else { throw SigningIssue.invalidSignature }
            let payload = try blob.slice(offset + 8, size - 8).copiedData()
            if slot == 5 {
                guard xml == nil, magic == 0xfade7171 else { throw SigningIssue.invalidSignature }
                xml = payload
            } else {
                guard der == nil, magic == 0xfade7172 else { throw SigningIssue.invalidSignature }
                der = payload
            }
        }
        let xmlValue = try xml.map { try decodeDictionary(PropertyListSerialization.propertyList(from: $0, format: nil)) }
        let derValue = try der.map { try decodeDictionary(SignatureDER.decode($0)) }
        // Modern systems use DER entitlements. Never accept a stale XML permission after a bad re-sign.
        if let xmlValue, let derValue, xmlValue != derValue { throw SigningIssue.inconsistentEntitlements }
        guard let value = derValue ?? xmlValue else { throw SigningIssue.missingSignature }
        return value
    }

    private static func decodeDictionary(_ value: Any) throws -> Self {
        guard let dictionary = value as? [String: Any] else { throw SigningIssue.invalidSignature }
        func string(_ key: String) throws -> String? {
            guard let value = dictionary[key] else { return nil }
            guard let string = value as? String, string.utf8.count <= 512 else { throw SigningIssue.invalidSignature }
            return string
        }
        func strings(_ key: String) throws -> [String] {
            guard let value = dictionary[key] else { return [] }
            guard let values = value as? [String], values.count <= 128,
                  values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 }) else { throw SigningIssue.invalidSignature }
            return Array(Set(values)).sorted()
        }
        return try Self(applicationIdentifier: string("application-identifier"),
            teamIdentifier: string("com.apple.developer.team-identifier"),
            appGroups: strings("com.apple.security.application-groups"),
            keychainGroups: strings("keychain-access-groups"),
            networkExtensions: strings("com.apple.developer.networking.networkextension"))
    }
}

private struct SignatureBytes {
    let data: Data
    var start = 0
    var count: Int
    init(data: Data) { self.data = data; count = data.count }
    private init(data: Data, start: Int, count: Int) { self.data = data; self.start = start; self.count = count }
    func slice(_ offset: Int, _ length: Int) throws -> Self {
        guard offset >= 0, length >= 0, offset <= count, length <= count - offset else { throw SigningIssue.invalidSignature }
        return Self(data: data, start: start + offset, count: length)
    }
    func integer(_ offset: Int, width: Int = 4, bigEndian: Bool = false) throws -> Int {
        let part = try slice(offset, width)
        var value: UInt64 = 0
        for index in 0..<width {
            let byte = UInt64(data[data.startIndex + part.start + index])
            value |= byte << ((bigEndian ? width - 1 - index : index) * 8)
        }
        guard let integer = Int(exactly: value) else { throw SigningIssue.invalidSignature }
        return integer
    }
    func copiedData() -> Data { Data(data[(data.startIndex + start)..<(data.startIndex + start + count)]) }
}

/// Small, bounded decoder for the documented plist DER types used in signed entitlements.
/// Supports the legacy SET dictionary and the current application-16 / version-1 wrapper.
private enum SignatureDER {
    static func decode(_ data: Data) throws -> Any {
        var cursor = 0, budget = 4096
        let result = try value(data, cursor: &cursor, end: data.count, depth: 0, budget: &budget)
        guard cursor == data.count else { throw SigningIssue.invalidSignature }
        return result
    }
    private static func value(_ data: Data, cursor: inout Int, end: Int, depth: Int, budget: inout Int) throws -> Any {
        guard depth < 24, budget > 0, cursor < end else { throw SigningIssue.invalidSignature }
        budget -= 1
        let tag = data[cursor]; cursor += 1
        guard cursor < end else { throw SigningIssue.invalidSignature }
        let initial = Int(data[cursor]); cursor += 1
        var length = initial
        if initial & 0x80 != 0 {
            let bytes = initial & 0x7f
            guard (1...4).contains(bytes), bytes <= end - cursor, data[cursor] != 0 else { throw SigningIssue.invalidSignature }
            length = 0
            for _ in 0..<bytes { length = length * 256 + Int(data[cursor]); cursor += 1 }
            guard length >= 128 else { throw SigningIssue.invalidSignature }
        }
        guard length <= end - cursor else { throw SigningIssue.invalidSignature }
        let finish = cursor + length
        switch tag {
        case 0x0c, 0x12, 0x16:
            guard let string = String(data: data[cursor..<finish], encoding: .utf8) else { throw SigningIssue.invalidSignature }
            cursor = finish; return string
        case 0x01:
            guard length == 1 else { throw SigningIssue.invalidSignature }
            let result = data[cursor] != 0; cursor = finish; return result
        case 0x02:
            guard (1...8).contains(length) else { throw SigningIssue.invalidSignature }
            var number: UInt64 = 0
            while cursor < finish { number = (number << 8) | UInt64(data[cursor]); cursor += 1 }
            return NSNumber(value: number)
        case 0x04:
            let result = Data(data[cursor..<finish]); cursor = finish; return result
        case 0x31, 0xb0:
            var dictionary: [String: Any] = [:]
            while cursor < finish {
                let pair = try value(data, cursor: &cursor, end: finish, depth: depth + 1, budget: &budget)
                guard let pair = pair as? [Any], pair.count == 2, let key = pair[0] as? String,
                      dictionary[key] == nil else { throw SigningIssue.invalidSignature }
                dictionary[key] = pair[1]
            }
            return dictionary
        case 0x30, 0x70:
            var values: [Any] = []
            while cursor < finish { values.append(try value(data, cursor: &cursor, end: finish, depth: depth + 1, budget: &budget)) }
            if tag == 0x70 {
                guard values.count == 2, (values[0] as? NSNumber)?.intValue == 1,
                      let dictionary = values[1] as? [String: Any] else { throw SigningIssue.invalidSignature }
                return dictionary
            }
            return values
        default: throw SigningIssue.invalidSignature
        }
    }
}
