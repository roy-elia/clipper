import Foundation

/// What to do with a clip that looks like a credential.
public enum SecretPolicy: String, Codable, CaseIterable, Sendable {
    case mask    // keep it, hidden on the shelf
    case expire  // keep it hidden, then delete it after a few minutes
    case skip    // never save it
}

/// How long unpinned clips are kept.
public enum Retention: String, Codable, CaseIterable, Sendable {
    case day, week, month, year, forever
    public var seconds: TimeInterval? {
        switch self { case .day: 86_400; case .week: 7 * 86_400; case .month: 30 * 86_400; case .year: 365 * 86_400; case .forever: nil }
    }
    public var label: String { rawValue == "forever" ? "Forever" : "1 \(rawValue)" }
}

/// What picking a clip does: paste into the front app, or only put it on the clipboard.
public enum PasteTarget: String, Codable, CaseIterable, Sendable { case activeApp, clipboard }

/// The key held with 1…9 to paste a clip by position.
public enum QuickModifier: String, Codable, CaseIterable, Sendable {
    case command, option, control
    public var symbol: String { switch self { case .command: "⌘"; case .option: "⌥"; case .control: "⌃" } }
}

/// A capture pause that may end on its own.
public struct CapturePause: Equatable, Sendable {
    public var until: Date?          // nil while paused means "until resumed"
    public var active: Bool
    public init(active: Bool = false, until: Date? = nil) { self.active = active; self.until = until }
    public static let durations: [(String, TimeInterval)] = [("15 minutes", 900), ("30 minutes", 1800), ("1 hour", 3600), ("3 hours", 10_800), ("8 hours", 28_800)]
    public func isPaused(at now: Date = Date()) -> Bool { active && (until.map { now < $0 } ?? true) }
}

/// When the shelf opens on Picks (suggestions) instead of the full history.
public enum SuggestTrigger: String, Codable, CaseIterable, Sendable {
    case always        // every time the shelf opens
    case appChanged    // only when you open it from a different app than last time
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
    public var stackHotkey: Hotkey = Hotkey(keyCode: 8, modifiers: Hotkey.cmd | Hotkey.shift)
    /// Clears screenshots from anywhere: ⌃⌥⌘⌫ (Delete is key code 51).
    public var screenshotsHotkey: Hotkey = Hotkey(keyCode: 51, modifiers: Hotkey.control | Hotkey.option | Hotkey.cmd)
    public var onboarded: Bool = false
    public var lastSeenVersion: String?
    public var iCloudSync: Bool = false
    public var alwaysPlain: Bool = false
    public var showMenuBarIcon: Bool = true
    public var retention: Retention = .forever
    public var linkPreviews: Bool = false
    public var pasteTarget: PasteTarget = .activeApp
    public var ignoreConfidential: Bool = true
    public var ignoreTransient: Bool = true
    public var quickModifier: QuickModifier = .command
    public var editorAutosave: Bool = false
    public var suggestTrigger: SuggestTrigger = .always
    public var askedDirectPaste: Bool = false
    public var askedMoveToApplications: Bool = false

    public init() {}

    /// Shelf ⇧⌘V and Paste Stack ⇧⌘C.
    public mutating func resetShortcuts() {
        let d = AppSettings(); hotkey = d.hotkey; stackHotkey = d.stackHotkey; screenshotsHotkey = d.screenshotsHotkey; quickModifier = d.quickModifier
    }

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
        screenshotsHotkey = try c.decodeIfPresent(Hotkey.self, forKey: .screenshotsHotkey) ?? def.screenshotsHotkey
        onboarded = try c.decodeIfPresent(Bool.self, forKey: .onboarded) ?? def.onboarded
        lastSeenVersion = try c.decodeIfPresent(String.self, forKey: .lastSeenVersion)
        iCloudSync = try c.decodeIfPresent(Bool.self, forKey: .iCloudSync) ?? def.iCloudSync
        alwaysPlain = try c.decodeIfPresent(Bool.self, forKey: .alwaysPlain) ?? def.alwaysPlain
        showMenuBarIcon = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon) ?? def.showMenuBarIcon
        retention = try c.decodeIfPresent(Retention.self, forKey: .retention) ?? def.retention
        linkPreviews = try c.decodeIfPresent(Bool.self, forKey: .linkPreviews) ?? def.linkPreviews
        pasteTarget = try c.decodeIfPresent(PasteTarget.self, forKey: .pasteTarget) ?? def.pasteTarget
        ignoreConfidential = try c.decodeIfPresent(Bool.self, forKey: .ignoreConfidential) ?? def.ignoreConfidential
        ignoreTransient = try c.decodeIfPresent(Bool.self, forKey: .ignoreTransient) ?? def.ignoreTransient
        quickModifier = try c.decodeIfPresent(QuickModifier.self, forKey: .quickModifier) ?? def.quickModifier
        editorAutosave = try c.decodeIfPresent(Bool.self, forKey: .editorAutosave) ?? def.editorAutosave
        suggestTrigger = try c.decodeIfPresent(SuggestTrigger.self, forKey: .suggestTrigger) ?? def.suggestTrigger
        askedDirectPaste = try c.decodeIfPresent(Bool.self, forKey: .askedDirectPaste) ?? def.askedDirectPaste
        askedMoveToApplications = try c.decodeIfPresent(Bool.self, forKey: .askedMoveToApplications) ?? def.askedMoveToApplications
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
