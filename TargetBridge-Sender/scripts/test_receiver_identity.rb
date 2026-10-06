#!/usr/bin/env ruby
# macOS + full Xcode/XCTest. No app is launched and no capture/input permission
# is requested. Extract pure production code; do not duplicate its logic here.
require 'tmpdir'
require 'fileutils'
root = File.expand_path('..', __dir__)
def section(source, first, last)
  start = source.index(first) or abort "Missing section: #{first}"
  stop = source.index(last, start) or abort "Missing boundary: #{last}"
  source[start...stop]
end
Dir.mktmpdir('tb-receiver-identity.') do |dir|
  sources = File.join(dir, 'Sources/TargetBridge')
  tests = File.join(dir, 'Tests/TargetBridgeTests')
  FileUtils.mkdir_p([sources, tests])
  discovery = File.read(File.join(root, 'TBDisplaySender/TBReceiverDiscovery.swift'))
  model = section(discovery, 'import Foundation', 'final class TBReceiverDiscovery:')
  manager = File.read(File.join(root, 'TBDisplaySender/TBDisplaySenderManager.swift'))
  transport = section(manager, 'enum TBTransportKind:', '    func title(') + "}\n"
  automation = File.read(File.join(root, 'TBDisplaySender/TBDisplaySenderAutomation.swift'))
  selectors = section(automation, '    static func automaticReceiver(', '    private static func selectConnectionPath(')
  matching = section(automation, '    static func matches(', '    static func parseTransport(')
  File.write(File.join(sources, 'Identity.swift'), model + transport +
    "\nenum TBSenderAutomation {\n" + selectors + matching + "}\n")
  FileUtils.cp(File.join(root, 'TBDisplaySenderTests/TBReceiverDiscoveryModelTests.swift'), tests)
  parsing = File.read(File.join(root, 'TBDisplaySenderTests/TBSenderAutomationParsingTests.swift'))
  cases = section(parsing, '    private func makeReceiver()', '    func testNoSessionParamTargetsAllSessionsWhenNotCreating()')
  File.write(File.join(tests, 'SelectionTests.swift'),
    "import XCTest\n@testable import TargetBridge\nfinal class SelectionTests: XCTestCase {\n" + cases + "}\n")
  File.write(File.join(dir, 'Package.swift'), <<~'SWIFT')
    // swift-tools-version: 5.9
    import PackageDescription
    let package = Package(name: "ReceiverIdentityTests", platforms: [.macOS(.v14)],
      targets: [.target(name: "TargetBridge"),
                .testTarget(name: "TargetBridgeTests", dependencies: ["TargetBridge"])])
  SWIFT
  abort 'Identity/selection tests failed' unless system('swift', 'test', '--package-path', dir,
    '--scratch-path', File.join(dir, 'build'), '--cache-path', File.join(dir, 'cache'),
    '--config-path', File.join(dir, 'config'), '--security-path', File.join(dir, 'security'),
    '--disable-sandbox')

  # Exercise the exact persistence function in a unique disposable preferences
  # domain, never com.targetbridge.receiver or the running app's preferences.
  main = File.read(File.join(root, '../TargetBridge-Receiver/TBReceiverC/src/main.c'))
  persist = section(main, 'static int tb_receiver_load_or_create_id(', 'static void on_bonjour_register(')
  harness = <<~'C'
    #include <CoreFoundation/CoreFoundation.h>
    #include <assert.h>
    #include <stdbool.h>
    #include <stdio.h>
    #include <string.h>
    #include <unistd.h>
  C
  harness += persist
  harness += <<~'C'
    int main(void) {
      CFStringRef domain = CFStringCreateWithFormat(NULL, NULL,
        CFSTR("org.targetbridge.tests.identity.%d"), getpid());
      char first[64], second[64];
      assert(tb_receiver_load_or_create_id(first, sizeof(first), domain) == 0);
      assert(strlen(first) == 36);
      assert(tb_receiver_load_or_create_id(second, sizeof(second), domain) == 0);
      assert(strcmp(first, second) == 0);
      CFPreferencesSetAppValue(CFSTR("receiverID"), CFSTR("not-a-uuid"), domain);
      assert(tb_receiver_load_or_create_id(second, sizeof(second), domain) == 0);
      assert(strlen(second) == 36 && strcmp(first, second) != 0);
      CFPreferencesSetAppValue(CFSTR("receiverID"), kCFBooleanTrue, domain);
      assert(tb_receiver_load_or_create_id(first, sizeof(first), domain) == 0);
      assert(strlen(first) == 36);
      CFPreferencesSetAppValue(CFSTR("receiverID"),
        CFSTR("a4e28721-22a7-42a9-89d7-70f3dbb0e906"), domain);
      assert(tb_receiver_load_or_create_id(first, sizeof(first), domain) == 0);
      assert(strcmp(first, "A4E28721-22A7-42A9-89D7-70F3DBB0E906") == 0);
      assert(tb_receiver_load_or_create_id(second, 2, domain) == -1 && second[0] == 0);
      assert(tb_receiver_load_or_create_id(NULL, 64, domain) == -1);
      assert(tb_receiver_load_or_create_id(second, sizeof(second), NULL) == -1);
      CFPreferencesSetAppValue(CFSTR("receiverID"), NULL, domain);
      assert(CFPreferencesAppSynchronize(domain));
      CFRelease(domain);
      puts("PASS: Receiver UUID creation, persistence, normalization, malformed/type recovery and argument guards");
    }
  C
  c_path = File.join(dir, 'identity.c')
  binary = File.join(dir, 'identity-test')
  File.write(c_path, harness)
  abort 'Persistence test build failed' unless system('xcrun', 'clang', '-Wall', '-Wextra', '-Werror',
    c_path, '-framework', 'CoreFoundation', '-o', binary)
  abort 'Persistence test failed' unless system(binary)
end
