import SwiftUI

struct TBDisplaySenderAboutView: View {
    @ObservedObject var service: TBDisplaySenderService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
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
                        Image(systemName: "display.2")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.95))
                    }
                    .frame(width: 74, height: 74)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(TBDisplaySenderL10n.appName(service.language))
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                        Text(aboutSubtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        versionChip
                    }

                    Spacer()

                    Button(closeTitle) {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                }
            }

            SurfaceCard {
                VStack(alignment: .leading, spacing: 14) {
                    sectionHeading(projectTitle)
                    Text(projectDescription)
                        .font(.body)
                        .foregroundStyle(.primary)
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

            SurfaceCard {
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeading(creditsTitle)
                    Text(creditsBody)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 420)
        .background(appBackground)
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

    private func sectionHeading(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(.caption, design: .rounded, weight: .bold))
            .tracking(1.0)
            .foregroundStyle(.secondary)
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

    private var aboutSubtitle: String {
        switch service.language {
        case .italian: return "Riporta l'idea di Target Display Mode nel mondo Apple Silicon con una pipeline diretta Mac-to-Mac."
        case .english: return "Brings the Target Display Mode idea back to Apple Silicon with a direct Mac-to-Mac display pipeline."
        case .german: return "Bringt die Idee von Target Display Mode mit einer direkten Mac-zu-Mac-Display-Pipeline zurück auf Apple Silicon."
        }
    }

    private var projectTitle: String {
        switch service.language {
        case .italian: return "Progetto"
        case .english: return "Project"
        case .german: return "Projekt"
        }
    }

    private var projectDescription: String {
        switch service.language {
        case .italian: return "TargetBridge cattura il desktop o il monitor virtuale sul Mac sender, codifica lo stream e lo presenta su un iMac receiver via Thunderbolt Bridge o Network Link sperimentale."
        case .english: return "TargetBridge captures the sender desktop or virtual display, encodes the stream, and presents it on an iMac receiver over Thunderbolt Bridge or experimental Network Link."
        case .german: return "TargetBridge erfasst den Sender-Desktop oder das virtuelle Display, kodiert den Stream und zeigt ihn auf einem iMac-Empfänger über Thunderbolt Bridge oder experimentellen Network Link an."
        }
    }

    private var creditsTitle: String {
        switch service.language {
        case .italian: return "Crediti"
        case .english: return "Credits"
        case .german: return "Mitwirkende"
        }
    }

    private var creditsBody: String {
        switch service.language {
        case .italian: return "Creato da swellweb con il supporto della community open source TargetBridge. Contributi chiave da tester e collaboratori come ThomasWaldmann, DrDavidL, potar712 e altri membri della community."
        case .english: return "Created by swellweb with support from the TargetBridge open-source community. Key contributions from testers and collaborators such as ThomasWaldmann, DrDavidL, potar712, and other community members."
        case .german: return "Erstellt von swellweb mit Unterstützung der TargetBridge-Open-Source-Community. Wichtige Beiträge von Testern und Mitwirkenden wie ThomasWaldmann, DrDavidL, potar712 und weiteren Community-Mitgliedern."
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

    private var closeTitle: String {
        switch service.language {
        case .italian: return "Chiudi"
        case .english: return "Close"
        case .german: return "Schließen"
        }
    }
}
