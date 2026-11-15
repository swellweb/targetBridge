require 'fileutils'
require 'open3'

root = File.expand_path('..', __dir__)
out = File.join(root, 'review-results', ARGV.fetch(0, 'tcp-latency'))
FileUtils.mkdir_p(out)
relative = 'TargetBridge-Receiver/TBReceiverC/src/net.c'
source = File.join(root, relative)
if ARGV[1] && File.file?(ARGV[1])
  source = ARGV[1]
elsif ARGV[1]
  code, error, status = Open3.capture3('git', '-C', root, 'show', "#{ARGV[1]}:#{relative}")
  abort error unless status.success?
  source = File.join(out, 'net.c')
  File.write(source, code)
end
binary = File.join(out, 'Latency')
definitions = ENV['TB_TEST_KEY_BYTES'] ? ["-DKEY_BYTES=#{Integer(ENV.fetch('TB_TEST_KEY_BYTES'))}"] : []
system('xcrun', 'clang', '-O2', '-Wall', '-Wextra', '-Werror',
  *definitions, '-I', File.join(root, File.dirname(relative)), source,
  File.join(__dir__, 'tcp_latency_fixture.c'), '-framework', 'CoreFoundation',
  '-framework', 'SystemConfiguration', '-o', binary, exception: true)
File.open(File.join(out, 'results.log'), 'w') do |log|
  2.times { system(binary, out: log, err: log, exception: true) }
end
puts File.read(File.join(out, 'results.log'))
