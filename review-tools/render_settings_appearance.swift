import AppKit
import SwiftUI

@main
struct SettingsAppearanceFixture {
    @MainActor
    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for scheme in [ColorScheme.light, .dark] {
            let renderer = ImageRenderer(content: fixture
                .environment(\.colorScheme, scheme))
            renderer.scale = 1
            guard let image = renderer.cgImage,
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: output.appendingPathComponent("settings-\(scheme).png"))
        }
    }

    @MainActor
    private static var fixture: some View {
        VStack(alignment: .leading, spacing: 18) {
            SurfaceCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("TargetBridge Settings").font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("Appearance regression fixture").foregroundStyle(.secondary)
                }
            }
            SurfaceCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("INTERFACE").font(.caption.bold()).foregroundStyle(.secondary)
                    Text("Show menu bar icon").foregroundStyle(.primary)
                    Text("Prevent display sleep").foregroundStyle(.primary)
                }
            }
            SurfaceSubcard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Add-ons").font(.headline).foregroundStyle(.primary)
                    Text("Global preferences follow the system appearance.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .frame(width: 640, height: 360)
        .background(TBSettingsBackground())
    }
}
