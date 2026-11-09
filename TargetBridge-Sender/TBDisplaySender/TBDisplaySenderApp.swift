import AppKit
import ApplicationServices
import Darwin
import SwiftUI

/// How the Sender presents itself: Standard (window and Dock icon),
/// Background (menu bar icon only) or Faceless (no window or icons). In the
/// last two, opening the app again (Finder, Launchpad, `open`) shows the window.
enum TBAppPresentation: Int, CaseIterable, Identifiable {
    case standard = 0
    case background = 1
    case faceless = 2

    var id: Int { rawValue }

    static let defaultsKey = "fd.tbdisplaysender.appPresentation"

    static func load() -> TBAppPresentation {
        TBAppPresentation(rawValue: UserDefaults.standard.integer(forKey: defaultsKey)) ?? .standard
    }

    func title(_ language: TBDisplaySenderLanguage) -> String {
        switch self {
        case .standard: return TBDisplaySenderL10n.text("sender.app_mode.standard", language)
        case .background: return TBDisplaySenderL10n.text("sender.app_mode.background", language)
        case .faceless: return TBDisplaySenderL10n.text("sender.app_mode.faceless", language)
        }
    }
}

@MainActor
enum TBAppPresentationController {
    /// Opens a new main window when none exists (set by the main view).
    static var openMainWindow: (() -> Void)?
    private static var handledLaunch = false

    static func apply(_ presentation: TBAppPresentation) {
        NSApp.setActivationPolicy(presentation == .standard ? .regular : .accessory)
    }

    static func mainWindows() -> [NSWindow] {
        let byIdentifier = NSApp.windows.filter { $0.identifier?.rawValue.hasPrefix("main") == true }
        if !byIdentifier.isEmpty { return byIdentifier }
        return NSApp.windows.filter { $0.title == "TargetBridge" && $0.canBecomeMain }
    }

    /// The main window appeared for the first time: at launch, Background and
    /// Faceless start without it.
    static func mainWindowAppeared(_ presentation: TBAppPresentation) {
        guard !handledLaunch else { return }
        handledLaunch = true
        guard presentation != .standard else { return }
        DispatchQueue.main.async {
            for window in mainWindows() { window.orderOut(nil) }
        }
    }

    static func showMainWindow() {
        handledLaunch = true
        NSApp.activate(ignoringOtherApps: true)
        let windows = mainWindows()
        if windows.isEmpty {
            openMainWindow?()
        } else {
            for window in windows { window.makeKeyAndOrderFront(nil) }
        }
    }
}

@MainActor
final class TBDisplaySenderAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        TBAppPresentationController.apply(TBAppPresentation.load())
    }

    /// Opening the app again while it runs (Finder, Dock, Launchpad): show
    /// the window. The way back to the settings in Faceless mode.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        TBAppPresentationController.showMainWindow()
        return false
    }
}

/// Keeps a way to open the main window from AppKit code.
private struct TBMainWindowOpenerInstaller: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            TBAppPresentationController.openMainWindow = { openWindow(id: "main") }
        }
    }
}

@main
struct TBDisplaySenderApp: App {
    @NSApplicationDelegateAdaptor(TBDisplaySenderAppDelegate.self) private var appDelegate
    @StateObject private var service: TBDisplaySenderService
    private let statusItemController: TBDisplaySenderStatusItemController

    @MainActor
    init() {
        // This probe is intentionally handled before constructing the shared
        // service. The Setup Assistant can inspect the exact installed binary
        // without opening a window, starting capture or attaching a display.
        if CommandLine.arguments.contains("--permission-status") {
            let screenRecording = CGPreflightScreenCaptureAccess() ? 1 : 0
            let accessibility = AXIsProcessTrusted() ? 1 : 0
            let inputMonitoring = CGPreflightListenEventAccess() ? 1 : 0
            print("TB_PERMISSION_STATUS:screen_recording=\(screenRecording):accessibility=\(accessibility):input_monitoring=\(inputMonitoring)")
            fflush(stdout)
            Darwin.exit(EXIT_SUCCESS)
        }

        let sharedService = TBDisplaySenderService.shared
        _service = StateObject(wrappedValue: sharedService)
        statusItemController = TBDisplaySenderStatusItemController(service: sharedService)

        // LaunchAgent automation must not depend on SwiftUI restoring or showing
        // the main window on a headless Mac.
        TBSenderAutomation.handleLaunchArguments(CommandLine.arguments)
    }

    var body: some Scene {
        WindowGroup("TargetBridge", id: "main") {
            TBDisplaySenderContentView(service: service)
                .frame(minWidth: 540)
                .modifier(TBMainWindowOpenerInstaller())
                .onAppear {
                    TBAppPresentationController.mainWindowAppeared(service.appPresentation)
                }
                .task {
                    statusItemController.activate()
                }
                .onOpenURL { url in
                    TBSenderAutomation.handle(url: url)
                }
        }
        .defaultSize(width: 860, height: 860)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button(TBDisplaySenderL10n.quitApp(service.language)) {
                    service.quitAfterUserRequest()
                }
                .keyboardShortcut("q")
            }
        }

        Settings {
            TBDisplaySenderSettingsView(service: service)
                .frame(minWidth: 760, minHeight: 620)
        }
    }
}
