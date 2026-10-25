import Foundation

/// What to do with a clip that looks like a credential.
public enum SecretPolicy: String, Codable, CaseIterable, Sendable {
    case mask    // keep it, hidden on the shelf
    case expire  // keep it hidden, then delete it after a few minutes
    case skip    // never save it
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var hotkey: Hotkey = .default
    public var historyCapacity: Int = 1000
    public var playSounds: Bool = false
    public var ignoredBundleIDs: [String] = Array(CaptureRules.defaultIgnored).sorted()
    public var mcpEnabled: Bool = false
    public var mcpPort: UInt16 = 47821
    public var spotlightEnabled: Bool = false
    public var secretPolicy: SecretPolicy = .expire
    public var secretMinutes: Int = 5
    public var opensOnPicks: Bool = true
    public var smartModel: Bool = true
    public var hideFromSharing: Bool = true
    public var stackHotkey: Hotkey = Hotkey(keyCode: 9, modifiers: Hotkey.cmd | Hotkey.control)
    public var onboarded: Bool = false
    public var lastSeenVersion: String?
    public var iCloudSync: Bool = false

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
        secretPolicy = try c.decodeIfPresent(SecretPolicy.self, forKey: .secretPolicy) ?? def.secretPolicy
        secretMinutes = try c.decodeIfPresent(Int.self, forKey: .secretMinutes) ?? def.secretMinutes
        opensOnPicks = try c.decodeIfPresent(Bool.self, forKey: .opensOnPicks) ?? def.opensOnPicks
        smartModel = try c.decodeIfPresent(Bool.self, forKey: .smartModel) ?? def.smartModel
        hideFromSharing = try c.decodeIfPresent(Bool.self, forKey: .hideFromSharing) ?? def.hideFromSharing
        stackHotkey = try c.decodeIfPresent(Hotkey.self, forKey: .stackHotkey) ?? def.stackHotkey
        onboarded = try c.decodeIfPresent(Bool.self, forKey: .onboarded) ?? def.onboarded
        lastSeenVersion = try c.decodeIfPresent(String.self, forKey: .lastSeenVersion)
        iCloudSync = try c.decodeIfPresent(Bool.self, forKey: .iCloudSync) ?? def.iCloudSync
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
