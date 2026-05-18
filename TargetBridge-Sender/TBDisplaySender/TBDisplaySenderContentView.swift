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

            GeometryReader { geometry in
                HStack(alignment: .top, spacing: 16) {
                    GroupBox(TBDisplaySenderL10n.connectionGroup(service.language)) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Local: \(service.myTBIP ?? TBDisplaySenderL10n.notDetected(service.language))")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(service.statusText)
                                    .foregroundStyle(service.isStreaming ? .green : .secondary)
                            }

                            HStack {
                                Text(TBDisplaySenderL10n.receiverIP(service.language))
                                    .foregroundStyle(.secondary)
                                TextField("169.254.x.x", text: $service.receiverIP)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.body, design: .monospaced))
                                    .disabled(service.isConnected || service.isStreaming)
                            }

                            HStack(spacing: 8) {
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

                                Button(action: {
                                    service.startCableTest()
                                }) {
                                    HStack(spacing: 4) {
                                        if service.isCableTesting {
                                            ProgressView()
                                                .progressViewStyle(.circular)
                                                .controlSize(.small)
                                        }
                                        Text(service.isCableTesting ? TBDisplaySenderL10n.testingButton(service.language) : TBDisplaySenderL10n.cableTestButton(service.language))
                                    }
                                }
                                .disabled(service.isConnected || service.isCableTesting || trimmedReceiverIP.isEmpty)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    .frame(width: (geometry.size.width - 16) * 0.6)

                    GroupBox(TBDisplaySenderL10n.cableTestGroup(service.language)) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(TBDisplaySenderL10n.transferRateLabel(service.language))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if let rate = service.cableTestResult {
                                    Text(String(format: "%.2f Gbits/s", rate))
                                        .font(.system(.body, design: .monospaced).bold())
                                        .foregroundStyle(.green)
                                } else {
                                    Text(TBDisplaySenderL10n.noTestResult(service.language))
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Divider()

                            Text("TCP throughput is expected to be less than cable rating (e.g. ~20Gb/s for a 40Gb/s cable).")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    .frame(width: (geometry.size.width - 16) * 0.4)
                }
            }
            .frame(height: 105)

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
                    Picker(TBDisplaySenderL10n.captureSource(service.language), selection: $service.captureSource) {
                        ForEach(TBDisplayCaptureSource.allCases) { source in
                            Text(source.title(service.language)).tag(source)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(service.isConnected || service.isStreaming)

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
                    infoRow("Capture", service.captureDisplayText)
                    infoRow("State", service.displayStateText)
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
            Toggle(TBDisplaySenderL10n.largeCursor(service.language), isOn: $service.largeCursor)
                .disabled(service.isConnected || service.isStreaming)

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
