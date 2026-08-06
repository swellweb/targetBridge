import Foundation
import Darwin

@MainActor
enum TBInputDebugLog {
    private static let fileManager = FileManager.default
    private static let maximumInputLogBytes: UInt64 = 5 * 1_024 * 1_024
    private static let maximumLaunchLogBytes: off_t = 20 * 1_024 * 1_024

    private static var logURL: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("TargetBridge", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("input-debug.log", isDirectory: false)
    }

    static func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp) \(message)\n"
        let url = logURL
        let directory = url.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        if let data = line.data(using: .utf8) {
            if fileManager.fileExists(atPath: url.path) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    if ((try? handle.seekToEnd()) ?? 0) > maximumInputLogBytes {
                        try? handle.truncate(atOffset: 0)
                    }
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// launchd opens these files before starting the app. Trim only regular
    /// files (never Terminal/Console descriptors) so long-running headless use
    /// cannot consume disk space without bound.
    static func prepareForLaunch() {
        trimStandardStream(FileHandle.standardOutput)
        trimStandardStream(FileHandle.standardError)
    }

    private static func trimStandardStream(_ handle: FileHandle) {
        var status = stat()
        let descriptor = handle.fileDescriptor
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_size > maximumLaunchLogBytes else { return }
        _ = ftruncate(descriptor, 0)
    }

    static var currentLogPath: String {
        logURL.path
    }
}
