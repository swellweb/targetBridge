# Smoke-test either built binary without normal UI startup or permission requests.
require 'tempfile'
require 'timeout'

role, executable = ARGV
abort 'Usage: ruby test_permission_status.rb sender|receiver <executable>' unless
  ARGV.length == 2 && %w[sender receiver].include?(role) && File.executable?(executable)

2.times do
  Tempfile.create('tb-permission-stdout') do |output|
    Tempfile.create('tb-permission-stderr') do |errors|
      pid = Process.spawn(executable, '--permission-status', out: output, err: errors)
      status = nil
      begin
        Timeout.timeout(10) { _, status = Process.wait2(pid) }
      rescue Timeout::Error
        Process.kill('KILL', pid) rescue Errno::ESRCH
        Process.wait(pid) rescue Errno::ECHILD
        abort "#{role}: permission probe did not exit within 10 seconds"
      end
      output.rewind
      errors.rewind
      text = output.read
      abort "#{role}: probe failed: #{errors.read}" unless status.success?
      match = /\ATB_PERMISSION_STATUS:screen_recording=([01]):accessibility=([01]):input_monitoring=([01])\n\z/.match(text)
      abort "#{role}: unexpected probe output: #{text.inspect}" unless match
      abort 'receiver: screen recording must be zero (not applicable)' if role == 'receiver' && match[1] != '0'
    end
  end
end
puts "PASS #{role}: two bounded permission probes returned valid status and exited"
