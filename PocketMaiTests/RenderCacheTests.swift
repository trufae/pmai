import XCTest

@testable import PocketMai

@MainActor
final class RenderCacheTests: XCTestCase {
  // A count limit alone lets large, obsolete stream snapshots exhaust memory.
  // Use tiny costs to exercise eviction without a memory/load test in CI.
  func testLargeSnapshotsEvictLeastRecentlyUsedResults() {
    var cache = RenderCache<String, String>(maximumCount: 3, maximumCost: 10)
    cache.insert("first result", for: "first", cost: 4)
    cache.insert("second result", for: "second", cost: 4)
    XCTAssertEqual(cache.value(for: "first"), "first result")
    cache.insert("third result", for: "third", cost: 5)
    XCTAssertNil(cache.value(for: "second"))
    XCTAssertEqual(cache.value(for: "first"), "first result")
    XCTAssertEqual(cache.value(for: "third"), "third result")
    cache.insert("replacement", for: "third", cost: 1)
    cache.insert("fourth result", for: "fourth", cost: 5)
    XCTAssertEqual(cache.value(for: "first"), "first result")
    XCTAssertEqual(cache.value(for: "third"), "replacement")
    cache.insert("too large", for: "third", cost: 11)
    XCTAssertNil(cache.value(for: "third"))
    XCTAssertEqual(cache.value(for: "fourth"), "fourth result")
    cache.removeValue(for: "fourth")
    XCTAssertNil(cache.value(for: "fourth"))
  }

  func testSmallEntriesStillRespectTheCountLimit() {
    var cache = RenderCache<Int, String>(maximumCount: 1, maximumCost: 10)
    cache.insert("old", for: 1, cost: 0)
    cache.insert("new", for: 2, cost: 0)
    XCTAssertNil(cache.value(for: 1))
    XCTAssertEqual(cache.value(for: 2), "new")
  }
}
