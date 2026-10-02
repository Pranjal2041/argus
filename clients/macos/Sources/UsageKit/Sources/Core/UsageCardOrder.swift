import Foundation

@available(macOS 14.0, *)
public enum UsageCardPlacement { case before, after }

/// Ordering identifies the represented account/device, never its current
/// reading or status. Aggregate cards carry their member accounts' anchors so
/// an unavailable account becoming a reporting group keeps its chosen place.
@available(macOS 14.0, *)
struct UsageCardIdentity {
    var primary: String?
    var members: [String] = []
    var keys: [String] { UsageCardOrder.unique([primary].compactMap { $0 } + members) }

    static func source(_ id: String) -> Self { Self(primary: "source:" + id) }
    static func group(sources: [String]) -> Self { Self(members: sources.map { "source:" + $0 }) }
    static func drive(sourceID: String, driveID: String) -> Self {
        Self(primary: "drive:" + UsageMeasurement.identity([sourceID, driveID]), members: ["source:" + sourceID])
    }
}

@available(macOS 14.0, *)
struct UsageCardOrder {
    private(set) var keys: [String]

    init(keys: [String] = []) { self.keys = Self.unique(keys.filter { !$0.isEmpty }) }

    func arranged(_ cards: [UsageGlance]) -> [UsageGlance] {
        let ranks = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($0.element, $0.offset) })
        func rank(_ card: UsageGlance) -> Int {
            let identity = card.ordering ?? UsageCardIdentity(primary: "card:" + card.id)
            if let primary = identity.primary, let rank = ranks[primary] { return rank }
            return identity.members.compactMap { ranks[$0] }.min() ?? Int.max
        }
        return cards.enumerated().sorted {
            let left = rank($0.element), right = rank($1.element)
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
    }

    @discardableResult
    mutating func move(_ id: String, relativeTo targetID: String, placement: UsageCardPlacement,
                       cards: [UsageGlance]) -> Bool {
        let current = arranged(cards)
        guard id != targetID, let from = current.firstIndex(where: { $0.id == id }),
              current.contains(where: { $0.id == targetID }) else { return false }
        var reordered = current
        let moved = reordered.remove(at: from)
        guard let target = reordered.firstIndex(where: { $0.id == targetID }) else { return false }
        reordered.insert(moved, at: target + (placement == .after ? 1 : 0))
        guard current.map(\.id) != reordered.map(\.id) else { return false }
        func identities(_ cards: [UsageGlance]) -> [String] {
            Self.unique(cards.flatMap { ($0.ordering ?? UsageCardIdentity(primary: "card:" + $0.id)).keys })
        }
        let visible = Set(identities(current))
        var reorderedKeys = identities(reordered).makeIterator()
        var result: [String] = []
        // Keep temporarily absent cards in their saved slots. A refresh or a
        // disconnected machine must not erase its arrangement.
        for key in keys {
            if visible.contains(key) {
                if let next = reorderedKeys.next() { result.append(next) }
            } else { result.append(key) }
        }
        while let next = reorderedKeys.next() { result.append(next) }
        keys = Self.unique(result)
        return true
    }

    static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
