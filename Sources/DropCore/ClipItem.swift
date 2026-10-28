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
    /// True when only the language model (not a hard rule) flagged the clip. Those are hidden but never auto-deleted.
    public var modelFlagged: Bool?
    /// Last change time, used to settle sync conflicts (newest wins). Nil on clips saved before sync existed.
    public var modifiedAt: Date?
    /// A name the user gave the clip (Rename); shown instead of the kind on the card.
    public var customTitle: String?
    /// When the clip was last pasted or copied back out of Clipper; nil means never.
    public var lastUsed: Date?

    public init(id: UUID = UUID(), kind: ClipKind, title: String, text: String? = nil, data: Data? = nil,
                sourceBundleID: String? = nil, checksum: String, createdAt: Date = Date(), pinboard: String? = nil,
                extras: [String: Data]? = nil, fileURLs: [String]? = nil, sensitive: Bool? = nil, modifiedAt: Date? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.text = text; self.data = data
        self.sourceBundleID = sourceBundleID; self.checksum = checksum; self.createdAt = createdAt
        self.pinboard = pinboard; self.extras = extras; self.fileURLs = fileURLs; self.sensitive = sensitive; self.modifiedAt = modifiedAt
    }
}

public extension ClipItem {
    var changedAt: Date { modifiedAt ?? createdAt }
    /// What a plain-text paste inserts: no formatting, files become their paths.
    var plainText: String? { text }
    var isSecret: Bool { sensitive == true }
    /// Formatting kept from the source app (rtf), not the preview data Clipper adds itself.
    var isRich: Bool { (extras ?? [:]).keys.contains { $0 != "linkTitle" && $0 != "linkImage" } }
    /// Pasting several selected clips at once: their text, one per line, in the order selected. Secrets and
    /// clips without text (images) are left out.
    static func joinedText(_ items: [ClipItem]) -> String {
        items.filter { !$0.isSecret }.compactMap { $0.text }.joined(separator: "\n")
    }
    var fileNames: [String] { (fileURLs ?? []).map { URL(string: $0)?.lastPathComponent ?? $0 } }
}

extension ClipItem {
    /// Apps whose copied images are screenshots. Matched by prefix, so versioned IDs such as Snagit's count too.
    public static let screenshotApps = ["com.apple.screencaptureui", "com.apple.screenshot", "cc.ffitch.shottr",
                                        "pl.maketheweb.cleanshotx", "com.TechSmith.Snagit", "com.xnipapp.xnip",
                                        "com.skillbrains.lightshot", "com.monosnap.monosnap"]
    private static let screenshotNames = try! NSRegularExpression(pattern: #"^(Screenshot|Screen Shot|CleanShot|Shottr|SCR-)[ _-]?.*\.(png|jpe?g|heic|tiff?|gif|webp)$"#, options: [.caseInsensitive])

    /// An image copied from a screenshot tool, or a copied file named like a screenshot (macOS, CleanShot, Shottr).
    public var isScreenshot: Bool {
        switch kind {
        case .image:
            guard let b = sourceBundleID else { return false }
            return Self.screenshotApps.contains { b.hasPrefix($0) }
        case .file:
            return (fileURLs ?? []).contains { u in
                let name = (URL(string: u)?.lastPathComponent).flatMap { $0.isEmpty ? nil : $0 } ?? (u as NSString).lastPathComponent
                return Self.screenshotNames.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
            }
        default: return false
        }
    }
}
