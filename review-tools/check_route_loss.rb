require 'fileutils'
require 'open3'
root = File.expand_path('..', __dir__)
source = File.read(File.join(root, 'TargetBridge-Sender/TBDisplaySender/TBDisplaySenderService.swift'))
method = source[/    private func connectionViabilityChanged\(_ isViable: Bool\) \{[\s\S]*?\n    \}/]
abort 'Missing production route-loss handler' unless method
fixture = <<~SWIFT
  import Foundation
  import OSLog
  enum TBLog { static let connection = Logger(subsystem: "org.targetbridge.tests", category: "route") }
  @MainActor final class Session {
      var connection: NSObject? = NSObject()
      var routeLossWorkItem: DispatchWorkItem?
      var routeLossGeneration: UInt64 = 0
      var isConnected = true
      var receiverIP = "127.0.0.1"
      var connectInterfaceName: String? = "loopback"
      var stops = 0
      enum Status { case connectionClosed(String) }
      func setStatus(_ status: Status) {}
      func stop(resetStatusTo: Status?) { stops += 1 }
      #{method}
      func queueLossThenRecover(replace: Bool) {
          connectionViabilityChanged(false)
          routeLossWorkItem!.perform()
          if replace { connection = NSObject() }
          connectionViabilityChanged(true)
      }
      func queuePersistentLoss() {
          connectionViabilityChanged(false)
          routeLossWorkItem!.perform()
      }
  }
  @main struct Runner {
      @MainActor static func main() async {
          let recovered = Session(), replaced = Session(), persistent = Session()
          recovered.queueLossThenRecover(replace: false)
          replaced.queueLossThenRecover(replace: true)
          persistent.queuePersistentLoss()
          try? await Task.sleep(nanoseconds: 30_000_000)
          print("recovered=\\(recovered.stops) replaced=\\(replaced.stops) persistent=\\(persistent.stops)")
          let baseline = CommandLine.arguments.contains("--baseline")
          precondition(recovered.stops == (baseline ? 1 : 0))
          precondition(replaced.stops == (baseline ? 1 : 0))
          precondition(persistent.stops == 1)
      }
  }
SWIFT
out = File.join(root, 'review-results', ARGV.include?('--baseline') ? 'route-before' : 'route-after')
FileUtils.mkdir_p(out)
path = File.join(out, 'Fixture.swift')
File.write(path, fixture)
binary = File.join(out, 'fixture')
system('xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', path, '-o', binary, exception: true)
output, status = Open3.capture2e(binary, *ARGV)
File.write(File.join(out, 'results.log'), output)
puts output
abort 'Route-loss regression failed' unless status.success?
