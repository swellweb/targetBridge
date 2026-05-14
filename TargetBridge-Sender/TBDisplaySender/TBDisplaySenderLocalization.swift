import Foundation

enum TBDisplaySenderLanguage: String, CaseIterable, Identifiable {
    case italian
    case english

    static let defaultsKey = "fd.tbdisplaysender.language"

    var id: String { rawValue }

    var pickerTitle: String {
        switch self {
        case .italian: return "Italiano"
        case .english: return "English"
        }
    }

    static func load() -> TBDisplaySenderLanguage {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let language = TBDisplaySenderLanguage(rawValue: raw) else {
            return .italian
        }
        return language
    }

    func persist() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
    }
}

enum TBDisplaySenderStatusState {
    case ready
    case connecting(String)
    case waitingDisplayProfile
    case connectionFailed(String)
    case stopped
    case connectionClosed(String)
    case receiverClosedDuringCapture
    case receiverClosedConnection
    case receiverTerminatedSession
    case creatingVirtualDisplay
    case virtualDisplayCreationFailed
    case startingCapture(String)
    case captureStartedWaitingFirstFrame
    case captureActive(String, String)
    case captureError(String)
    case captureDesktopError(String)
    case noShareableDisplay(String)
    case hevcNoFrames
    case noFirstFrame

    func text(_ language: TBDisplaySenderLanguage) -> String {
        switch (self, language) {
        case (.ready, .italian): return "Pronto"
        case (.ready, .english): return "Ready"

        case let (.connecting(ip), .italian): return "Connessione a \(ip)…"
        case let (.connecting(ip), .english): return "Connecting to \(ip)…"

        case (.waitingDisplayProfile, .italian): return "Receiver connesso, attendo profilo display…"
        case (.waitingDisplayProfile, .english): return "Receiver connected, waiting for display profile…"

        case let (.connectionFailed(error), .italian): return "Connessione fallita: \(error)"
        case let (.connectionFailed(error), .english): return "Connection failed: \(error)"

        case (.stopped, .italian): return "Interrotto"
        case (.stopped, .english): return "Stopped"

        case let (.connectionClosed(error), .italian): return "Connessione chiusa: \(error)"
        case let (.connectionClosed(error), .english): return "Connection closed: \(error)"

        case (.receiverClosedDuringCapture, .italian): return "Receiver chiuso durante l'avvio cattura"
        case (.receiverClosedDuringCapture, .english): return "Receiver closed while capture was starting"

        case (.receiverClosedConnection, .italian): return "Receiver ha chiuso la connessione"
        case (.receiverClosedConnection, .english): return "Receiver closed the connection"

        case (.receiverTerminatedSession, .italian): return "Receiver ha terminato la sessione"
        case (.receiverTerminatedSession, .english): return "Receiver terminated the session"

        case (.creatingVirtualDisplay, .italian): return "Creo virtual display…"
        case (.creatingVirtualDisplay, .english): return "Creating virtual display…"

        case (.virtualDisplayCreationFailed, .italian): return "Creazione virtual display fallita"
        case (.virtualDisplayCreationFailed, .english): return "Virtual display creation failed"

        case let (.startingCapture(resolution), .italian): return "Avvio cattura del desktop principale (\(resolution))…"
        case let (.startingCapture(resolution), .english): return "Starting main desktop capture (\(resolution))…"

        case (.captureStartedWaitingFirstFrame, .italian): return "Cattura avviata, attendo il primo frame…"
        case (.captureStartedWaitingFirstFrame, .english): return "Capture started, waiting for the first frame…"

        case let (.captureActive(resolution, codec), .italian): return "Duplicazione desktop attiva (\(resolution), \(codec))"
        case let (.captureActive(resolution, codec), .english): return "Desktop duplication active (\(resolution), \(codec))"

        case let (.captureError(error), .italian): return "Errore capture: \(error)"
        case let (.captureError(error), .english): return "Capture error: \(error)"

        case let (.captureDesktopError(error), .italian): return "Errore cattura desktop: \(error)"
        case let (.captureDesktopError(error), .english): return "Desktop capture error: \(error)"

        case let (.noShareableDisplay(details), .italian): return details
        case let (.noShareableDisplay(details), .english): return details

        case (.hevcNoFrames, .italian): return "5K avviato ma il path HEVC non sta producendo frame"
        case (.hevcNoFrames, .english): return "5K started but the HEVC path is not producing frames"

        case (.noFirstFrame, .italian): return "Cattura avviata ma non e' arrivato il primo frame"
        case (.noFirstFrame, .english): return "Capture started but the first frame never arrived"
        }
    }
}

enum TBDisplaySenderL10n {
    static func appName(_ language: TBDisplaySenderLanguage) -> String {
        "TargetBridge"
    }

    static func appSubtitle(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian:
            return "Crea la sessione monitor per macOS, duplica il desktop principale e lo invia al receiver 5K."
        case .english:
            return "Creates the macOS monitor session, duplicates the main desktop, and sends it to the 5K receiver."
        }
    }

    static func connectionGroup(_ language: TBDisplaySenderLanguage) -> String {
        language == .italian ? "Connessione" : "Connection"
    }

    static func localTBIP(_ language: TBDisplaySenderLanguage) -> String {
        language == .italian ? "IP Thunderbolt locale" : "Local Thunderbolt IP"
    }

    static func notDetected(_ language: TBDisplaySenderLanguage) -> String {
        language == .italian ? "Non rilevato" : "Not detected"
    }

    static func receiverIP(_ language: TBDisplaySenderLanguage) -> String {
        language == .italian ? "IP receiver" : "Receiver IP"
    }

    static func connectButton(_ language: TBDisplaySenderLanguage) -> String {
        language == .italian ? "Connetti" : "Connect"
    }

    static func stopButton(_ language: TBDisplaySenderLanguage) -> String {
        "Stop"
    }

    static func refreshIPButton(_ language: TBDisplaySenderLanguage) -> String {
        language == .italian ? "Aggiorna IP" : "Refresh IP"
    }

    static func languageGroup(_ language: TBDisplaySenderLanguage) -> String {
        language == .italian ? "Lingua" : "Language"
    }

    static func streamResolutionGroup(_ language: TBDisplaySenderLanguage) -> String {
        language == .italian ? "Risoluzione stream" : "Stream resolution"
    }

    static func streamProfile(_ language: TBDisplaySenderLanguage) -> String {
        language == .italian ? "Profilo stream" : "Stream profile"
    }

    static func streamHint1(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian:
            return "`Standard` mantiene il profilo attuale. `5K` prova la cattura a 5120 × 2880 mantenendo la duplicazione del desktop principale."
        case .english:
            return "`Standard` keeps the current profile. `5K` tries 5120 × 2880 capture while still duplicating the main desktop."
        }
    }

    static func streamHint2(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian:
            return "Il profilo `5K` usa `HEVC` con tuning più aggressivo sulla latenza."
        case .english:
            return "The `5K` profile uses `HEVC` with more aggressive latency tuning."
        }
    }

    static func monitorSessionGroup(_ language: TBDisplaySenderLanguage) -> String {
        language == .italian ? "Sessione monitor" : "Monitor session"
    }

    static func receiverLabel(_ language: TBDisplaySenderLanguage) -> String {
        "Receiver"
    }

    static func virtualDisplayLabel(_ language: TBDisplaySenderLanguage) -> String {
        language == .italian ? "Virtual display" : "Virtual display"
    }

    static func streamLabel(_ language: TBDisplaySenderLanguage) -> String {
        "Stream"
    }

    static func fpsLabel(_ language: TBDisplaySenderLanguage) -> String {
        language == .italian ? "FPS sender" : "Sender FPS"
    }

    static func modeGroup(_ language: TBDisplaySenderLanguage) -> String {
        language == .italian ? "Modalità v1" : "Mode v1"
    }

    static func modeLine1(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Pannello iMac target: 5120 × 2880 (5K)"
        case .english: return "Target iMac panel: 5120 × 2880 (5K)"
        }
    }

    static func modeLine2(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Monitor esposto al MacBook: 2560 × 1440 HiDPI @ 60 Hz"
        case .english: return "Display exposed to the MacBook: 2560 × 1440 HiDPI @ 60 Hz"
        }
    }

    static func modeLine3(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Pipeline: sessione virtual display + desktop principale → ScreenCaptureKit → codec hardware → TCP"
        case .english: return "Pipeline: virtual display session + main desktop → ScreenCaptureKit → hardware codec → TCP"
        }
    }

    static func modeLine4(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Il receiver va in fullscreen solo quando arriva il primo frame."
        case .english: return "The receiver switches to fullscreen only when the first frame arrives."
        }
    }

    static func modeLine5(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Puoi scegliere se restare sul profilo standard o provare la cattura 5K."
        case .english: return "You can stay on the standard profile or try 5K capture."
        }
    }

    static func versionLabel(_ language: TBDisplaySenderLanguage) -> String {
        language == .italian ? "Versione" : "Version"
    }

    static func showMenuBarIcon(_ language: TBDisplaySenderLanguage) -> String {
        language == .italian ? "Mostra icona nella topbar" : "Show icon in top bar"
    }

    static func showMainWindow(_ language: TBDisplaySenderLanguage) -> String {
        language == .italian ? "Mostra finestra principale" : "Show main window"
    }

    static func topBarIP(_ language: TBDisplaySenderLanguage, _ ip: String) -> String {
        language == .italian ? "IP TB: \(ip)" : "TB IP: \(ip)"
    }

    static func hideMenuBarIcon(_ language: TBDisplaySenderLanguage) -> String {
        language == .italian ? "Nascondi icona dalla topbar" : "Hide top bar icon"
    }

    static func quitApp(_ language: TBDisplaySenderLanguage) -> String {
        language == .italian ? "Esci da TargetBridge" : "Quit TargetBridge"
    }

    static func topBarToolTip(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian:
            return "TargetBridge - Monitor target display software"
        case .english:
            return "TargetBridge - Software target display monitor"
        }
    }

    static func waitingReceiverProfile(_ language: TBDisplaySenderLanguage) -> String {
        language == .italian ? "In attesa del profilo receiver" : "Waiting for receiver profile"
    }

    static func virtualDisplayNotCreated(_ language: TBDisplaySenderLanguage) -> String {
        language == .italian ? "Virtual display non creato" : "Virtual display not created"
    }

    static func receiverSummary(_ profile: TBMonitorDisplayProfile, language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian:
            return "\(profile.receiverName): pannello \(profile.panelWidth)×\(profile.panelHeight), modalità \(profile.modeWidth)×\(profile.modeHeight) HiDPI"
        case .english:
            return "\(profile.receiverName): panel \(profile.panelWidth)×\(profile.panelHeight), mode \(profile.modeWidth)×\(profile.modeHeight) HiDPI"
        }
    }

    static func virtualDisplaySummary(name: String, id: UInt32, language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian:
            return "Virtual display: \(name) (\(id))"
        case .english:
            return "Virtual display: \(name) (\(id))"
        }
    }

    static func streamSummary(preset: TBDisplayCapturePreset, language: TBDisplaySenderLanguage) -> String {
        "\(preset.description) (\(preset.title(language)), \(preset.codecName))"
    }

    static func missingScreenRecordingPermission(language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian:
            return "TargetBridge non ha il permesso Registrazione Schermo. Verifica Privacy e Sicurezza > Registrazione Schermo."
        case .english:
            return "TargetBridge does not have Screen Recording permission. Check Privacy & Security > Screen Recording."
        }
    }

    static func screenCaptureKitPermissionMismatch(details: String, language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian:
            return "ScreenCaptureKit ha fallito anche se il permesso Registrazione Schermo risulta concesso. Dettagli: \(details)"
        case .english:
            return "ScreenCaptureKit failed even though Screen Recording permission appears granted. Details: \(details)"
        }
    }
}

extension TBDisplayCapturePreset {
    func title(_ language: TBDisplaySenderLanguage) -> String {
        switch (self, language) {
        case (.standard1440p, .italian): return "Standard"
        case (.standard1440p, .english): return "Standard"
        case (.native5k, .italian): return "5K"
        case (.native5k, .english): return "5K"
        }
    }
}
