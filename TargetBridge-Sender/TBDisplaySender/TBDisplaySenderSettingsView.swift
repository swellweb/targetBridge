import SwiftUI

struct TBDisplaySenderSettingsView: View {
    @ObservedObject var service: TBDisplaySenderService

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
        }
    }

    private var settingsSubtitle: String {
        switch service.language {
        case .italian: return "Preferenze globali dell’app separate dalla dashboard operativa."
        case .english: return "Global app preferences separated from the operational dashboard."
        case .german: return "Globale App-Einstellungen getrennt vom operativen Dashboard."
        }
    }

    private var generalTitle: String {
        switch service.language {
        case .italian: return "Generale"
        case .english: return "General"
        case .german: return "Allgemein"
        }
    }

    private var interfaceTitle: String {
        switch service.language {
        case .italian: return "Interfaccia"
        case .english: return "Interface"
        case .german: return "Oberfläche"
        }
    }

    private var behaviorTitle: String {
        switch service.language {
        case .italian: return "Comportamento"
        case .english: return "Behavior"
        case .german: return "Verhalten"
        }
    }

    private var aboutTitle: String {
        switch service.language {
        case .italian: return "About"
        case .english: return "About"
        case .german: return "Info"
        }
    }

    private var aboutBody: String {
        switch service.language {
        case .italian: return "TargetBridge e una utility open source per riutilizzare pannelli iMac Intel come display esterni per Mac moderni. Le preferenze generali vivono qui; le impostazioni operative di ogni sessione restano nella finestra principale."
        case .english: return "TargetBridge is an open-source utility for reusing Intel iMac panels as external displays for modern Macs. Global preferences live here; per-session operational settings stay in the main window."
        case .german: return "TargetBridge ist ein Open-Source-Werkzeug, um Intel-iMac-Panels als externe Displays fuer moderne Macs weiterzuverwenden. Globale Einstellungen leben hier; operative Sitzungsoptionen bleiben im Hauptfenster."
        }
    }

    private var githubTitle: String {
        switch service.language {
        case .italian: return "GitHub"
        case .english: return "GitHub"
        case .german: return "GitHub"
        }
    }

    private var releaseTitle: String {
        switch service.language {
        case .italian: return "Ultima release"
        case .english: return "Latest release"
        case .german: return "Letztes Release"
        }
    }

    private var versionTitle: String {
        switch service.language {
        case .italian: return "Versione"
        case .english: return "Version"
        case .german: return "Version"
        }
    }
}
