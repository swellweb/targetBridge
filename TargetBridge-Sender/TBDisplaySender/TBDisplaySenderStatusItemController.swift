import AppKit
import Combine

@MainActor
final class TBDisplaySenderStatusItemController: NSObject {
    private let service: TBDisplaySenderService
    nonisolated(unsafe) private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private var hasActivated = false
    private var pendingMenuAction: (@MainActor @Sendable () -> Void)?
    // Retains the target objects for the current menu's sliders (NSSlider holds
    // its target weakly). Cleared and rebuilt each time the menu opens.
    private var sliderTargets: [TBMenuSliderTarget] = []
    private var toggleRows: [TBMenuToggleRowView] = []

    init(service: TBDisplaySenderService) {
        self.service = service
        super.init()
        bind()
        observeApplicationLifecycle()
    }

    deinit {
        let item = statusItem
        DispatchQueue.main.async { [item] in
            if let item {
                NSStatusBar.system.removeStatusItem(item)
            }
        }
    }

    private func bind() {
        service.$showsMenuBarIcon
            .sink { [weak self] _ in
                guard let self, self.hasActivated else { return }
                self.syncVisibility()
            }
            .store(in: &cancellables)

        service.objectWillChange
            .sink { [weak self] _ in
                self?.refreshStatusItem()
            }
            .store(in: &cancellables)
    }

    private func observeApplicationLifecycle() {
        NotificationCenter.default.publisher(for: NSApplication.didFinishLaunchingNotification)
            .sink { [weak self] _ in
                self?.activate()
            }
            .store(in: &cancellables)
    }

    func activate() {
        guard !hasActivated else { return }
        hasActivated = true
        syncVisibility()
    }

    private func syncVisibility() {
        if service.showsMenuBarIcon {
            ensureStatusItem()
            refreshStatusItem()
        } else {
            removeStatusItem()
        }
    }

    private func ensureStatusItem() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "TargetBridge")
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = TBDisplaySenderL10n.topBarToolTip(service.language)

        // Assign one menu instance for the lifetime of the status item and
        // repopulate it lazily in `menuNeedsUpdate(_:)`. Swapping `item.menu`
        // out from under an open/tracking menu leaves macOS holding an
        // orphaned, invisible menu window that swallows clicks at the menu's
        // location — the "dead zone" below the menu bar icon.
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    private func removeStatusItem() {
        guard let item = statusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
    }

    private func refreshStatusItem() {
        guard let item = statusItem else { return }
        item.button?.toolTip = TBDisplaySenderL10n.topBarToolTip(service.language)
    }

    private func rebuildMenuItems(in menu: NSMenu) {
        menu.removeAllItems()
        sliderTargets.removeAll()
        toggleRows.removeAll()

        let titleItem = NSMenuItem(title: "TargetBridge", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        let statusItem = NSMenuItem(title: service.summaryStatusText(), action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        // Brightness / volume sliders for each connected session. Reliable and
        // native-feeling: they drive the receiver directly via the existing
        // brightness/volume path — no event taps, no cursor/keyboard routing.
        let connectedSessions = service.sessions.filter { $0.isConnected }
        if !connectedSessions.isEmpty {
            menu.addItem(.separator())
            for session in connectedSessions {
                if connectedSessions.count > 1 {
                    let header = NSMenuItem(title: service.sessionTitle(for: session), action: nil, keyEquivalent: "")
                    header.isEnabled = false
                    menu.addItem(header)
                }
                menu.addItem(makeSliderItem(symbol: "sun.min.fill",
                                            trailingSymbol: "sun.max.fill",
                                            label: brightnessMenuLabel(),
                                            value: session.brightness) { [weak session] value in
                    session?.brightness = value
                })
                // No volume slider: with the TargetBridge audio device selected,
                // macOS's own Sound slider and the F11/F12 keys already drive the
                // receiver's hardware volume, so a second control here would just
                // be a duplicate that can disagree with the system one.
                var toggles: [TBMenuToggleSpec] = []
                if session.receiverSupportsNightShift {
                    toggles.append(TBMenuToggleSpec(
                        symbol: "sun.lefthalf.filled",
                        title: nightShiftMenuLabel(),
                        stateText: session.nightShiftEnabled ? onWord() : offWord(),
                        isOn: session.nightShiftEnabled) { [weak session] on in
                            session?.nightShiftEnabled = on
                        })
                }
                if session.receiverSupportsTrueTone {
                    toggles.append(TBMenuToggleSpec(
                        symbol: "sun.max.fill",
                        title: trueToneMenuLabel(),
                        stateText: session.trueToneEnabled ? onWord() : offWord(),
                        isOn: session.trueToneEnabled) { [weak session] on in
                            session?.trueToneEnabled = on
                        })
                }
                if !toggles.isEmpty {
                    let row = TBMenuToggleRowView(specs: toggles,
                                                  width: TBMenuMetrics.width,
                                                  leadingInset: TBMenuMetrics.inset)
                    row.onWord = onWord()
                    row.offWord = offWord()
                    let item = NSMenuItem()
                    item.view = row
                    menu.addItem(item)
                    toggleRows.append(row)
                }
            }
        }

        menu.addItem(.separator())

        let openItem = NSMenuItem(
            title: TBDisplaySenderL10n.showMainWindow(service.language),
            action: #selector(showMainWindow),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)

        let addItem = NSMenuItem(
            title: TBDisplaySenderL10n.addSessionButton(service.language),
            action: #selector(addSession),
            keyEquivalent: ""
        )
        addItem.target = self
        menu.addItem(addItem)

        let stopAllItem = NSMenuItem(
            title: TBDisplaySenderL10n.stopAllButton(service.language),
            action: #selector(stopAll),
            keyEquivalent: ""
        )
        stopAllItem.target = self
        stopAllItem.isEnabled = service.anyConnected
        menu.addItem(stopAllItem)

        // The verbose connection/IP details live behind a submenu so the default
        // menu stays focused on the useful actions.
        if !service.localInterfaces.isEmpty || !service.sessions.isEmpty {
            let infoItem = NSMenuItem(title: connectionInfoMenuLabel(), action: nil, keyEquivalent: "")
            let infoSubmenu = NSMenu()
            if !service.localInterfaces.isEmpty {
                let ipItem = NSMenuItem(title: TBDisplaySenderL10n.topBarIP(service.language, service.localInterfaceSummaryText), action: nil, keyEquivalent: "")
                ipItem.isEnabled = false
                infoSubmenu.addItem(ipItem)
            }
            for session in service.sessions {
                let line = "\(service.sessionTitle(for: session)): \(session.statusText)"
                let sessionItem = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                sessionItem.isEnabled = false
                infoSubmenu.addItem(sessionItem)
            }
            infoItem.submenu = infoSubmenu
            menu.addItem(infoItem)
        }

        let hideItem = NSMenuItem(
            title: TBDisplaySenderL10n.hideMenuBarIcon(service.language),
            action: #selector(hideStatusItem),
            keyEquivalent: ""
        )
        hideItem.target = self
        menu.addItem(hideItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: TBDisplaySenderL10n.quitApp(service.language), action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    /// Builds a menu row with an icon and a 0…1 slider whose changes are pushed
    /// live to `onChange` (which sets `session.brightness`/`.volume`, forwarding
    /// to the receiver).
    /// Brightness row: a small glyph, the system slider, and a larger glyph
    /// closing the row. The trailing icon is what stops the track running to the
    /// edge of the menu.
    ///
    /// Stock NSSlider, deliberately, after two attempts at Control Center's
    /// accent-filled track. `trackFillColor` is set below and menus ignore it.
    /// Overriding NSSliderCell.drawBar does produce the fill, but any drawing
    /// override opts the cell out of AppKit's modern slider rendering and the
    /// knob loses its pressed-state translucency — more noticeable than a grey
    /// track, since it makes the control feel wrong rather than just look plain.
    private func makeSliderItem(symbol: String, trailingSymbol: String, label: String,
                                value: Double, onChange: @escaping (Double) -> Void) -> NSMenuItem {
        let width = TBMenuMetrics.width
        let height: CGFloat = 28
        let inset = TBMenuMetrics.inset
        let leadingIcon: CGFloat = 13
        let trailingIcon: CGFloat = 17
        let gap: CGFloat = 8
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        func glyph(_ name: String, size: CGFloat, x: CGFloat) -> NSImageView {
            let view = NSImageView(frame: NSRect(x: x, y: (height - size) / 2, width: size, height: size))
            view.image = NSImage(systemSymbolName: name, accessibilityDescription: label)
            // Decorative: the slider itself carries the name, so reading these
            // as well would announce the row three times.
            view.setAccessibilityElement(false)
            view.contentTintColor = .secondaryLabelColor
            view.imageScaling = .scaleProportionallyUpOrDown
            return view
        }

        container.addSubview(glyph(symbol, size: leadingIcon, x: inset))
        container.addSubview(glyph(trailingSymbol, size: trailingIcon,
                                   x: width - inset - trailingIcon))

        let sliderX = inset + leadingIcon + gap
        let sliderWidth = width - sliderX - gap - trailingIcon - inset
        let slider = NSSlider(frame: NSRect(x: sliderX, y: (height - 19) / 2,
                                            width: sliderWidth, height: 19))
        slider.minValue = 0
        slider.maxValue = 1
        slider.doubleValue = value
        slider.isContinuous = true
        // Set even though menus currently ignore it: harmless, and it is the
        // supported way to get an accent-filled track if that changes.
        slider.trackFillColor = .controlAccentColor
        slider.controlSize = .small
        slider.setAccessibilityLabel(label)
        let target = TBMenuSliderTarget(onChange)
        slider.target = target
        slider.action = #selector(TBMenuSliderTarget.changed(_:))
        sliderTargets.append(target)
        container.addSubview(slider)

        let item = NSMenuItem()
        item.view = container
        item.toolTip = label
        return item
    }

    private func brightnessMenuLabel() -> String {
        switch service.language {
        case .italian: return "Luminosità"
        case .french: return "Luminosité"
        case .english: return "Brightness"
        case .german: return "Helligkeit"
        case .chinese: return "亮度"
        }
    }

    private func onWord() -> String {
        switch service.language {
        case .italian: return "Attivo"
        case .english: return "On"
        case .german: return "Ein"
        case .chinese: return "开"
        case .french: return "Activé"
        }
    }

    private func offWord() -> String {
        switch service.language {
        case .italian: return "Non attivo"
        case .english: return "Off"
        case .german: return "Aus"
        case .chinese: return "关"
        case .french: return "Désactivé"
        }
    }

    private func nightShiftMenuLabel() -> String {
        switch service.language {
        case .italian: return "Night Shift"
        case .english: return "Night Shift"
        case .german: return "Night Shift"
        case .chinese: return "夜览"
        case .french: return "Night Shift"
        }
    }

    private func trueToneMenuLabel() -> String {
        switch service.language {
        case .italian: return "True Tone"
        case .english: return "True Tone"
        case .german: return "True Tone"
        case .chinese: return "原彩显示"
        case .french: return "True Tone"
        }
    }

    private func volumeMenuLabel() -> String {
        switch service.language {
        case .italian: return "Volume"
        case .french: return "Volume"
        case .english: return "Volume"
        case .german: return "Lautstärke"
        case .chinese: return "音量"
        }
    }

    private func connectionInfoMenuLabel() -> String {
        switch service.language {
        case .italian: return "Info connessione"
        case .french: return "Infos de connexion"
        case .english: return "Connection info"
        case .german: return "Verbindungsinfo"
        case .chinese: return "连接信息"
        }
    }

    // AppKit's menu uses a nested tracking loop. Run state changes only after it
    // positively reports closure, avoiding an invisible menu window that can
    // remain above the streamed desktop and swallow clicks.
    private func runAfterMenuDismissal(
        _ action: @escaping @MainActor @Sendable () -> Void
    ) {
        pendingMenuAction = action
    }

    @objc
    private func showMainWindow() {
        runAfterMenuDismissal {
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    @objc
    private func addSession() {
        runAfterMenuDismissal { [service] in
            service.addSession()
        }
    }

    @objc
    private func stopAll() {
        runAfterMenuDismissal { [service] in
            service.stopAll()
        }
    }

    @objc
    private func hideStatusItem() {
        runAfterMenuDismissal { [service] in
            service.showsMenuBarIcon = false
        }
    }

    @objc
    private func quitApp() {
        runAfterMenuDismissal { [service] in
            service.quitAfterUserRequest()
        }
    }
}

extension TBDisplaySenderStatusItemController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenuItems(in: menu)
    }

    func menuDidClose(_ menu: NSMenu) {
        guard let action = pendingMenuAction else { return }
        pendingMenuAction = nil
        DispatchQueue.main.async(execute: action)
    }
}

/// Target for a menu slider. NSSlider holds its target weakly, so the controller
/// retains these for the lifetime of the open menu.
@MainActor
final class TBMenuSliderTarget: NSObject {
    private let onChange: (Double) -> Void

    init(_ onChange: @escaping (Double) -> Void) {
        self.onChange = onChange
    }

    @objc func changed(_ sender: NSSlider) {
        onChange(sender.doubleValue)
    }
}
