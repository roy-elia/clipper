import Foundation

public struct Settings: Codable, Equatable, Sendable {
    public var hotkey: Hotkey = .default
    public var historyCapacity: Int = 1000
    public var playSounds: Bool = false
    public var ignoredBundleIDs: [String] = Array(CaptureRules.defaultIgnored).sorted()

    public init() {}

    public static let capacityRange = 50...10_000

    public mutating func setCapacity(_ n: Int) {
        historyCapacity = min(max(n, Settings.capacityRange.lowerBound), Settings.capacityRange.upperBound)
    }

    public static func load(_ url: URL) -> Settings {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
    }

    public func save(_ url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
