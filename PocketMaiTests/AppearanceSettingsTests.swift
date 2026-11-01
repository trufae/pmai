import XCTest

@testable import PocketMai

final class AppearanceSettingsTests: XCTestCase {
  func testTablesDefaultToBalancedLayout() throws {
    XCTAssertEqual(AppearanceSettings.defaults.tableLayout, .balanced)
    for json in ["{}", "{\"tableLayout\":\"unknown\"}"] {
      let decoded = try JSONDecoder().decode(AppearanceSettings.self, from: Data(json.utf8))
      XCTAssertEqual(decoded.tableLayout, .balanced)
    }
  }

  func testLegacyTableChoicesArePreserved() throws {
    for unwrapped in [true, false] {
      let data = Data("{\"unwrappedTables\":\(unwrapped)}".utf8)
      let decoded = try JSONDecoder().decode(AppearanceSettings.self, from: data)
      XCTAssertEqual(decoded.tableLayout, unwrapped ? .expanded : .compact)
    }
    let data = Data("{\"tableLayout\":\"balanced\",\"unwrappedTables\":true}".utf8)
    XCTAssertEqual(
      try JSONDecoder().decode(AppearanceSettings.self, from: data).tableLayout, .balanced)
  }

  func testAllTableLayoutsAreSavedAndRestored() throws {
    for layout in AppearanceTableLayout.allCases {
      var settings = AppearanceSettings.defaults
      settings.tableLayout = layout
      let encoded = try JSONEncoder().encode(settings)
      XCTAssertEqual(try JSONDecoder().decode(AppearanceSettings.self, from: encoded), settings)
      let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
      XCTAssertEqual(object["tableLayout"] as? String, layout.rawValue)
      XCTAssertNil(object["unwrappedTables"])
    }
  }

  func testGitHubTokenDefaultsAndRoundTrips() throws {
    var settings = try JSONDecoder().decode(NativeToolSettings.self, from: Data("{}".utf8))
    XCTAssertEqual(settings.githubAPIKey, "")
    settings.githubAPIKey = "test-token"
    let decoded = try JSONDecoder().decode(
      NativeToolSettings.self, from: JSONEncoder().encode(settings))
    XCTAssertEqual(decoded.githubAPIKey, "test-token")
  }

  func testResponseFollowingDefaultsToKeepingResponseBeginningsVisible() throws {
    let decoded = try JSONDecoder().decode(AppearanceSettings.self, from: Data("{}".utf8))
    XCTAssertFalse(AppearanceSettings.defaults.scrollToFollowResponses)
    XCTAssertFalse(decoded.scrollToFollowResponses)
  }

  func testResponseFollowingSettingIsRestoredAndSaved() throws {
    for enabled in [true, false] {
      let data = Data("{\"scrollToFollowResponses\":\(enabled)}".utf8)
      let decoded = try JSONDecoder().decode(AppearanceSettings.self, from: data)
      XCTAssertEqual(decoded.scrollToFollowResponses, enabled)
      let encoded = try JSONEncoder().encode(decoded)
      let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
      XCTAssertEqual(object["scrollToFollowResponses"] as? Bool, enabled)
      XCTAssertEqual(try JSONDecoder().decode(AppearanceSettings.self, from: encoded), decoded)
    }
  }

  func testRetiredBubbleSettingsAreIgnoredAndNotSaved() throws {
    let retiredSettings = [
      "\"solidBubbles\":\"user\"",
      "\"solidBubbles\":\"both\"",
      "\"solidBubbles\":\"none\"",
      "\"solidBubbles\":\"unknown\"",
      "\"solidBubbles\":null",
      "\"solidResponseBubbles\":true",
      "\"solidResponseBubbles\":false",
      "\"colorizeResponseBubbles\":true",
      "\"colorizeResponseBubbles\":false",
    ]
    var expected = AppearanceSettings.defaults
    expected.fontSize = 23

    for setting in retiredSettings {
      let data = Data("{\"fontSize\":23,\(setting)}".utf8)
      let decoded = try JSONDecoder().decode(AppearanceSettings.self, from: data)
      XCTAssertEqual(decoded, expected, setting)
      let encoded = try JSONEncoder().encode(decoded)
      let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
      XCTAssertNil(object["solidBubbles"])
      XCTAssertNil(object["solidResponseBubbles"])
      XCTAssertNil(object["colorizeResponseBubbles"])
    }
  }
}
