import Foundation
import MaiCore
import XCTest

@testable import PocketMai

final class AgentSoulTests: XCTestCase {
  func testDocumentDraftKeepsEmptyEditsAcrossReloadAndFailedSave() throws {
    var saved = "Original instructions"
    var draft = TextDocumentDraft()
    try draft.load { saved }
    draft.text = ""
    try draft.load { saved }
    XCTAssertEqual(draft.text, "")
    XCTAssertTrue(draft.hasChanges)
    XCTAssertThrowsError(try draft.save { _ in throw CocoaError(.fileWriteNoPermission) })
    XCTAssertEqual(draft.text, "")
    XCTAssertTrue(draft.hasChanges, "A failed save must keep the unsaved-change protection")
    XCTAssertTrue(try draft.save { saved = $0 })
    XCTAssertEqual(saved, "")
    XCTAssertFalse(draft.hasChanges)
  }

  func testFailedDocumentLoadCannotOverwriteTheSavedFile() throws {
    var saved = "Existing instructions"
    var draft = TextDocumentDraft()
    XCTAssertThrowsError(try draft.load { throw CocoaError(.fileReadNoPermission) })
    XCTAssertFalse(try draft.save { saved = $0 })
    XCTAssertEqual(saved, "Existing instructions")
    try draft.load { saved }
    XCTAssertTrue(draft.isLoaded)
    XCTAssertEqual(draft.text, saved)
  }

  func testSoulEditsPersistAndChangeTheNextSystemPrompt() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let soul = AgentSoul(url: directory.appendingPathComponent(".pmai/SOUL.md"))
    let settings = AppSettings()
    let conversation = Conversation()
    let original = PromptComposer.systemPrompt(
      settings: settings, conversation: conversation, soul: soul)
    XCTAssertEqual(try soul.load(), "")
    XCTAssertNil(soul.instructions)
    XCTAssertFalse(FileManager.default.fileExists(atPath: soul.url.path))

    let first = "# Personality\nUse a warm, direct voice.\n"
    var draft = TextDocumentDraft()
    try draft.load(using: soul.load)
    draft.text = first
    XCTAssertTrue(try draft.save(using: soul.save))
    XCTAssertEqual(try AgentSoul(url: soul.url).load(), first)
    let prompt = PromptComposer.systemPrompt(
      settings: settings, conversation: conversation, soul: soul)
    XCTAssertTrue(prompt.contains(first.trimmingCharacters(in: .newlines)))
    XCTAssertTrue(prompt.contains(settings.defaultPrompt().text))
    XCTAssertNotEqual(prompt, original)

    let second = "# Personality\nPrefer short answers.\n"
    try soul.save(second)
    let updated = PromptComposer.systemPrompt(
      settings: settings, conversation: conversation, soul: soul)
    XCTAssertTrue(updated.contains("Prefer short answers."))
    XCTAssertFalse(updated.contains("Use a warm, direct voice."))
    try soul.save(" \n ")
    XCTAssertEqual(
      PromptComposer.systemPrompt(settings: settings, conversation: conversation, soul: soul),
      original)
  }

  func testSoulInstructionsPassThroughTheSharedRedactionBoundary() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let soul = AgentSoul(url: directory.appendingPathComponent("SOUL.md"))
    try soul.save("My name is Jane.")
    var settings = AppSettings()
    settings.redaction = .init(enabled: true, rules: "Jane")
    let prompt = PromptComposer.systemPrompt(
      settings: settings, conversation: Conversation(), soul: soul)
    let request = try AppRedaction.request(
      .init(model: "test", messages: [.system(prompt)]), settings: settings)
    XCTAssertFalse(request.messages.contains { $0.text.contains("Jane") })
    XCTAssertEqual(try soul.load(), "My name is Jane.")
  }
}
