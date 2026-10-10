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

  func testLegacyResponseFollowingSettingIsIgnoredAndNotSaved() throws {
    for enabled in [true, false] {
      let data = Data("{\"scrollToFollowResponses\":\(enabled)}".utf8)
      let decoded = try JSONDecoder().decode(AppearanceSettings.self, from: data)
      XCTAssertEqual(decoded, .defaults)
      let encoded = try JSONEncoder().encode(decoded)
      let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
      XCTAssertNil(object["scrollToFollowResponses"])
    }
  }
}
