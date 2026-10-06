import Foundation

private final class TBAsyncInputDebugLogWriter: @unchecked Sendable {
    private let fileManager = FileManager.default
    private let writeQueue = DispatchQueue(label: "fd.tbdisplaysender.input-debug-log", qos: .utility)

    func enqueue(_ message: String) {
        writeQueue.async { [self] in
            write(message)
        }
    }

    private func write(_ message: String) {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        let url = base
            .appendingPathComponent("TargetBridge", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("input-debug.log", isDirectory: false)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp) \(message)\n"
        let directory = url.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        guard let data = line.data(using: .utf8) else { return }
        if fileManager.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}

@MainActor
enum TBInputDebugLog {
    private static let writer = TBAsyncInputDebugLogWriter()
    private static var inputEventCount: UInt64 = 0
    private static let inputEventBurstLimit: UInt64 = 20
    private static let inputEventSampleInterval: UInt64 = 100

    private static var logURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("TargetBridge", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("input-debug.log", isDirectory: false)
    }

    static func log(_ message: String) {
        writer.enqueue(message)
    }

    /// Mouse motion can arrive hundreds of times per second. Keep the first few
    /// records plus a periodic sample, without putting file I/O on the input path.
    static func logInputEvent(_ message: @autoclosure () -> String) {
        inputEventCount &+= 1
        let count = inputEventCount

        guard count <= inputEventBurstLimit || count.isMultiple(of: inputEventSampleInterval) else { return }
        log(message())
    }

    static var currentLogPath: String {
        logURL.path
    }
}
