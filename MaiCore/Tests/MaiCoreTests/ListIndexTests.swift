import Testing

@testable import MaiCore

@Test("List positions accept either end and reject invalid or overflowing numbers")
func listIndexPositions() {
  for (raw, expected) in [("1", 0), ("3", 2), ("-1", 2), ("-2", 1), ("-3", 0)] {
    #expect(ListIndex.resolve(raw, count: 3) == expected)
  }
  for raw in [
    "0", "4", "-4", "", "missing", "1 extra", String(Int.min), String(Int.max),
    "-9223372036854775809", "9223372036854775808",
  ] {
    #expect(ListIndex.resolve(raw, count: 3) == nil)
  }
  for raw in ["1", "-1", "0", String(Int.min)] {
    #expect(ListIndex.resolve(raw, count: 0) == nil)
  }
  #expect(ListIndex.resolve("-1", count: Int.max) == Int.max - 1)
  #expect(ListIndex.resolve(String(Int.min), count: Int.max) == nil)
}
