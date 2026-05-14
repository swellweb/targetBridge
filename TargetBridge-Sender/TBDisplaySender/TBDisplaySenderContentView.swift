import SwiftUI

struct TBDisplaySenderContentView: View {
    @ObservedObject var service: TBDisplaySenderService

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(TBDisplaySenderL10n.appName(service.language))
                    .font(.title2.weight(.semibold))
                Text(TBDisplaySenderL10n.appSubtitle(service.language))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            GroupBox(TBDisplaySenderL10n.connectionGroup(service.language)) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(TBDisplaySenderL10n.localTBIP(service.language))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(service.myTBIP ?? TBDisplaySenderL10n.notDetected(service.language))
                            .font(.system(.body, design: .monospaced))
                    }

                    HStack {
                        Text(TBDisplaySenderL10n.receiverIP(service.language))
                            .foregroundStyle(.secondary)
                        TextField("169.254.x.x", text: $service.receiverIP)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .disabled(service.isConnected || service.isStreaming)
                    }

                    HStack(spacing: 10) {
                        Button(service.isConnected ? TBDisplaySenderL10n.stopButton(service.language) : TBDisplaySenderL10n.connectButton(service.language)) {
                            if service.isConnected {
                                service.stop()
                            } else {
                                service.connect()
                            }
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!service.isConnected && trimmedReceiverIP.isEmpty)

                        Button(TBDisplaySenderL10n.refreshIPButton(service.language)) {
                            service.refreshTBIP()
                        }

                        Spacer()

                        Text(service.statusText)
                            .foregroundStyle(service.isStreaming ? .green : .secondary)
                    }
                }
            }

            GroupBox(TBDisplaySenderL10n.languageGroup(service.language)) {
                Picker(TBDisplaySenderL10n.languageGroup(service.language), selection: $service.language) {
                    ForEach(TBDisplaySenderLanguage.allCases) { language in
                        Text(language.pickerTitle).tag(language)
                    }
                }
                .pickerStyle(.segmented)
            }

            GroupBox(TBDisplaySenderL10n.streamResolutionGroup(service.language)) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker(TBDisplaySenderL10n.streamProfile(service.language), selection: $service.capturePreset) {
                        ForEach(TBDisplayCapturePreset.allCases) { preset in
                            Text("\(preset.title(service.language)) · \(preset.description)").tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(service.isConnected || service.isStreaming)

                    Text(TBDisplaySenderL10n.streamHint1(service.language))
                    Text(TBDisplaySenderL10n.streamHint2(service.language))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            GroupBox(TBDisplaySenderL10n.monitorSessionGroup(service.language)) {
                VStack(alignment: .leading, spacing: 8) {
                    infoRow(TBDisplaySenderL10n.receiverLabel(service.language), service.receiverPanelText)
                    infoRow(TBDisplaySenderL10n.virtualDisplayLabel(service.language), service.virtualDisplayText)
                    infoRow(TBDisplaySenderL10n.streamLabel(service.language), service.streamResolutionText)
                    infoRow(TBDisplaySenderL10n.fpsLabel(service.language), "\(service.senderFPS)")
                }
            }

            GroupBox(TBDisplaySenderL10n.modeGroup(service.language)) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(TBDisplaySenderL10n.modeLine1(service.language))
                    Text(TBDisplaySenderL10n.modeLine2(service.language))
                    Text(TBDisplaySenderL10n.modeLine3(service.language))
                    Text(TBDisplaySenderL10n.modeLine4(service.language))
                    Text(TBDisplaySenderL10n.modeLine5(service.language))
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            Toggle(TBDisplaySenderL10n.showMenuBarIcon(service.language), isOn: $service.showsMenuBarIcon)

            HStack {
                Spacer()
                Text("\(TBDisplaySenderL10n.versionLabel(service.language)) \(TBDisplaySenderBuildInfo.versionDisplay)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(18)
        .task {
            service.refreshTBIP()
        }
    }

    private var trimmedReceiverIP: String {
        service.receiverIP.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
        }
    }
}
