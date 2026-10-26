/// Resolves a displayed list position to a zero-based array index.
public enum ListIndex {
  /// Positive positions start at one; negative positions count from the end.
  public static func resolve(_ raw: String, count: Int) -> Int? {
    guard count > 0, let value = Int(raw), value != 0 else { return nil }
    let index = value > 0 ? value - 1 : count + value
    return (0..<count).contains(index) ? index : nil
  }
}
