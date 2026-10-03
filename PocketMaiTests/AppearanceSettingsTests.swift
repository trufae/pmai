import XCTest

@testable import PocketMai

final class AppearanceSettingsTests: XCTestCase {
  func testGitHubTokenDefaultsAndRoundTrips() throws {
    var settings = try JSONDecoder().decode(NativeToolSettings.self, from: Data("{}".utf8))
    XCTAssertEqual(settings.githubAPIKey, "")
    settings.githubAPIKey = "test-token"
    let decoded = try JSONDecoder().decode(
      NativeToolSettings.self, from: JSONEncoder().encode(settings))
    XCTAssertEqual(decoded.githubAPIKey, "test-token")
  }

  func testResponseFollowingPreservesExistingDefaultForLegacySettings() throws {
    let decoded = try JSONDecoder().decode(AppearanceSettings.self, from: Data("{}".utf8))

    XCTAssertTrue(AppearanceSettings.defaults.scrollToFollowResponses)
    XCTAssertTrue(decoded.scrollToFollowResponses)
  }

  func testDisabledResponseFollowingRoundTrips() throws {
    var settings = AppearanceSettings.defaults
    settings.scrollToFollowResponses = false

    let decoded = try JSONDecoder().decode(
      AppearanceSettings.self,
      from: JSONEncoder().encode(settings))

    XCTAssertFalse(decoded.scrollToFollowResponses)
  }
}
