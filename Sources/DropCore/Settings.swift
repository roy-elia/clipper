import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    public var hotkey: Hotkey = .default
    public var historyCapacity: Int = 1000
    public var playSounds: Bool = false
    public var ignoredBundleIDs: [String] = Array(CaptureRules.defaultIgnored).sorted()
    public var mcpEnabled: Bool = false
    public var mcpPort: UInt16 = 47821
    public var spotlightEnabled: Bool = false

    public init() {}

    // Older settings files lack newer keys; fall back to defaults instead of discarding everything.
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let def = AppSettings()
        hotkey = try c.decodeIfPresent(Hotkey.self, forKey: .hotkey) ?? def.hotkey
        historyCapacity = try c.decodeIfPresent(Int.self, forKey: .historyCapacity) ?? def.historyCapacity
        playSounds = try c.decodeIfPresent(Bool.self, forKey: .playSounds) ?? def.playSounds
        ignoredBundleIDs = try c.decodeIfPresent([String].self, forKey: .ignoredBundleIDs) ?? def.ignoredBundleIDs
        mcpEnabled = try c.decodeIfPresent(Bool.self, forKey: .mcpEnabled) ?? def.mcpEnabled
        mcpPort = try c.decodeIfPresent(UInt16.self, forKey: .mcpPort) ?? def.mcpPort
        spotlightEnabled = try c.decodeIfPresent(Bool.self, forKey: .spotlightEnabled) ?? def.spotlightEnabled
    }

    public static let capacityRange = 50...10_000

    public mutating func setCapacity(_ n: Int) {
        historyCapacity = min(max(n, AppSettings.capacityRange.lowerBound), AppSettings.capacityRange.upperBound)
    }

    public static func load(_ url: URL) -> AppSettings {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) } ?? AppSettings()
    }

    public func save(_ url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
