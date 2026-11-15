require 'fileutils'
require 'open3'

root = File.expand_path('..', __dir__)
out = File.join(root, 'review-results', ARGV.fetch(0, 'frame-pacing'))
FileUtils.mkdir_p(out)
relative = 'TargetBridge-Sender/TBDisplaySender/TBDisplaySenderService.swift'
source = File.read(File.join(root, relative))
if ARGV[1]
  source, error, status = Open3.capture3('git', '-C', root, 'show', "#{ARGV[1]}:#{relative}")
  abort error unless status.success?
end
pacer = source[/struct TBFrameRatePacer \{.*?(?=\nenum TBDisplayCodecPreference)/m]
pacer ||= File.read(File.join(root, 'TargetBridge-Sender/TBDisplaySender/TBFrameRatePacer.swift'))
fixture = <<~SWIFT
  import CoreMedia
  import Foundation
  #{pacer}
  func measure(target: Int, source: Int, jitter: Double, random: Bool = false) {
      var pacer = TBFrameRatePacer(maximumFrameRate: target)
      let frames = source * 20
      var emitted = 0
      var seed: UInt64 = 23
      for i in 0..<frames {
          seed = seed &* 6364136223846793005 &+ 1
          let variation = random ? (Double(seed % 2001) / 1000 - 1) * jitter : (i % 2 == 0 ? jitter : -jitter)
          let pts = Double(i) / Double(source) + variation
          if pacer.shouldEmit(presentationTime: CMTime(seconds: pts, preferredTimescale: 1_000_000)) {
              emitted += 1
          }
      }
      print(["target=" + String(target), "source=" + String(source),
             "jitter_ms=" + String(jitter * 1000), "emitted=" + String(emitted) + "/" + String(frames),
             "fps=" + String(Double(emitted) / 20), "random=" + String(random)].joined(separator: " "))
  }
  for rate in [30, 48, 60] {
      for jitter in [0.0, 0.0005, 0.001, 0.002] { measure(target: rate, source: rate, jitter: jitter) }
  }
  measure(target: 48, source: 60, jitter: 0)
  measure(target: 48, source: 120, jitter: 0)
  measure(target: 60, source: 75, jitter: 0)
  for input in [48, 60, 75, 120] { measure(target: 48, source: input, jitter: 0.002, random: true) }
SWIFT
generated = File.join(out, 'Pacer.swift')
File.write(generated, fixture)
binary = File.join(out, 'Pacer')
system('xcrun', 'swiftc', generated, '-o', binary, exception: true)
output, status = Open3.capture2e(binary)
File.write(File.join(out, 'results.log'), output)
puts output
exit status.exitstatus
