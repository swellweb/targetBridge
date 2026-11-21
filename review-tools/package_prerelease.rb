require 'fileutils'
require 'open3'

root = File.expand_path('..', __dir__)
out = File.expand_path(ARGV.fetch(0, 'build/release/v3.6.1-rc.2'), root)
FileUtils.mkdir_p(out)
env = {'TARGETBRIDGE_CODESIGN_IDENTITY' => '-', 'TARGETBRIDGE_ALLOW_ADHOC' => '1'}
%w[arm64 x86_64].each do |arch|
  app = File.join(out, arch, 'TargetBridge.app')
  abort "Refusing to overwrite #{app}" if File.exist?(app)
  system('ditto', File.join(root, 'build/TargetBridge.app'), app, exception: true)
  binary = File.join(app, 'Contents/MacOS/TargetBridge')
  system('lipo', binary, '-thin', arch, '-output', binary + '.thin', exception: true)
  File.rename(binary + '.thin', binary)
  system(env, 'zsh', File.join(root, 'TargetBridge-Sender/scripts/sign_targetbridge_sender_app.sh'), app, exception: true)
  system('lipo', binary, '-verify_arch', arch, exception: true)
  if arch == `uname -m`.strip
    system('ruby', File.join(root, 'TargetBridge-Sender/scripts/test_permission_status.rb'), 'sender', binary, exception: true)
  else
    puts "#{arch} runtime probe must run on a native Mac, not this host's Rosetta runtime."
  end
  resources = Dir[File.join(app, 'Contents/Resources/**/*')]
  abort 'Development script in Sender resources' if resources.any? { |p| p.end_with?('.sh', '.rb', '.py') }
  %w[de en fr it zh].each { |lang| abort "Missing #{lang}.json" unless resources.any? { |p| p.end_with?("/#{lang}.json") } }
  system('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', app,
    File.join(out, "TargetBridge-#{arch}.app.zip"), exception: true)
end
receiver = File.join(root, 'build/TargetBridge Receiver.app')
system('codesign', '--verify', '--deep', '--strict', '--all-architectures', receiver, exception: true)
system('ruby', File.join(root, 'TargetBridge-Sender/scripts/test_permission_status.rb'), 'receiver',
  File.join(receiver, 'Contents/MacOS/TargetBridgeReceiver'), exception: true)
system('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', receiver,
  File.join(out, 'TargetBridge-Receiver-arm64.app.zip'), exception: true)
puts "Prepared three archives in #{out}; Intel Receiver is built natively on the iMac."
