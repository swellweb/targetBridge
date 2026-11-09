require 'fileutils'
require 'json'
require 'shellwords'

root = File.expand_path('..', __dir__)
out = File.join(root, 'review-results', ARGV.fetch(0, 'hardware-rc2'))
FileUtils.mkdir_p(out)
ssh = ['ssh', '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', 'marco@marcos-imac.local']
remote_root = '/Users/marco/TargetBridge-release-361-20261109'
receiver = File.join(remote_root, 'build/TargetBridge Receiver.app/Contents/MacOS/TargetBridgeReceiver')
remote_backup = File.join(remote_root, "receiver-before-#{File.basename(out)}.plist")
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
  system(*ssh, 'pkill -TERM -f "^/Applications/TargetBridge Receiver.app/Contents/MacOS/TargetBridgeReceiver( |$)"')
  sleep 3
  system('xcrun', 'swift', helper, 'snapshot', backup, exception: true)
  system('xcrun', 'swift', helper, 'prepare', backup, exception: true)
  system(*ssh, "test ! -e #{remote_backup} && defaults export com.targetbridge.receiver #{remote_backup}", exception: true)
  cases = [['extended', '1440p', 60], ['mirror', '5k', 120], ['mirror', '5k', 40]]
  cases.each_with_index do |(mode, preset, seconds), i|
    receiver_log = File.join(out, "receiver-#{i}.log")
    remote = Process.spawn(*ssh, '-tt', "exec #{Shellwords.escape(receiver)} --windowed", out: receiver_log, err: [:child, :out])
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
  system('xcrun', 'swift', helper, 'restore', backup) if File.exist?(backup)
  system(*ssh, "test ! -f #{remote_backup} || defaults import com.targetbridge.receiver #{remote_backup}")
  system(*ssh, 'nohup "/Applications/TargetBridge Receiver.app/Contents/MacOS/TargetBridgeReceiver" > /tmp/tb361-restored-receiver.log 2>&1 < /dev/null &')
  restored_pid = Process.spawn(installed, *original_args, out: File.join(out, 'restored-sender.log'), err: [:child, :out])
  Process.detach(restored_pid)
  sleep 8
  system('xcrun', 'swift', helper, 'restore', backup) if File.exist?(backup)
  system(*ssh, "test ! -f #{remote_backup} || defaults import com.targetbridge.receiver #{remote_backup}")
  restored = false
  if File.exist?(backup)
    3.times do
      system('xcrun', 'swift', helper, 'restore', backup, exception: true)
      restored = system('xcrun', 'swift', helper, 'verify', backup)
      break if restored
      sleep 2
    end
  end
  File.write(File.join(out, 'results.json'), JSON.pretty_generate(results))
end
exit(restored && results.size == 3 && results.all? { |r| r[:sender_alive] && r[:frames_presented] && r[:decode_errors].empty? } ? 0 : 1)
