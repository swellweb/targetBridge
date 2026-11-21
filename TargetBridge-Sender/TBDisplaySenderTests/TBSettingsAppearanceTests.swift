import AppKit
import SwiftUI
import XCTest
@testable import TargetBridge

@MainActor
final class TBSettingsAppearanceTests: XCTestCase {
    func testLightBackgroundIsLight() throws {
        let pixels = try render(TBSettingsBackground(), scheme: .light)
        XCTAssertGreaterThan(try luminance(pixels, x: 64, y: 64), 0.85)
    }

    func testDarkBackgroundRemainsDark() throws {
        let pixels = try render(TBSettingsBackground(), scheme: .dark)
        XCTAssertLessThan(try luminance(pixels, x: 64, y: 64), 0.05)
    }

    func testCardTextContrastInBothAppearances() throws {
        for scheme in [ColorScheme.light, .dark] {
            try assertContrast(SurfaceCard { label }, scheme: scheme)
        }
    }

    func testSubcardTextContrastInBothAppearances() throws {
        for scheme in [ColorScheme.light, .dark] {
            try assertContrast(SurfaceSubcard { label }, scheme: scheme)
        }
    }

    private var label: some View {
        Text("Settings").font(.system(size: 24, weight: .bold)).foregroundStyle(.primary)
    }

    private func assertContrast<V: View>(_ content: V, scheme: ColorScheme) throws {
        let pixels = try render(content.background(TBSettingsBackground()), scheme: scheme)
        var darkest = 1.0
        var lightest = 0.0
        for y in 24..<104 {
            for x in 12..<116 {
                let value = try luminance(pixels, x: x, y: y)
                darkest = min(darkest, value)
                lightest = max(lightest, value)
            }
        }
        XCTAssertGreaterThan((lightest + 0.05) / (darkest + 0.05), 4.5, "\(scheme)")
    }

    private func render<V: View>(_ content: V, scheme: ColorScheme) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: content.frame(width: 128, height: 128)
            .environment(\.colorScheme, scheme))
        renderer.scale = 1
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }

    private func luminance(_ pixels: NSBitmapImageRep, x: Int, y: Int) throws -> Double {
        let color = try XCTUnwrap(pixels.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        func linear(_ channel: CGFloat) -> Double {
            let value = Double(channel)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent)
            + 0.0722 * linear(color.blueComponent)
    }
}
