// Inert collaborators for the real TBDisplaySenderApp.swift scene. This fixture
// never constructs a Sender service, advertises a receiver or captures a screen.
import AppKit
import SwiftUI

@MainActor
final class TBDisplaySenderService: ObservableObject {
    static let shared = TBDisplaySenderService()
    let language = "en"
    func quitAfterUserRequest() { NSApp.terminate(nil) }
}

@MainActor
final class TBDisplaySenderStatusItemController {
    init(service: TBDisplaySenderService) { }
    func activate() { }
}

enum TBDisplaySenderL10n {
    static func quitApp(_ language: String) -> String { "Quit fixture" }
}

struct TBDisplaySenderContentView: View {
    let service: TBDisplaySenderService
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Text("Inert Sender window lifecycle fixture")
            .onAppear { WindowFixture.openSettings = { openSettings() } }
    }
}

struct TBDisplaySenderSettingsView: View {
    let service: TBDisplaySenderService
    var body: some View { Text("Inert settings").navigationTitle("Fixture settings") }
}

@MainActor
enum TBSenderAutomation {
    static func handleLaunchArguments(_ arguments: [String]) {
        WindowFixture.start(arguments: arguments)
    }
    static func handle(url: URL) {
        WindowFixture.receivedURLs.append(url.absoluteString)
    }
}

@MainActor
enum WindowFixture {
    static var receivedURLs: [String] = []
    static var openSettings: (() -> Void)?
    private static var lastCommand = -1
    private static var root: URL!
    private static var timer: Timer?
    private static var configuredActivationPolicy = false
    private static var activity: NSObjectProtocol?
    private static var closeObserver: NSObjectProtocol?
    private static var closedWindows: Set<ObjectIdentifier> = []
    private static var mainCloseNotifications = 0

    static func start(arguments: [String]) {
        guard let index = arguments.firstIndex(of: "--fixture-state"),
              index + 1 < arguments.count else { fatalError("Missing fixture state") }
        root = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { notification in
            guard let window = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                closedWindows.insert(ObjectIdentifier(window))
                if window.title == "TargetBridge" { mainCloseNotifications += 1 }
            }
        }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Bounded isolated window lifecycle regression")
        // Only this disposable process is hidden. No foreground application,
        // global input, desktop window or real Sender is controlled.
        timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private static func tick() {
        if !configuredActivationPolicy {
            NSApp.setActivationPolicy(.prohibited)
            configuredActivationPolicy = true
        }
        if let data = try? Data(contentsOf: root.appendingPathComponent("command.json")),
           let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = command["id"] as? Int, id != lastCommand {
            lastCommand = id
            switch command["action"] as? String {
            case "close":
                NSApp.windows.filter { $0.title == "TargetBridge" }.forEach { $0.close() }
            case "minimize":
                NSApp.windows.filter { $0.title == "TargetBridge" }.forEach { $0.miniaturize(nil) }
            case "hide":
                NSApp.windows.filter { $0.title == "TargetBridge" }.forEach { $0.orderOut(nil) }
            case "settings": openSettings?()
            case "close-settings":
                NSApp.windows.filter { $0.title == "Fixture settings" }.forEach { $0.close() }
            case "quit": NSApp.terminate(nil)
            default: break
            }
        }
        let retained = NSApp.windows.filter { $0.contentView != nil && $0.frame.height > 50 }
        // AppKit may retain a closed NSWindow. A close notification, unlike
        // orderOut, ends that window's lifecycle until it is shown again.
        for window in retained where window.isVisible || window.isMiniaturized {
            closedWindows.remove(ObjectIdentifier(window))
        }
        let windows = retained.filter { !closedWindows.contains(ObjectIdentifier($0)) }
        let main = windows.filter { $0.title == "TargetBridge" }
        let snapshot: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "time": Date().timeIntervalSince1970,
            "command": lastCommand,
            "receivedURLs": receivedURLs,
            "mainCount": main.count,
            "retainedMainCount": retained.filter { $0.title == "TargetBridge" }.count,
            "mainCloseNotifications": mainCloseNotifications,
            "visibleMainCount": main.filter(\.isVisible).count,
            "minimizedMainCount": main.filter(\.isMiniaturized).count,
            "windows": windows.map { ["title": $0.title, "visible": $0.isVisible,
                                       "identifier": $0.identifier?.rawValue ?? ""] as [String: Any] },
            "newWindowCommandCount": countNewCommands(NSApp.mainMenu)
        ]
        if let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: root.appendingPathComponent("state.json"), options: .atomic)
        }
    }

    private static func countNewCommands(_ menu: NSMenu?) -> Int {
        (menu?.items ?? []).reduce(0) { count, item in
            count + (item.keyEquivalent == "n" && item.keyEquivalentModifierMask.contains(.command) ? 1 : 0)
                + countNewCommands(item.submenu)
        }
    }
}
