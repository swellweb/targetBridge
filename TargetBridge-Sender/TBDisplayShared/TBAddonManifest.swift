import Foundation

enum TBAddonCapability: String, Codable, CaseIterable, Hashable {
    case networkLink = "network-link"
    case audioRelay = "audio-relay"
}

enum TBAddonOrigin: String, Hashable {
    case bundled
    case user
}

struct TBAddonManifest: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let version: String
    let summary: String
    let author: String?
    let websiteURL: String?
    let documentationURL: String?
    let minimumSenderVersion: String?
    let capabilities: [TBAddonCapability]
    let experimental: Bool
    let defaultEnabled: Bool

    init(
        id: String,
        name: String,
        version: String,
        summary: String,
        author: String? = nil,
        websiteURL: String? = nil,
        documentationURL: String? = nil,
        minimumSenderVersion: String? = nil,
        capabilities: [TBAddonCapability] = [],
        experimental: Bool = false,
        defaultEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.summary = summary
        self.author = author
        self.websiteURL = websiteURL
        self.documentationURL = documentationURL
        self.minimumSenderVersion = minimumSenderVersion
        self.capabilities = capabilities
        self.experimental = experimental
        self.defaultEnabled = defaultEnabled
    }
}

struct TBAddonRecord: Identifiable, Hashable {
    let manifest: TBAddonManifest
    let origin: TBAddonOrigin
    let sourceURL: URL

    var id: String { manifest.id }
    var name: String { manifest.name }
    var version: String { manifest.version }
    var summary: String { manifest.summary }
}
