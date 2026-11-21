require 'digest'
require 'fileutils'
require 'json'
require 'open3'

root = File.expand_path('..', __dir__)
out = File.join(root, 'build/release/v3.6.1-rc.2-final')
checks = []
%w[arm64 x86_64].product(%w[Sender Receiver]).each do |arch, role|
  name = role == 'Sender' ? "TargetBridge-#{arch}.app.zip" : "TargetBridge-Receiver-#{arch}.app.zip"
  zip = File.join(out, name)
  dest = File.join(root, 'review-results/archive-verification', arch, role)
  FileUtils.mkdir_p(dest)
  system('unzip', '-tq', zip, exception: true)
  system('ditto', '-x', '-k', zip, dest, exception: true)
  app = File.join(dest, role == 'Sender' ? 'TargetBridge.app' : 'TargetBridge Receiver.app')
  plist = File.join(app, 'Contents/Info.plist')
  metadata = JSON.parse(Open3.capture2('plutil', '-convert', 'json', '-o', '-', plist).first)
  abort 'Incorrect prerelease stamp' unless metadata['CFBundleShortVersionString'] == '3.6.1-rc.2' && metadata['CFBundleVersion'] == '20261109180000'
  binary = File.join(app, 'Contents/MacOS', metadata.fetch('CFBundleExecutable'))
  actual, status = Open3.capture2('lipo', binary, '-archs')
  abort "Wrong architecture for #{name}: #{actual}" unless status.success? && actual.strip == arch
  system('codesign', '--verify', '--deep', '--strict', '--all-architectures', app, exception: true)
  machos = [binary, *Dir[File.join(app, 'Contents/Frameworks/*.dylib')]]
  dependencies, status = Open3.capture2('otool', '-L', *machos)
  abort 'Dependency inspection failed' unless status.success?
  abort "External Homebrew runtime in #{name}" if dependencies.match?(/^\s+\/(usr\/local|opt\/homebrew)\//)
  checks << {file: name, sha256: Digest::SHA256.file(zip).hexdigest, bytes: File.size(zip),
    architecture: arch, minimum_macos: metadata['LSMinimumSystemVersion'],
    version: metadata['CFBundleShortVersionString'], build: metadata['CFBundleVersion'],
    signature: 'ad-hoc; not notarized; no permission-continuity certification'}
end
File.write(File.join(out, 'SHA256SUMS'), checks.map { |c| "#{c[:sha256]}  #{c[:file]}\n" }.join)
File.write(File.join(out, 'package-manifest.json'), JSON.pretty_generate(checks) + "\n")
puts JSON.pretty_generate(checks)
