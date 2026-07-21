import Foundation

struct TBDisplayProfileSettings: Equatable {
    let captureSource: TBDisplayCaptureSource
    let capturePreset: TBDisplayCapturePreset
    let matchRenderToStream: Bool
    let audioEnabled: Bool
}

enum TBDisplayProfile: String, CaseIterable, Identifiable, Codable {
    case work5K
    case lowLatency
    case presentation

    var id: String { rawValue }

    var settings: TBDisplayProfileSettings {
        switch self {
        case .work5K:
            return TBDisplayProfileSettings(
                captureSource: .extendedDesktop,
                capturePreset: .native5k,
                matchRenderToStream: true,
                audioEnabled: false
            )
        case .lowLatency:
            return TBDisplayProfileSettings(
                captureSource: .desktopMirror,
                capturePreset: .smooth1440p60,
                matchRenderToStream: false,
                audioEnabled: false
            )
        case .presentation:
            return TBDisplayProfileSettings(
                captureSource: .desktopMirror,
                capturePreset: .standard1440p,
                matchRenderToStream: false,
                audioEnabled: true
            )
        }
    }
}
