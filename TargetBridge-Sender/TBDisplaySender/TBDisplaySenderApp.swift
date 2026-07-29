import SwiftUI

@main
struct TBDisplaySenderApp: App {
    @StateObject private var service = TBDisplaySenderService.shared
    private let statusItemController = TBDisplaySenderStatusItemController(service: TBDisplaySenderService.shared)

    var body: some Scene {
        WindowGroup("TargetBridge", id: "main") {
            TBDisplaySenderContentView(service: service)
                .frame(minWidth: 540)
                .task {
                    statusItemController.activate()
                    // Track which output the user was on before selecting ours,
                    // so we can hand it back rather than leaving them silent.
                    // Only meaningful when our device exists to be selected.
                    if service.audioDriverAvailable {
                        TBDefaultOutputGuard.shared.begin()
                    }
                    TBSenderAutomation.handleLaunchArguments(CommandLine.arguments)
                }
                .onOpenURL { url in
                    TBSenderAutomation.handle(url: url)
                }
        }
        .defaultSize(width: 860, height: 860)

        Settings {
            TBDisplaySenderSettingsView(service: service)
                .frame(minWidth: 760, minHeight: 620)
        }
    }
}
