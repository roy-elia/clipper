import Foundation

/// An ordered queue of clips pasted one after another (first in, first out).
public struct PasteStack: Sendable, Equatable {
    public private(set) var items: [ClipItem] = []
    public init() {}
    public var isEmpty: Bool { items.isEmpty }
    public mutating func push(_ item: ClipItem) { items.append(item) }
    public mutating func pop() -> ClipItem? { items.isEmpty ? nil : items.removeFirst() }
    public mutating func remove(_ id: UUID) { items.removeAll { $0.id == id } }
    public mutating func move(from: Int, to: Int) {
        guard items.indices.contains(from), (0...items.count - 1).contains(to) else { return }
        items.insert(items.remove(at: from), at: to)
    }
    public mutating func clear() { items.removeAll() }
}
