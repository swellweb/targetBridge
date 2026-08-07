import Foundation
import os

/// Writes the receiver's shipped stderr to a file on the sender Mac.
///
/// The receiver runs on the other machine, so reading its log used to mean
/// asking whoever sits there to copy it out of a terminal. Both sides' logs now
/// live on one machine, next to what `log show` already gives for the sender.
///
/// A file rather than os_log on purpose: unified logging rate-limits and elides,
/// and a diagnostic that silently drops the interesting burst is worse than
/// useless. Bytes arrive as raw UTF-8 with no line framing — a packet may split
/// a line or carry several — so this appends them verbatim and lets the text
/// reassemble itself.
/// `@unchecked Sendable` is accurate rather than a shortcut: every mutable
/// field below is touched only inside `queue`, which is the serial queue this
/// class exists to funnel writes through.
final class TBReceiverLogSink: @unchecked Sendable {
    static let shared = TBReceiverLogSink()

    /// Everything here happens off the connection queue. Log volume is small
    /// next to video, but a synchronous write to a file on a busy disk has no
    /// business sitting in the path that also carries frames.
    private let queue = DispatchQueue(label: "com.targetbridge.receiverlog",
                                      qos: .utility)
    private var handle: FileHandle?
    private var written = 0
    /// Whether the last byte written ended a line. Receiver bytes arrive
    /// unframed, so a shipped packet routinely leaves the file mid-line; a
    /// sender line appended right then would splice itself into the middle of a
    /// receiver one. Tracked so `note` can break the line first.
    private var atLineStart = true

    /// Rotated rather than truncated at open, so the previous session survives
    /// long enough to be read after a crash — which is exactly when it matters.
    private static let maxBytes = 32 * 1024 * 1024

    let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/TargetBridge", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("receiver.log")
    }()

    private init() {}

    func append(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        queue.async { [self] in
            if handle == nil { open() }
            guard let h = handle else { return }
            do {
                try h.write(contentsOf: bytes)
                written += bytes.count
                atLineStart = bytes.last == 0x0A
                if written >= Self.maxBytes { rotate() }
            } catch {
                // The sink failing must never take the session with it, and
                // there is nowhere useful to report it to — the thing that
                // failed is the log.
                handle = nil
            }
        }
    }

    /// Writes one of the SENDER's own telemetry lines into the same file.
    ///
    /// The sender already logs this through os_log, and that turned out to be
    /// the reason a long-standing intermittent stall stayed undiagnosed: os_log
    /// `.info` is memory-backed and evaporates within about fifteen minutes, so
    /// by the time anyone looked, the only surviving record was the receiver's.
    /// Half the evidence, and the half that cannot see why frames stopped being
    /// produced. Both ends now land in one durable file, in order.
    ///
    /// Timestamped because the receiver's shipped lines are not — its stderr
    /// carries no clock of its own, so these stamps are the only anchors the
    /// file has for lining the two sides up against each other.
    func note(_ line: String) {
        let stamp = Self.clock.string(from: Date())
        queue.async { [self] in
            if handle == nil { open() }
            guard let h = handle else { return }
            let text = (atLineStart ? "" : "\n") + "\(stamp) [sender] \(line)\n"
            do {
                try h.write(contentsOf: Data(text.utf8))
                written += text.utf8.count
                atLineStart = true
                if written >= Self.maxBytes { rotate() }
            } catch {
                handle = nil
            }
        }
    }

    /// Wall clock rather than ISO8601: these lines are read next to
    /// `log show` output, which prints local time, and matching it by eye is
    /// the whole point of having a stamp.
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Marks a session boundary. Without it a reader cannot tell where one run
    /// ends and the next begins, and the file is a rolling record of many.
    func noteSessionStart(_ what: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        append(Data("\n===== \(what) — \(stamp) =====\n".utf8))
    }

    private func open() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        if let h = handle {
            let end = (try? h.seekToEnd()) ?? 0
            written = Int(end)
            if written >= Self.maxBytes { rotate() }
        }
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        let previous = url.deletingLastPathComponent()
            .appendingPathComponent("receiver.log.1")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: url, to: previous)
        written = 0
        open()
    }
}
