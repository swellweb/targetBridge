require 'fileutils'
require 'open3'

abort 'Explicit stable ad-hoc approval is required' unless ENV['TARGETBRIDGE_APPROVED_STABLE_ADHOC'] == '1'
root = File.expand_path('..', __dir__)
out = File.expand_path(ARGV.fetch(0), root)
role = ARGV.fetch(1)
abort 'Expected sender or receiver' unless %w[sender receiver].include?(role)
env = {'TARGETBRIDGE_CODESIGN_IDENTITY' => '-', 'TARGETBRIDGE_ALLOW_ADHOC' => '1'}
architectures = role == 'sender' ? %w[arm64 x86_64] : [Open3.capture2('uname', '-m').first.strip]
app_name = role == 'sender' ? 'TargetBridge.app' : 'TargetBridge Receiver.app'
FileUtils.mkdir_p(out)
architectures.each do |arch|
  app = File.join(out, arch, app_name)
  zip_name = role == 'sender' ? "TargetBridge-#{arch}.app.zip" : "TargetBridge-Receiver-#{arch}.app.zip"
  zip = File.join(out, zip_name)
  abort "Refusing to overwrite #{app} or #{zip}" if File.exist?(app) || File.exist?(zip)
  system('ditto', File.join(root, 'build', app_name), app, exception: true)
  executable = role == 'sender' ? 'TargetBridge' : 'TargetBridgeReceiver'
  binary = File.join(app, 'Contents/MacOS', executable)
  if role == 'sender'
    system('lipo', binary, '-thin', arch, '-output', binary + '.thin', exception: true)
    File.rename(binary + '.thin', binary)
  end
  script = role == 'sender' ? 'TargetBridge-Sender/scripts/sign_targetbridge_sender_app.sh' :
                            'TargetBridge-Receiver/scripts/sign_targetbridge_receiver_app.sh'
  system(env, 'zsh', File.join(root, script), app, exception: true)
  actual, status = Open3.capture2('lipo', '-archs', binary)
  abort 'Wrong package architecture' unless status.success? && actual.strip == arch
  system('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', app, zip, exception: true)
  puts "Packaged #{zip} (ad-hoc; not notarized)"
end
