import SwiftUI

struct TBDisplaySenderContentView: View {
    @ObservedObject var service: TBDisplaySenderService

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerCard
                connectionCard
                languageCard

                ForEach(service.sessions) { session in
                    TBDisplaySenderSessionCard(service: service, session: session)
                }

                modeCard

                settingsCard

                HStack {
                    Spacer()
                    Text("\(TBDisplaySenderL10n.versionLabel(service.language)) \(TBDisplaySenderBuildInfo.versionDisplay)")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color.black.opacity(0.02))
        .task {
            service.refreshBridgeInterfaces()
        }
    }

    private var headerCard: some View {
        SurfaceCard {
            HStack(alignment: .top, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.green.opacity(0.28),
                                    Color.cyan.opacity(0.12)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: "display.2")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                }
                .frame(width: 58, height: 58)

                VStack(alignment: .leading, spacing: 6) {
                    Text(TBDisplaySenderL10n.appName(service.language))
                        .font(.system(size: 31, weight: .bold, design: .rounded))
                    Text(TBDisplaySenderL10n.appSubtitle(service.language))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 16)

                VStack(alignment: .trailing, spacing: 8) {
                    statusChip(
                        service.summaryStatusText(),
                        tint: service.anyStreaming ? .green : .secondary
                    )
                    Text(service.bridgeSummaryText)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }

    private var connectionCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeading(TBDisplaySenderL10n.connectionGroup(service.language))

                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(TBDisplaySenderL10n.availableTBInterfaces(service.language))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(TBDisplaySenderL10n.multiSessionHint(service.language))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(service.bridgeSummaryText)
                        .font(.system(.body, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }

                HStack(spacing: 10) {
                    Button(TBDisplaySenderL10n.addSessionButton(service.language)) {
                        service.addSession()
                    }
                    .buttonStyle(.borderedProminent)

                    Button(TBDisplaySenderL10n.refreshIPButton(service.language)) {
                        service.refreshBridgeInterfaces()
                    }
                    .buttonStyle(.bordered)

                    Button(TBDisplaySenderL10n.stopAllButton(service.language)) {
                        service.stopAll()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!service.anyConnected)
                }
            }
        }
    }

    private var languageCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeading(TBDisplaySenderL10n.languageGroup(service.language))
                Picker(TBDisplaySenderL10n.languageGroup(service.language), selection: $service.language) {
                    ForEach(TBDisplaySenderLanguage.allCases) { language in
                        Text(language.pickerTitle).tag(language)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
        }
    }

    private var modeCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeading(TBDisplaySenderL10n.modeGroup(service.language))

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
        }
    }

    private var settingsCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeading(settingsTitle)

                Toggle(TBDisplaySenderL10n.showMenuBarIcon(service.language), isOn: $service.showsMenuBarIcon)

                Toggle(TBDisplaySenderL10n.largeCursor(service.language), isOn: $service.largeCursor)
                    .disabled(service.anyConnected)

                Toggle(TBDisplaySenderL10n.preventDisplaySleep(service.language), isOn: $service.preventDisplaySleep)

                Toggle(TBDisplaySenderL10n.autoRestartOnWake(service.language), isOn: $service.autoRestartOnWake)

                Toggle(TBDisplaySenderL10n.verboseDisplayLogging(service.language), isOn: $service.verboseDisplayLogging)

                Toggle(TBDisplaySenderL10n.controlIMacKVM(service.language), isOn: $service.controlIMacKVM)
                    .disabled(!service.canControlIMac && !service.controlIMacKVM)

                if service.controlIMacKVM {
                    Label(TBDisplaySenderL10n.controlIMacKVMActive(service.language), systemImage: "keyboard.badge.ellipsis")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(.caption, design: .rounded, weight: .bold))
            .tracking(1.1)
            .foregroundStyle(.secondary)
    }

    private var settingsTitle: String {
        switch service.language {
        case .italian: return "Preferenze"
        case .english: return "Settings"
        case .german: return "Einstellungen"
        }
    }

    private func statusChip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(.footnote, design: .rounded, weight: .bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.12))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(tint.opacity(0.28), lineWidth: 1)
            )
    }
}

private struct TBDisplaySenderSessionCard: View {
    @ObservedObject var service: TBDisplaySenderService
    @ObservedObject var session: TBDisplaySenderSession

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 16) {
                topBar

                VStack(alignment: .leading, spacing: 10) {
                    sectionHeading(routingTitle)
                    controlRow(TBDisplaySenderL10n.localTBIP(service.language)) {
                        Picker(TBDisplaySenderL10n.localTBIP(service.language), selection: $session.localTBIP) {
                            Text(TBDisplaySenderL10n.notDetected(service.language)).tag("")
                            ForEach(service.bridgeInterfaces) { bridgeInterface in
                                Text(bridgeInterface.displayText).tag(bridgeInterface.ip)
                            }
                        }
                        .disabled(session.isConnected || session.isStreaming)
                    }

                    controlRow(TBDisplaySenderL10n.discoveredReceiver(service.language)) {
                        Picker(TBDisplaySenderL10n.discoveredReceiver(service.language), selection: $session.selectedReceiverID) {
                            Text(TBDisplaySenderL10n.manualReceiverEntry(service.language)).tag("")
                            ForEach(service.discoveredReceivers) { receiver in
                                Text(receiver.displayText).tag(receiver.id)
                            }
                        }
                        .onChange(of: session.selectedReceiverID) { _, newValue in
                            guard let receiver = service.discoveredReceivers.first(where: { $0.id == newValue }) else { return }
                            // Defer the mutation past SwiftUI's current view-update phase to avoid
                            // "Publishing changes from within view updates is not allowed".
                            DispatchQueue.main.async {
                                service.applyDiscoveredReceiver(receiver, to: session)
                            }
                        }
                        .disabled(session.isConnected || session.isStreaming)
                    }

                    controlRow(TBDisplaySenderL10n.receiverIP(service.language)) {
                        TextField("169.254.x.x", text: $session.receiverIP)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .disabled(session.isConnected || session.isStreaming)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    sectionHeading(outputTitle)
                    controlStack(TBDisplaySenderL10n.captureSource(service.language)) {
                        Picker("", selection: $session.captureSource) {
                            ForEach(TBDisplayCaptureSource.allCases) { source in
                                Text(source.title(service.language)).tag(source)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .disabled(session.isConnected || session.isStreaming)
                    }

                    controlStack(TBDisplaySenderL10n.streamProfile(service.language)) {
                        Picker("", selection: $session.capturePreset) {
                            ForEach(TBDisplayCapturePreset.allCases) { preset in
                                Text("\(preset.title(service.language)) · \(preset.description)").tag(preset)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .disabled(session.isConnected || session.isStreaming)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(TBDisplaySenderL10n.streamHint1(service.language))
                        Text(TBDisplaySenderL10n.streamHint2(service.language))
                            .foregroundStyle(.secondary)

                        if !service.discoveredReceivers.isEmpty {
                            Text(TBDisplaySenderL10n.discoveryHint(service.language))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.footnote)
                }

                HStack(alignment: .top, spacing: 14) {
                    metricCard(
                        title: TBDisplaySenderL10n.cableTestGroup(service.language),
                        value: cableRateText,
                        accent: session.cableTestResult == nil ? .secondary : .green,
                        subtitle: session.isCableTesting ? TBDisplaySenderL10n.testingButton(service.language) : TBDisplaySenderL10n.transferRateLabel(service.language)
                    )
                    .frame(maxWidth: 240)

                    monitorDetailsCard
                }
            }
        }
    }

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(service.sessionTitle(for: session))
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text(session.statusText)
                        .font(.subheadline)
                        .foregroundStyle(session.isStreaming ? .green : .secondary)
                }

                Spacer(minLength: 12)

                statusChip
            }

            HStack(spacing: 10) {
                Button(session.isConnected ? TBDisplaySenderL10n.stopButton(service.language) : TBDisplaySenderL10n.connectButton(service.language)) {
                    if session.isConnected {
                        session.stop()
                    } else {
                        session.connect()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!session.isConnected && (trimmedReceiverIP.isEmpty || session.localTBIP.isEmpty))

                Button(action: {
                    session.startCableTest()
                }) {
                    HStack(spacing: 6) {
                        if session.isCableTesting {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .controlSize(.small)
                        }
                        Text(session.isCableTesting ? TBDisplaySenderL10n.testingButton(service.language) : TBDisplaySenderL10n.cableTestButton(service.language))
                    }
                }
                .buttonStyle(.bordered)
                .disabled(session.isConnected || session.isStreaming || session.isCableTesting || trimmedReceiverIP.isEmpty || session.localTBIP.isEmpty)

                Button(TBDisplaySenderL10n.restartCaptureButton(service.language)) {
                    session.restartCaptureNow()
                }
                .buttonStyle(.bordered)
                .disabled(!session.canRestartCapture)

                Button(TBDisplaySenderL10n.removeSessionButton(service.language)) {
                    service.removeSession(session)
                }
                .buttonStyle(.bordered)
                .disabled(service.sessions.count == 1 || session.isConnected || session.isStreaming)
            }
        }
    }

    private var monitorDetailsCard: some View {
        SurfaceSubcard {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeading(sessionMonitorTitle)

                VStack(alignment: .leading, spacing: 8) {
                    infoRow(TBDisplaySenderL10n.receiverLabel(service.language), session.receiverPanelText)
                    infoRow(TBDisplaySenderL10n.virtualDisplayLabel(service.language), session.virtualDisplayText)
                    infoRow(TBDisplaySenderL10n.streamLabel(service.language), session.streamResolutionText)
                    // Observes the dedicated metrics object so the ~1 Hz FPS tick
                    // re-renders only this row, not the whole session card / window.
                    SessionMonitorFPSRow(label: TBDisplaySenderL10n.fpsLabel(service.language), metrics: session.liveMetrics)
                    infoRow("Capture", session.captureDisplayText)
                    infoRow("State", session.displayStateText)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cableRateText: String {
        if let rate = session.cableTestResult {
            return String(format: "%.2f Gbits/s", rate)
        }
        return TBDisplaySenderL10n.noTestResult(service.language)
    }

    private var trimmedReceiverIP: String {
        session.receiverIP.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var statusChip: some View {
        Text(chipText)
            .font(.system(.footnote, design: .rounded, weight: .bold))
            .foregroundStyle(chipTint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(chipTint.opacity(0.12))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(chipTint.opacity(0.28), lineWidth: 1)
            )
    }

    private var chipText: String {
        if session.isStreaming { return liveTitle }
        if session.isConnected { return connectedTitle }
        return idleTitle
    }

    private var chipTint: Color {
        if session.isStreaming { return .green }
        if session.isConnected { return .orange }
        return .secondary
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(.caption, design: .rounded, weight: .bold))
            .tracking(1.0)
            .foregroundStyle(.secondary)
    }

    private var routingTitle: String {
        switch service.language {
        case .italian: return "Instradamento"
        case .english: return "Routing"
        case .german: return "Verbindung"
        }
    }

    private var outputTitle: String {
        switch service.language {
        case .italian: return "Uscita"
        case .english: return "Output"
        case .german: return "Ausgabe"
        }
    }

    private var sessionMonitorTitle: String {
        switch service.language {
        case .italian: return "Sessione Monitor"
        case .english: return "Session Monitor"
        case .german: return "Monitor-Sitzung"
        }
    }

    private var liveTitle: String {
        switch service.language {
        case .italian: return "Attivo"
        case .english: return "Live"
        case .german: return "Aktiv"
        }
    }

    private var connectedTitle: String {
        switch service.language {
        case .italian: return "Connesso"
        case .english: return "Connected"
        case .german: return "Verbunden"
        }
    }

    private var idleTitle: String {
        switch service.language {
        case .italian: return "In attesa"
        case .english: return "Idle"
        case .german: return "Bereit"
        }
    }

    private func controlRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 138, alignment: .leading)
            content()
        }
    }

    private func controlStack<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func metricCard(title: String, value: String, accent: Color, subtitle: String) -> some View {
        SurfaceSubcard {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeading(title)
                Text(value)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(accent)
                    .textSelection(.enabled)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 138, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// FPS readout that observes only `TBSessionLiveMetrics`. Isolating it here means
/// the once-per-second FPS update invalidates just this small row instead of the
/// entire session card (and, via the manager bubble-up, the whole window).
private struct SessionMonitorFPSRow: View {
    let label: String
    @ObservedObject var metrics: TBSessionLiveMetrics

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 138, alignment: .leading)
            Text("\(metrics.senderFPS)")
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SurfaceCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.065),
                            Color.white.opacity(0.03)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
        )
    }
}

private struct SurfaceSubcard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
        )
    }
}
