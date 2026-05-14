import AppKit
import Combine

@MainActor
final class TBDisplaySenderStatusItemController: NSObject {
    private let service: TBDisplaySenderService
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private var hasActivated = false

    init(service: TBDisplaySenderService) {
        self.service = service
        super.init()
        bind()
        observeApplicationLifecycle()
    }

    private func bind() {
        service.$showsMenuBarIcon
            .sink { [weak self] _ in
                guard let self, self.hasActivated else { return }
                self.syncVisibility()
            }
            .store(in: &cancellables)

        Publishers.MergeMany(
            service.$language.map { _ in () }.eraseToAnyPublisher(),
            service.$statusText.map { _ in () }.eraseToAnyPublisher(),
            service.$isConnected.map { _ in () }.eraseToAnyPublisher(),
            service.$isStreaming.map { _ in () }.eraseToAnyPublisher(),
            service.$myTBIP.map { _ in () }.eraseToAnyPublisher(),
            service.$receiverIP.map { _ in () }.eraseToAnyPublisher()
        )
        .sink { [weak self] in
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
        item.menu = makeMenu()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let titleItem = NSMenuItem(title: "TargetBridge", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        let statusItem = NSMenuItem(title: service.statusText, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        if let ip = service.myTBIP {
            let ipItem = NSMenuItem(title: TBDisplaySenderL10n.topBarIP(service.language, ip), action: nil, keyEquivalent: "")
            ipItem.isEnabled = false
            menu.addItem(ipItem)
        }

        menu.addItem(.separator())

        let openItem = NSMenuItem(
            title: TBDisplaySenderL10n.showMainWindow(service.language),
            action: #selector(showMainWindow),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)

        let connectTitle = service.isConnected
            ? TBDisplaySenderL10n.stopButton(service.language)
            : TBDisplaySenderL10n.connectButton(service.language)
        let connectItem = NSMenuItem(title: connectTitle, action: #selector(toggleConnection), keyEquivalent: "")
        connectItem.target = self
        connectItem.isEnabled = service.isConnected || !service.receiverIP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        menu.addItem(connectItem)

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

        return menu
    }

    @objc
    private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows {
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc
    private func toggleConnection() {
        if service.isConnected {
            service.stop()
        } else {
            service.connect()
        }
    }

    @objc
    private func hideStatusItem() {
        service.showsMenuBarIcon = false
    }

    @objc
    private func quitApp() {
        NSApp.terminate(nil)
    }
}
