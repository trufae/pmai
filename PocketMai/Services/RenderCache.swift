import Foundation

/// Rendering is reproducible: evict derived data before it can retain an
/// unbounded amount of chat history. Costs include source text and estimated
/// rendered storage, not just the number of messages or streaming snapshots.
struct RenderCache<Key: Hashable, Value> {
  private struct Entry {
    var value: Value
    var cost: Int
    var access: UInt64
  }

  let maximumCount: Int
  let maximumCost: Int
  private var entries: [Key: Entry] = [:]
  private var access: UInt64 = 0
  private(set) var totalCost = 0

  init(maximumCount: Int, maximumCost: Int) {
    self.maximumCount = max(0, maximumCount)
    self.maximumCost = max(0, maximumCost)
  }

  mutating func value(for key: Key) -> Value? {
    guard var entry = entries[key] else { return nil }
    access &+= 1
    entry.access = access
    entries[key] = entry
    return entry.value
  }

  mutating func removeValue(for key: Key) {
    if let old = entries.removeValue(forKey: key) { totalCost -= old.cost }
  }

  mutating func insert(_ value: Value, for key: Key, cost: Int) {
    removeValue(for: key)
    let cost = max(0, cost)
    guard maximumCount > 0, cost <= maximumCost else { return }
    while entries.count >= maximumCount || totalCost > maximumCost - cost {
      guard let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key else { break }
      removeValue(for: oldest)
    }
    access &+= 1
    entries[key] = Entry(value: value, cost: cost, access: access)
    totalCost += cost
  }
}
