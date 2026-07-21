import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TBDisplaySenderSettingsView: View {
    @ObservedObject var service: TBDisplaySenderService
    @State private var importError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SurfaceCard {
                    HStack(alignment: .top, spacing: 16) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color.green.opacity(0.30),
                                            Color.cyan.opacity(0.16)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.95))
                        }
                        .frame(width: 68, height: 68)

                        VStack(alignment: .leading, spacing: 8) {
                            Text(settingsTitle)
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                            Text(settingsSubtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            versionChip
                        }

                        Spacer()
                    }
                }

                settingsSection(title: generalTitle) {
                    Picker(TBDisplaySenderL10n.languageGroup(service.language), selection: $service.language) {
                        ForEach(TBDisplaySenderLanguage.allCases) { language in
                            Text(language.pickerTitle).tag(language)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                settingsSection(title: interfaceTitle) {
                    Toggle(TBDisplaySenderL10n.showMenuBarIcon(service.language), isOn: $service.showsMenuBarIcon)
                    Toggle(TBDisplaySenderL10n.largeCursor(service.language), isOn: $service.largeCursor)
                        .disabled(service.anyConnected)
                    Toggle(TBDisplaySenderL10n.preventDisplaySleep(service.language), isOn: $service.preventDisplaySleep)
                    Toggle(TBDisplaySenderL10n.autoRestartOnWake(service.language), isOn: $service.autoRestartOnWake)
                    Toggle(TBDisplaySenderL10n.verboseDisplayLogging(service.language), isOn: $service.verboseDisplayLogging)
                    Toggle(TBDisplaySenderL10n.volumeKeysControlReceiver(service.language), isOn: $service.volumeKeysControlReceiver)
                    if service.volumeKeyRelayNeedsAccessibility {
                        Text(TBDisplaySenderL10n.volumeKeysAccessibilityHint(service.language))
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                settingsSection(title: behaviorTitle) {
                    Text(TBDisplaySenderL10n.settingsHint(service.language))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(TBDisplaySenderL10n.modeLine3(service.language))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(TBDisplaySenderL10n.modeLine5(service.language))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                settingsSection(title: addonsTitle) {
                    Text(addonsSubtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if service.anyConnected {
                        Text(addonsConnectedHint)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 12) {
                        Button(importAddonTitle) {
                            importAddonManifest()
                        }
                        .buttonStyle(.borderedProminent)

                        Button(refreshAddonsTitle) {
                            service.refreshAddons()
                        }
                        .buttonStyle(.bordered)

                        Button(openAddonsFolderTitle) {
                            service.openAddonsFolder()
                        }
                        .buttonStyle(.bordered)
                    }

                    if service.addons.isEmpty {
                        Text(noAddonsTitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(service.addons) { addon in
                                addonCard(addon)
                            }
                        }
                    }
                }

                settingsSection(title: aboutTitle) {
                    Text(aboutBody)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 12) {
                        Link(destination: URL(string: "https://github.com/swellweb/targetBridge")!) {
                            Label(githubTitle, systemImage: "link")
                        }
                        .buttonStyle(.borderedProminent)

                        Link(destination: URL(string: "https://github.com/swellweb/targetBridge/releases/latest")!) {
                            Label(releaseTitle, systemImage: "shippingbox")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding(20)
        }
        .background(appBackground)
        .alert(addonImportErrorTitle, isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) {
                importError = nil
            }
        } message: {
            Text(importError ?? "")
        }
    }

    private func settingsSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(title.uppercased())
                    .font(.system(.caption, design: .rounded, weight: .bold))
                    .tracking(1.0)
                    .foregroundStyle(.secondary)
                content()
            }
        }
    }

    private var versionChip: some View {
        Text("\(versionTitle) \(TBDisplaySenderBuildInfo.versionDisplay)")
            .font(.system(.footnote, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
    }

    private func addonCard(_ addon: TBAddonRecord) -> some View {
        SurfaceSubcard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(addon.name)
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                        Text(addon.summary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()

                    Toggle(
                        service.isAddonEnabled(addon) ? addonEnabledTitle : addonDisabledTitle,
                        isOn: Binding(
                            get: { service.isAddonEnabled(addon) },
                            set: { service.setAddonEnabled($0, for: addon) }
                        )
                    )
                    .toggleStyle(.switch)
                    .disabled(!service.isAddonCompatible(addon) || service.anyConnected)
                }

                HStack(spacing: 8) {
                    addonChip(originTitle(for: addon.origin), tint: addon.origin == .bundled ? .cyan : .orange)
                    addonChip("\(versionTitle) \(addon.version)", tint: .secondary)
                    if addon.manifest.experimental {
                        addonChip(experimentalTitle, tint: .yellow)
                    }
                    if !service.isAddonCompatible(addon) {
                        addonChip(incompatibleTitle, tint: .red)
                    }
                }

                    if !addon.manifest.capabilities.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(capabilitiesTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            ForEach(addon.manifest.capabilities, id: \.self) { capability in
                                addonChip(capabilityTitle(for: capability), tint: .green)
                            }
                        }
                    }
                }
            }
        }
    }

    private func addonChip(_ title: String, tint: Color) -> some View {
        Text(title)
            .font(.system(.caption, design: .rounded, weight: .bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.12))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(tint.opacity(0.25), lineWidth: 1)
            )
    }

    private func importAddonManifest() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = importPanelMessage

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try service.importAddonManifest(from: url)
        } catch {
            importError = error.localizedDescription
        }
    }

    private var appBackground: some View {
        LinearGradient(
            colors: [
                Color(red: 0.12, green: 0.13, blue: 0.14),
                Color(red: 0.08, green: 0.09, blue: 0.10)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private var settingsTitle: String {
        switch service.language {
        case .italian: return "Impostazioni TargetBridge"
        case .english: return "TargetBridge Settings"
        case .german: return "TargetBridge-Einstellungen"
        case .chinese: return "TargetBridge 设置"
        }
    }

    private var settingsSubtitle: String {
        switch service.language {
        case .italian: return "Preferenze globali dell’app separate dalla dashboard operativa."
        case .english: return "Global app preferences separated from the operational dashboard."
        case .german: return "Globale App-Einstellungen getrennt vom operativen Dashboard."
        case .chinese: return "全局应用偏好设置与主操作面板分离。"
        }
    }

    private var generalTitle: String {
        switch service.language {
        case .italian: return "Generale"
        case .english: return "General"
        case .german: return "Allgemein"
        case .chinese: return "通用"
        }
    }

    private var interfaceTitle: String {
        switch service.language {
        case .italian: return "Interfaccia"
        case .english: return "Interface"
        case .german: return "Oberfläche"
        case .chinese: return "界面"
        }
    }

    private var behaviorTitle: String {
        switch service.language {
        case .italian: return "Comportamento"
        case .english: return "Behavior"
        case .german: return "Verhalten"
        case .chinese: return "行为"
        }
    }

    private var aboutTitle: String {
        switch service.language {
        case .italian: return "About"
        case .english: return "About"
        case .german: return "Info"
        case .chinese: return "关于"
        }
    }

    private var aboutBody: String {
        switch service.language {
        case .italian: return "TargetBridge e una utility open source per riutilizzare pannelli iMac Intel come display esterni per Mac moderni. Le preferenze generali vivono qui; le impostazioni operative di ogni sessione restano nella finestra principale."
        case .english: return "TargetBridge is an open-source utility for reusing Intel iMac panels as external displays for modern Macs. Global preferences live here; per-session operational settings stay in the main window."
        case .german: return "TargetBridge ist ein Open-Source-Werkzeug, um Intel-iMac-Panels als externe Displays für moderne Macs weiterzuverwenden. Globale Einstellungen sind hier; operative Sitzungsoptionen sind im Hauptfenster."
        case .chinese: return "TargetBridge 是一个开源工具，可将 Intel iMac 面板重新用作现代 Mac 的外接显示器。全局偏好设置在这里管理；每个会话的操作设置保留在主窗口中。"
        }
    }

    private var githubTitle: String {
        switch service.language {
        case .italian: return "GitHub"
        case .english: return "GitHub"
        case .german: return "GitHub"
        case .chinese: return "GitHub"
        }
    }

    private var releaseTitle: String {
        switch service.language {
        case .italian: return "Ultima release"
        case .english: return "Latest release"
        case .german: return "Letztes Release"
        case .chinese: return "最新发布"
        }
    }

    private var versionTitle: String {
        switch service.language {
        case .italian: return "Versione"
        case .english: return "Version"
        case .german: return "Version"
        case .chinese: return "版本"
        }
    }

    private var addonsTitle: String {
        switch service.language {
        case .italian: return "Add-on"
        case .english: return "Add-ons"
        case .german: return "Add-ons"
        case .chinese: return "附加组件"
        }
    }

    private var addonsSubtitle: String {
        switch service.language {
        case .italian: return "Gli add-on vengono letti da manifest JSON sicuri. Quelli ufficiali sono inclusi nell'app, mentre quelli personalizzati si importano nella cartella Addons utente."
        case .english: return "Add-ons are loaded from safe JSON manifests. Official ones ship with the app, while custom ones can be imported into the user Addons folder."
        case .german: return "Add-ons werden aus sicheren JSON-Manifests geladen. Offizielle Add-ons sind in der App enthalten, benutzerdefinierte können in den Benutzer-Addons-Ordner importiert werden."
        case .chinese: return "附加组件通过安全的 JSON 清单加载。官方附加组件随应用提供，自定义附加组件可导入到用户 Addons 文件夹。"
        }
    }

    private var importAddonTitle: String {
        switch service.language {
        case .italian: return "Importa Add-on..."
        case .english: return "Import Add-on..."
        case .german: return "Add-on importieren..."
        case .chinese: return "导入附加组件..."
        }
    }

    private var refreshAddonsTitle: String {
        switch service.language {
        case .italian: return "Ricarica"
        case .english: return "Reload"
        case .german: return "Neu laden"
        case .chinese: return "重新加载"
        }
    }

    private var openAddonsFolderTitle: String {
        switch service.language {
        case .italian: return "Apri cartella Addons"
        case .english: return "Open Addons Folder"
        case .german: return "Add-ons-Ordner öffnen"
        case .chinese: return "打开 Addons 文件夹"
        }
    }

    private var noAddonsTitle: String {
        switch service.language {
        case .italian: return "Nessun add-on trovato. Importa un manifest JSON oppure usa quelli ufficiali inclusi."
        case .english: return "No add-ons found. Import a JSON manifest or use the bundled official ones."
        case .german: return "Keine Add-ons gefunden. Importiere ein JSON-Manifest oder nutze die eingebauten offiziellen Add-ons."
        case .chinese: return "未找到附加组件。请导入 JSON 清单或使用内置官方附加组件。"
        }
    }

    private var addonsConnectedHint: String {
        switch service.language {
        case .italian: return "Ferma tutte le sessioni prima di attivare o disattivare un add-on."
        case .english: return "Stop all sessions before enabling or disabling an add-on."
        case .german: return "Beende alle Sitzungen, bevor du ein Add-on aktivierst oder deaktivierst."
        case .chinese: return "请先停止所有会话，再启用或禁用附加组件。"
        }
    }

    private var addonEnabledTitle: String {
        switch service.language {
        case .italian: return "Attivo"
        case .english: return "Enabled"
        case .german: return "Aktiv"
        case .chinese: return "已启用"
        }
    }

    private var addonDisabledTitle: String {
        switch service.language {
        case .italian: return "Disattivato"
        case .english: return "Disabled"
        case .german: return "Deaktiviert"
        case .chinese: return "已禁用"
        }
    }

    private var experimentalTitle: String {
        switch service.language {
        case .italian: return "Sperimentale"
        case .english: return "Experimental"
        case .german: return "Experimentell"
        case .chinese: return "实验性"
        }
    }

    private var incompatibleTitle: String {
        switch service.language {
        case .italian: return "Incompatibile"
        case .english: return "Incompatible"
        case .german: return "Inkompatibel"
        case .chinese: return "不兼容"
        }
    }

    private var capabilitiesTitle: String {
        switch service.language {
        case .italian: return "Capability"
        case .english: return "Capabilities"
        case .german: return "Fähigkeiten"
        case .chinese: return "能力"
        }
    }

    private var addonImportErrorTitle: String {
        switch service.language {
        case .italian: return "Importazione add-on fallita"
        case .english: return "Add-on import failed"
        case .german: return "Add-on-Import fehlgeschlagen"
        case .chinese: return "导入附加组件失败"
        }
    }

    private var importPanelMessage: String {
        switch service.language {
        case .italian: return "Seleziona un file manifest JSON per l'add-on."
        case .english: return "Choose a JSON manifest file for the add-on."
        case .german: return "Wähle eine JSON-Manifestdatei für das Add-on."
        case .chinese: return "请选择附加组件的 JSON 清单文件。"
        }
    }

    private func originTitle(for origin: TBAddonOrigin) -> String {
        switch (origin, service.language) {
        case (.bundled, .italian): return "Ufficiale"
        case (.bundled, .english): return "Bundled"
        case (.bundled, .german): return "Mitgeliefert"
        case (.bundled, .chinese): return "内置"
        case (.user, .italian): return "Utente"
        case (.user, .english): return "User"
        case (.user, .german): return "Benutzer"
        case (.user, .chinese): return "用户"
        }
    }

    private func capabilityTitle(for capability: TBAddonCapability) -> String {
        switch (capability, service.language) {
        case (.networkLink, .italian): return "Network Link"
        case (.networkLink, .english): return "Network Link"
        case (.networkLink, .german): return "Network Link"
        case (.networkLink, .chinese): return "网络链路"
        case (.audioRelay, .italian): return "Audio Relay"
        case (.audioRelay, .english): return "Audio Relay"
        case (.audioRelay, .german): return "Audio Relay"
        case (.audioRelay, .chinese): return "音频转发"
        case (.inputDockstation, .italian): return "Input Dockstation"
        case (.inputDockstation, .english): return "Input Dockstation"
        case (.inputDockstation, .german): return "Input Dockstation"
        case (.inputDockstation, .chinese): return "输入扩展坞"
        }
    }
}
