require 'fileutils'
require 'open3'
root = File.expand_path('..', __dir__)
out = File.join(root, 'review-results', ARGV.fetch(0, 'heartbeat-stall'))
FileUtils.mkdir_p(out)
header = File.join(out, 'Bridge.h')
File.write(header, "#include \"#{__dir__}/heartbeat_loopback.h\"\n#include \"#{__dir__}/heartbeat_monitor.h\"\n")
objects = %w[heartbeat_loopback.c heartbeat_monitor.c ../TargetBridge-Receiver/TBReceiverC/src/idle_watchdog.c].map do |relative|
  source = File.expand_path(relative, __dir__)
  object = File.join(out, File.basename(source) + '.o')
  system('cc', '-std=c11', '-c', source, '-o', object, exception: true)
  object
end
binary = File.join(out, 'HeartbeatStall')
helper = File.join(root, 'TargetBridge-Sender/TBDisplaySender/TBHeartbeatTimer.swift')
if ARGV[2]
  code, error, status = Open3.capture3('git', '-C', root, 'show', "#{ARGV[2]}:TargetBridge-Sender/TBDisplaySender/TBHeartbeatTimer.swift")
  abort error unless status.success?
  helper = File.join(out, 'TBHeartbeatTimer.swift')
  File.write(helper, code, encoding: 'UTF-8')
end
code = File.read(helper, encoding: 'UTF-8')
fixture = File.read(File.join(__dir__, 'heartbeat_stall_fixture.swift'), encoding: 'UTF-8')
fixture = fixture.sub('HEARTBEAT_SEQUENCE_ARGUMENT', code.include?('(UInt64) -> Void') ? '_ in' : '')
generated = File.join(out, 'Fixture.swift')
File.write(generated, fixture, encoding: 'UTF-8')
system('xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', '-import-objc-header', header,
  helper, generated, *objects, '-o', binary, exception: true)
File.open(File.join(out, 'results.log'), 'w') do |log|
  system(binary, ARGV.fetch(1, 'healthy'), out: log, err: log, exception: true)
end
puts File.read(File.join(out, 'results.log'))
