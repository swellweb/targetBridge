import Foundation

/// Installs the TargetBridge Audio driver embedded in the app. macOS only loads
/// audio drivers from a system folder, so this needs an administrator password.
enum TBAudioDriverInstaller {
    private static let driverName = "TargetBridgeAudio.driver"
    private static let installedPath = "/Library/Audio/Plug-Ins/HAL/\(driverName)"
    private static let restartCoreAudio = "/bin/launchctl kickstart -k system/com.apple.audio.coreaudiod"

    private struct CommandError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static var bundledURL: URL? {
        guard let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent(driverName),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: installedPath)
    }

    static func installCommand(from source: URL) -> String {
        let target = shellQuoted(installedPath)
        return [
            "/bin/mkdir -p /Library/Audio/Plug-Ins/HAL",
            "/bin/rm -rf \(target)",
            "/usr/bin/ditto \(shellQuoted(source.path)) \(target)",
            "/usr/bin/xattr -cr \(target)",
            "/usr/sbin/chown -R root:wheel \(target)",
            restartCoreAudio
        ].joined(separator: " && ")
    }

    static var removeCommand: String {
        "/bin/rm -rf \(shellQuoted(installedPath)) && \(restartCoreAudio)"
    }

    static func runAsAdministrator(_ command: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            try runBlocking(command)
        }.value
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func runBlocking(_ command: String) throws {
        let errorPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "do shell script \(appleScriptQuoted(command)) with administrator privileges"
        ]
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw CommandError(message: message ?? "osascript failed")
        }
    }
}
