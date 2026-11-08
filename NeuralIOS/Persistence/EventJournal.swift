import Foundation

/// Called only from the session thread. Two 2 MiB segments bound on-disk history.
final class EventJournal {
    private let directory: URL
    private let current: URL
    private let previous: URL
    private let segmentLimit = 2 * 1024 * 1024
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970; encoder.outputFormatting = [.sortedKeys]; return encoder
    }()
    struct Record: Encodable {
        let kind: String
        let received: ReceiptContext
        let sessionID: UUID
        let message: String?
        let gesture: GestureEvent?
    }
    init() throws {
        directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("BandJournal", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        current = directory.appendingPathComponent("current.jsonl"); previous = directory.appendingPathComponent("previous.jsonl")
        var url = directory; var resource = URLResourceValues(); resource.isExcludedFromBackup = true; try url.setResourceValues(resource)
    }
    func append(kind: String, receipt: ReceiptContext, session: UUID, message: String? = nil, gesture: GestureEvent? = nil) throws {
        var data = try encoder.encode(Record(kind: kind, received: receipt, sessionID: session, message: message, gesture: gesture)); data.append(10)
        guard data.count <= segmentLimit else { throw BandError.storage("Journal entry exceeds segment limit.") }
        let size = (try? FileManager.default.attributesOfItem(atPath: current.path)[.size] as? NSNumber)?.intValue ?? 0
        if size + data.count > segmentLimit {
            if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
            if FileManager.default.fileExists(atPath: current.path) { try FileManager.default.moveItem(at: current, to: previous) }
        }
        if !FileManager.default.fileExists(atPath: current.path) {
            guard FileManager.default.createFile(atPath: current.path, contents: nil, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else { throw BandError.storage("Cannot create the event journal.") }
        }
        let handle = try FileHandle(forWritingTo: current); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data); try handle.synchronize()
    }
    func export() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NeuralIOS-events.jsonl")
        var data = Data()
        for file in [previous, current] where FileManager.default.fileExists(atPath: file.path) { data.append(try Data(contentsOf: file)) }
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]); return url
    }
    func clear() throws {
        for file in [previous, current, FileManager.default.temporaryDirectory.appendingPathComponent("NeuralIOS-events.jsonl")] where FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
}
