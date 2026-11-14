import AppKit
import ApplicationServices
import Darwin
import SwiftUI

@main
struct TBDisplaySenderApp: App {
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
                .task {
                    statusItemController.activate()
                }
                // Every control URL belongs to this shared Sender. Without an
                // explicit match SwiftUI creates a new window for each request.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .onOpenURL { url in
                    TBSenderAutomation.handle(url: url)
                }
        }
        .handlesExternalEvents(matching: ["*"])
        .defaultSize(width: 860, height: 860)
        .commands {
            // Keep WindowGroup's background lifetime when the panel closes,
            // but do not offer another panel for the same shared service.
            CommandGroup(replacing: .newItem) { }
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
