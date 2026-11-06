import Foundation

/// Rejected submissions remain explicit review items; they are never replayed
/// into a different approval prompt or sent to a model automatically.
struct REPLRecoveredInput {
  struct Entry {
    var text: String
    var promptID: String?
  }
  private(set) var entries: [Entry] = []
  mutating func keep(_ text: String, promptID: String?) {
    entries.append(Entry(text: text, promptID: promptID))
  }
  mutating func take(_ number: Int) -> String? {
    guard entries.indices.contains(number - 1) else { return nil }
    return entries.remove(at: number - 1).text
  }
  mutating func clear() { entries = [] }
}
