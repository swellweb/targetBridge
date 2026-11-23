require 'fileutils'
require 'open3'
root = File.expand_path('..', __dir__)
path = File.join(root, 'TargetBridge-Sender/TBDisplaySender/TBDisplaySenderAutomation.swift')
source = File.read(path)
start = source.index("@MainActor\nenum TBSystemSleepGate") or abort 'Missing sleep gate'
gate = source[start..].gsub('ProcessInfo.processInfo.systemUptime', 'FixtureClock.now')
gate = gate.gsub('NSWorkspace.shared.notificationCenter', 'FixtureEvents.center')
fixture = <<~SWIFT
  import AppKit
  import Foundation
  @MainActor enum FixtureClock { static var now: TimeInterval = 100 }
  @MainActor enum FixtureEvents { static let center = NotificationCenter() }
  #{gate}
  @main struct Runner {
      @MainActor static func main() async {
          TBSystemSleepGate.install()
          precondition(!TBSystemSleepGate.isSleeping)
          FixtureEvents.center.post(name: NSWorkspace.willSleepNotification, object: nil)
          precondition(TBSystemSleepGate.isSleeping)
          FixtureClock.now = 219.999
          precondition(TBSystemSleepGate.isSleeping)
          FixtureClock.now = 220
          precondition(!TBSystemSleepGate.isSleeping)
          FixtureClock.now = 300
          FixtureEvents.center.post(name: NSWorkspace.willSleepNotification, object: nil)
          precondition(TBSystemSleepGate.isSleeping)
          FixtureEvents.center.post(name: NSWorkspace.didWakeNotification, object: nil)
          precondition(!TBSystemSleepGate.isSleeping)
          FixtureEvents.center.post(name: NSWorkspace.willSleepNotification, object: nil)
          FixtureEvents.center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
          precondition(!TBSystemSleepGate.isSleeping)
          FixtureEvents.center.post(name: NSWorkspace.willSleepNotification, object: nil)
          let waiting = Task { await TBSystemSleepGate.waitUntilAwake() }
          await Task.yield()
          waiting.cancel()
          await waiting.value
          FixtureEvents.center.post(name: NSWorkspace.didWakeNotification, object: nil)
          await TBSystemSleepGate.waitUntilAwake()
          print("PASS source sleep gate: sleep, wake, screens wake, timeout boundary and cancellation")
      }
  }
SWIFT
out = File.join(root, 'review-results', 'sleep-gate')
FileUtils.mkdir_p(out)
generated = File.join(out, 'Fixture.swift')
File.write(generated, fixture)
binary = File.join(out, 'fixture')
system('xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', generated, '-o', binary, exception: true)
output, status = Open3.capture2e(binary)
File.write(File.join(out, 'results.log'), output)
puts output
abort 'Sleep gate regression failed' unless status.success?
