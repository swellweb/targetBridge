require 'open3'
require 'tmpdir'

root = File.expand_path('..', __dir__)
source = File.read(File.join(root, 'TargetBridge-Sender/TBDisplaySender/TBDisplaySenderService.swift'))
method = source[/    static func chooseCodec\([\s\S]*?(?=\n    private func resolvedCodecDecision)/]
abort 'Production chooseCodec not found' unless method
fixture = <<~SWIFT
  import CoreMedia
  enum TBDisplayCodecPreference { case automatic, h264, hevc }
  struct TBDisplayCapturePreset {
      let codecType: CMVideoCodecType
  }
  struct TBDisplayCodecDecision {
      let codecType: CMVideoCodecType
      let usedFallback: Bool
  }
  struct TBDisplaySenderSession {
  #{method}
  }
  let preset = TBDisplayCapturePreset(codecType: kCMVideoCodecType_HEVC)
  var unsupportedSelections = 0
  for preference in [TBDisplayCodecPreference.automatic, .h264, .hevc] {
      let decision = TBDisplaySenderSession.chooseCodec(
          preference: preference, preset: preset, receiverSupportsHEVC: false,
          senderSupportsH264: false, senderSupportsHEVC: true)
      print("receiverHEVC=false senderH264=false senderHEVC=true preference=\\(preference) selected=\\(decision == nil ? "none" : "HEVC")")
      if decision != nil { unsupportedSelections += 1 }
      let software = TBDisplaySenderSession.chooseCodec(
          preference: preference, preset: preset, receiverSupportsHEVC: false,
          senderSupportsH264: false, senderSupportsHEVC: true,
          receiverSupportsHEVCSoftware: true)
      assert(software?.codecType == kCMVideoCodecType_HEVC && software?.usedFallback == true)
  }
  let compatible = TBDisplaySenderSession.chooseCodec(
      preference: .automatic, preset: preset, receiverSupportsHEVC: false,
      senderSupportsH264: true, senderSupportsHEVC: true)
  assert(compatible?.codecType == kCMVideoCodecType_H264)
  let available = TBDisplaySenderSession.chooseCodec(
      preference: .automatic, preset: preset, receiverSupportsHEVC: true,
      senderSupportsH264: false, senderSupportsHEVC: true)
  assert(available?.codecType == kCMVideoCodecType_HEVC)
  print("unsupported selections: \\(unsupportedSelections); H264 and advertised HEVC controls passed")
  exit(unsupportedSelections == 0 ? 0 : 1)
SWIFT
Dir.mktmpdir('targetbridge-codec-review-') do |dir|
  path = File.join(dir, 'probe.swift')
  File.write(path, fixture)
  output, status = Open3.capture2e('xcrun', 'swift', path)
  puts output
  exit status.exitstatus
end
