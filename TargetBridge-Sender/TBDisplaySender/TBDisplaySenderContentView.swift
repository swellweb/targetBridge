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
        }
    }

    private var aboutToolbarTitle: String {
        switch service.language {
        case .italian: return "About"
        case .english: return "About"
        case .german: return "Info"
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
                value: trimmedReceiverIP.isEmpty ? TBDisplaySenderL10n.notDetected(service.language) : trimmedReceiverIP,
                subtitle: session.receiverPanelText
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
        }
    }

    private var receiverTitle: String {
        switch service.language {
        case .italian: return "Receiver"
        case .english: return "Receiver"
        case .german: return "Empfänger"
        }
    }

    private var sourceTitle: String {
        switch service.language {
        case .italian: return "Modalità"
        case .english: return "Mode"
        case .german: return "Modus"
        }
    }

    private var fpsTitle: String {
        switch service.language {
        case .italian: return "Telemetria"
        case .english: return "Telemetry"
        case .german: return "Telemetrie"
        }
    }

    private var liveSubtitle: String {
        switch service.language {
        case .italian: return "Frame in invio"
        case .english: return "Frames currently sending"
        case .german: return "Frames werden gesendet"
        }
    }

    private var idleSubtitle: String {
        switch service.language {
        case .italian: return "Nessuno stream attivo"
        case .english: return "No active stream"
        case .german: return "Kein aktiver Stream"
        }
    }

    private var sessionMonitorTitle: String {
        switch service.language {
        case .italian: return "Sessione monitor"
        case .english: return "Monitor Session"
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
                            ForEach(TBTransportKind.allCases) { transportKind in
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
        }
    }

    private var connectionSettingsTitle: String {
        switch service.language {
        case .italian: return "Connessione"
        case .english: return "Connection"
        case .german: return "Verbindung"
        }
    }

    private var outputSettingsTitle: String {
        switch service.language {
        case .italian: return "Uscita"
        case .english: return "Output"
        case .german: return "Ausgabe"
        }
    }

    private var diagnosticsTitle: String {
        switch service.language {
        case .italian: return "Diagnostica"
        case .english: return "Diagnostics"
        case .german: return "Diagnose"
        }
    }

    private var transportDetails: String {
        switch service.language {
        case .italian: return "Scegli il percorso di rete per questa sessione. Thunderbolt Bridge resta il profilo raccomandato; Network Link e sperimentale."
        case .english: return "Choose the network path for this session. Thunderbolt Bridge remains the recommended profile; Network Link is experimental."
        case .german: return "Wahle den Netzwerkpfad fuer diese Sitzung. Thunderbolt Bridge bleibt die empfohlene Option; Network Link ist experimentell."
        }
    }

    private var localInterfaceDetails: String {
        switch service.language {
        case .italian: return "L'interfaccia locale determina da quale indirizzo il sender apre la connessione."
        case .english: return "The local interface controls which source address the sender binds before opening the connection."
        case .german: return "Die lokale Schnittstelle bestimmt, an welche Quelladresse der Sender beim Verbindungsaufbau bindet."
        }
    }

    private var discoveryDetails: String {
        switch service.language {
        case .italian: return "Seleziona un receiver rilevato automaticamente oppure lascia inserimento manuale."
        case .english: return "Select an automatically discovered receiver or keep manual entry."
        case .german: return "Wahle einen automatisch gefundenen Empfanger oder bleibe bei der manuellen Eingabe."
        }
    }

    private var receiverDetails: String {
        switch service.language {
        case .italian: return "Indirizzo diretto del receiver. Puoi usare IP Thunderbolt o LAN a seconda del trasporto."
        case .english: return "Direct receiver address. You can use a Thunderbolt or LAN IP depending on the selected transport."
        case .german: return "Direkte Empfangeradresse. Je nach gewahltem Transport kann eine Thunderbolt- oder LAN-IP verwendet werden."
        }
    }

    private var captureModeDetails: String {
        switch service.language {
        case .italian: return "Mirror per duplicare il desktop, Extended per creare un display indipendente."
        case .english: return "Mirror duplicates the desktop, Extended creates a separate display."
        case .german: return "Mirror dupliziert den Desktop, Extended erstellt ein separates Display."
        }
    }

    private var streamProfileDetails: String {
        switch service.language {
        case .italian: return "Parti da preset conservativi su Wi-Fi o reti lente, poi sali se la stabilita rimane buona."
        case .english: return "Start with conservative presets on Wi-Fi or slower links, then move up if stability stays good."
        case .german: return "Beginne bei WLAN oder langsameren Verbindungen mit konservativen Profilen und gehe dann bei stabiler Verbindung nach oben."
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
