require 'digest'
require 'fileutils'
require 'json'
require 'open3'

root = File.expand_path('..', __dir__)
out = File.expand_path(ARGV.fetch(0, 'build/release/v3.6.1-rc.2-final'), root)
version = ARGV.fetch(1, '3.6.1-rc.2')
build = ARGV.fetch(2, '20261109180000')
verification_id = ARGV.fetch(3, version)
commit, commit_status = Open3.capture2('git', '-C', root, 'rev-parse', 'HEAD')
abort 'Cannot identify release source' unless commit_status.success?
checks = []
%w[arm64 x86_64].product(%w[Sender Receiver]).each do |arch, role|
  name = role == 'Sender' ? "TargetBridge-#{arch}.app.zip" : "TargetBridge-Receiver-#{arch}.app.zip"
  zip = File.join(out, name)
  dest = File.join(root, 'review-results/archive-verification', verification_id, arch, role)
  abort "Refusing to reuse verification directory #{dest}" if File.exist?(dest)
  FileUtils.mkdir_p(dest)
  system('unzip', '-tq', zip, exception: true)
  system('ditto', '-x', '-k', zip, dest, exception: true)
  app = File.join(dest, role == 'Sender' ? 'TargetBridge.app' : 'TargetBridge Receiver.app')
  plist = File.join(app, 'Contents/Info.plist')
  metadata = JSON.parse(Open3.capture2('plutil', '-convert', 'json', '-o', '-', plist).first)
  abort 'Incorrect version/build stamp' unless metadata['CFBundleShortVersionString'] == version && metadata['CFBundleVersion'] == build
  binary = File.join(app, 'Contents/MacOS', metadata.fetch('CFBundleExecutable'))
  actual, status = Open3.capture2('lipo', binary, '-archs')
  abort "Wrong architecture for #{name}: #{actual}" unless status.success? && actual.strip == arch
  system('codesign', '--verify', '--deep', '--strict', '--all-architectures', app, exception: true)
  signature, signature_status = Open3.capture2e('codesign', '-dv', app)
  abort 'Expected explicitly approved ad-hoc signature' unless signature_status.success? && signature.include?('Signature=adhoc')
  languages = role == 'Sender' ? 'Contents/Resources' : 'Contents/Resources/Languages'
  %w[de en fr it zh].each do |language|
    abort "Missing language #{language}" unless File.file?(File.join(app, languages, "#{language}.json"))
  end
  abort 'Development scripts in app resources' if Dir[File.join(app, 'Contents/Resources/**/*')].any? { |path| path.match?(/\.(sh|rb|py)$/) }
  machos = [binary, *Dir[File.join(app, 'Contents/Frameworks/*.dylib')]]
  dependencies, status = Open3.capture2('otool', '-L', *machos)
  abort 'Dependency inspection failed' unless status.success?
  abort "External Homebrew runtime in #{name}" if dependencies.match?(/^\s+\/(usr\/local|opt\/homebrew)\//)
  checks << {file: name, sha256: Digest::SHA256.file(zip).hexdigest, bytes: File.size(zip),
    architecture: arch, minimum_macos: metadata['LSMinimumSystemVersion'],
    version: metadata['CFBundleShortVersionString'], build: metadata['CFBundleVersion'],
    source_commit: commit.strip,
    signature: 'ad-hoc; not notarized; no permission-continuity certification'}
end
File.write(File.join(out, 'SHA256SUMS'), checks.map { |c| "#{c[:sha256]}  #{c[:file]}\n" }.join)
File.write(File.join(out, 'package-manifest.json'), JSON.pretty_generate(checks) + "\n")
puts JSON.pretty_generate(checks)
