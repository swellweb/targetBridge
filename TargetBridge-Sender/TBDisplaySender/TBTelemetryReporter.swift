import Foundation

/// Formats and emits the capture telemetry, off the capture thread.
///
/// The formatting used to happen inline in the capture callback: four os_log
/// calls plus two histograms built with enumerated/filter/map/joined. That is a
/// lot of allocation for a thread with a 16.7 ms budget, and it ran once per 240
/// frames -- which is exactly how often `send(wall)` showed a single 2-period
/// gap. It was the last 1%, and the one cost `process` could never reveal,
/// because the report is emitted after the measurement it reports.
///
/// A diagnostic that perturbs what it measures is worse than no diagnostic.
enum TBTelemetryReporter {
    private static let queue = DispatchQueue(label: "com.targetbridge.telemetry",
                                             qos: .utility)

    /// Spacing of packets ACTUALLY leaving, binned here rather than at the
    /// caller.
    ///
    /// `send(wall)` used to be sampled where the frame was submitted to the
    /// encoder. Once the encode went async that stopped being when packets left
    /// -- emission happens later, from the completion callback -- and the metric
    /// read a clean 100% while the receiver was visibly bunching frames into
    /// pairs. A measurement taken at the wrong point is worse than none.
    ///
    /// It lives here because emission happens on the encoder's queue while the
    /// capture histogram is written on the capture thread; binning on this
    /// queue keeps both off each other's memory.
    /// `nonisolated(unsafe)` is accurate: both are read and written only inside
    /// `queue`, which is serial.
    nonisolated(unsafe) private static var emitBins = [Int](repeating: 0, count: 8)
    nonisolated(unsafe) private static var lastEmit = 0.0

    /// Call as the frame's LAST band goes to the socket. Cheap: a timestamp and
    /// an async hop, no formatting.
    static func noteEmit() {
        let now = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        queue.async {
            if lastEmit > 0 {
                let periods = Int(((now - lastEmit) / (1.0 / 60.0)).rounded())
                emitBins[max(0, min(7, periods))] += 1
            }
            lastEmit = now
        }
    }

    private static func fmt(_ bins: [Int]) -> String {
        let total = max(1, bins.reduce(0, +))
        return bins.enumerated()
            .filter { $0.element > 0 }
            .map { "\($0.offset):\($0.element) (\(Int(100.0 * Double($0.element) / Double(total)))%)" }
            .joined(separator: "  ")
    }

    static func report(capBins: [Int], sendBins: [Int], drops: Int, idle: Int,
                       probe: Double, lock: Double, ctx: Double, submit: Double,
                       hadProcess: Bool,
                       deliverySum: Double, deliveryMax: Double,
                       processSum: Double, processMax: Double, samples: Int,
                       inflight: Int, budget: Int,
                       idleInputGap: Double,
                       wakeShortSum: Double, wakeShortCount: Int,
                       wakeLongSum: Double, wakeLongMax: Double, wakeLongCount: Int,
                       wakeRejected: Int) {
        queue.async {
            // An idle burst means the compositor produced nothing. Whether that
            // is a wedge or simply nobody at the keyboard is decided by how
            // recently the machine saw input WHILE those frames were idle --
            // "idle 996 (input 0.2s)" is a bug, "idle 996 (input 41.7s)" is a
            // desk nobody is sitting at.
            let idleNote: String
            if idle > 0 && idleInputGap.isFinite {
                idleNote = " idle \(idle) (input \(String(format: "%.1f", idleInputGap))s)"
            } else {
                idleNote = " idle \(idle)"
            }
            emit("cadence capture(pts) \(fmt(capBins)) \(idleNote)")
            emit("cadence emit(wall)   \(fmt(emitBins))  drops \(drops)")
            // The wake-up cost, which every other number here is blind to.
            // `long` is the one that matters: resuming after a real pause.
            // `short` is the gap between keystrokes mid-word, which was never
            // slow and only ever diluted the average.
            if wakeShortCount > 0 || wakeLongCount > 0 || wakeRejected > 0 {
                let shortAvg = wakeShortCount > 0 ? wakeShortSum / Double(wakeShortCount) * 1000.0 : 0
                let longAvg  = wakeLongCount  > 0 ? wakeLongSum  / Double(wakeLongCount)  * 1000.0 : 0
                emit("wake: short(<1s) \(wakeShortCount) @ \(String(format: "%.0f", shortAvg)) ms | LONG(>=1s) \(wakeLongCount) @ \(String(format: "%.0f", longAvg)) ms worst \(String(format: "%.0f", wakeLongMax * 1000.0)) ms | \(wakeRejected) not input-caused")
            }
            emitBins = [Int](repeating: 0, count: 8)
            if hadProcess {
                emit("stage worst ms: probe \(String(format: "%.1f", probe)) | lock \(String(format: "%.1f", lock)) | ctx \(String(format: "%.1f", ctx)) | submit \(String(format: "%.1f", submit))")
            }
            if samples > 0 {
                let n = Double(samples)
                emit("latency delivery \(String(format: "%.1f", deliverySum / n)) ms avg / \(String(format: "%.1f", deliveryMax)) max | process \(String(format: "%.1f", processSum / n)) ms avg / \(String(format: "%.1f", processMax)) max | inflight \(inflight)/\(budget)")
            }
        }
    }

    /// One telemetry line to both sinks.
    ///
    /// os_log stays because it is what `log show` and Console read live. The
    /// file is what survives: these are `.info` records, which unified logging
    /// keeps in memory and drops after roughly fifteen minutes, and that is
    /// precisely long enough to lose every intermittent fault worth chasing.
    static func emit(_ line: String) {
        TBLog.connection.info("\(line, privacy: .public)")
        TBReceiverLogSink.shared.note(line)
    }
}
