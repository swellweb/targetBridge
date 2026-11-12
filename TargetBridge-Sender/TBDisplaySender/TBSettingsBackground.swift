import SwiftUI

struct TBSettingsBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        LinearGradient(
            colors: colorScheme == .dark
                ? [
                    Color(red: 0.12, green: 0.13, blue: 0.14),
                    Color(red: 0.08, green: 0.09, blue: 0.10)
                ]
                : [
                    Color(red: 0.99, green: 0.99, blue: 1.00),
                    Color(red: 0.95, green: 0.96, blue: 0.97)
                ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}
