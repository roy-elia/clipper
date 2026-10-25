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

    public init(id: UUID = UUID(), kind: ClipKind, title: String, text: String? = nil, data: Data? = nil,
                sourceBundleID: String? = nil, checksum: String, createdAt: Date = Date(), pinboard: String? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.text = text; self.data = data
        self.sourceBundleID = sourceBundleID; self.checksum = checksum; self.createdAt = createdAt
        self.pinboard = pinboard
    }
}
