import Foundation
import Testing
@testable import MijiaLANApp

struct HAPDiagnosticLogTests {
    @Test("A local capture preserves record order and restricts file access")
    func orderedCapture() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("hap.log")
        let log = HAPDiagnosticLog(url: url)
        let rows = (0..<40).map { "record \($0) 台灯\n" }
        for row in rows { log.append(row) }
        await log.flush()
        #expect(try String(contentsOf: url, encoding: .utf8) == rows.joined())
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("Rotation retains the most recent records in at most two bounded files")
    func rotates() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("hap.log")
        let log = HAPDiagnosticLog(url: url, byteLimit: 256)
        for i in 0..<30 { log.append("\(i): " + String(repeating: "台灯", count: 12)) }
        await log.flush()
        let paths = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(paths.count == 2)
        for path in paths {
            let data = try Data(contentsOf: path)
            #expect(data.count <= 256)
            #expect(String(data: data, encoding: .utf8) != nil)
        }
        let current = try String(contentsOf: url, encoding: .utf8)
        #expect(current.contains("29: "))
        #expect(!current.contains("0: "))
    }

    @Test("Concurrent producers do not interleave or lose complete records within the queue bound")
    func concurrentCapture() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("hap.log")
        let log = HAPDiagnosticLog(url: url)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<200 { group.addTask { log.append("event \(i)") } }
        }
        await log.flush()
        let rows = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(rows.count == 200)
        #expect(Set(rows) == Set((0..<200).map { "event \($0)" }))
    }

    @Test("A resumed capture enforces the current limit on both existing files")
    func resumesWithinBounds() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("hap.log")
        try Data("earlier response\n".utf8).write(to: url)
        try Data(repeating: 65, count: 1024).write(to: url.appendingPathExtension("previous"))
        let log = HAPDiagnosticLog(url: url, byteLimit: 256)
        log.append("resumed response")
        await log.flush()
        let paths = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for path in paths { #expect(try Data(contentsOf: path).count <= 256) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "earlier response\nresumed response\n")
    }

    @Test("Oversized entries cannot break the size bound or truncate a UTF-8 record")
    func oversizedEntry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("hap.log")
        let log = HAPDiagnosticLog(url: url, byteLimit: 256)
        log.append(String(repeating: "台灯", count: 500))
        log.append("next response 200")
        await log.flush()
        let data = try Data(contentsOf: url)
        #expect(data.count <= 256)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("omitted"))
        #expect(text.hasSuffix("next response 200\n"))
    }
}
