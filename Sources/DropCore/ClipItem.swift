import Foundation

public enum ClipKind: String, Codable, Sendable, CaseIterable {
    case text, link, image, file, color
}

public struct ClipItem: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: ClipKind
    public var title: String
    public var text: String?
    public var data: Data?
    public var sourceBundleID: String?
    public var checksum: String
    public var createdAt: Date
    public var pinboard: String?
    /// Extra pasteboard representations (rtf, html) kept so a paste keeps its formatting.
    public var extras: [String: Data]?
    /// Set for file clips: the file URLs, so the paste hands back real files rather than their paths as text.
    public var fileURLs: [String]?
    /// Set when the clip looks like a credential. Such clips are masked, never suggested, hidden from MCP and Spotlight.
    public var sensitive: Bool?

    public init(id: UUID = UUID(), kind: ClipKind, title: String, text: String? = nil, data: Data? = nil,
                sourceBundleID: String? = nil, checksum: String, createdAt: Date = Date(), pinboard: String? = nil,
                extras: [String: Data]? = nil, fileURLs: [String]? = nil, sensitive: Bool? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.text = text; self.data = data
        self.sourceBundleID = sourceBundleID; self.checksum = checksum; self.createdAt = createdAt
        self.pinboard = pinboard; self.extras = extras; self.fileURLs = fileURLs; self.sensitive = sensitive
    }
}

public extension ClipItem {
    /// What a plain-text paste inserts: no formatting, files become their paths.
    var plainText: String? { text }
    var isSecret: Bool { sensitive == true }
    var isRich: Bool { !(extras?.isEmpty ?? true) }
    var fileNames: [String] { (fileURLs ?? []).map { URL(string: $0)?.lastPathComponent ?? $0 } }
}
