import Foundation

/// All mutable state and disk access are confined to queue. Never logs payloads itself.
nonisolated final class FileLogger: @unchecked Sendable {
    static let shared = FileLogger()
    let fileURL: URL
    private let queue = DispatchQueue(label: "Trainpod.FileLogger", qos: .utility)
    private let maximumBytes = 500 * 1024
    private let retainedBytes = 250 * 1024

    init(directory: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]) {
        fileURL = directory.appendingPathComponent("transit.log")
        queue.async { self.perform { try self.prepareFile(); try self.trimIfNeeded() } }
    }

    func log(_ message: String) {
        queue.async {
            self.perform {
                try self.prepareFile()
                // Bound individual entries and prevent multiline entries from forging timestamps.
                let clean = String(message.prefix(4096)).components(separatedBy: .newlines).joined(separator: " ")
                let entry = "\(ISO8601DateFormatter().string(from: Date())) \(clean)\n"
                let handle = try FileHandle(forWritingTo: self.fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(entry.utf8))
                try self.trimIfNeeded()
            }
        }
    }

    func clearLogs() {
        queue.async { self.perform { try self.prepareFile(); try Data().write(to: self.fileURL, options: .atomic) } }
    }

    /// Await before presenting the share sheet so previously queued entries are on disk.
    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    private func prepareFile() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: fileURL.path) {
            try Data().write(to: fileURL, options: .atomic)
        }
    }

    private func trimIfNeeded() throws {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size > maximumBytes else { return }
        try handle.seek(toOffset: size - UInt64(retainedBytes))
        var tail = try handle.readToEnd() ?? Data()
        if let newline = tail.firstIndex(of: 10) { tail = Data(tail.suffix(from: tail.index(after: newline))) }
        try tail.write(to: fileURL, options: .atomic)
    }

    private func perform(_ operation: () throws -> Void) {
        do { try operation() }
        catch {
            #if DEBUG
            print("[FileLogger] Disk operation failed (code \((error as NSError).code))")
            #endif
        }
    }
}
