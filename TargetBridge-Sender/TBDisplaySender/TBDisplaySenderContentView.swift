import SwiftUI

struct TBDisplaySenderContentView: View {
    @ObservedObject var service: TBDisplaySenderService
    @State private var showingAbout = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerCard
                controlDeck

                ForEach(service.sessions) { session in
                    TBDisplaySenderSessionCard(service: service, session: session)
                }

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
            service.refreshLocalInterfaces()
        }
        .sheet(isPresented: $showingAbout) {
            TBDisplaySenderAboutView(service: service)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showingAbout = true
                } label: {
                    Label(aboutToolbarTitle, systemImage: "info.circle")
                }

                SettingsLink {
                    Label(settingsToolbarTitle, systemImage: "slider.horizontal.3")
                }
            }
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
                    Text(service.localInterfaceSummaryText)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }

    private var controlDeck: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        sectionHeading(TBDisplaySenderL10n.connectionGroup(service.language))
                        Text(TBDisplaySenderL10n.multiSessionHint(service.language))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    HStack(spacing: 10) {
                        Button(TBDisplaySenderL10n.addSessionButton(service.language)) {
                            service.addSession()
                        }
                        .buttonStyle(.borderedProminent)

                        Button(TBDisplaySenderL10n.refreshIPButton(service.language)) {
                            service.refreshLocalInterfaces()
                        }
                        .buttonStyle(.bordered)

                        Button(TBDisplaySenderL10n.stopAllButton(service.language)) {
                            service.stopAll()
                        }
                        .buttonStyle(.bordered)
                        .disabled(!service.anyConnected)
                    }
                }

                SurfaceSubcard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(TBDisplaySenderL10n.availableLocalInterfaces(service.language))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(service.localInterfaceSummaryText)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
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

    private var settingsToolbarTitle: String {
        switch service.language {
        case .italian: return "Impostazioni"
        case .english: return "Settings"
        case .german: return "Einstellungen"
        case .chinese: return "设置"
        }
    }

    private var aboutToolbarTitle: String {
        switch service.language {
        case .italian: return "About"
        case .english: return "About"
        case .german: return "Info"
        case .chinese: return "关于"
        }
    }
}

private struct TBDisplaySenderSessionCard: View {
    @ObservedObject var service: TBDisplaySenderService
    @ObservedObject var session: TBDisplaySenderSession
    @State private var showingSessionSettings = false

    private let summaryColumns = [
        GridItem(.adaptive(minimum: 180), spacing: 12)
    ]

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 16) {
                topBar
                summaryGrid
                if session.isConnected {
                    brightnessCard
                }
                if session.isConnected && session.audioEnabled {
                    volumeCard
                }
                monitorDetailsCard
            }
        }
        .sheet(isPresented: $showingSessionSettings) {
            TBDisplaySenderSessionSettingsSheet(service: service, session: session)
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
                .disabled(!session.isConnected && (trimmedReceiverIP.isEmpty || session.localInterfaceIP.isEmpty))

                Button {
                    showingSessionSettings = true
                } label: {
                    Label(TBDisplaySenderL10n.showSettings(service.language), systemImage: "gearshape.2")
                }
                .buttonStyle(.bordered)

                Button(TBDisplaySenderL10n.removeSessionButton(service.language)) {
                    service.removeSession(session)
                }
                .buttonStyle(.bordered)
                .disabled(service.sessions.count == 1 || session.isConnected || session.isStreaming)
            }
        }
    }

    private var summaryGrid: some View {
        LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 12) {
            summaryTile(
                title: transportTitle,
                value: session.transportKind.title(service.language),
                subtitle: service.interfaceDisplayText(for: session.localInterfaceIP)
            )

            summaryTile(
                title: receiverTitle,
                value: session.receiverDisplayName.isEmpty ? TBDisplaySenderL10n.notDetected(service.language) : session.receiverDisplayName,
                subtitle: session.receiverSubtitle
            )

            summaryTile(
                title: sourceTitle,
                value: session.captureSource.title(service.language),
                subtitle: session.streamResolutionText
            )

            summaryTile(
                title: fpsTitle,
                value: "\(session.senderFPS)",
                subtitle: session.isStreaming ? liveSubtitle : idleSubtitle,
                accent: session.isStreaming ? .green : .secondary
            )
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
                    infoRow(TBDisplaySenderL10n.fpsLabel(service.language), "\(session.senderFPS)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var brightnessCard: some View {
        SurfaceSubcard {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeading(brightnessTitle)
                HStack(spacing: 12) {
                    Image(systemName: "sun.min.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)

                    Slider(value: $session.brightness, in: 0.0...1.0)
                        .tint(.orange)

                    Image(systemName: "sun.max.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)

                    Text("\(Int((session.brightness * 100).rounded()))%")
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 44, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var volumeCard: some View {
        SurfaceSubcard {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeading(volumeTitle)
                HStack(spacing: 12) {
                    Image(systemName: "speaker.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)

                    Slider(value: $session.volume, in: 0.0...1.0)
                        .tint(.blue)

                    Image(systemName: "speaker.wave.3.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)

                    Text("\(Int((session.volume * 100).rounded()))%")
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 44, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private func summaryTile(title: String, value: String, subtitle: String, accent: Color = .primary) -> some View {
        SurfaceSubcard {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeading(title)
                Text(value)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(accent)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var transportTitle: String {
        switch service.language {
        case .italian: return "Trasporto"
        case .english: return "Transport"
        case .german: return "Transport"
        case .chinese: return "传输"
        }
    }

    private var receiverTitle: String {
        switch service.language {
        case .italian: return "Receiver"
        case .english: return "Receiver"
        case .german: return "Empfänger"
        case .chinese: return "接收端"
        }
    }

    private var sourceTitle: String {
        switch service.language {
        case .italian: return "Modalità"
        case .english: return "Mode"
        case .german: return "Modus"
        case .chinese: return "模式"
        }
    }

    private var fpsTitle: String {
        switch service.language {
        case .italian: return "Telemetria"
        case .english: return "Telemetry"
        case .german: return "Telemetrie"
        case .chinese: return "遥测"
        }
    }

    private var brightnessTitle: String {
        switch service.language {
        case .italian: return "Luminosità"
        case .english: return "Brightness"
        case .german: return "Helligkeit"
        case .chinese: return "亮度"
        }
    }

    private var volumeTitle: String {
        switch service.language {
        case .italian: return "Volume"
        case .english: return "Volume"
        case .german: return "Lautstärke"
        case .chinese: return "音量"
        }
    }

    private var liveSubtitle: String {
        switch service.language {
        case .italian: return "Frame in invio"
        case .english: return "Frames currently sending"
        case .german: return "Frames werden gesendet"
        case .chinese: return "正在发送画面帧"
        }
    }

    private var idleSubtitle: String {
        switch service.language {
        case .italian: return "Nessuno stream attivo"
        case .english: return "No active stream"
        case .german: return "Kein aktiver Stream"
        case .chinese: return "当前没有活动流"
        }
    }

    private var sessionMonitorTitle: String {
        switch service.language {
        case .italian: return "Sessione monitor"
        case .english: return "Monitor Session"
        case .german: return "Monitor-Sitzung"
        case .chinese: return "显示会话"
        }
    }

    private var liveTitle: String {
        TBDisplaySenderL10n.statusChipLive(service.language)
    }

    private var connectedTitle: String {
        TBDisplaySenderL10n.statusChipConnected(service.language)
    }

    private var idleTitle: String {
        TBDisplaySenderL10n.statusChipIdle(service.language)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 138, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct TBDisplaySenderSessionSettingsSheet: View {
    @ObservedObject var service: TBDisplaySenderService
    @ObservedObject var session: TBDisplaySenderSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                settingsSection(title: connectionSettingsTitle) {
                    settingRow(TBDisplaySenderL10n.transportKind(service.language), details: transportDetails) {
                        Picker(TBDisplaySenderL10n.transportKind(service.language), selection: $session.transportKind) {
                            ForEach(service.availableTransportKinds) { transportKind in
                                Text(transportKind.title(service.language)).tag(transportKind)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: session.transportKind) { _, _ in
                            service.transportDidChange(for: session)
                        }
                        .disabled(session.isConnected || session.isStreaming)
                    }

                    settingRow(TBDisplaySenderL10n.localInterfaceIP(service.language), details: localInterfaceDetails) {
                        Picker(TBDisplaySenderL10n.localInterfaceIP(service.language), selection: $session.localInterfaceIP) {
                            Text(TBDisplaySenderL10n.notDetected(service.language)).tag("")
                            ForEach(service.availableInterfaces(for: session.transportKind)) { localInterface in
                                Text(localInterface.displayText(service.language)).tag(localInterface.ip)
                            }
                        }
                        .pickerStyle(.menu)
                        .disabled(session.isConnected || session.isStreaming)
                    }

                    settingRow(TBDisplaySenderL10n.discoveredReceiver(service.language), details: discoveryDetails) {
                        Picker(TBDisplaySenderL10n.discoveredReceiver(service.language), selection: $session.selectedReceiverID) {
                            Text(TBDisplaySenderL10n.manualReceiverEntry(service.language)).tag("")
                            ForEach(service.discoveredReceivers) { receiver in
                                Text(receiver.displayText).tag(receiver.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: session.selectedReceiverID) { _, newValue in
                            guard let receiver = service.discoveredReceivers.first(where: { $0.id == newValue }) else { return }
                            service.applyDiscoveredReceiver(receiver, to: session)
                        }
                        .disabled(session.isConnected || session.isStreaming)
                    }

                    settingRow(TBDisplaySenderL10n.receiverIP(service.language), details: receiverDetails) {
                        TextField("169.254.x.x / 192.168.x.x", text: $session.receiverIP)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .disabled(session.isConnected || session.isStreaming)
                    }
                }

                settingsSection(title: outputSettingsTitle) {
                    settingRow(TBDisplaySenderL10n.captureSource(service.language), details: captureModeDetails) {
                        Picker(TBDisplaySenderL10n.captureSource(service.language), selection: $session.captureSource) {
                            ForEach(TBDisplayCaptureSource.allCases) { source in
                                Text(source.title(service.language)).tag(source)
                            }
                        }
                        .pickerStyle(.menu)
                        .disabled(session.isConnected || session.isStreaming)
                    }

                    settingRow(TBDisplaySenderL10n.streamProfile(service.language), details: streamProfileDetails) {
                        Picker(TBDisplaySenderL10n.streamProfile(service.language), selection: $session.capturePreset) {
                            ForEach(TBDisplayCapturePreset.allCases, id: \.self) { preset in
                                Text("\(preset.title(service.language)) · \(preset.description)").tag(preset)
                            }
                        }
                        .pickerStyle(.menu)
                        .disabled(session.isConnected || session.isStreaming)
                    }

                    if service.audioRelayAvailable {
                        settingRow(TBDisplaySenderL10n.streamAudio(service.language), details: audioDetails) {
                            Toggle("", isOn: $session.audioEnabled)
                                .labelsHidden()
                                .disabled(session.isConnected || session.isStreaming)
                        }
                    }

                    if service.inputDockstationAvailable {
                        settingRow(inputDockstationTitle, details: inputDockstationDetails) {
                            Picker(
                                inputDockstationTitle,
                                selection: Binding(
                                    get: { session.inputControlRole },
                                    set: { service.setInputControlRole($0, for: session) }
                                )
                            ) {
                                ForEach(TBInputControlRole.allCases) { role in
                                    Text(inputControlRoleTitle(role)).tag(role)
                                }
                            }
                            .pickerStyle(.menu)
                            .disabled(!session.isConnected)
                        }

                        if session.inputControlRole == .senderMaster {
                            settingRow(inputGestureModeTitle, details: inputGestureModeDetails) {
                                Picker(
                                    inputGestureModeTitle,
                                    selection: $session.inputGestureMode
                                ) {
                                    ForEach(TBInputGestureMode.allCases) { mode in
                                        Text(inputGestureModeOptionTitle(mode)).tag(mode)
                                    }
                                }
                                .pickerStyle(.menu)
                                .disabled(!session.isConnected)
                            }
                        }

                        if session.inputControlRole == .receiverMaster {
                            SurfaceSubcard {
                                TBInputBindingsView(session: session, language: service.language)
                            }
                        }

                        if session.inputControlRole == .senderMaster, !service.localInputMonitoringTrusted {
                            SurfaceSubcard {
                                permissionWarningCard(
                                    title: localInputMonitoringWarningTitle,
                                    body: localInputMonitoringWarningBody,
                                    actionTitle: openInputMonitoringSettingsTitle,
                                    action: { service.openInputMonitoringSettings() },
                                    statusText: "listen=false"
                                )
                            }
                        }

                        if session.inputControlRole == .senderMaster, session.receiverAccessibilityTrustedHint == false {
                            SurfaceSubcard {
                                permissionWarningCard(
                                    title: receiverAccessibilityWarningTitle,
                                    body: receiverAccessibilityWarningBody,
                                    actionTitle: nil,
                                    action: nil,
                                    statusText: "receiver accessibility=false"
                                )
                            }
                        }

                        if session.inputControlRole == .receiverMaster, !service.localInputInjectionTrusted {
                            SurfaceSubcard {
                                permissionWarningCard(
                                    title: inputPermissionWarningTitle,
                                    body: inputPermissionWarningBody,
                                    actionTitle: openAccessibilitySettingsTitle,
                                    action: { service.openAccessibilitySettings() },
                                    statusText: inputPermissionStatusText
                                )
                            }
                        }

                        if session.inputControlRole == .receiverMaster, session.receiverInputMonitoringTrustedHint == false {
                            SurfaceSubcard {
                                permissionWarningCard(
                                    title: receiverInputMonitoringWarningTitle,
                                    body: receiverInputMonitoringWarningBody,
                                    actionTitle: nil,
                                    action: nil,
                                    statusText: "receiver input-monitoring=false"
                                )
                            }
                        }
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
                    .fixedSize(horizontal: false, vertical: true)
                }

                settingsSection(title: diagnosticsTitle) {
                    SurfaceSubcard {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 12) {
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
                                .disabled(session.isConnected || session.isStreaming || session.isCableTesting || trimmedReceiverIP.isEmpty || session.localInterfaceIP.isEmpty)

                                Text(cableRateText)
                                    .font(.system(.body, design: .rounded, weight: .semibold))
                                    .foregroundStyle(cableRateColor)

                                Spacer()

                                Button(TBDisplaySenderL10n.restartCaptureButton(service.language)) {
                                    session.restartCaptureNow()
                                }
                                .buttonStyle(.bordered)
                                .disabled(!session.canRestartCapture)
                            }

                            Divider().overlay(Color.white.opacity(0.08))

                            VStack(alignment: .leading, spacing: 8) {
                                infoRow("Capture", session.captureDisplayText)
                                infoRow("State", session.displayStateText)
                            }
                        }
                    }
                }
            }
            .padding(24)
            .padding(.top, 14)
        }
        .frame(width: 720, height: 620)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.12, green: 0.13, blue: 0.14),
                    Color(red: 0.08, green: 0.09, blue: 0.10)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
        // The panel uses a fixed dark background, so force the dark color scheme:
        // otherwise in system Light mode the semantic text colors (.primary /
        // .secondary) resolve to dark variants and render dark-on-dark.
        .preferredColorScheme(.dark)
    }

    private func settingsSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeading(title)
                content()
            }
        }
    }

    private func settingRow<Content: View>(_ label: String, details: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                content()
                    .frame(maxWidth: 310, alignment: .trailing)
            }

            Text(details)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(.caption, design: .rounded, weight: .bold))
            .tracking(1.0)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func permissionWarningCard(
        title: String,
        body: String,
        actionTitle: String?,
        action: (() -> Void)?,
        statusText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(title)
                    .font(.subheadline.weight(.semibold))
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
            }

            Text(body)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                if let actionTitle, let action {
                    Button(actionTitle) {
                        action()
                    }
                    .buttonStyle(.borderedProminent)
                }

                Text(statusText)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var header: some View {
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
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                }
                .frame(width: 58, height: 58)

                VStack(alignment: .leading, spacing: 6) {
                    Text(service.sessionTitle(for: session))
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Text(settingsSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(TBDisplaySenderL10n.hideSettings(service.language)) {
                    dismiss()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var settingsSubtitle: String {
        switch service.language {
        case .italian: return "Configura trasporto, output e diagnostica senza sporcare la dashboard principale."
        case .english: return "Configure transport, output, and diagnostics without cluttering the main dashboard."
        case .german: return "Transport, Ausgabe und Diagnose konfigurieren, ohne das Haupt-Dashboard zu überladen."
        case .chinese: return "在不干扰主控制面板的情况下配置传输、输出和诊断。"
        }
    }

    private var connectionSettingsTitle: String {
        switch service.language {
        case .italian: return "Connessione"
        case .english: return "Connection"
        case .german: return "Verbindung"
        case .chinese: return "连接"
        }
    }

    private var outputSettingsTitle: String {
        switch service.language {
        case .italian: return "Uscita"
        case .english: return "Output"
        case .german: return "Ausgabe"
        case .chinese: return "输出"
        }
    }

    private var diagnosticsTitle: String {
        switch service.language {
        case .italian: return "Diagnostica"
        case .english: return "Diagnostics"
        case .german: return "Diagnose"
        case .chinese: return "诊断"
        }
    }

    private var transportDetails: String {
        switch service.language {
        case .italian: return "Scegli il percorso di rete per questa sessione. Thunderbolt Bridge resta il profilo raccomandato; Network Link e sperimentale."
        case .english: return "Choose the network path for this session. Thunderbolt Bridge remains the recommended profile; Network Link is experimental."
        case .german: return "Wähle den Netzwerkpfad für diese Sitzung. Thunderbolt Bridge bleibt die empfohlene Option; Network Link ist experimentell."
        case .chinese: return "为该会话选择网络路径。Thunderbolt Bridge 仍然是推荐模式；Network Link 为实验性功能。"
        }
    }

    private var localInterfaceDetails: String {
        switch service.language {
        case .italian: return "L'interfaccia locale determina da quale indirizzo il sender apre la connessione."
        case .english: return "The local interface controls which source address the sender binds before opening the connection."
        case .german: return "Die lokale Schnittstelle bestimmt, an welche Quelladresse der Sender beim Verbindungsaufbau bindet."
        case .chinese: return "本地接口决定 sender 在建立连接前绑定的源地址。"
        }
    }

    private var discoveryDetails: String {
        switch service.language {
        case .italian: return "Seleziona un receiver rilevato automaticamente oppure lascia inserimento manuale."
        case .english: return "Select an automatically discovered receiver or keep manual entry."
        case .german: return "Wähle einen automatisch gefundenen Empfänger oder bleibe bei der manuellen Eingabe."
        case .chinese: return "选择自动发现的 receiver，或者保持手动输入。"
        }
    }

    private var receiverDetails: String {
        switch service.language {
        case .italian: return "Indirizzo diretto del receiver. Puoi usare IP Thunderbolt o LAN a seconda del trasporto."
        case .english: return "Direct receiver address. You can use a Thunderbolt or LAN IP depending on the selected transport."
        case .german: return "Direkte Empfängeradresse. Je nach gewähltem Transport kann eine Thunderbolt- oder LAN-IP verwendet werden."
        case .chinese: return "receiver 的直连地址。可以根据所选传输使用 Thunderbolt 或局域网 IP。"
        }
    }

    private var captureModeDetails: String {
        switch service.language {
        case .italian: return "Mirror per duplicare il desktop, Extended per creare un display indipendente."
        case .english: return "Mirror duplicates the desktop, Extended creates a separate display."
        case .german: return "Mirror dupliziert den Desktop, Extended erstellt ein separates Display."
        case .chinese: return "Mirror 复制桌面，Extended 创建独立显示器。"
        }
    }

    private var streamProfileDetails: String {
        switch service.language {
        case .italian: return "Parti da preset conservativi su Wi-Fi o reti lente, poi sali se la stabilita rimane buona."
        case .english: return "Start with conservative presets on Wi-Fi or slower links, then move up if stability stays good."
        case .german: return "Beginne bei WLAN oder langsameren Verbindungen mit konservativen Profilen und wähle höhere Einstellungen, wenn die Verbindung stabil bleibt."
        case .chinese: return "在 Wi‑Fi 或较慢链路上先使用保守预设，稳定后再逐步提高。"
        }
    }

    private var audioDetails: String {
        switch service.language {
        case .italian: return "Invia anche l'audio di sistema del sender al receiver per questa sessione."
        case .english: return "Also send the sender’s system audio to the receiver for this session."
        case .german: return "Überträgt für diese Sitzung auch den Systemton des Senders an den Empfänger."
        case .chinese: return "同时将 sender 的系统音频传到此会话的 receiver。"
        }
    }

    private var inputDockstationTitle: String {
        switch service.language {
        case .italian: return "Input Dockstation"
        case .english: return "Input Dockstation"
        case .german: return "Input Dockstation"
        case .chinese: return "输入扩展坞"
        }
    }

    private var inputDockstationDetails: String {
        switch service.language {
        case .italian: return "Definisce il ruolo input di questa sessione. Una sola sessione puo avere un master attivo alla volta: questo Mac puo controllare il receiver, oppure il receiver puo controllare questo Mac. Per uscire rapidamente dal controllo usa Ctrl+Option+Command+K."
        case .english: return "Defines the input role for this session. Only one session can have an active master at a time: this Mac can control the receiver, or the receiver can control this Mac. Use Control+Option+Command+K to exit control quickly."
        case .german: return "Legt die Eingaberolle für diese Sitzung fest. Nur eine Sitzung kann gleichzeitig einen aktiven Master haben: Dieser Mac kann den Empfänger steuern oder der Empfänger kann diesen Mac steuern. Mit Ctrl+Option+Command+K beendest du die Steuerung schnell."
        case .chinese: return "定义此会话的输入角色。同一时间只能有一个活动 master：这台 Mac 可以控制 receiver，或者 receiver 可以控制这台 Mac。按下 Control+Option+Command+K 可以快速退出控制。"
        }
    }

    private var inputGestureModeTitle: String {
        switch service.language {
        case .italian: return "Cambio slave"
        case .english: return "Slave switching"
        case .german: return "Slave-Wechsel"
        case .chinese: return "Slave 切换"
        }
    }

    private var inputGestureModeDetails: String {
        switch service.language {
        case .italian:
            return "Decide come passare da uno slave all'altro quando 'Questo Mac e Master' e attivo. In modalita nativa, macOS continua a gestire normalmente il desktop del master. In modalita relay, TargetBridge usa il bordo sinistro/destro dello schermo e le hotkey Ctrl+Option+Freccia Sinistra/Destra per spostare il controllo allo slave precedente o successivo."
        case .english:
            return "Chooses how to move control from one slave to another when 'This Mac is Master' is active. In native mode, macOS keeps handling the master's desktop normally. In relay mode, TargetBridge uses the left/right screen edge and the Ctrl+Option+Left/Right hotkeys to move control to the previous or next slave."
        case .german:
            return "Legt fest, wie die Steuerung von einem Slave zum anderen wechselt, wenn 'Dieser Mac ist Master' aktiv ist. Im nativen Modus verwaltet macOS den Desktop des Masters normal weiter. Im Relay-Modus nutzt TargetBridge den linken/rechten Bildschirmrand und die Hotkeys Ctrl+Option+Links/Rechts, um zum vorherigen oder nächsten Slave zu wechseln."
        case .chinese:
            return "决定在“这台 Mac 是 Master”启用时如何在不同 slave 之间切换控制。原生模式下，macOS 继续正常处理 master 的桌面；relay 模式下，TargetBridge 会使用屏幕左右边缘以及 Ctrl+Option+Left/Right 热键，把控制切换到上一个或下一个 slave。"
        }
    }

    private func inputGestureModeOptionTitle(_ mode: TBInputGestureMode) -> String {
        switch (mode, service.language) {
        case (.native, .italian): return "Lascia il desktop nativo del master"
        case (.native, .english): return "Keep master's desktop native"
        case (.native, .german): return "Desktop des Masters nativ lassen"
        case (.native, .chinese): return "保留 master 的原生桌面行为"
        case (.relayToSlave, .italian): return "Usa bordi schermo e hotkey per cambiare slave"
        case (.relayToSlave, .english): return "Use screen edges and hotkeys to switch slave"
        case (.relayToSlave, .german): return "Bildschirmränder und Hotkeys für Slave-Wechsel nutzen"
        case (.relayToSlave, .chinese): return "使用屏幕边缘和热键切换 slave"
        }
    }

    private func inputControlRoleTitle(_ role: TBInputControlRole) -> String {
        switch (role, service.language) {
        case (.off, .italian): return "Off"
        case (.off, .english): return "Off"
        case (.off, .german): return "Aus"
        case (.off, .chinese): return "关闭"
        case (.senderMaster, .italian): return "Questo Mac e Master"
        case (.senderMaster, .english): return "This Mac is Master"
        case (.senderMaster, .german): return "Dieser Mac ist Master"
        case (.senderMaster, .chinese): return "这台 Mac 是 Master"
        case (.receiverMaster, .italian): return "Receiver e Master"
        case (.receiverMaster, .english): return "Receiver is Master"
        case (.receiverMaster, .german): return "Empfänger ist Master"
        case (.receiverMaster, .chinese): return "Receiver 是 Master"
        }
    }

    private var inputPermissionWarningTitle: String {
        switch service.language {
        case .italian: return "Il sender non puo ancora iniettare input"
        case .english: return "The sender cannot inject input yet"
        case .german: return "Der Sender kann noch keine Eingaben injizieren"
        case .chinese: return "Sender 目前还不能注入输入"
        }
    }

    private var inputPermissionWarningBody: String {
        switch service.language {
        case .italian:
            return "Per usare 'Receiver e Master', questa app TargetBridge sul sender deve essere autorizzata in Privacy e Sicurezza > Accessibilita. Apri le impostazioni, abilita l'app che stai usando e poi riapri la sessione. Le scorciatoie configurate richiedono inoltre una sola autorizzazione macOS per controllare System Events."
        case .english:
            return "To use 'Receiver is Master', this TargetBridge app on the sender must be allowed under Privacy & Security > Accessibility. Open the settings, enable the app you are actually running, then reopen the session. Configured shortcuts also require a one-time macOS permission to control System Events."
        case .german:
            return "Um 'Empfänger ist Master' zu verwenden, muss diese TargetBridge-App auf dem Sender unter Datenschutz & Sicherheit > Bedienungshilfen erlaubt sein. Öffne die Einstellungen, aktiviere die wirklich verwendete App und öffne dann die Sitzung erneut. Konfigurierte Kurzbefehle benötigen außerdem einmalig die macOS-Erlaubnis, System Events zu steuern."
        case .chinese:
            return "要使用“Receiver 是 Master”，sender 上这份 TargetBridge 必须在“隐私与安全性 > 辅助功能”中被允许。打开设置，启用你当前运行的这份应用，然后重新打开会话。已配置的快捷键还需要一次性授权 TargetBridge 控制 System Events。"
        }
    }

    private var openAccessibilitySettingsTitle: String {
        switch service.language {
        case .italian: return "Apri Accessibilita"
        case .english: return "Open Accessibility"
        case .german: return "Bedienungshilfen öffnen"
        case .chinese: return "打开辅助功能"
        }
    }

    private var inputPermissionStatusText: String {
        service.localInputInjectionTrusted ? "trusted=true" : "trusted=false"
    }

    private var localInputMonitoringWarningTitle: String {
        switch service.language {
        case .italian: return "Manca il monitoraggio input sul sender"
        case .english: return "Input Monitoring is missing on the sender"
        case .german: return "Eingabeüberwachung fehlt auf dem Sender"
        case .chinese: return "sender 缺少输入监控权限"
        }
    }

    private var localInputMonitoringWarningBody: String {
        switch service.language {
        case .italian:
            return "Per usare 'Questo Mac e Master' in modo affidabile anche fuori dalla finestra attiva, il sender deve avere il permesso Monitoraggio input. Senza questo permesso alcuni tasti o movimenti globali possono non essere catturati."
        case .english:
            return "To use 'This Mac is Master' reliably outside the active app window, the sender needs Input Monitoring permission. Without it, some keys or global pointer events may not be captured."
        case .german:
            return "Damit 'Dieser Mac ist Master' auch außerhalb des aktiven Fensters zuverlässig funktioniert, braucht der Sender die Berechtigung für Eingabeüberwachung. Ohne diese können einige Tasten oder globale Zeigerereignisse fehlen."
        case .chinese:
            return "要让“这台 Mac 是 Master”在活动窗口之外也可靠工作，sender 需要“输入监控”权限。没有它，一些按键或全局指针事件可能无法被捕获。"
        }
    }

    private var receiverAccessibilityWarningTitle: String {
        switch service.language {
        case .italian: return "Manca Accessibilita sul receiver"
        case .english: return "Accessibility is missing on the receiver"
        case .german: return "Bedienungshilfen fehlen auf dem Empfänger"
        case .chinese: return "receiver 缺少辅助功能权限"
        }
    }

    private var receiverAccessibilityWarningBody: String {
        switch service.language {
        case .italian:
            return "Con 'Questo Mac e Master', il receiver deve poter iniettare click e tastiera. Sul Mac receiver abilita TargetBridge Receiver in Privacy e Sicurezza > Accessibilita."
        case .english:
            return "With 'This Mac is Master', the receiver must be allowed to inject clicks and keyboard events. On the receiver Mac, enable TargetBridge Receiver under Privacy & Security > Accessibility."
        case .german:
            return "Bei 'Dieser Mac ist Master' muss der Empfänger Klicks und Tastatureingaben injizieren dürfen. Aktiviere auf dem Empfänger-Mac TargetBridge-Receiver unter Datenschutz & Sicherheit > Bedienungshilfen."
        case .chinese:
            return "在“这台 Mac 是 Master”模式下，receiver 必须被允许注入点击和键盘事件。请在 receiver Mac 的“隐私与安全性 > 辅助功能”中启用 TargetBridge Receiver。"
        }
    }

    private var receiverInputMonitoringWarningTitle: String {
        switch service.language {
        case .italian: return "Manca Monitoraggio input sul receiver"
        case .english: return "Input Monitoring is missing on the receiver"
        case .german: return "Eingabeüberwachung fehlt auf dem Empfänger"
        case .chinese: return "receiver 缺少输入监控权限"
        }
    }

    private var receiverInputMonitoringWarningBody: String {
        switch service.language {
        case .italian:
            return "Con 'Receiver e Master', il Mac receiver deve poter leggere tastiera e mouse locali. Sul receiver abilita TargetBridge Receiver in Privacy e Sicurezza > Monitoraggio input."
        case .english:
            return "With 'Receiver is Master', the receiver Mac must be allowed to read local keyboard and mouse input. On the receiver, enable TargetBridge Receiver under Privacy & Security > Input Monitoring."
        case .german:
            return "Bei 'Empfänger ist Master' muss der Empfänger-Mac lokale Tastatur- und Mauseingaben lesen dürfen. Aktiviere dort TargetBridge-Receiver unter Datenschutz & Sicherheit > Eingabeüberwachung."
        case .chinese:
            return "在“Receiver 是 Master”模式下，receiver Mac 必须被允许读取本地键盘和鼠标输入。请在 receiver 上的“隐私与安全性 > 输入监控”中启用 TargetBridge Receiver。"
        }
    }

    private var openInputMonitoringSettingsTitle: String {
        switch service.language {
        case .italian: return "Apri Monitoraggio input"
        case .english: return "Open Settings"
        case .german: return "Einstellungen öffnen"
        case .chinese: return "打开设置"
        }
    }

    private var trimmedReceiverIP: String {
        session.receiverIP.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var cableRateText: String {
        if let rate = session.cableTestResult {
            return String(format: "%.2f Gbits/s", rate)
        }
        return TBDisplaySenderL10n.noTestResult(service.language)
    }

    private var cableRateColor: Color {
        session.cableTestResult == nil ? .secondary : .green
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 138, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
