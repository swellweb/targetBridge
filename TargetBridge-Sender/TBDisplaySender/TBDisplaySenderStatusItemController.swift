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
    }

    // Menu-item handlers run while the menu is still dismissing. Doing work
    // synchronously here (activating the app, ordering windows front, mutating
    // observed session state) interrupts the menu window's fade-out: its alpha
    // animates to 0 but the window is never closed, leaving an invisible
    // menu-layer window that swallows clicks at the menu's footprint. Deferring
    // to the next runloop tick lets the menu fully tear down first.
    private func runAfterMenuDismissal(_ action: @escaping () -> Void) {
        DispatchQueue.main.async(execute: action)
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
        runAfterMenuDismissal {
            NSApp.terminate(nil)
        }
    }
}

extension TBDisplaySenderStatusItemController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenuItems(in: menu)
    }
}
