import Foundation

enum TBDisplaySenderLanguage: String, CaseIterable, Identifiable {
    case italian
    case english
    case german
    case chinese

    static let defaultsKey = "fd.tbdisplaysender.language"

    var id: String { rawValue }

    var pickerTitle: String {
        switch self {
        case .italian: return "Italiano"
        case .english: return "English"
        case .german: return "Deutsch"
        case .chinese: return "中文"
        }
    }

    /// Loads the language from UserDefaults if previously persisted.
    /// Otherwise picks a sensible default based on the system locale:
    ///   * zh-Hans / zh-Hant / zh-CN / zh-TW … → .chinese
    ///   * it-* → .italian
    ///   * de-* → .german
    ///   * everything else → .english
    static func load() -> TBDisplaySenderLanguage {
        if let raw = UserDefaults.standard.string(forKey: defaultsKey),
           let language = TBDisplaySenderLanguage(rawValue: raw) {
            return language
        }
        return preferredFromLocale()
    }

    private static func preferredFromLocale() -> TBDisplaySenderLanguage {
        let candidates = Locale.preferredLanguages + [Locale.current.identifier]
        for raw in candidates {
            let lower = raw.lowercased()
            if lower.hasPrefix("zh") { return .chinese }
            if lower.hasPrefix("it") { return .italian }
            if lower.hasPrefix("de") { return .german }
            if lower.hasPrefix("en") { return .english }
        }
        return .english
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
    case testingCable

    func text(_ language: TBDisplaySenderLanguage) -> String {
        switch (self, language) {
        case (.ready, .italian): return "Pronto"
        case (.ready, .english): return "Ready"
        case (.ready, .german): return "Bereit"
        case (.ready, .chinese): return "就绪"

        case let (.connecting(ip), .italian): return "Connessione a \(ip)…"
        case let (.connecting(ip), .english): return "Connecting to \(ip)…"
        case let (.connecting(ip), .german): return "Verbinden mit \(ip)…"
        case let (.connecting(ip), .chinese): return "正在连接 \(ip)…"

        case (.testingCable, .italian): return "Test del cavo in corso…"
        case (.testingCable, .english): return "Testing cable performance…"
        case (.testingCable, .german): return "Kabel-Performance wird getestet…"
        case (.testingCable, .chinese): return "正在测试线缆性能…"

        case (.waitingDisplayProfile, .italian): return "Receiver connesso, attendo profilo display…"
        case (.waitingDisplayProfile, .english): return "Receiver connected, waiting for display profile…"
        case (.waitingDisplayProfile, .german): return "Empfänger verbunden, warte auf Display-Profil…"
        case (.waitingDisplayProfile, .chinese): return "接收端已连接，等待显示配置…"

        case let (.connectionFailed(error), .italian): return "Connessione fallita: \(error)"
        case let (.connectionFailed(error), .english): return "Connection failed: \(error)"
        case let (.connectionFailed(error), .german): return "Verbindung fehlgeschlagen: \(error)"
        case let (.connectionFailed(error), .chinese): return "连接失败：\(error)"

        case (.stopped, .italian): return "Interrotto"
        case (.stopped, .english): return "Stopped"
        case (.stopped, .german): return "Gestoppt"
        case (.stopped, .chinese): return "已停止"

        case let (.connectionClosed(error), .italian): return "Connessione chiusa: \(error)"
        case let (.connectionClosed(error), .english): return "Connection closed: \(error)"
        case let (.connectionClosed(error), .german): return "Verbindung geschlossen: \(error)"
        case let (.connectionClosed(error), .chinese): return "连接已关闭：\(error)"

        case (.receiverClosedDuringCapture, .italian): return "Receiver chiuso durante l'avvio cattura"
        case (.receiverClosedDuringCapture, .english): return "Receiver closed while capture was starting"
        case (.receiverClosedDuringCapture, .german): return "Empfänger während des Aufnahmestarts geschlossen"
        case (.receiverClosedDuringCapture, .chinese): return "捕获启动时接收端已关闭"

        case (.receiverClosedConnection, .italian): return "Receiver ha chiuso la connessione"
        case (.receiverClosedConnection, .english): return "Receiver closed the connection"
        case (.receiverClosedConnection, .german): return "Empfänger hat die Verbindung geschlossen"
        case (.receiverClosedConnection, .chinese): return "接收端已关闭连接"

        case (.receiverTerminatedSession, .italian): return "Receiver ha terminato la sessione"
        case (.receiverTerminatedSession, .english): return "Receiver terminated the session"
        case (.receiverTerminatedSession, .german): return "Empfänger hat die Sitzung beendet"
        case (.receiverTerminatedSession, .chinese): return "接收端已终止会话"

        case (.creatingVirtualDisplay, .italian): return "Creo virtual display…"
        case (.creatingVirtualDisplay, .english): return "Creating virtual display…"
        case (.creatingVirtualDisplay, .german): return "Virtuelles Display wird erstellt…"
        case (.creatingVirtualDisplay, .chinese): return "正在创建虚拟显示器…"

        case (.virtualDisplayCreationFailed, .italian): return "Creazione virtual display fallita"
        case (.virtualDisplayCreationFailed, .english): return "Virtual display creation failed"
        case (.virtualDisplayCreationFailed, .german): return "Virtuelles Display konnte nicht erstellt werden"
        case (.virtualDisplayCreationFailed, .chinese): return "虚拟显示器创建失败"

        case let (.startingCapture(resolution, source), .italian):
            return "Avvio \(source.title(language).lowercased()) (\(resolution))…"
        case let (.startingCapture(resolution, source), .english):
            return "Starting \(source.title(language).lowercased()) capture (\(resolution))…"
        case let (.startingCapture(resolution, source), .german):
            return "\(source.title(language)) wird gestartet (\(resolution))…"
        case let (.startingCapture(resolution, source), .chinese):
            return "正在启动 \(source.title(language))（\(resolution)）…"

        case (.captureStartedWaitingFirstFrame, .italian): return "Cattura avviata, attendo il primo frame…"
        case (.captureStartedWaitingFirstFrame, .english): return "Capture started, waiting for the first frame…"
        case (.captureStartedWaitingFirstFrame, .german): return "Aufnahme gestartet, warte auf ersten Bildinhalt…"
        case (.captureStartedWaitingFirstFrame, .chinese): return "捕获已启动，等待首帧…"

        case let (.captureActive(resolution, codec, source), .italian): return "\(source.title(language)) attivo (\(resolution), \(codec))"
        case let (.captureActive(resolution, codec, source), .english): return "\(source.title(language)) active (\(resolution), \(codec))"
        case let (.captureActive(resolution, codec, source), .german): return "\(source.title(language)) aktiv (\(resolution), \(codec))"
        case let (.captureActive(resolution, codec, source), .chinese): return "\(source.title(language)) 进行中（\(resolution)，\(codec)）"

        case let (.captureError(error), .italian): return "Errore capture: \(error)"
        case let (.captureError(error), .english): return "Capture error: \(error)"
        case let (.captureError(error), .german): return "Aufnahmefehler: \(error)"
        case let (.captureError(error), .chinese): return "捕获错误：\(error)"

        case let (.captureDesktopError(error), .italian): return "Errore cattura desktop: \(error)"
        case let (.captureDesktopError(error), .english): return "Desktop capture error: \(error)"
        case let (.captureDesktopError(error), .german): return "Desktop-Aufnahmefehler: \(error)"
        case let (.captureDesktopError(error), .chinese): return "桌面捕获错误：\(error)"

        case let (.noShareableDisplay(details), .italian): return details
        case let (.noShareableDisplay(details), .english): return details
        case let (.noShareableDisplay(details), .german): return details
        case let (.noShareableDisplay(details), .chinese): return details

        case (.hevcNoFrames, .italian): return "5K avviato ma il path HEVC non sta producendo frame"
        case (.hevcNoFrames, .english): return "5K started but the HEVC path is not producing frames"
        case (.hevcNoFrames, .german): return "5K gestartet, aber der HEVC-Pfad erzeugt keine Bildinhalte"
        case (.hevcNoFrames, .chinese): return "5K 已启动，但 HEVC 通道未输出任何帧"

        case (.noFirstFrame, .italian): return "Cattura avviata ma non e' arrivato il primo frame"
        case (.noFirstFrame, .english): return "Capture started but the first frame never arrived"
        case (.noFirstFrame, .german): return "Aufnahme gestartet, aber der erste Bildinhalt ist nie angekommen"
        case (.noFirstFrame, .chinese): return "捕获已启动，但始终未收到首帧"
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
        case .chinese:
            return "在 macOS 上创建一个 iMac 虚拟显示器，并将其内容发送到 5K 接收端。"
        }
    }

    static func cableTestGroup(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Test Cavo"
        case .english: return "Cable Test"
        case .german: return "Kabeltest"
        case .chinese: return "线缆测试"
        }
    }

    static func cableTestButton(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Esegui Test Cavo"
        case .english: return "Run Cable Test"
        case .german: return "Kabeltest ausführen"
        case .chinese: return "运行线缆测试"
        }
    }

    static func testingButton(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Test in corso…"
        case .english: return "Testing…"
        case .german: return "Test läuft…"
        case .chinese: return "测试中…"
        }
    }

    static func transferRateLabel(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Velocità:"
        case .english: return "Transfer Rate:"
        case .german: return "Übertragungsrate:"
        case .chinese: return "传输速率："
        }
    }

    static func noTestResult(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Nessun test eseguito"
        case .english: return "No test run yet"
        case .german: return "Noch kein Test ausgeführt"
        case .chinese: return "尚未运行测试"
        }
    }

    static func connectionGroup(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Connessione"
        case .english: return "Connection"
        case .german: return "Verbindung"
        case .chinese: return "连接"
        }
    }

    static func localTBIP(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "IP Thunderbolt locale"
        case .english: return "Local Thunderbolt IP"
        case .german: return "Lokale Thunderbolt-IP"
        case .chinese: return "本机 Thunderbolt IP"
        }
    }

    static func availableTBInterfaces(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Interfacce Thunderbolt"
        case .english: return "Thunderbolt interfaces"
        case .german: return "Thunderbolt-Schnittstellen"
        case .chinese: return "Thunderbolt 接口"
        }
    }

    static func notDetected(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Non rilevato"
        case .english: return "Not detected"
        case .german: return "Nicht erkannt"
        case .chinese: return "未检测到"
        }
    }

    static func receiverIP(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "IP receiver"
        case .english: return "Receiver IP"
        case .german: return "Empfänger-IP"
        case .chinese: return "接收端 IP"
        }
    }

    static func discoveredReceiver(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Receiver trovato"
        case .english: return "Discovered receiver"
        case .german: return "Gefundener Empfänger"
        case .chinese: return "已发现的接收端"
        }
    }

    static func manualReceiverEntry(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Inserimento manuale"
        case .english: return "Manual entry"
        case .german: return "Manuelle Eingabe"
        case .chinese: return "手动输入"
        }
    }

    static func connectButton(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Connetti"
        case .english: return "Connect"
        case .german: return "Verbinden"
        case .chinese: return "连接"
        }
    }

    static func stopButton(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .chinese: return "停止"
        default: return "Stop"
        }
    }

    static func refreshIPButton(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Aggiorna IP"
        case .english: return "Refresh IP"
        case .german: return "IP aktualisieren"
        case .chinese: return "刷新 IP"
        }
    }

    static func addSessionButton(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Aggiungi sessione"
        case .english: return "Add session"
        case .german: return "Sitzung hinzufügen"
        case .chinese: return "新增会话"
        }
    }

    static func stopAllButton(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Ferma tutto"
        case .english: return "Stop all"
        case .german: return "Alle stoppen"
        case .chinese: return "全部停止"
        }
    }

    static func removeSessionButton(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Rimuovi sessione"
        case .english: return "Remove session"
        case .german: return "Sitzung entfernen"
        case .chinese: return "移除会话"
        }
    }

    static func languageGroup(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Lingua"
        case .english: return "Language"
        case .german: return "Sprache"
        case .chinese: return "语言"
        }
    }

    static func streamResolutionGroup(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Risoluzione stream"
        case .english: return "Stream resolution"
        case .german: return "Stream-Auflösung"
        case .chinese: return "码流分辨率"
        }
    }

    static func streamProfile(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Profilo stream"
        case .english: return "Stream profile"
        case .german: return "Stream-Profil"
        case .chinese: return "码流配置"
        }
    }

    static func captureSource(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Sorgente"
        case .english: return "Source"
        case .german: return "Quelle"
        case .chinese: return "来源"
        }
    }

    static func streamHint1(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian:
            return "`Duplica Desktop` crea un monitor virtuale e lo mette in mirror col display principale. `Desktop Esteso` crea un monitor virtuale separato visibile nelle impostazioni schermo."
        case .english:
            return "`Duplicate Desktop` creates a virtual monitor and mirrors the main display onto it. `Extended Desktop` creates a separate virtual monitor visible in Display Settings."
        case .german:
            return "`Desktop duplizieren` erstellt ein virtuelles Display und spiegelt den Hauptbildschirm darauf. `Erweiterter Desktop` erstellt ein separates virtuelles Display, das in den Anzeigeeinstellungen sichtbar ist."
        case .chinese:
            return "`镜像桌面` 会创建一个虚拟显示器，并将主屏镜像到上面。`扩展桌面` 会创建一个独立的虚拟显示器，可在「显示器」设置中看到。"
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
        case .chinese:
            return "`Smooth+` 偏向流畅。`Crisp` 提升清晰度。`5K` 像素最高。"
        }
    }

    static func multiSessionHint(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian:
            return "Ogni sessione usa un IP Thunderbolt locale dedicato e uno stream indipendente verso il suo iMac."
        case .english:
            return "Each session uses its own local Thunderbolt IP and an independent stream to its target iMac."
        case .german:
            return "Jede Sitzung verwendet eine eigene lokale Thunderbolt-IP und einen unabhängigen Stream zu ihrem Ziel-iMac."
        case .chinese:
            return "每个会话独占一个本机 Thunderbolt IP，向各自的 iMac 推送独立的码流。"
        }
    }

    static func discoveryHint(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian:
            return "Se selezioni un receiver trovato automaticamente, l'IP viene compilato da solo."
        case .english:
            return "Selecting a discovered receiver fills in the receiver IP automatically."
        case .german:
            return "Wenn du einen gefundenen Empfänger auswählst, wird die Empfänger-IP automatisch eingetragen."
        case .chinese:
            return "选择已发现的接收端时，接收端 IP 会自动填入。"
        }
    }

    static func monitorSessionGroup(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Sessione monitor"
        case .english: return "Monitor session"
        case .german: return "Bildschirmsitzung"
        case .chinese: return "显示会话"
        }
    }

    static func receiverLabel(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Receiver"
        case .english: return "Receiver"
        case .german: return "Empfänger"
        case .chinese: return "接收端"
        }
    }

    static func virtualDisplayLabel(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Virtual display"
        case .english: return "Virtual display"
        case .german: return "Virtuelles Display"
        case .chinese: return "虚拟显示器"
        }
    }

    static func streamLabel(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .chinese: return "码流"
        default: return "Stream"
        }
    }

    static func fpsLabel(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "FPS sender"
        case .english: return "Sender FPS"
        case .german: return "Sender-FPS"
        case .chinese: return "发送端 FPS"
        }
    }

    static func modeGroup(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Modalità v1"
        case .english: return "Mode v1"
        case .german: return "Modus v1"
        case .chinese: return "v1 模式"
        }
    }

    static func modeLine1(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Pannello iMac target: 5120 × 2880 (5K)"
        case .english: return "Target iMac panel: 5120 × 2880 (5K)"
        case .german: return "Ziel-iMac-Bildschirm: 5120 × 2880 (5K)"
        case .chinese: return "目标 iMac 面板：5120 × 2880（5K）"
        }
    }

    static func modeLine2(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Monitor esposto al MacBook: 2560 × 1440 HiDPI @ 60 Hz"
        case .english: return "Display exposed to the MacBook: 2560 × 1440 HiDPI @ 60 Hz"
        case .german: return "Dem MacBook bereitgestelltes Display: 2560 × 1440 HiDPI @ 60 Hz"
        case .chinese: return "暴露给 MacBook 的显示器：2560 × 1440 HiDPI @ 60 Hz"
        }
    }

    static func modeLine3(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Pipeline: virtual display reale (esteso o mirror) → capture diretta → codec hardware → TCP"
        case .english: return "Pipeline: real virtual display (extended or mirrored) → direct capture → hardware codec → TCP"
        case .german: return "Pipeline: echtes virtuelles Display (erweitert oder gespiegelt) → direkte Aufnahme → Hardware-Codec → TCP"
        case .chinese: return "流水线：真实虚拟显示器（扩展或镜像）→ 直接捕获 → 硬件编码 → TCP"
        }
    }

    static func modeLine4(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Il receiver va in fullscreen solo quando arriva il primo frame."
        case .english: return "The receiver switches to fullscreen only when the first frame arrives."
        case .german: return "Der Empfänger schaltet erst auf Vollbild um, wenn der erste Bildinhalt ankommt."
        case .chinese: return "接收端仅在收到首帧后才会切换到全屏。"
        }
    }

    static func modeLine5(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Scegli la sorgente, poi bilancia fluidità e nitidezza col profilo stream."
        case .english: return "Choose the source, then balance motion and clarity with the stream profile."
        case .german: return "Quelle wählen, dann Bewegungsfluss und Schärfe mit dem Stream-Profil abstimmen."
        case .chinese: return "先选择来源，再用码流配置在流畅度与清晰度之间取舍。"
        }
    }

    static func versionLabel(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Versione"
        case .english: return "Version"
        case .german: return "Version"
        case .chinese: return "版本"
        }
    }

    static func showMenuBarIcon(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Mostra icona nella topbar"
        case .english: return "Show icon in top bar"
        case .german: return "Symbol in Menüleiste anzeigen"
        case .chinese: return "在菜单栏显示图标"
        }
    }

    static func largeCursor(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Cursore ingrandito sul receiver"
        case .english: return "Large cursor on receiver"
        case .german: return "Großer Zeiger auf dem Empfänger"
        case .chinese: return "在接收端使用大光标"
        }
    }

    static func showMainWindow(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Mostra finestra principale"
        case .english: return "Show main window"
        case .german: return "Hauptfenster anzeigen"
        case .chinese: return "显示主窗口"
        }
    }

    static func topBarIP(_ language: TBDisplaySenderLanguage, _ ip: String) -> String {
        switch language {
        case .italian: return "IP TB: \(ip)"
        case .english: return "TB IP: \(ip)"
        case .german: return "TB-IP: \(ip)"
        case .chinese: return "TB IP：\(ip)"
        }
    }

    static func sessionTitle(_ language: TBDisplaySenderLanguage, index: Int) -> String {
        switch language {
        case .italian: return "Sessione \(index)"
        case .english: return "Session \(index)"
        case .german: return "Sitzung \(index)"
        case .chinese: return "会话 \(index)"
        }
    }

    static func multiSessionSummaryConnected(_ language: TBDisplaySenderLanguage, active: Int, total: Int) -> String {
        switch language {
        case .italian: return "\(active) sessioni collegate su \(total)"
        case .english: return "\(active) connected sessions of \(total)"
        case .german: return "\(active) verbundene Sitzungen von \(total)"
        case .chinese: return "\(total) 个会话中已连接 \(active) 个"
        }
    }

    static func multiSessionSummaryStreaming(_ language: TBDisplaySenderLanguage, active: Int, total: Int) -> String {
        switch language {
        case .italian: return "\(active) sessioni attive su \(total)"
        case .english: return "\(active) active sessions of \(total)"
        case .german: return "\(active) aktive Sitzungen von \(total)"
        case .chinese: return "\(total) 个会话中活跃 \(active) 个"
        }
    }

    static func hideMenuBarIcon(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Nascondi icona dalla topbar"
        case .english: return "Hide top bar icon"
        case .german: return "Symbol in Menüleiste ausblenden"
        case .chinese: return "隐藏菜单栏图标"
        }
    }

    static func quitApp(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Esci da TargetBridge"
        case .english: return "Quit TargetBridge"
        case .german: return "TargetBridge beenden"
        case .chinese: return "退出 TargetBridge"
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
        case .chinese:
            return "TargetBridge - 软件目标显示器"
        }
    }

    static func waitingReceiverProfile(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "In attesa del profilo receiver"
        case .english: return "Waiting for receiver profile"
        case .german: return "Warte auf Empfänger-Profil"
        case .chinese: return "正在等待接收端配置"
        }
    }

    static func virtualDisplayNotCreated(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Virtual display non creato"
        case .english: return "Virtual display not created"
        case .german: return "Virtuelles Display nicht erstellt"
        case .chinese: return "尚未创建虚拟显示器"
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
        case .chinese:
            return "\(profile.receiverName)：面板 \(profile.panelWidth)×\(profile.panelHeight)，模式 \(profile.modeWidth)×\(profile.modeHeight) HiDPI"
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
        case .chinese:
            return "虚拟显示器：\(name)（\(id)）"
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
        case .chinese:
            return "TargetBridge 没有「屏幕录制」权限。请前往「隐私与安全性 → 屏幕录制」检查。"
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
        case .chinese:
            return "屏幕录制权限看起来已授予，但 ScreenCaptureKit 仍然失败。详情：\(details)"
        }
    }

    // MARK: - Settings sheet (introduced when languageCard was moved into a Settings sheet)

    static func settingsTitle(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Preferenze"
        case .english: return "Settings"
        case .german: return "Einstellungen"
        case .chinese: return "设置"
        }
    }

    static func settingsDoneButton(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Fatto"
        case .english: return "Done"
        case .german: return "Fertig"
        case .chinese: return "完成"
        }
    }

    static func settingsLanguageSection(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Lingua"
        case .english: return "Language"
        case .german: return "Sprache"
        case .chinese: return "语言"
        }
    }

    static func settingsAppearanceSection(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Aspetto"
        case .english: return "Appearance"
        case .german: return "Darstellung"
        case .chinese: return "外观"
        }
    }

    static func settingsAboutSection(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Informazioni"
        case .english: return "About"
        case .german: return "Über"
        case .chinese: return "关于"
        }
    }

    static func settingsButtonAccessibility(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Apri preferenze"
        case .english: return "Open settings"
        case .german: return "Einstellungen öffnen"
        case .chinese: return "打开设置"
        }
    }
}

extension TBDisplayCapturePreset {
    func title(_ language: TBDisplaySenderLanguage) -> String {
        switch self {
        case .standard1440p: return "Standard"
        case .smooth1440p60: return "Smooth"
        case .smooth1800p60: return "Smooth+"
        case .crisp2160p60:  return "Crisp"
        case .native5k:      return "5K"
        }
    }
}
