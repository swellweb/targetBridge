import Foundation

/// Installs and removes the virtual audio driver from inside the app.
///
/// The driver is a HAL plug-in, so it has to live in `/Library/Audio/Plug-Ins/HAL`,
/// which only root can write. Rather than ship a separate installer package and
/// ask people to use a terminal, the app requests that authority through the
/// standard macOS authentication dialog — it is not sandboxed, so it may. Users
/// see one password prompt and nothing else.
///
/// Doing it here rather than in a `.pkg` also buys two things a package cannot:
/// the app can *remove* the driver again, and it can notice that the installed
/// copy is older than the one it ships. That second point matters more than it
/// sounds — a stale driver still loads and still plays audio, so it presents as
/// "the fix I just made did nothing" with no other symptom.
enum TBAudioDriverInstaller {

    static let installedPath = "/Library/Audio/Plug-Ins/HAL/TargetBridge.driver"

    enum Status: Equatable {
        /// The app was built without the driver alongside it.
        case notBundled
        case notInstalled
        case outdated(installed: String, bundled: String)
        case installed(version: String)
    }

    enum InstallError: Error {
        case notBundled
        /// The user dismissed the password prompt; not worth reporting as a failure.
        case cancelled
        case failed(String)
    }

    // MARK: - State

    static var bundledDriverURL: URL? {
        Bundle.main.url(forResource: "TargetBridge", withExtension: "driver")
    }

    private static func version(ofBundleAt url: URL) -> String? {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: plist) else { return nil }
        // Stamped by the driver's build.sh with a hash of its sources, so any
        // change to the driver changes this and a stale install is detectable.
        return dict["CFBundleVersion"] as? String
    }

    static func status() -> Status {
        guard let bundled = bundledDriverURL, let bundledVersion = version(ofBundleAt: bundled) else {
            return .notBundled
        }
        let installed = URL(fileURLWithPath: installedPath)
        guard FileManager.default.fileExists(atPath: installedPath),
              let installedVersion = version(ofBundleAt: installed) else {
            return .notInstalled
        }
        return installedVersion == bundledVersion
            ? .installed(version: installedVersion)
            : .outdated(installed: installedVersion, bundled: bundledVersion)
    }

    // MARK: - Actions

    static func install() throws {
        guard let source = bundledDriverURL else { throw InstallError.notBundled }
        let src = shellQuoted(source.path)
        let dst = shellQuoted(installedPath)

        // Mirrors install.sh. The holder lookup has to happen before the bundle
        // is replaced, while the path still names the inode those processes hold.
        try runPrivileged("""
        HOLDERS=$(/usr/sbin/lsof -t \(dst)/Contents/MacOS/TargetBridge 2>/dev/null || true)
        /bin/rm -rf \(dst) || exit 1
        /usr/bin/ditto \(src) \(dst) || exit 1
        /usr/sbin/chown -R root:wheel \(dst) || exit 1
        if [ -n "$HOLDERS" ]; then /bin/kill $HOLDERS 2>/dev/null || true; fi
        \(restartAudioServer)
        exit 0
        """)
    }

    static func uninstall() throws {
        try runPrivileged("""
        /bin/rm -rf \(shellQuoted(installedPath)) || exit 1
        \(restartAudioServer)
        exit 0
        """)
    }

    /// Recent macOS uses audiomxd; older releases use coreaudiod. The plug-in is
    /// only loaded at startup, so without this the new bundle sits on disk unused.
    private static let restartAudioServer = """
    /usr/bin/killall audiomxd 2>/dev/null || true
    /usr/bin/killall coreaudiod 2>/dev/null || true
    """

    // MARK: - Privileged execution

    /// Quote for /bin/sh. Everything interpolated into the script below is a
    /// path we control, but an app can sit in a directory with a quote or a
    /// space in its name, and this runs as root — so never rely on that.
    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptQuoted(_ text: String) -> String {
        "\"" + text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            + "\""
    }

    private static func runPrivileged(_ script: String) throws {
        // NSAppleScript is not thread-safe and the prompt is UI, so this must be
        // on the main thread.
        assert(Thread.isMainThread, "runPrivileged must be called on the main thread")

        let source = "do shell script \(appleScriptQuoted(script)) with administrator privileges"
        guard let apple = NSAppleScript(source: source) else {
            throw InstallError.failed("could not build the installer script")
        }
        var errorInfo: NSDictionary?
        apple.executeAndReturnError(&errorInfo)
        guard let errorInfo else { return }

        let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
        if code == -128 { throw InstallError.cancelled }   // user dismissed the prompt
        let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "unknown error"
        TBLog.connection.error("audio driver install failed (\(code, privacy: .public)): \(message, privacy: .public)")
        throw InstallError.failed(message)
    }
}
