import Foundation
import Logging
import MijiaLAN
import os

/// hap-swift logs through swift-log, which prints to stdout and is lost when the app is opened from Finder. This
/// sends it to the unified log instead, where a failed pairing can be read afterwards:
///
///     log show --last 1h --predicate 'subsystem == "com.mijialan.MijiaLAN" AND category BEGINSWITH "hap."'
///
/// Keep verbose request/accessory dumps disabled by default. Upstream messages can contain controller identifiers,
/// device names and readings, so all dynamic message text remains private in the unified log.
struct UnifiedLogHandler: LogHandler {
    var logLevel: Logging.Logger.Level
    var metadata: Logging.Logger.Metadata = [:]
    private let logger: os.Logger
    private let label: String
    private static let environment = ProcessInfo.processInfo.environment
    private static let traceURL: URL? = {
        guard let path = environment["MIJIALAN_TRACE_FILE"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }()
    private static let localDiagnostics = environment["MIJIALAN_HAP_DIAGNOSTICS"] == "1" || traceURL != nil
    private static let diagnosticQueue = DispatchQueue(label: "MijiaLAN.hap-diagnostic-log", qos: .utility)
    private static let diagnosticFile: HAPDiagnosticLog? = {
        if let traceURL { return HAPDiagnosticLog(url: traceURL) }
        guard localDiagnostics, let path = environment["MIJIALAN_HAP_DIAGNOSTICS_FILE"],
              path.hasPrefix("/") else { return nil }
        return HAPDiagnosticLog(url: URL(fileURLWithPath: path))
    }()

    init(label: String) {
        self.label = label
        logger = os.Logger(subsystem: "com.mijialan.MijiaLAN", category: label)
        logLevel = Self.environment["MIJIALAN_HAP_TRACE"] == "1" ? .trace : Self.localDiagnostics ? .debug : .info
    }

    static func configureMiioTrace() {
        guard traceURL != nil, let file = diagnosticFile else { return }
        MiioClient.setTrace { message in file.append(diagnosticLine(label: "miio", message: message)) }
    }

    private static func diagnosticLine(label: String, message: String) -> String {
        "\(Date().ISO8601Format(.init(includingFractionalSeconds: true))) [\(label)] \(message)\n"
    }

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        guard event.level >= logLevel else { return }
        // Explicit opt-in for a local diagnostic launch. Never copy trace payloads or crypto/pairing logs;
        // the normal unified log keeps its privacy protection. A file destination rotates at 2 x 4 MiB.
        if Self.localDiagnostics, event.level >= .debug,
           ["hap.apple", "hap.apple.tcp", "hap.characteristic", "hap.bridge"].contains(label) {
            let line = Self.diagnosticLine(label: label, message: event.message.description)
            if let file = Self.diagnosticFile { file.append(line) }
            else { Self.diagnosticQueue.async { try? FileHandle.standardError.write(contentsOf: Data(line.utf8)) } }
        }
        for text in Self.pieces(of: event.message.description) {
            switch event.level {
            case .trace, .debug:
                logger.debug("\(text, privacy: .private)")
            case .info:
                logger.info("\(text, privacy: .private)")
            case .notice:
                logger.notice("\(text, privacy: .private)")
            case .warning, .error, .critical:
                logger.error("\(text, privacy: .private)")
            }
        }
    }

    /// The log store cuts long messages short, and the accessory list runs to several kilobytes: longer messages
    /// go out as numbered pieces.
    static func pieces(of text: String, maxBytes: Int = 800) -> [String] {
        guard text.utf8.count > maxBytes else { return [text] }
        var pieces: [String] = []
        var current = ""
        var bytes = 0
        for character in text {
            let size = character.utf8.count
            if bytes + size > maxBytes {
                pieces.append(current)
                current = ""
                bytes = 0
            }
            current.append(character)
            bytes += size
        }
        pieces.append(current)
        return pieces.enumerated().map { "[\($0.offset + 1)/\(pieces.count)] \($0.element)" }
    }
}
