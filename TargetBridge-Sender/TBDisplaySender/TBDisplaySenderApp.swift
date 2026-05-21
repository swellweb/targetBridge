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
                }
        }
        .defaultSize(width: 860, height: 860)

        Settings {
            TBDisplaySenderSettingsView(service: service)
                .frame(minWidth: 560, minHeight: 420)
        }
    }
}
