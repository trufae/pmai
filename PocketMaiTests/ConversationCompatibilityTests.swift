import Foundation
import XCTest

@testable import PocketMai

@MainActor
final class ConversationCompatibilityTests: XCTestCase {
  // These are the released on-disk schema boundaries. Intermediate releases either used one of
  // these formats or only changed fields outside Conversation/ChatMessage persistence. Version 1.0
  // predates the PocketMai iOS conversation store.
  private struct FixtureExpectation {
    let id: UUID
    let title: String
    let messageTexts: [String]
    let enabledTools: Set<BuiltInToolID>
    let folderID: String
    var displayText: String?
    var voiceRecordingFilename: String?
    var attachmentCount = 0
    var isUnread = false
  }

  private let fixtures: [String: FixtureExpectation] = [
    "conversation-v1.1": FixtureExpectation(
      id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
      title: "PocketMai 1.1 conversation",
      messageTexts: [
        "Keep this original 1.1 message.",
        "This reply must survive migration.",
      ],
      enabledTools: [
        .datetime, .location, .weather, .webSearch, .todo, .textToSpeech, .files, .memory,
      ],
      folderID: ConversationFolder.archivedID),
    "conversation-v1.2.4": FixtureExpectation(
      id: UUID(uuidString: "12222222-2222-4222-8222-222222222222")!,
      title: "PocketMai 1.2.4 conversation",
      messageTexts: [
        "A system message from 1.2.4.",
        "Preserve the second format boundary.",
      ],
      enabledTools: [.datetime, .weather, .files, .memory],
      folderID: ConversationFolder.defaultID),
    "conversation-v1.3.0": FixtureExpectation(
      id: UUID(uuidString: "13000000-0000-4300-8300-000000000000")!,
      title: "PocketMai 1.3.0 conversation",
      messageTexts: ["This message has an old voice recording."],
      enabledTools: [.language, .calculator, .textToSpeech],
      folderID: ConversationFolder.defaultID,
      voiceRecordingFilename: "recording-1.3.m4a"),
    "conversation-v1.3.6": FixtureExpectation(
      id: UUID(uuidString: "13666666-6666-4366-8366-666666666666")!,
      title: "PocketMai 1.3.6 attachments",
      messageTexts: ["Read both historical attachments."],
      enabledTools: [.language, .calculator, .files],
      folderID: ConversationFolder.defaultID,
      attachmentCount: 2),
    "conversation-v1.4.8": FixtureExpectation(
      id: UUID(uuidString: "14888888-8888-4488-8488-888888888888")!,
      title: "PocketMai 1.4.8 folder conversation",
      messageTexts: ["Internal tool transcript that remains as context."],
      enabledTools: [.calendar, .memory, .webSearch],
      folderID: "historical-folder",
      displayText: "Visible assistant answer from 1.4.8."),
    "conversation-v1.5.8": FixtureExpectation(
      id: UUID(uuidString: "15888888-8888-4588-8588-888888888888")!,
      title: "PocketMai 1.5.8 conversation",
      messageTexts: ["Historical calendar tool result."],
      enabledTools: [.calendar, .datetime, .todo],
      folderID: ConversationFolder.defaultID,
      displayText: "Calendar result"),
    "conversation-v1.6.2": FixtureExpectation(
      id: UUID(uuidString: "16222222-2222-4622-8622-222222222222")!,
      title: "PocketMai 1.6.2 conversation",
      messageTexts: ["Even error messages are user data."],
      enabledTools: [
        .datetime, .language, .location, .weather, .webSearch, .todo, .calculator,
        .textToSpeech, .files, .calendar, .memory,
      ],
      folderID: ConversationFolder.archivedID,
      displayText: "A recoverable historical error.",
      voiceRecordingFilename: "voice-1.6.2.m4a",
      isUnread: true),
  ]

  func testReleasedConversationFixturesDecodeWithoutDataLoss() throws {
    for name in fixtures.keys.sorted() {
      try XCTContext.runActivity(named: name) { _ in
        let expected = try XCTUnwrap(fixtures[name])
        let conversation = try decodeFixture(named: name)

        XCTAssertEqual(conversation.id, expected.id)
        XCTAssertEqual(conversation.title, expected.title)
        XCTAssertEqual(conversation.messages.map(\.text), expected.messageTexts)
        XCTAssertEqual(conversation.enabledTools, expected.enabledTools)
        XCTAssertEqual(conversation.folderID, expected.folderID)
        XCTAssertEqual(conversation.messages.first?.displayText, expected.displayText)
        XCTAssertEqual(
          conversation.messages.first?.voiceRecordingFilename,
          expected.voiceRecordingFilename)
        XCTAssertEqual(conversation.messages.first?.attachments.count, expected.attachmentCount)
        XCTAssertEqual(conversation.isUnread, expected.isUnread)
        XCTAssertNil(conversation.toolCallingMode)

        let encoded = try makeEncoder().encode(conversation)
        XCTAssertEqual(try makeDecoder().decode(Conversation.self, from: encoded), conversation)
      }
    }
  }

  func testBackgroundStatusDefaultsOffAndRetainsExistingPreferences() throws {
    let decoder = JSONDecoder()
    let defaults = try decoder.decode(BackgroundActivitySettings.self, from: Data("{}".utf8))
    XCTAssertFalse(defaults.liveActivityEnabled)
    XCTAssertFalse(defaults.notifyWhenResponseFinishes)
    XCTAssertFalse(defaults.notifyWhenApprovalNeeded)
    let legacy = Data("""
      {"liveActivityEnabled":true,"notifyWhenResponseFinishes":true,
       "notifyWhenApprovalNeeded":false,"extendedBackgroundProcessing":true}
      """.utf8)
    let restored = try decoder.decode(BackgroundActivitySettings.self, from: legacy)
    XCTAssertTrue(restored.liveActivityEnabled)
    XCTAssertTrue(restored.notifyWhenResponseFinishes)
    XCTAssertFalse(restored.notifyWhenApprovalNeeded)
    XCTAssertEqual(
      try decoder.decode(BackgroundActivitySettings.self, from: JSONEncoder().encode(restored)),
      restored)
  }

  func testPersistenceStoreLoadsEveryReleasedFixture() throws {
    for name in fixtures.keys.sorted() {
      try XCTContext.runActivity(named: name) { _ in
        let expected = try decodeFixture(named: name)
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }

        let conversationsURL = baseURL.appendingPathComponent("conversations", isDirectory: true)
        try FileManager.default.createDirectory(
          at: conversationsURL, withIntermediateDirectories: true)
        let storedURL = conversationsURL.appendingPathComponent("\(expected.id.uuidString).json")
        try fixtureData(named: name).write(to: storedURL, options: .atomic)

        let loaded = PersistenceStore(localBaseURL: baseURL).loadConversations()
        XCTAssertEqual(loaded, [expected])
        XCTAssertTrue(FileManager.default.fileExists(atPath: storedURL.path))
        XCTAssertFalse(
          FileManager.default.fileExists(atPath: storedURL.appendingPathExtension("corrupt").path))
      }
    }
  }

  func testLegacyEnvelopeAndArrayFilesMigrateWithoutDataLoss() throws {
    // A real store can contain several schema generations, not just one chat.
    let names = fixtures.keys.sorted()
    let expected = try names.map { try decodeFixture(named: $0) }
      .sorted { $0.id.uuidString < $1.id.uuidString }
    let objects = try names.map { try JSONSerialization.jsonObject(with: fixtureData(named: $0)) }
    let legacyDocuments: [(String, Any)] = [
      ("envelope", ["conversations": objects]),
      ("array", objects),
    ]

    for (name, legacyObject) in legacyDocuments {
      try XCTContext.runActivity(named: name) { _ in
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let legacyURL = baseURL.appendingPathComponent("conversations.json")
        let data = try JSONSerialization.data(withJSONObject: legacyObject)
        try data.write(to: legacyURL, options: .atomic)

        let loaded = PersistenceStore(localBaseURL: baseURL).loadConversations()
          .sorted { $0.id.uuidString < $1.id.uuidString }
        XCTAssertEqual(loaded, expected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        let migratedURLs = expected.map {
          baseURL.appendingPathComponent("conversations/\($0.id.uuidString).json")
        }
        let migratedBytes = try migratedURLs.map { try Data(contentsOf: $0) }
        for (conversation, bytes) in zip(expected, migratedBytes) {
          XCTAssertEqual(try makeDecoder().decode(Conversation.self, from: bytes), conversation)
        }
        // Reopening must not duplicate chats or rewrite the migrated documents.
        XCTAssertEqual(
          PersistenceStore(localBaseURL: baseURL).loadConversations()
            .sorted { $0.id.uuidString < $1.id.uuidString }, expected)
        XCTAssertEqual(try migratedURLs.map { try Data(contentsOf: $0) }, migratedBytes)
      }
    }
  }

  func testUnreadableConversationIsQuarantinedWithoutChangingItsBytes() throws {
    let baseURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: baseURL) }
    let conversationsURL = baseURL.appendingPathComponent("conversations", isDirectory: true)
    try FileManager.default.createDirectory(at: conversationsURL, withIntermediateDirectories: true)
    let sourceURL = conversationsURL.appendingPathComponent(
      "BAD00000-0000-4000-8000-000000000000.json")
    let original = Data(#"{"validJSON":true,"but":"not a conversation"}"#.utf8)
    try original.write(to: sourceURL, options: .atomic)

    let validBytes = try fixtureData(named: "conversation-v1.6.2")
    let expected = try decodeFixture(named: "conversation-v1.6.2")
    let validURL = conversationsURL.appendingPathComponent("\(expected.id.uuidString).json")
    try validBytes.write(to: validURL, options: .atomic)

    XCTAssertEqual(PersistenceStore(localBaseURL: baseURL).loadConversations(), [expected])

    let quarantinedURL = sourceURL.appendingPathExtension("corrupt")
    XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
    XCTAssertEqual(try Data(contentsOf: quarantinedURL), original)
    // The first unindexed load upgrades valid legacy JSON to the current schema.
    let migratedBytes = try Data(contentsOf: validURL)
    XCTAssertEqual(try makeDecoder().decode(Conversation.self, from: migratedBytes), expected)
    XCTAssertEqual(PersistenceStore(localBaseURL: baseURL).loadConversations(), [expected])
    XCTAssertEqual(try Data(contentsOf: validURL), migratedBytes)
    XCTAssertEqual(try Data(contentsOf: quarantinedURL), original)
  }

  func testEnabledToolsRemainAStringArrayAndUnknownIDsDoNotBreakLoading() throws {
    var object = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: fixtureData(named: "conversation-v1.6.2"))
        as? [String: Any])
    var tools = try XCTUnwrap(object["enabledTools"] as? [String])
    tools.append("tool-added-by-a-future-version")
    object["enabledTools"] = tools

    let conversation = try makeDecoder().decode(
      Conversation.self,
      from: JSONSerialization.data(withJSONObject: object))
    XCTAssertEqual(conversation.enabledTools, fixtures["conversation-v1.6.2"]?.enabledTools)

    let encodedObject = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: makeEncoder().encode(conversation))
        as? [String: Any])
    XCTAssertNotNil(encodedObject["enabledTools"] as? [String])
  }

  // Bookmarks live in bookmarks.json beside the conversations, never inside a
  // conversation file. A build that predates them has to keep reading, and
  // rewriting, conversations a bookmarks-era build has touched.
  func testBookmarkingAddsNoFieldToTheConversationDocument() throws {
    for name in fixtures.keys.sorted() {
      try XCTContext.runActivity(named: name) { _ in
        let conversation = try decodeFixture(named: name)
        let object = try XCTUnwrap(
          try JSONSerialization.jsonObject(with: makeEncoder().encode(conversation))
            as? [String: Any])

        XCTAssertFalse(
          object.keys.contains { $0.lowercased().contains("bookmark") },
          "A bookmark field leaked into the conversation document: \(object.keys.sorted())")
        for message in try XCTUnwrap(object["messages"] as? [[String: Any]]) {
          XCTAssertFalse(
            message.keys.contains { $0.lowercased().contains("bookmark") },
            "A bookmark field leaked into a message: \(message.keys.sorted())")
        }
      }
    }
  }

  // The other half of that contract: were a later version to put bookmark state
  // into the conversation document after all, this version must ignore it
  // rather than refuse the file or drop the rest of the conversation.
  func testUnknownFutureFieldsInAConversationAreIgnored() throws {
    let expected = try decodeFixture(named: "conversation-v1.6.2")
    var object = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: fixtureData(named: "conversation-v1.6.2"))
        as? [String: Any])
    object["bookmarks"] = [
      ["messageID": UUID().uuidString, "createdAt": "2026-09-01T00:00:00Z", "isPinned": true]
    ]
    var messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
    messages[0]["isBookmarked"] = true
    object["messages"] = messages

    let conversation = try makeDecoder().decode(
      Conversation.self, from: JSONSerialization.data(withJSONObject: object))
    XCTAssertEqual(conversation, expected)
  }

  // bookmarks.json sits at the store root, outside the scanned conversations
  // directory, so loading must neither pick it up nor quarantine it.
  func testBookmarksFileBesideTheConversationsIsLeftAlone() throws {
    let expected = try decodeFixture(named: "conversation-v1.6.2")
    let baseURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: baseURL) }

    let conversationsURL = baseURL.appendingPathComponent("conversations", isDirectory: true)
    try FileManager.default.createDirectory(
      at: conversationsURL, withIntermediateDirectories: true)
    try fixtureData(named: "conversation-v1.6.2").write(
      to: conversationsURL.appendingPathComponent("\(expected.id.uuidString).json"),
      options: .atomic)

    let bookmarksURL = baseURL.appendingPathComponent("bookmarks.json")
    let bookmarks: [String: Any] = [
      "version": 1,
      "bookmarks": [
        [
          "conversationID": expected.id.uuidString,
          "messageID": expected.messages[0].id.uuidString,
          "createdAt": "2026-09-01T00:00:00Z",
          "isPinned": false,
        ]
      ],
    ]
    let bookmarksData = try JSONSerialization.data(withJSONObject: bookmarks)
    try bookmarksData.write(to: bookmarksURL, options: .atomic)

    XCTAssertEqual(PersistenceStore(localBaseURL: baseURL).loadConversations(), [expected])
    XCTAssertEqual(try Data(contentsOf: bookmarksURL), bookmarksData)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: bookmarksURL.appendingPathExtension("corrupt").path))
  }

  private func fixtureData(named name: String) throws -> Data {
    let bundle = Bundle(for: Self.self)
    let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
      ?? bundle.url(forResource: name, withExtension: "json")
    return try Data(contentsOf: XCTUnwrap(url, "Missing compatibility fixture \(name).json"))
  }

  private func decodeFixture(named name: String) throws -> Conversation {
    try makeDecoder().decode(Conversation.self, from: fixtureData(named: name))
  }

  private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "PocketMaiCompatibilityTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  private func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }
}
