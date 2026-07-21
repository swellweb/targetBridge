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

    var fileStem: String {
        switch self {
        case .italian: return "it"
        case .english: return "en"
        case .german: return "de"
        case .chinese: return "zh"
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
    case testingCable

    func text(_ language: TBDisplaySenderLanguage) -> String {
        switch self {
        case .ready:
            return TBDisplaySenderL10n.text("sender.status.ready", language)
        case let .connecting(ip):
            return TBDisplaySenderL10n.text("sender.status.connecting", language, ["ip": ip])
        case .waitingDisplayProfile:
            return TBDisplaySenderL10n.text("sender.status.waiting_display_profile", language)
        case let .connectionFailed(error):
            return TBDisplaySenderL10n.text("sender.status.connection_failed", language, ["error": error])
        case .stopped:
            return TBDisplaySenderL10n.text("sender.status.stopped", language)
        case let .connectionClosed(error):
            return TBDisplaySenderL10n.text("sender.status.connection_closed", language, ["error": error])
        case .receiverClosedDuringCapture:
            return TBDisplaySenderL10n.text("sender.status.receiver_closed_during_capture", language)
        case .receiverClosedConnection:
            return TBDisplaySenderL10n.text("sender.status.receiver_closed_connection", language)
        case .receiverTerminatedSession:
            return TBDisplaySenderL10n.text("sender.status.receiver_terminated_session", language)
        case .creatingVirtualDisplay:
            return TBDisplaySenderL10n.text("sender.status.creating_virtual_display", language)
        case .virtualDisplayCreationFailed:
            return TBDisplaySenderL10n.text("sender.status.virtual_display_creation_failed", language)
        case let .startingCapture(resolution, source):
            let sourceText = language == .german ? source.title(language) : source.title(language).lowercased()
            return TBDisplaySenderL10n.text("sender.status.starting_capture", language, [
                "resolution": resolution,
                "source": sourceText
            ])
        case .captureStartedWaitingFirstFrame:
            return TBDisplaySenderL10n.text("sender.status.capture_started_waiting_first_frame", language)
        case let .captureActive(resolution, codec, source):
            return TBDisplaySenderL10n.text("sender.status.capture_active", language, [
                "resolution": resolution,
                "codec": codec,
                "source": source.title(language)
            ])
        case let .captureError(error):
            return TBDisplaySenderL10n.text("sender.status.capture_error", language, ["error": error])
        case let .captureDesktopError(error):
            return TBDisplaySenderL10n.text("sender.status.capture_desktop_error", language, ["error": error])
        case let .noShareableDisplay(details):
            return TBDisplaySenderL10n.text("sender.status.no_shareable_display", language, ["details": details])
        case .hevcNoFrames:
            return TBDisplaySenderL10n.text("sender.status.hevc_no_frames", language)
        case .noFirstFrame:
            return TBDisplaySenderL10n.text("sender.status.no_first_frame", language)
        case .testingCable:
            return TBDisplaySenderL10n.text("sender.status.testing_cable", language)
        }
    }
}

enum TBDisplaySenderL10n {
    private static let store = TBLocalizationStore.shared

    static func text(_ key: String, _ language: TBDisplaySenderLanguage, _ values: [String: String] = [:]) -> String {
        store.string(key, language: language, values: values)
    }

    static func appName(_ language: TBDisplaySenderLanguage) -> String {
        text("common.app_name", language)
    }

    static func appSubtitle(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.app_subtitle", language)
    }

    static func cableTestGroup(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.section.cable_test", language)
    }

    static func cableTestButton(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.cable_test.button", language)
    }

    static func testingButton(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.cable_test.testing", language)
    }

    static func transferRateLabel(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.cable_test.transfer_rate", language)
    }

    static func noTestResult(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.cable_test.none", language)
    }

    static func connectionGroup(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.section.connection", language)
    }

    static func localTBIP(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.label.local_tb_ip", language)
    }

    static func availableTBInterfaces(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.available_tb_interfaces", language)
    }

    static func transportKind(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Trasporto"
        case .english: return "Transport"
        case .german: return "Transport"
        case .chinese: return "传输"
        }
    }

    static func localInterfaceIP(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "IP locale"
        case .english: return "Local interface IP"
        case .german: return "Lokale Interface-IP"
        case .chinese: return "本地接口 IP"
        }
    }

    static func availableLocalInterfaces(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Interfacce locali disponibili"
        case .english: return "Available local interfaces"
        case .german: return "Verfügbare lokale Schnittstellen"
        case .chinese: return "可用本地接口"
        }
    }

    static func notDetected(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.option.not_detected", language)
    }

    static func receiverIP(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.label.receiver_ip", language)
    }

    static func discoveredReceiver(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.label.discovered_receiver", language)
    }

    static func manualReceiverEntry(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.option.manual_entry", language)
    }

    static func connectButton(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.button.connect", language)
    }

    static func stopButton(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.button.stop", language)
    }

    static func refreshIPButton(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.button.refresh_ip", language)
    }

    static func addSessionButton(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.button.add_session", language)
    }

    static func stopAllButton(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.button.stop_all", language)
    }

    static func removeSessionButton(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.button.remove_session", language)
    }

    static func languageGroup(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.section.language", language)
    }

    static func streamResolutionGroup(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.group.stream_profile", language)
    }

    static func streamProfile(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.group.stream_profile", language)
    }

    static func displayProfiles(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.group.display_profiles", language)
    }

    static func displayProfilesHint(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.display_profiles.hint", language)
    }

    static func displayProfileTitle(_ profile: TBDisplayProfile, language: TBDisplaySenderLanguage) -> String {
        switch profile {
        case .work5K:
            return text("sender.display_profiles.work_5k", language)
        case .lowLatency:
            return text("sender.display_profiles.low_latency", language)
        case .presentation:
            return text("sender.display_profiles.presentation", language)
        }
    }

    static func captureSource(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.group.capture_source", language)
    }

    static func streamHint1(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.stream_hint_1", language)
    }

    static func streamHint2(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.stream_hint_2", language)
    }

    static func multiSessionHint(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.multi_session_hint", language)
    }

    static func discoveryHint(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.discovery_hint", language)
    }

    static func monitorSessionGroup(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.section.monitor_session", language)
    }

    static func receiverLabel(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.label.receiver", language)
    }

    static func virtualDisplayLabel(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.label.virtual_display", language)
    }

    static func streamLabel(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.label.stream", language)
    }

    static func fpsLabel(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.label.sender_fps", language)
    }

    static func captureLabel(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.label.capture", language)
    }

    static func stateLabel(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.label.state", language)
    }

    static func modeGroup(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.section.mode", language)
    }

    static func modeLine1(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.mode_line_1", language)
    }

    static func modeLine2(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.mode_line_2", language)
    }

    static func modeLine3(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.mode_line_3", language)
    }

    static func modeLine4(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.mode_line_4", language)
    }

    static func modeLine5(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.mode_line_5", language)
    }

    static func versionLabel(_ language: TBDisplaySenderLanguage) -> String {
        text("common.version_label", language)
    }

    static func settingsTitle(_ language: TBDisplaySenderLanguage) -> String {
        text("common.settings", language)
    }

    static func showMenuBarIcon(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.toggle.show_menu_bar_icon", language)
    }

    static func showSettings(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Mostra impostazioni"
        case .english: return "Show settings"
        case .german: return "Einstellungen anzeigen"
        case .chinese: return "显示设置"
        }
    }

    static func hideSettings(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Nascondi impostazioni"
        case .english: return "Hide settings"
        case .german: return "Einstellungen ausblenden"
        case .chinese: return "隐藏设置"
        }
    }

    static func settingsHint(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Lascia visibili solo i controlli quotidiani e apri qui le preferenze quando devi riconfigurare."
        case .english: return "Keep daily controls visible and open this section only when you need to reconfigure the app."
        case .german: return "Lass die täglichen Steuerelemente sichtbar und öffne diesen Bereich nur, wenn du die App neu konfigurieren musst."
        case .chinese: return "让日常控制保持可见，只在需要重新配置应用时再打开这里。"
        }
    }

    static func largeCursor(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.toggle.large_cursor", language)
    }

    static func preventDisplaySleep(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.toggle.prevent_display_sleep", language)
    }

    static func autoRestartOnWake(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.toggle.auto_restart_on_wake", language)
    }

    static func restartCaptureButton(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.button.restart_capture", language)
    }

    static func streamAudio(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.toggle.stream_audio", language)
    }

    static func defaultStreamAudio(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.toggle.default_stream_audio", language)
    }

    static func verboseDisplayLogging(_ language: TBDisplaySenderLanguage) -> String {
        switch language {
        case .italian: return "Diagnostica display in Console (verboso)"
        case .english: return "Log virtual display events to Console (verbose)"
        case .german: return "Virtuelle Display-Ereignisse in Konsole protokollieren (ausführlich)"
        case .chinese: return "将虚拟显示事件详细记录到 Console"
        }
    }

    static func showMainWindow(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.menu.show_main_window", language)
    }

    static func topBarIP(_ language: TBDisplaySenderLanguage, _ ip: String) -> String {
        text("sender.top_bar_ip", language, ["ip": ip])
    }

    static func sessionTitle(_ language: TBDisplaySenderLanguage, index: Int) -> String {
        text("sender.session_title", language, ["index": "\(index)"])
    }

    static func multiSessionSummaryConnected(_ language: TBDisplaySenderLanguage, active: Int, total: Int) -> String {
        text("sender.multi_session_summary_connected", language, [
            "active": "\(active)",
            "total": "\(total)"
        ])
    }

    static func multiSessionSummaryStreaming(_ language: TBDisplaySenderLanguage, active: Int, total: Int) -> String {
        text("sender.multi_session_summary_streaming", language, [
            "active": "\(active)",
            "total": "\(total)"
        ])
    }

    static func hideMenuBarIcon(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.menu.hide_top_bar_icon", language)
    }

    static func quitApp(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.menu.quit", language)
    }

    static func topBarToolTip(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.tooltip.top_bar", language)
    }

    static func waitingReceiverProfile(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.waiting_receiver_profile", language)
    }

    static func virtualDisplayNotCreated(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.virtual_display_not_created", language)
    }

    static func receiverSummary(_ profile: TBMonitorDisplayProfile, language: TBDisplaySenderLanguage) -> String {
        text("sender.receiver_summary", language, [
            "name": profile.receiverName,
            "panelWidth": "\(profile.panelWidth)",
            "panelHeight": "\(profile.panelHeight)",
            "modeWidth": "\(profile.modeWidth)",
            "modeHeight": "\(profile.modeHeight)"
        ])
    }

    static func virtualDisplaySummary(name: String, id: UInt32, language: TBDisplaySenderLanguage) -> String {
        text("sender.virtual_display_summary", language, [
            "name": name,
            "id": "\(id)"
        ])
    }

    static func streamSummary(preset: TBDisplayCapturePreset, source: TBDisplayCaptureSource, language: TBDisplaySenderLanguage, codecName: String? = nil) -> String {
        text("sender.stream_summary", language, [
            "source": source.title(language),
            "description": preset.description,
            "preset": preset.title(language),
            "codec": codecName ?? preset.codecName
        ])
    }

    static func missingScreenRecordingPermission(language: TBDisplaySenderLanguage) -> String {
        text("sender.error.screen_recording_permission", language)
    }

    static func screenCaptureKitPermissionMismatch(details: String, language: TBDisplaySenderLanguage) -> String {
        text("sender.error.sck_permission_mismatch", language, ["details": details])
    }

    static func routingTitle(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.section.routing", language)
    }

    static func outputTitle(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.section.output", language)
    }

    static func sessionMonitorTitle(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.section.monitor_session", language)
    }

    static func statusChipLive(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.status_chip.live", language)
    }

    static func statusChipConnected(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.status_chip.connected", language)
    }

    static func statusChipIdle(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.status_chip.idle", language)
    }

    static func captureDisplayNotAvailable(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.capture_display.na", language)
    }

    static func captureDisplaySCDisplay(_ language: TBDisplaySenderLanguage, id: UInt32) -> String {
        text("sender.capture_display.scdisplay", language, ["id": "\(id)"])
    }

    static func captureDisplayCGDisplayStream(_ language: TBDisplaySenderLanguage, id: UInt32) -> String {
        text("sender.capture_display.cgdisplaystream", language, ["id": "\(id)"])
    }

    static func displayStateNotAvailable(_ language: TBDisplaySenderLanguage) -> String {
        text("sender.display_state.na", language)
    }

    static func displayStateSummary(language: TBDisplaySenderLanguage,
                                    identity: String,
                                    virtual: UInt32,
                                    virtualMirror: Bool,
                                    virtualMirrors: UInt32,
                                    main: UInt32,
                                    mainMirror: Bool,
                                    mainMirrors: UInt32) -> String {
        text("sender.display_state.summary", language, [
            "identity": identity,
            "virtual": "\(virtual)",
            "virtualMirror": "\(virtualMirror)",
            "virtualMirrors": "\(virtualMirrors)",
            "main": "\(main)",
            "mainMirror": "\(mainMirror)",
            "mainMirrors": "\(mainMirrors)"
        ])
    }
}

extension TBDisplayCapturePreset {
    func title(_ language: TBDisplaySenderLanguage) -> String {
        switch self {
        case .standard1440p:
            return TBDisplaySenderL10n.text("sender.profile.standard", language)
        case .smooth1440p60:
            return TBDisplaySenderL10n.text("sender.profile.smooth", language)
        case .smooth1800p60:
            return TBDisplaySenderL10n.text("sender.profile.smooth_plus", language)
        case .crisp2160p60:
            return TBDisplaySenderL10n.text("sender.profile.crisp", language)
        case .native5k:
            return TBDisplaySenderL10n.text("sender.profile.native_5k", language)
        }
    }
}
