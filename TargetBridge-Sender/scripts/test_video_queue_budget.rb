# Execute the production policy, plus source guards for both capture paths.
# Synthetic counters only; no display capture, network, credentials or input.
require 'tmpdir'
root = File.expand_path('..', __dir__)
source = File.read(File.join(root, 'TBDisplaySender/TBDisplaySenderService.swift'))
policy = source[/enum TBVideoQueueBudget \{.*?(?=\nenum TBDisplayCapturePreset)/m]
abort 'missing production budget policy' unless policy
abort 'both capture paths must reserve capacity' unless source.scan('if !TBVideoQueueBudget.canEncode(').size == 2
encoded = source[/private func handleEncoded\(.*?(?=    \/\/\/ Raw passthrough)/m]
abort 'encoded frames are still dropped' if encoded.include?('droppedAfterEncodeFrames +=')
tests = <<~'SWIFT'
import Foundation
func admit(_ pending: Int, _ flight: Int, _ limit: Int = 3, _ enc: Int = 2) -> Bool {
    TBVideoQueueBudget.canEncode(pending: pending, inFlight: flight, packetLimit: limit, encodeLimit: enc)
}
precondition(admit(0, 0) && admit(1, 1) && !admit(2, 1) && !admit(0, 2))
precondition(!admit(-1, 0) && !admit(0, -1) && !admit(Int.max, 0))
precondition(admit(0, 0, 0, 0) && !admit(1, 0, 0, 0))
precondition(!admit(64, 0, Int.max, Int.max))
// Explore all legal transitions: capture, encoder success/failure, transport ACK.
// No post-encode discard is needed, including when ACKs are delayed indefinitely.
for limit in 1...12 {
    for enc in 1...12 {
        for pending in 0...limit {
            for flight in 0...(limit - pending) {
                if admit(pending, flight, limit, enc) {
                    precondition(pending + flight + 1 <= limit && flight + 1 <= enc)
                }
                if flight > 0 { precondition((pending + 1) + (flight - 1) <= limit) }
            }
        }
    }
}
print("PASS production video budget: both paths, bounded reservations, delayed ACKs, encode failure, invalid limits; no post-encode discard")
SWIFT
Dir.mktmpdir('tb-video-budget.') do |dir|
  file = File.join(dir, 'main.swift')
  File.write(file, policy + tests)
  abort 'compile failed' unless system('swiftc', '-module-cache-path', File.join(dir, 'cache'), file, '-o', File.join(dir, 'test'))
  abort 'tests failed' unless system(File.join(dir, 'test'))
end
