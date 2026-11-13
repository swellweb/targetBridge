require 'fileutils'
require 'open3'

root = File.expand_path('..', __dir__)
out = File.join(root, 'review-results', ARGV.fetch(0, 'heartbeat-modes'))
legacy = ARGV[1] == 'legacy'
FileUtils.mkdir_p(out)
service_path = 'TargetBridge-Sender/TBDisplaySender/TBDisplaySenderService.swift'
service = File.read(File.join(root, service_path), encoding: 'UTF-8')
if ARGV[2]
  service, error, status = Open3.capture3('git', '-C', root, 'show', "#{ARGV[2]}:#{service_path}")
  abort error unless status.success?
  service.force_encoding('UTF-8')
end
method = service[/    private func startHeartbeat\(\) \{.*?(?=\n    private func startFirstFrameWatchdog)/m]
abort 'Production heartbeat method not found' unless method
fixture = File.read(File.join(__dir__, 'heartbeat_mode_fixture.swift'), encoding: 'UTF-8')
fixture = fixture.sub('/* PRODUCTION_HEARTBEAT_METHOD */', method.sub('private func', 'func'))
fixture = fixture.sub('HEARTBEAT_TIMER_TYPE', method.include?('guard let connection') ? 'TBHeartbeatTimer' : 'Timer')
receiver = File.read(File.join(root, 'TargetBridge-Receiver/TBReceiverC/src/main.c'), encoding: 'UTF-8')
timeout = receiver[/^#define TB_SENDER_IDLE_TIMEOUT_MS\s+(\d+)$/, 1]
abort 'Receiver watchdog constant not found' unless timeout
fixture = fixture.gsub('RECEIVER_TIMEOUT_MS', timeout)
generated = File.join(out, 'HeartbeatFixture.swift')
File.write(generated, fixture, encoding: 'UTF-8')
objects = %w[heartbeat_loopback.c heartbeat_monitor.c ../TargetBridge-Receiver/TBReceiverC/src/idle_watchdog.c].map do |relative|
  source = File.expand_path(relative, __dir__)
  object = File.join(out, File.basename(source) + '.o')
  system('cc', '-std=c11', '-c', source, '-o', object, exception: true)
  object
end
helper = File.join(root, 'TargetBridge-Sender/TBDisplaySender/TBHeartbeatTimer.swift')
sources = File.exist?(helper) ? [helper] : []
if ARGV[2]
  code, _, status = Open3.capture3('git', '-C', root, 'show', "#{ARGV[2]}:TargetBridge-Sender/TBDisplaySender/TBHeartbeatTimer.swift")
  sources = []
  if status.success?
    old_helper = File.join(out, 'TBHeartbeatTimer.swift')
    File.write(old_helper, code, encoding: 'UTF-8')
    sources = [old_helper]
  end
end
header = File.join(out, 'Bridge.h')
File.write(header, "#include \"#{__dir__}/heartbeat_loopback.h\"\n#include \"#{__dir__}/heartbeat_monitor.h\"\n")
binary = File.join(out, 'HeartbeatFixture')
system('xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library',
  '-import-objc-header', header, *sources, generated,
  File.join(__dir__, 'heartbeat_transport_fixture.swift'), *objects, '-o', binary, exception: true)
modes = legacy ? %w[tracking modal] : ARGV[1] == 'soak' ? %w[default] : %w[default tracking modal]
File.open(File.join(out, 'results.log'), 'w') do |log|
  modes.each do |mode|
    expected = legacy ? 'expired' : 'healthy'
    system(binary, mode, expected, out: log, err: log, exception: true)
  end
end
puts File.read(File.join(out, 'results.log'))
