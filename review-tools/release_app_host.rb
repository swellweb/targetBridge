require 'fileutils'
require 'open3'
require 'shellwords'
require 'timeout'

root = File.expand_path('..', __dir__)
out = File.join(root, 'review-results/app-host-rc2')
FileUtils.mkdir_p(out)
backup = File.join(out, 'sender-before.plist')
helper = File.join(__dir__, 'release_preferences.swift')
installed = '/Applications/TargetBridge.app/Contents/MacOS/TargetBridge'
derived = File.join(root, 'TargetBridge-Sender/.build/Release361')
host = File.join(derived, 'Build/Products/Debug/TargetBridge.app/Contents/MacOS/TargetBridge')
lines = IO.popen(['pgrep', '-alf', "^#{Regexp.escape(installed)}( |$)"], &:read).lines
abort 'Expected one installed Sender session' unless lines.length == 1
pid, command = lines.first.split(' ', 2)
original_args = Shellwords.split(command).drop(1)
code = 1
begin
  Process.kill('TERM', Integer(pid))
  sleep 2
  system('xcrun', 'swift', helper, 'snapshot', backup, exception: true)
  system('xcrun', 'swift', helper, 'prepare', backup, exception: true)
  File.open(File.join(out, 'tests.log'), 'w') do |log|
    child = Process.spawn('xcodebuild', '-project', 'TargetBridge.xcodeproj', '-scheme', 'TBDisplaySender',
      '-destination', 'platform=macOS', '-derivedDataPath', derived,
      '-resultBundlePath', File.join(out, 'results.xcresult'), 'CODE_SIGNING_ALLOWED=NO',
      'test-without-building', chdir: File.join(root, 'TargetBridge-Sender'), out: log, err: log)
    begin
      _, status = Timeout.timeout(240) { Process.wait2(child) }
      code = status.exitstatus || 1
    rescue Timeout::Error
      Process.kill('TERM', child) rescue Errno::ESRCH
      Process.wait(child) rescue Errno::ECHILD
    end
  end
ensure
  system('pkill', '-TERM', '-f', "^#{Regexp.escape(host)}( |$)")
  if File.exist?(backup)
    system('xcrun', 'swift', helper, 'restore', backup, exception: true)
  end
  system('open', '-a', '/Applications/TargetBridge.app', '--args', *original_args, exception: true)
  sleep 3
  if File.exist?(backup)
    system('xcrun', 'swift', helper, 'restore', backup, exception: true)
    system('xcrun', 'swift', helper, 'verify', backup, exception: true)
  end
end
puts "App-host test exit=#{code}"
exit code
