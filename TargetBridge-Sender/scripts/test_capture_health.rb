#!/usr/bin/env ruby
# Run the actual model and XCTest file without launching the Sender or requesting
# screen/input permissions. The temporary package has no external dependencies.
require 'tmpdir'
require 'fileutils'
root = File.expand_path('..', __dir__)
Dir.mktmpdir('tb-capture-health.') do |dir|
  FileUtils.mkdir_p(File.join(dir, 'Sources/TargetBridge'))
  FileUtils.mkdir_p(File.join(dir, 'Tests/TargetBridgeTests'))
  FileUtils.cp(File.join(root, 'TBDisplaySender/TBCaptureHealth.swift'), File.join(dir, 'Sources/TargetBridge'))
  FileUtils.cp(File.join(root, 'TBDisplaySenderTests/TBCaptureHealthTests.swift'), File.join(dir, 'Tests/TargetBridgeTests'))
  File.write(File.join(dir, 'Package.swift'), <<~'SWIFT')
    // swift-tools-version: 5.9
    import PackageDescription
    let package = Package(name: "CaptureHealthTests", platforms: [.macOS(.v14)],
      targets: [.target(name: "TargetBridge"),
                .testTarget(name: "TargetBridgeTests", dependencies: ["TargetBridge"])])
  SWIFT
  ok = system('swift', 'test', '--package-path', dir,
    '--scratch-path', File.join(dir, 'build'), '--cache-path', File.join(dir, 'cache'),
    '--config-path', File.join(dir, 'config'), '--security-path', File.join(dir, 'security'),
    '--disable-sandbox')
  abort 'Capture health tests failed' unless ok
end
