require 'fileutils'
require 'json'
require 'shellwords'

root = File.expand_path('..', __dir__)
out = File.join(root, 'review-results/hardware-rc2')
FileUtils.mkdir_p(out)
ssh = ['ssh', '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', 'marco@marcos-imac.local']
remote_root = '/Users/marco/TargetBridge-release-361-20261109'
receiver = File.join(remote_root, 'build/TargetBridge Receiver.app/Contents/MacOS/TargetBridgeReceiver')
remote_backup = File.join(remote_root, 'receiver-before-hardware.plist')
sender = File.join(root, 'build/TargetBridge.app/Contents/MacOS/TargetBridge')
backup = File.join(out, 'sender-before.plist')
helper = File.join(__dir__, 'release_preferences.swift')
installed = '/Applications/TargetBridge.app/Contents/MacOS/TargetBridge'
lines = IO.popen(['pgrep', '-alf', "^#{Regexp.escape(installed)}( |$)"], &:read).lines
abort 'Expected one installed Sender session' unless lines.size == 1
pid, command = lines.first.split(' ', 2)
original_args = Shellwords.split(command).drop(1)
results = []
children = []
def stop(pid)
  Process.kill('TERM', pid) rescue Errno::ESRCH
  Process.wait(pid) rescue Errno::ECHILD
end
begin
  Process.kill('TERM', Integer(pid))
  system(*ssh, 'pkill -TERM -f "^/Applications/TargetBridge Receiver.app/Contents/MacOS/TargetBridgeReceiver$"')
  sleep 3
  system('xcrun', 'swift', helper, 'snapshot', backup, exception: true)
  system('xcrun', 'swift', helper, 'prepare', backup, exception: true)
  system(*ssh, "test ! -e #{remote_backup} && defaults export com.targetbridge.receiver #{remote_backup}", exception: true)
  [['extended', '1440p', 60], ['mirror', '5k', 120], ['mirror', '5k', 40]].each_with_index do |(mode, preset, seconds), i|
    receiver_log = File.join(out, "receiver-#{i}.log")
    remote = Process.spawn(*ssh, "exec #{Shellwords.escape(receiver)} --windowed", out: receiver_log, err: [:child, :out])
    children << remote
    sleep 3
    sender_log = File.join(out, "sender-#{i}.log")
    local = Process.spawn(sender, '--connect', '--receiver', '169.254.8.54', '--mode', mode,
      '--preset', preset, '--transport', 'tb', '--local-ip', '169.254.96.173', out: sender_log, err: [:child, :out])
    children << local
    sleep seconds
    alive = Process.waitpid(local, Process::WNOHANG).nil?
    stop(local) if alive
    children.delete(local)
    sleep 2
    stop(remote)
    children.delete(remote)
    system(*ssh, "pkill -TERM -f '^#{Regexp.escape(receiver)} --windowed$'")
    log = File.binread(receiver_log).force_encoding('UTF-8').scrub
    fps = log.scan(/\[main\] (\d+) fps/).flatten.map(&:to_i)
    result = {mode: mode, preset: preset, seconds: seconds, sender_alive: alive,
      connected: log.include?('[main] client connected'), frames_presented: fps.any?(&:positive?),
      fps_buckets: fps, audio_opened: log.include?('SDL audio device opened'),
      decode_errors: log.scan(/\[dec\] (?:send_packet|recv_frame)=[^\n]+/)}
    results << result
    puts JSON.generate(result)
  end
ensure
  children.reverse_each { |child| stop(child) }
  system(*ssh, "pkill -TERM -f '^#{Regexp.escape(receiver)} --windowed$'")
  system('defaults', 'import', 'com.targetbridge.sender', backup) if File.exist?(backup)
  system(*ssh, "test ! -f #{remote_backup} || defaults import com.targetbridge.receiver #{remote_backup}")
  system(*ssh, 'open -a "/Applications/TargetBridge Receiver.app"')
  system('open', '-a', '/Applications/TargetBridge.app', '--args', *original_args)
  sleep 8
  system('defaults', 'import', 'com.targetbridge.sender', backup) if File.exist?(backup)
  system(*ssh, "test ! -f #{remote_backup} || defaults import com.targetbridge.receiver #{remote_backup}")
  system('xcrun', 'swift', helper, 'verify', backup) if File.exist?(backup)
  File.write(File.join(out, 'results.json'), JSON.pretty_generate(results))
end
exit(results.size == 3 && results.all? { |r| r[:sender_alive] && r[:frames_presented] && r[:decode_errors].empty? } ? 0 : 1)
