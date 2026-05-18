import Foundation

enum TBDisplaySenderLanguage: String, CaseIterable, Identifiable {
    case italian
    case english
    case german

    static let defaultsKey = "fd.tbdisplaysender.language"

    var id: String { rawValue }

    var pickerTitle: String {
        switch self {
        case .italian: return "Italiano"
        case .english: return "English"
        case .german: return "Deutsch"
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
    case startingCapture(String, TBDisplayCaptureSource)
    case captureStartedWaitingFirstFrame
    case captureActive(String, String, TBDisplayCaptureSource)
    case captureError(String)
    case captureDesktopError(String)
    case noShareableDisplay(String)
    case hevcNoFrames
    case noFirstFrame

    func text(_ language: TBDisplaySenderLanguage) -> String {
        switch (self, language) {
        case (.ready, .italian): return "Pronto"
        case (.ready, .english): return "Ready"
        case (.ready, .german): return "Bereit"

        case let (.connecting(ip), .italian): return "Connessione a \(ip)…"
        case let (.connecting(ip), .english): return "Connecting to \(ip)…"
        case let (.connecting(ip), .german): return "Verbinden mit \(ip)…"

        case (.waitingDisplayProfile, .italian): return "Receiver connesso, attendo profilo display…"
        case (.waitingDisplayProfile, .english): return "Receiver connected, waiting for display profile…"
        case (.waitingDisplayProfile, .german): return "Empfänger verbunden, warte auf Display-Profil…"

        case let (.connectionFailed(error), .italian): return "Connessione fallita: \(error)"
        case let (.connectionFailed(error), .english): return "Connection failed: \(error)"
        case let (.connectionFailed(error), .german): return "Verbindung fehlgeschlagen: \(error)"

        case (.stopped, .italian): return "Interrotto"
        case (.stopped, .english): return "Stopped"
        case (.stopped, .german): return "Gestoppt"

        case let (.connectionClosed(error), .italian): return "Connessione chiusa: \(error)"
        case let (.connectionClosed(error), .english): return "Connection closed: \(error)"
        case let (.connectionClosed(error), .german): return "Verbindung geschlossen: \(error)"

        case (.receiverClosedDuringCapture, .italian): return "Receiver chiuso durante l'avvio cattura"
        case (.receiverClosedDuringCapture, .english): return "Receiver closed while capture was starting"
        case (.receiverClosedDuringCapture, .german): return "Empfänger während des Aufnahmestarts geschlossen"

        case (.receiverClosedConnection, .italian): return "Receiver ha chiuso la connessione"
        case (.receiverClosedConnection, .english): return "Receiver closed the connection"
        case (.receiverClosedConnection, .german): return "Empfänger hat die Verbindung geschlossen"

        case (.receiverTerminatedSession, .italian): return "Receiver ha terminato la sessione"
        case (.receiverTerminatedSession, .english): return "Receiver terminated the session"
        case (.receiverTerminatedSession, .german): return "Empfänger hat die Sitzung beendet"

        case (.creatingVirtualDisplay, .italian): return "Creo virtual display…"
        case (.creatingVirtualDisplay, .english): return "Creating virtual display…"
        case (.creatingVirtualDisplay, .german): return "Virtuelles Display wird erstellt…"

        case (.virtualDisplayCreationFailed, .italian): return "Creazione virtual display fallita"
        case (.virtualDisplayCreationFailed, .english): return "Virtual display creation failed"
        case (.virtualDisplayCreationFailed, .german): return "Virtuelles Display konnte nicht erstellt werden"

        case let (.startingCapture(resolution, source), .italian):
            return "Avvio \(source.title(language).lowercased()) (\(resolution))…"
        case let (.startingCapture(resolution, source), .english):
            return "Starting \(source.title(language).lowercased()) capture (\(resolution))…"
        case let (.startingCapture(resolution, source), .german):
            return "\(source.title(language)) wird gestartet (\(resolution))…"

        case (.captureStartedWaitingFirstFrame, .italian): return "Cattura avviata, attendo il primo frame…"
        case (.captureStartedWaitingFirstFrame, .english): return "Capture started, waiting for the first frame…"
        case (.captureStartedWaitingFirstFrame, .german): return "Aufnahme gestartet, warte auf ersten Bildinhalt…"

        case let (.captureActive(resolution, codec, source), .italian): return "\(source.title(language)) attivo (\(resolution), \(codec))"
        case let (.captureActive(resolution, codec, source), .english): return "\(source.title(language)) active (\(resolution), \(codec))"
        case let (.captureActive(resolution, codec, source), .german): return "\(source.title(language)) aktiv (\(resolution), \(codec))"

        case let (.captureError(error), .italian): return "Errore capture: \(error)"
        case let (.captureError(error), .english): return "Capture error: \(error)"
        case let (.captureError(error), .german): return "Aufnahmefehler: \(error)"

        case let (.captureDesktopError(error), .italian): return "Errore cattura desktop: \(error)"
        case let (.captureDesktopError(error), .english): return "Desktop capture error: \(error)"
        case let (.captureDesktopError(error), .german): return "Desktop-Aufnahmefehler: \(error)"

        case let (.noShareableDisplay(details), .italian): return details
        case let (.noShareableDisplay(details), .english): return details
        case let (.noShareableDisplay(details), .german): return details

        case (.hevcNoFrames, .italian): return "5K avviato ma il path HEVC non sta producendo frame"
        case (.hevcNoFrames, .english): return "5K started but the HEVC path is not producing frames"
        case (.hevcNoFrames, .german): return "5K gestartet, aber der HEVC-Pfad erzeugt keine Bildinhalte"

        case (.noFirstFrame, .italian): return "Cattura avviata ma non e' arrivato il primo frame"
        case (.noFirstFrame, .english): return "Capture started but the first frame never arrived"
        case (.noFirstFrame, .german): return "Aufnahme gestartet, aber der erste Bildinhalt ist nie angekommen"
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
            return "Crea un display virtuale iMac su macOS e ne invia il contenuto al receiver 5K."
        case .english:
            return "Creates an iMac virtual display on macOS and sends its contents to the 5K receiver."
        case .german:
            return "Erstellt ein virtuelles iMac-Display auf macOS und sendet dessen Inhalt an den 5K-Empfänger."
        }
    }

    static func connectionGroup(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Connessione"
        case .english: return "Connection"
        case .german: return "Verbindung"
        }
    }

    static func localTBIP(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "IP Thunderbolt locale"
        case .english: return "Local Thunderbolt IP"
        case .german: return "Lokale Thunderbolt-IP"
        }
    }

    static func notDetected(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Non rilevato"
        case .english: return "Not detected"
        case .german: return "Nicht erkannt"
        }
    }

    static func receiverIP(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "IP receiver"
        case .english: return "Receiver IP"
        case .german: return "Empfänger-IP"
        }
    }

    static func connectButton(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Connetti"
        case .english: return "Connect"
        case .german: return "Verbinden"
        }
    }

    static func stopButton(_ language: TBDisplaySenderLanguage) -> String {
        "Stop"
    }

    static func refreshIPButton(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Aggiorna IP"
        case .english: return "Refresh IP"
        case .german: return "IP aktualisieren"
        }
    }

    static func languageGroup(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Lingua"
        case .english: return "Language"
        case .german: return "Sprache"
        }
    }

    static func streamResolutionGroup(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Risoluzione stream"
        case .english: return "Stream resolution"
        case .german: return "Stream-Auflösung"
        }
    }

    static func streamProfile(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Profilo stream"
        case .english: return "Stream profile"
        case .german: return "Stream-Profil"
        }
    }

    static func captureSource(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Sorgente"
        case .english: return "Source"
        case .german: return "Quelle"
        }
    }

    static func streamHint1(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian:
            return "`Duplica Desktop` usa il monitor virtuale. `Desktop Esteso` cattura il display principale."
        case .english:
            return "`Duplicate Desktop` uses the virtual monitor. `Extended Desktop` captures the main display."
        case .german:
            return "`Desktop duplizieren` nutzt das virtuelle Display. `Erweiterter Desktop` erfasst das Hauptdisplay."
        }
    }

    static func streamHint2(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian:
            return "`Smooth+` privilegia fluidità. `Crisp` aumenta la nitidezza. `5K` massimizza i pixel."
        case .english:
            return "`Smooth+` prioritizes motion. `Crisp` improves clarity. `5K` maximizes pixels."
        case .german:
            return "`Smooth+` bevorzugt flüssige Bewegung. `Crisp` verbessert die Schärfe. `5K` maximiert die Pixel."
        }
    }

    static func monitorSessionGroup(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Sessione monitor"
        case .english: return "Monitor session"  // "Monitor" means "Display/Screen" here (noun)
        case .german: return "Bildschirmsitzung"
        }
    }

    static func receiverLabel(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Receiver"
        case .english: return "Receiver"
        case .german: return "Empfänger"
        }
    }

    static func virtualDisplayLabel(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Virtual display"
        case .english: return "Virtual display"
        case .german: return "Virtuelles Display"
        }
    }

    static func streamLabel(_ language: TBDisplaySenderLanguage) -> String {
        "Stream"
    }

    static func fpsLabel(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "FPS sender"
        case .english: return "Sender FPS"
        case .german: return "Sender-FPS"
        }
    }

    static func modeGroup(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Modalità v1"
        case .english: return "Mode v1"
        case .german: return "Modus v1"
        }
    }

    static func modeLine1(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Pannello iMac target: 5120 × 2880 (5K)"
        case .english: return "Target iMac panel: 5120 × 2880 (5K)"
        case .german: return "Ziel-iMac-Bildschirm: 5120 × 2880 (5K)"
        }
    }

    static func modeLine2(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Monitor esposto al MacBook: 2560 × 1440 HiDPI @ 60 Hz"
        case .english: return "Display exposed to the MacBook: 2560 × 1440 HiDPI @ 60 Hz"
        case .german: return "Dem MacBook bereitgestelltes Display: 2560 × 1440 HiDPI @ 60 Hz"
        }
    }

    static func modeLine3(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Pipeline: virtual display o mirror → capture diretta → codec hardware → TCP"
        case .english: return "Pipeline: virtual display or mirror → direct capture → hardware codec → TCP"
        case .german: return "Pipeline: Virtuelles Display oder Mirror → Direkte Aufnahme → Hardware-Codec → TCP"
        }
    }

    static func modeLine4(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Il receiver va in fullscreen solo quando arriva il primo frame."
        case .english: return "The receiver switches to fullscreen only when the first frame arrives."
        case .german: return "Der Empfänger schaltet erst auf Vollbild um, wenn der erste Bildinhalt ankommt."
        }
    }

    static func modeLine5(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Scegli la sorgente, poi bilancia fluidità e nitidezza col profilo stream."
        case .english: return "Choose the source, then balance motion and clarity with the stream profile."
        case .german: return "Quelle wählen, dann Bewegungsfluss und Schärfe mit dem Stream-Profil abstimmen."
        }
    }

    static func versionLabel(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Versione"
        case .english: return "Version"
        case .german: return "Version"
        }
    }

    static func showMenuBarIcon(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Mostra icona nella topbar"
        case .english: return "Show icon in top bar"
        case .german: return "Symbol in Menüleiste anzeigen"
        }
    }

    static func largeCursor(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Cursore ingrandito sul receiver"
        case .english: return "Large cursor on receiver"
        case .german: return "Großer Zeiger auf dem Empfänger"
        }
    }

    static func showMainWindow(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Mostra finestra principale"
        case .english: return "Show main window"
        case .german: return "Hauptfenster anzeigen"
        }
    }

    static func topBarIP(_ language: TBDisplaySenderLanguage, _ ip: String) -> String {
        switch language {
        case .italian: return "IP TB: \(ip)"
        case .english: return "TB IP: \(ip)"
        case .german: return "TB-IP: \(ip)"
        }
    }

    static func hideMenuBarIcon(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Nascondi icona dalla topbar"
        case .english: return "Hide top bar icon"
        case .german: return "Symbol in Menüleiste ausblenden"
        }
    }

    static func quitApp(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Esci da TargetBridge"
        case .english: return "Quit TargetBridge"
        case .german: return "TargetBridge beenden"
        }
    }

    static func topBarToolTip(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian:
            return "TargetBridge - Monitor target display software"
        case .english:
            return "TargetBridge - Software target display monitor"
        case .german:
            return "TargetBridge - Software Target-Display-Monitor"
        }
    }

    static func waitingReceiverProfile(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "In attesa del profilo receiver"
        case .english: return "Waiting for receiver profile"
        case .german: return "Warte auf Empfänger-Profil"
        }
    }

    static func virtualDisplayNotCreated(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Virtual display non creato"
        case .english: return "Virtual display not created"
        case .german: return "Virtuelles Display nicht erstellt"
        }
    }

    static func receiverSummary(_ profile: TBMonitorDisplayProfile, language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian:
            return "\(profile.receiverName): pannello \(profile.panelWidth)×\(profile.panelHeight), modalità \(profile.modeWidth)×\(profile.modeHeight) HiDPI"
        case .english:
            return "\(profile.receiverName): panel \(profile.panelWidth)×\(profile.panelHeight), mode \(profile.modeWidth)×\(profile.modeHeight) HiDPI"
        case .german:
            return "\(profile.receiverName): Panel \(profile.panelWidth)×\(profile.panelHeight), Modus \(profile.modeWidth)×\(profile.modeHeight) HiDPI"
        }
    }

    static func virtualDisplaySummary(name: String, id: UInt32, language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian:
            return "Virtual display: \(name) (\(id))"
        case .english:
            return "Virtual display: \(name) (\(id))"
        case .german:
            return "Virtuelles Display: \(name) (\(id))"
        }
    }

    static func streamSummary(preset: TBDisplayCapturePreset, source: TBDisplayCaptureSource, language: TBDisplaySenderLanguage) -> String {
        "\(source.title(language)) · \(preset.description) (\(preset.title(language)), \(preset.codecName))"
    }

    static func missingScreenRecordingPermission(language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian:
            return "TargetBridge non ha il permesso Registrazione Schermo. Verifica Privacy e Sicurezza > Registrazione Schermo."
        case .english:
            return "TargetBridge does not have Screen Recording permission. Check Privacy & Security > Screen Recording."
        case .german:
            return "TargetBridge hat keine Berechtigung für die Bildschirmaufnahme. Überprüfen Sie Systemeinstellungen > Datenschutz & Sicherheit > Bildschirmaufnahme."
        }
    }

    static func screenCaptureKitPermissionMismatch(details: String, language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian:
            return "ScreenCaptureKit ha fallito anche se il permesso Registrazione Schermo risulta concesso. Dettagli: \(details)"
        case .english:
            return "ScreenCaptureKit failed even though Screen Recording permission appears granted. Details: \(details)"
        case .german:
            return "ScreenCaptureKit fehlgeschlagen, obwohl die Berechtigung zur Bildschirmaufnahme erteilt zu sein scheint. Details: \(details)"
        }
    }
}

extension TBDisplayCapturePreset {
    func title(_ language: TBDisplaySenderLanguage) -> String {
        switch (self, language) {
        case (.standard1440p, .italian): return "Standard"
        case (.standard1440p, .english): return "Standard"
        case (.standard1440p, .german): return "Standard"
        case (.smooth1440p60, .italian): return "Smooth"
        case (.smooth1440p60, .english): return "Smooth"
        case (.smooth1440p60, .german): return "Smooth"
        case (.smooth1800p60, .italian): return "Smooth+"
        case (.smooth1800p60, .english): return "Smooth+"
        case (.smooth1800p60, .german): return "Smooth+"
        case (.crisp2160p48, .italian): return "Crisp"
        case (.crisp2160p48, .english): return "Crisp"
        case (.crisp2160p48, .german): return "Crisp"
        case (.native5k, .italian): return "5K"
        case (.native5k, .english): return "5K"
        case (.native5k, .german): return "5K"
        }
    }
}
