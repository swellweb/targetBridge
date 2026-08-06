import AppKit

private enum InstallRole: String {
    case receiver
    case sender

    static var current: InstallRole {
        #if arch(x86_64)
        return .receiver
        #else
        return .sender
        #endif
    }

    var deviceTitle: String {
        switch self {
        case .receiver: return "iMac — schermo TargetBridge"
        case .sender: return "Mac mini — trasmettitore TargetBridge"
        }
    }

    var detail: String {
        switch self {
        case .receiver:
            return "Installerò il ricevitore e l’avvio automatico su questo iMac."
        case .sender:
            return "Installerò il trasmettitore e l’avvio automatico su questo Mac mini."
        }
    }
}

@main
final class TargetBridgeInstallerApp: NSObject, NSApplicationDelegate {
    private let role = InstallRole.current
    private var window: NSWindow!
    private var statusLabel: NSTextField!
    private var progress: NSProgressIndicator!
    private var installButton: NSButton!
    private var verifyButton: NSButton!

    static func main() {
        let application = NSApplication.shared
        let delegate = TargetBridgeInstallerApp()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 430),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "TargetBridge Installer"
        window.center()
        window.isReleasedWhenClosed = false

        let background = NSVisualEffectView()
        background.material = .sidebar
        background.blendingMode = .behindWindow
        background.state = .active
        background.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = background

        let icon = NSImageView()
        icon.image = NSApplication.shared.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "TargetBridge")
        title.font = .systemFont(ofSize: 30, weight: .bold)
        title.textColor = .labelColor
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(labelWithString: "Configurazione automatica modalità monitor")
        subtitle.font = .systemFont(ofSize: 15, weight: .regular)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        let deviceCard = NSBox()
        deviceCard.boxType = .custom
        deviceCard.cornerRadius = 14
        deviceCard.fillColor = NSColor.controlBackgroundColor.withAlphaComponent(0.82)
        deviceCard.borderColor = NSColor.separatorColor.withAlphaComponent(0.55)
        deviceCard.borderWidth = 1
        deviceCard.translatesAutoresizingMaskIntoConstraints = false

        let deviceTitle = NSTextField(labelWithString: role.deviceTitle)
        deviceTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        deviceTitle.textColor = .labelColor
        deviceTitle.translatesAutoresizingMaskIntoConstraints = false

        let deviceDetail = NSTextField(wrappingLabelWithString: role.detail)
        deviceDetail.font = .systemFont(ofSize: 13)
        deviceDetail.textColor = .secondaryLabelColor
        deviceDetail.maximumNumberOfLines = 2
        deviceDetail.translatesAutoresizingMaskIntoConstraints = false

        deviceCard.contentView?.addSubview(deviceTitle)
        deviceCard.contentView?.addSubview(deviceDetail)

        progress = NSProgressIndicator()
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.translatesAutoresizingMaskIntoConstraints = false

        statusLabel = NSTextField(wrappingLabelWithString: "Pronto. Puoi installare oppure controllare la configurazione attuale.")
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.maximumNumberOfLines = 3
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        installButton = NSButton(title: "Installa / aggiorna", target: self, action: #selector(installPressed))
        installButton.bezelStyle = .rounded
        installButton.controlSize = .large
        installButton.keyEquivalent = "\r"
        installButton.translatesAutoresizingMaskIntoConstraints = false

        verifyButton = NSButton(title: "Verifica", target: self, action: #selector(verifyPressed))
        verifyButton.bezelStyle = .rounded
        verifyButton.controlSize = .large
        verifyButton.translatesAutoresizingMaskIntoConstraints = false

        let closeButton = NSButton(title: "Chiudi", target: self, action: #selector(closePressed))
        closeButton.bezelStyle = .rounded
        closeButton.controlSize = .large
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        [icon, title, subtitle, deviceCard, progress, statusLabel,
         installButton, verifyButton, closeButton].forEach(background.addSubview)

        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: background.topAnchor, constant: 24),
            icon.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64),

            title.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 8),
            title.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 36),
            title.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -36),

            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),

            deviceCard.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 22),
            deviceCard.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 54),
            deviceCard.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -54),
            deviceCard.heightAnchor.constraint(equalToConstant: 82),

            deviceTitle.topAnchor.constraint(equalTo: deviceCard.contentView!.topAnchor, constant: 15),
            deviceTitle.leadingAnchor.constraint(equalTo: deviceCard.contentView!.leadingAnchor, constant: 18),
            deviceTitle.trailingAnchor.constraint(equalTo: deviceCard.contentView!.trailingAnchor, constant: -18),
            deviceDetail.topAnchor.constraint(equalTo: deviceTitle.bottomAnchor, constant: 5),
            deviceDetail.leadingAnchor.constraint(equalTo: deviceTitle.leadingAnchor),
            deviceDetail.trailingAnchor.constraint(equalTo: deviceTitle.trailingAnchor),

            progress.topAnchor.constraint(equalTo: deviceCard.bottomAnchor, constant: 18),
            progress.centerXAnchor.constraint(equalTo: background.centerXAnchor),

            statusLabel.topAnchor.constraint(equalTo: progress.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 54),
            statusLabel.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -54),
            statusLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 38),

            installButton.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -28),
            installButton.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 54),
            installButton.widthAnchor.constraint(equalToConstant: 215),
            installButton.heightAnchor.constraint(equalToConstant: 40),

            verifyButton.centerYAnchor.constraint(equalTo: installButton.centerYAnchor),
            verifyButton.leadingAnchor.constraint(equalTo: installButton.trailingAnchor, constant: 12),
            verifyButton.widthAnchor.constraint(equalToConstant: 125),
            verifyButton.heightAnchor.constraint(equalToConstant: 40),

            closeButton.centerYAnchor.constraint(equalTo: installButton.centerYAnchor),
            closeButton.leadingAnchor.constraint(equalTo: verifyButton.trailingAnchor, constant: 12),
            closeButton.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -54),
            closeButton.heightAnchor.constraint(equalToConstant: 40)
        ])
    }

    @objc private func installPressed() {
        runIntegratedTool(action: "install")
    }

    @objc private func verifyPressed() {
        runIntegratedTool(action: "verify")
    }

    @objc private func closePressed() {
        window.close()
    }

    private func setBusy(_ busy: Bool, message: String) {
        installButton.isEnabled = !busy
        verifyButton.isEnabled = !busy
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = message
        busy ? progress.startAnimation(nil) : progress.stopAnimation(nil)
    }

    private func runIntegratedTool(action: String) {
        guard let script = Bundle.main.path(forResource: "install-targetbridge", ofType: "zsh", inDirectory: "Support") else {
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = "Il componente di installazione non è presente. Usa una copia integra dell’app."
            return
        }

        setBusy(true, message: action == "verify" ? "Controllo in corso…" : "Installazione in corso…")
        let roleValue = role.rawValue

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [script, action]
            process.standardOutput = output
            process.standardError = output
            var environment = ProcessInfo.processInfo.environment
            environment["TB_INSTALL_ROLE"] = roleValue
            process.environment = environment

            var launchError: Error?
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                launchError = error
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let result = String(data: data, encoding: .utf8) ?? ""
            let success = launchError == nil && process.terminationStatus == 0

            DispatchQueue.main.async {
                guard let self else { return }
                self.setBusy(false, message: "")
                if success {
                    self.statusLabel.textColor = .systemGreen
                    self.statusLabel.stringValue = action == "verify"
                        ? "Configurazione verificata: tutto è pronto."
                        : "Installazione completata. TargetBridge è attivo e partirà automaticamente."
                } else {
                    self.statusLabel.textColor = .systemRed
                    let detail = launchError?.localizedDescription ?? self.friendlyError(from: result)
                    self.statusLabel.stringValue = "Operazione non completata: \(detail)"
                }
                self.appendLog(action: action, success: success, output: result)
            }
        }
    }

    private func friendlyError(from output: String) -> String {
        if output.contains("PERMISSION") { return "non ho il permesso di scrivere nella cartella Applicazioni." }
        if output.contains("ARCHIVE_HASH") { return "il pacchetto risulta danneggiato." }
        if output.contains("SIGNATURE") { return "la firma dell’app non è valida." }
        if output.contains("ARCHITECTURE") { return "questa copia non è adatta al Mac in uso." }
        if output.contains("NOT_RUNNING") { return "l’app è installata ma non è riuscita ad avviarsi." }
        if let last = output.split(separator: "\n").last, !last.isEmpty {
            return String(last)
        }
        return "errore sconosciuto. Consulta il registro TargetBridge Installer."
    }

    private func appendLog(action: String, success: Bool, output: String) {
        let logs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let logURL = logs.appendingPathComponent("TargetBridge Installer.log")
        let entry = "\n[\(ISO8601DateFormatter().string(from: Date()))] \(action) role=\(role.rawValue) success=\(success)\n\(output)"
        guard let data = entry.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logURL, options: .atomic)
        }
    }
}
