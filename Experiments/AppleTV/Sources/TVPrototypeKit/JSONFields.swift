import MijiaCore

extension JSONValue {
    func field(_ key: String) -> JSONValue? {
        if case .object(let fields) = self { fields[key] } else { nil }
    }
    var elements: [JSONValue]? {
        if case .array(let values) = self { values } else { nil }
    }
}
