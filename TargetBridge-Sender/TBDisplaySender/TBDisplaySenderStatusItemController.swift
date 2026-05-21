import AppKit
import Combine

@MainActor
final class TBDisplaySenderStatusItemController: NSObject {
    private let service: TBDisplaySenderService
    nonisolated(unsafe) private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private var hasActivated = false

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

        let statusItem = NSMenuItem(title: service.summaryStatusText(), action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        if !service.localInterfaces.isEmpty {
            let ipItem = NSMenuItem(title: TBDisplaySenderL10n.topBarIP(service.language, service.localInterfaceSummaryText), action: nil, keyEquivalent: "")
            ipItem.isEnabled = false
            menu.addItem(ipItem)
        }

        for session in service.sessions {
            let line = "\(service.sessionTitle(for: session)): \(session.statusText)"
            let sessionItem = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            sessionItem.isEnabled = false
            menu.addItem(sessionItem)
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
    private func addSession() {
        service.addSession()
    }

    @objc
    private func stopAll() {
        service.stopAll()
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
