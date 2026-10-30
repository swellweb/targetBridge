#!/usr/bin/env ruby
# Execute the production asynchronous startup wrapper with controllable delayed
# completions, plus guards at the session integration boundaries. No capture/UI.
require 'tmpdir'
require 'fileutils'
root = File.expand_path('..', __dir__)
source = File.read(File.join(root, 'TBDisplaySender/TBDisplaySenderService.swift'))
tests = File.read(File.join(root, 'TBDisplaySenderTests/TBDisplayProfileTests.swift'))
startup = source[/@MainActor\nenum TBCaptureStartup \{.*?(?=\n\/\/\/ Confined to the video pipeline queue)/m]
startup_tests = tests[/final class TBCaptureStartupTests: XCTestCase \{.*/m]
abort 'missing production startup or async tests' unless startup && startup_tests
profile = source[/private func handleDisplayProfile\(.*?(?=    private func startCapture)/m]
capture = source[/private func startCapture\(.*?(?=    \/\/\/ Waking a headless)/m]
restart = source[/private func softRestartCapture\(.*?(?=    private func handleFirstEncodedFrame)/m]
abort 'profile setup must guard each suspension' unless profile&.scan('isCurrentCaptureAttempt(')&.size == 6
abort 'capture start must publish only a current pipeline' unless capture&.match?(/let started = try await TBCaptureStartup\.start\(.*?self\.pipeline === pipeline.*?discard:.*?stream\.stopCapture.*?guard started else \{ return false \}\s+isStreaming = true/m)
abort 'pending stream must be owned before suspension' unless capture&.match?(/scStream = stream\s+let started = try await TBCaptureStartup\.start/m)
abort 'failed stale capture must not replace the current error state' unless capture&.match?(/catch \{\s+guard isCurrentCaptureAttempt\(generation: generation, connection: connection\) else \{ return false \}/)
abort 'old first-frame callback must be rejected' unless capture&.match?(/onFirstFrame:.*?isCurrentCaptureAttempt.*?handleFirstEncodedFrame/m)
abort 'old audio must not enter a replacement connection' unless capture&.match?(/delegate\.onAudio.*?self\.pipeline === pipeline.*?isCurrentCaptureAttempt.*?connection\.send/m)
abort 'stale restart must not stop a replacement session' unless restart&.match?(/let started = await startCapture\(for: profile\)\s+guard isCurrentCaptureAttempt.*?if !started/m)
abort 'virtual-display destruction must not be deferred past reconnect' if source.include?('currentSession.destroy()')
direct = source[/private func startDirectDisplayStream\(.*?(?=    private func activityOptions)/m]
abort 'direct video must reject a stop during auxiliary audio startup' unless direct&.match?(/await startAuxiliaryAudioCapture.*?guard isCurrentCaptureAttempt.*?self\.directDisplayStream === directCapture.*?directCapture\.stop/m)
abort 'auxiliary audio must own and guard a pending stream' unless direct&.match?(/scStream = stream\s+let started = try await TBCaptureStartup\.start.*?self\.scStream === stream.*?stream\.stopCapture/m)
abort 'old auxiliary audio must not enter a replacement connection' unless direct&.match?(/delegate\.onAudio.*?self\.pipeline === pipeline.*?isCurrentCaptureAttempt.*?connection\.send/m)
schedule = source[/private func scheduleCaptureRestart\(.*?(?=    private func softRestartCapture)/m]
abort 'a cancelled watchdog must keep the current audio callbacks valid' unless schedule&.match?(/if onlyIfUnhealthy.*?return\s+\}.*?captureRestartGeneration &\+= 1/m)
Dir.mktmpdir('tb-capture-startup.') do |dir|
  FileUtils.mkdir_p(File.join(dir, 'Sources/TargetBridge'))
  FileUtils.mkdir_p(File.join(dir, 'Tests/TargetBridgeTests'))
  File.write(File.join(dir, 'Sources/TargetBridge/Startup.swift'), startup)
  File.write(File.join(dir, 'Tests/TargetBridgeTests/StartupTests.swift'), "import XCTest\n@testable import TargetBridge\n" + startup_tests)
  File.write(File.join(dir, 'Package.swift'), <<~'SWIFT')
    // swift-tools-version: 5.9
    import PackageDescription
    let package = Package(name: "CaptureStartupTests", platforms: [.macOS(.v14)],
      targets: [.target(name: "TargetBridge"),
                .testTarget(name: "TargetBridgeTests", dependencies: ["TargetBridge"])])
  SWIFT
  ok = system('swift', 'test', '--package-path', dir,
    '--scratch-path', File.join(dir, 'build'), '--cache-path', File.join(dir, 'cache'),
    '--config-path', File.join(dir, 'config'), '--security-path', File.join(dir, 'security'),
    '--disable-sandbox')
  abort 'Capture startup tests failed' unless ok
end
