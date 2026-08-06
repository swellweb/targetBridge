import AppKit
import SwiftUI

@main
struct TBDisplaySenderApp: App {
    @StateObject private var service = TBDisplaySenderService.shared
    private let statusItemController = TBDisplaySenderStatusItemController(service: TBDisplaySenderService.shared)

    @MainActor
    init() {
        TBInputDebugLog.prepareForLaunch()
        /* LaunchAgent automation must not depend on SwiftUI restoring or
         * displaying the main window. A headless Mac mini can legitimately
         * launch with that window closed; the Receiver still has to get video. */
        TBSenderAutomation.handleLaunchArguments(CommandLine.arguments)
    }

    var body: some Scene {
        WindowGroup("TargetBridge", id: "main") {
            TBDisplaySenderContentView(service: service)
                .frame(minWidth: 540)
                .task {
                    statusItemController.activate()
                }
                .onOpenURL { url in
                    TBSenderAutomation.handle(url: url)
                }
        }
        .defaultSize(width: 860, height: 860)
        .commands {
            // Replace macOS's default Quit action too, so the application menu
            // and Command-Q have the same persistent-stop semantics as the
            // menu-bar icon. Crash recovery remains managed by launchd.
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
