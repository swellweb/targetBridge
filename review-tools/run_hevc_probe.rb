require 'fileutils'
require 'json'
require 'open3'
require 'shellwords'

root = File.expand_path('..', __dir__)
out = File.join(root, 'review-results', 'hevc-probe')
FileUtils.mkdir_p(out)
src = File.join(root, 'TargetBridge-Receiver/TBReceiverC/src')
cflags = Shellwords.split(Open3.capture2('pkgconf', '--cflags', 'libavcodec', 'libavutil', 'libswscale').first)
libs = Shellwords.split(Open3.capture2('pkgconf', '--libs', 'libavcodec', 'libavutil', 'libswscale').first)
cases = {
  'native' => [],
  'no-hardware' => ['-DTB_TEST_NO_HEVC_HW', '-DVTIsHardwareDecodeSupported=tb_probe_hw_support'],
  'no-codec' => ['-DTB_TEST_NO_HEVC_CODEC', '-Davcodec_find_decoder=tb_probe_find_decoder']
}
results = cases.map do |name, defines|
  binary = File.join(out, name)
  command = ['xcrun', 'clang', '-std=c11', '-Wall', '-Wextra', *cflags, *defines,
             '-I', src, File.join(__dir__, 'hevc_probe.c'), File.join(src, 'decoder.c'),
             *libs, '-framework', 'VideoToolbox', '-framework', 'CoreMedia',
             '-framework', 'CoreVideo', '-o', binary]
  output, status = Open3.capture2e(*command)
  abort output unless status.success?
  output, status = Open3.capture2e(binary)
  result = {case: name, output: output.strip, exit_code: status.exitstatus}
  puts JSON.generate(result)
  result
end
File.write(File.join(out, 'results.json'), JSON.pretty_generate(results))
exit(results.all? { |result| result[:exit_code] == 0 } ? 0 : 1)
