import Foundation
import os.log

/// Owns file I/O on one utility queue. Entries stay ordered and the file handle is
/// reused; the main actor only formats an entry and enqueues it.
final class DiagnosticLogWriter: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "com.systems.autohideagent.diagnostic-log", qos: .utility)
    // These members are exclusively accessed on queue.
    private var handle: FileHandle?
    private var size = 0
    private var failure: (any Error)?
    private let maximumBytes: Int
    private let header: Data
    private let logger = Logger(subsystem: "com.systems.autohideagent", category: "DiagnosticLog")

    init(url: URL, maximumBytes: Int = 1_000_000) {
        self.url = url
        self.maximumBytes = maximumBytes
        header = "AutoHideAgent Diagnostic Log\nmacOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\nBundle ID: \(Bundle.main.bundleIdentifier ?? "unbundled")\n".data(using: .utf8)!
    }

    func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        queue.async { [self] in
            do {
                try openIfNeeded()
                if size > header.count && size + data.count > maximumBytes {
                    try handle?.close()
                    handle = nil
                    let previous = url.deletingPathExtension().appendingPathExtension("old.log")
                    if FileManager.default.fileExists(atPath: previous.path) {
                        try FileManager.default.removeItem(at: previous)
                    }
                    try FileManager.default.moveItem(at: url, to: previous)
                    try openIfNeeded()
                }
                try handle?.write(contentsOf: data)
                size += data.count
            } catch {
                failure = error
                logger.error("Diagnostic file write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func openIfNeeded() throws {
        guard handle == nil else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try header.write(to: url, options: .atomic)
        }
        handle = try FileHandle(forWritingTo: url)
        size = Int(try handle!.seekToEnd())
    }

    func flush() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                do {
                    try handle?.synchronize()
                    if let failure { throw failure }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Used only during orderly process termination, after producers have stopped.
    func finish() {
        queue.sync {
            try? handle?.synchronize()
            try? handle?.close()
            handle = nil
        }
    }

    static func defaultURL(isDevelopment: Bool, benchmarkDirectory: String? = nil) -> URL {
        if let benchmarkDirectory {
            return URL(fileURLWithPath: benchmarkDirectory).appendingPathComponent("logs/AutoHideAgent.log")
        }
        let name = isDevelopment ? "AutoHideAgent-Dev" : "AutoHideAgent"
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/\(name)/\(name).log")
    }
}
