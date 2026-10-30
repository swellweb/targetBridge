#!/usr/bin/env ruby
# Run production cable-transfer state, send loop and handshake with a fake
# connection. No display capture, network traffic, device or system settings.
require 'tmpdir'

root = File.expand_path('..', __dir__)
source = File.read(File.join(root, 'TBDisplaySender/TBDisplaySenderService.swift'))
protocol = File.read(File.join(root, 'TBDisplayShared/TBMonitorProtocol.swift'))
state = source[/enum TBCableTestError: LocalizedError \{.*?(?=\/\/\/ Counts only video packets)/m]
transfer = source[/    private func performCableTest\(\).*?(?=\n    func stop\()/m]
setup = source[/    private func sendSessionSetup\(\).*?(?=\n    private func sendHello)/m]
send_packet = source[/    private func send\(_ packet: Data\).*?(?=\n    func sendInputEvent)/m]
packet = protocol[/    static func makeDispatchPacket\(.*?(?=\n    static func makeJSONPacket)/m]
abort 'missing production cable-test implementation' unless [state, transfer, setup, send_packet, packet].all?

ready = source[/case \.ready:.*?(?=\n                case \.waiting)/m]
profile = source[/private func handleDisplayProfile\(.*?(?=    private func startCapture)/m]
stop = source[/    private func stop\(.*?(?=    \/\/\/ Stable per-receiver)/m]
abort 'ready/profile must share the guarded session setup' unless ready&.include?('self.sendSessionSetup()') && profile&.include?('sendSessionSetup()')
abort 'cable profile wait must have a deadline' unless ready.include?('startCableProfileWatchdog(for: conn)') && source.include?('TBCableTestError.profileTimedOut.localizedDescription')
abort 'normal heartbeat must not run for cable connections' unless ready.match?(/if self\.isCableTestConnection \{.*?\} else \{\s+self\.startHeartbeat\(\)/m)
abort 'stop must cancel transfer accounting and close cable sockets directly' unless stop&.include?('cableTestTransfer?.cancel()') && stop.match?(/if wasCableTest \{.*?connectionToClose\?\.cancel\(\)/m)
abort 'keep cable identity until stop decides how to close' if profile.include?('self.isCableTestConnection = false')
abort 'cable connection must not import remote clipboard/input' unless source.include?('isCableTestConnection && type != .displayProfile && type != .heartbeat && type != .teardown')
abort 'cable must bypass preset capability rejection' unless profile.include?('!isCableTestConnection && resolvedTransport(for: profile) == nil')

fixture = <<~'SWIFT'
import Foundation
import Dispatch
enum TBMonitorPacketType: UInt8 { case testData = 0x40 }
enum TBMonitorProtocol {
    static func appendBE32(_ data: inout Data, _ value: UInt32) {
        var value = value.bigEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
SWIFT

connection = <<~'SWIFT'
}
final class NWConnection: @unchecked Sendable {
    enum Mode { case immediate, error, held }
    enum SendCompletion { case contentProcessed(@Sendable (Error?) -> Void) }
    let mode: Mode
    private let lock = NSLock()
    private var sent = 0, controls = 0, cancellations = 0
    private var firstRegions: [UInt]?
    private var firstPacket: DispatchData?
    private var held: [SendCompletion] = []
    init(_ mode: Mode = .immediate) { self.mode = mode }
    var counts: (sent: Int, controls: Int, cancellations: Int) {
        lock.lock(); defer { lock.unlock() }
        return (sent, controls, cancellations)
    }
    func send(content: DispatchData, completion: SendCompletion) {
        precondition(content.count == 4_000_005)
        precondition(Array(content.prefix(5)) == [0, 0x3d, 0x09, 0x01, 0x40])
        var regions: [UInt] = []
        content.enumerateBytes { bytes, _, _ in regions.append(UInt(bitPattern: bytes.baseAddress!)) }
        lock.lock()
        sent += 1
        if let firstRegions { precondition(regions == firstRegions) }
        else { firstRegions = regions; firstPacket = content }
        if mode == .held { held.append(completion) }
        lock.unlock()
        if mode != .held, case let .contentProcessed(callback) = completion {
            callback(mode == .error ? NSError(domain: "test.send", code: 27) : nil)
        }
    }
    func send(content: Data, completion: SendCompletion) {
        lock.lock(); controls += 1; lock.unlock()
        if case let .contentProcessed(callback) = completion { callback(nil) }
    }
    func cancel() {
        lock.lock(); cancellations += 1; lock.unlock()
        // Deliberately don't invoke held completions. Cancellation must wake the
        // transfer itself, without depending on Network delivering a callback.
    }
    func completeHeld() {
        lock.lock(); let callbacks = held; held.removeAll(); lock.unlock()
        for completion in callbacks {
            if case let .contentProcessed(callback) = completion { callback(nil) }
        }
    }
    func assertOwnedPacket() {
        lock.lock(); let packet = firstPacket; lock.unlock()
        precondition(packet?.count == 4_000_005 && packet?[4] == 0x40 && packet?[4_000_004] == 0)
    }
}
@MainActor
final class Session {
    var connection: NWConnection?
    var cableTestTransfer: TBCableTestTransfer?
    var isCableTestConnection = true
    var commands: [String] = []
    init(_ connection: NWConnection) { self.connection = connection }
    func sendHello() { commands.append("hello"); send(Data([1])) }
    func sendInputControlModeUpdate() { commands.append("input"); send(Data([2])) }
    func sendBrightnessUpdate() { commands.append("brightness"); send(Data([3])) }
    func sendVolumeUpdate() { commands.append("volume"); send(Data([4])) }
    func setupForTest() { sendSessionSetup() }
    func tryControlPacket() { send(Data([5])) }
    func run() async throws -> Double { try await performCableTest() }
SWIFT

tests = <<~'SWIFT'
}
@main
struct Tests {
    static func expectTimeout(_ operation: () throws -> Void, completed: Int64, expected: Int64) {
        do { try operation(); preconditionFailure("timeout accepted as success") }
        catch TBCableTestError.timedOut(let actual, let total) {
            precondition(actual == completed && total == expected)
        } catch { preconditionFailure("wrong error: \(error)") }
    }
    static func stateTests() throws {
        let rate = TBCableTestTransfer.Result(completedPayloadBytes: 20_000_000_000, elapsedSeconds: 160.0 / 11)
        precondition(abs(rate.gigabitsPerSecond - 11) < 1e-9)

        let limited = TBCableTestTransfer(expectedBytes: 900, timeout: 1, stallTimeout: 0.04)
        for _ in 0..<8 { _ = try limited.reserve(payloadBytes: 100) }
        let started = ProcessInfo.processInfo.systemUptime
        expectTimeout({ _ = try limited.reserve(payloadBytes: 100) }, completed: 0, expected: 900)
        precondition(ProcessInfo.processInfo.systemUptime - started < 1)

        let partial = TBCableTestTransfer(expectedBytes: 200, timeout: 1, stallTimeout: 0.04)
        let first = try partial.reserve(payloadBytes: 100)
        _ = try partial.reserve(payloadBytes: 100)
        partial.complete(first, error: nil)
        partial.complete(first, error: nil) // duplicate callback must not double-count
        expectTimeout({ _ = try partial.finish() }, completed: 100, expected: 200)
        precondition(partial.completedPayloadBytes == 100)

        let incomplete = TBCableTestTransfer(expectedBytes: 200)
        let one = try incomplete.reserve(payloadBytes: 100)
        incomplete.complete(one, error: nil)
        do { _ = try incomplete.finish(); preconditionFailure("partial submission accepted") }
        catch TBCableTestError.incomplete(let count, let expected) { precondition(count == 100 && expected == 200) }

        let overall = TBCableTestTransfer(expectedBytes: 1000, maximumInFlight: 1, timeout: 0.03, stallTimeout: 1)
        let ticket = try overall.reserve(payloadBytes: 100)
        Thread.sleep(forTimeInterval: 0.04)
        overall.complete(ticket, error: nil) // progress must not extend the overall deadline
        expectTimeout({ _ = try overall.reserve(payloadBytes: 100) }, completed: 100, expected: 1000)

        let failing = TBCableTestTransfer(expectedBytes: 200)
        let failed = try failing.reserve(payloadBytes: 100)
        failing.complete(failed, error: NSError(domain: "fixture", code: 42))
        do { _ = try failing.reserve(payloadBytes: 100); preconditionFailure("send error ignored") }
        catch { precondition((error as NSError).domain == "fixture" && (error as NSError).code == 42) }
        precondition(failing.completedPayloadBytes == 0)

        let cancelled = TBCableTestTransfer(expectedBytes: 200, maximumInFlight: 1)
        let oldTicket = try cancelled.reserve(payloadBytes: 100)
        let entered = DispatchSemaphore(value: 0), returned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            entered.signal()
            do { _ = try cancelled.reserve(payloadBytes: 100); preconditionFailure("cancel ignored") }
            catch { precondition(error is CancellationError) }
            returned.signal()
        }
        precondition(entered.wait(timeout: .now() + 1) == .success)
        cancelled.cancel()
        precondition(returned.wait(timeout: .now() + 1) == .success)
        let replacement = TBCableTestTransfer(expectedBytes: 100)
        let newTicket = try replacement.reserve(payloadBytes: 100)
        cancelled.complete(oldTicket, error: nil)
        precondition(replacement.completedPayloadBytes == 0)
        replacement.complete(newTicket, error: nil)
        let replacementResult = try replacement.finish()
        precondition(replacementResult.completedPayloadBytes == 100)
    }
    @MainActor
    static func main() async throws {
        try stateTests()
        let connection = NWConnection()
        let session = Session(connection)
        session.setupForTest()
        session.tryControlPacket()
        precondition(session.commands.isEmpty && connection.counts.controls == 0)
        session.isCableTestConnection = false
        session.setupForTest()
        precondition(session.commands == ["hello", "input", "brightness", "volume"])
        precondition(connection.counts.controls == 4)
        session.isCableTestConnection = true
        let rate = try await session.run()
        precondition(rate.isFinite && rate > 0 && connection.counts.sent == 5000)
        precondition(session.cableTestTransfer == nil)
        connection.assertOwnedPacket()

        let errorConnection = NWConnection(.error)
        do { _ = try await Session(errorConnection).run(); preconditionFailure("send failure succeeded") }
        catch { precondition((error as NSError).domain == "test.send") }
        precondition(errorConnection.counts.sent == 1 && errorConnection.counts.cancellations > 0)

        let blockedConnection = NWConnection(.held)
        let blockedSession = Session(blockedConnection)
        let task = Task { try await blockedSession.run() }
        let waitDeadline = ProcessInfo.processInfo.systemUptime + 2
        while blockedConnection.counts.sent < 8 && ProcessInfo.processInfo.systemUptime < waitDeadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        precondition(blockedConnection.counts.sent == 8)
        task.cancel()
        do { _ = try await task.value; preconditionFailure("cancelled task succeeded") }
        catch { precondition(error is CancellationError) }
        precondition(blockedSession.cableTestTransfer == nil && blockedConnection.counts.cancellations > 0)
        blockedConnection.completeHeld() // safe even after cancellation/resumption
        print("PASS production cable test: owned/reused DispatchData, 5000 sends, slot/tail/overall deadlines, actual completed bytes, send errors, cancellation, late callbacks, isolated handshake")
    }
}
SWIFT

Dir.mktmpdir('tb-cable-test.') do |dir|
  file = File.join(dir, 'main.swift')
  File.write(file, "import Foundation\nimport Dispatch\n" + state + fixture + packet + connection + setup + send_packet + transfer + tests)
  abort 'compile failed' unless system('swiftc', '-parse-as-library', '-module-cache-path', File.join(dir, 'cache'), file, '-o', File.join(dir, 'test'))
  abort 'tests failed' unless system(File.join(dir, 'test'))
end
