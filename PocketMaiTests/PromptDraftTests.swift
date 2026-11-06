import MaiCore
import XCTest

@testable import PocketMai

final class PromptDraftTests: XCTestCase {
  func testNewPromptsSaveToTheCorrectCollection() {
    for kind in [PromptDraft.Kind.system, .user] {
      var settings = AppSettings()
      settings.systemPrompts = []
      settings.userPrompts = []
      let oldDefault = settings.defaultSystemPromptID
      let original = kind == .system ? PromptDraft() : PromptDraft(userPrompt: nil)
      var draft = original
      draft.name = " Review "
      draft.text = "Review this code."
      draft.isDefault = true
      XCTAssertNil(draft.save(to: &settings, original: original))
      if kind == .system {
        XCTAssertEqual(settings.systemPrompts.map(\.name), ["Review"])
        XCTAssertEqual(settings.systemPrompts.first?.text, draft.text)
        XCTAssertEqual(settings.defaultSystemPromptID, settings.systemPrompts.first?.id)
        XCTAssertTrue(settings.userPrompts.isEmpty)
      } else {
        XCTAssertEqual(settings.userPrompts.map(\.name), ["Review"])
        XCTAssertEqual(settings.userPrompts.first?.text, draft.text)
        XCTAssertEqual(settings.defaultSystemPromptID, oldDefault)
        XCTAssertTrue(settings.systemPrompts.isEmpty)
      }
    }
  }

  func testInvalidNamesAndCrossKindCollisionsLeaveSettingsUntouched() {
    var settings = AppSettings()
    settings.systemPrompts = [SystemPrompt(name: "System", text: "Instructions")]
    settings.userPrompts = [UserPrompt(name: "User", text: "Message")]
    let before = settings
    for original in [PromptDraft(), PromptDraft(userPrompt: nil)] {
      for name in ["", "two words", "/name", " system ", "uSeR"] {
        var draft = original
        draft.name = name
        XCTAssertNotNil(draft.save(to: &settings, original: original), name)
        XCTAssertEqual(settings, before)
      }
    }
  }

  func testExistingPromptsKeepTheirIdentityAndLegacyNames() {
    var settings = AppSettings()
    let system = SystemPrompt(name: "Legacy system", text: "Old")
    let user = UserPrompt(name: "Legacy user", text: "Old")
    settings.systemPrompts = [system]
    settings.userPrompts = [user]
    settings.defaultSystemPromptID = system.id
    for original in [PromptDraft(systemPrompt: system), PromptDraft(userPrompt: user)] {
      var draft = original
      draft.text = "Edited"
      XCTAssertNil(draft.save(to: &settings, original: original))
    }
    XCTAssertEqual(
      settings.systemPrompts, [SystemPrompt(id: system.id, name: system.name, text: "Edited")])
    XCTAssertEqual(settings.userPrompts, [UserPrompt(id: user.id, name: user.name, text: "Edited")])
    XCTAssertEqual(settings.defaultSystemPromptID, system.id)
  }

  func testStaleEditorsCannotRecreateDeletedPrompts() {
    var settings = AppSettings()
    let before = settings
    let drafts = [
      PromptDraft(systemPrompt: SystemPrompt(name: "Deleted", text: "Old"), isDefault: true),
      PromptDraft(userPrompt: UserPrompt(name: "Deleted", text: "Old")),
    ]
    for original in drafts {
      var draft = original
      draft.text = "Edited"
      XCTAssertEqual(draft.save(to: &settings, original: original), "This prompt no longer exists.")
      XCTAssertEqual(settings, before)
    }
  }
}
