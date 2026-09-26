import Foundation
import XCTest

@testable import PocketMai

@MainActor
final class SpeechTranscriptionPrivacyTests: XCTestCase {
  func testNewAndLegacySettingsNeverOptInToServerTranscription() throws {
    XCTAssertFalse(AppSettings.defaults.appleServerTranscriptionAllowed)
    for json in [
      "{}", "{\"allowAppleServerTranscription\":null}",
      "{\"allowAppleServerTranscription\":\"true\"}",
    ]
    {
      let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
      XCTAssertFalse(settings.allowAppleServerTranscription)
      XCTAssertFalse(settings.appleServerTranscriptionAllowed)
    }
  }

  func testAirplaneModeOverridesButPreservesSavedOptIn() throws {
    var settings = AppSettings.defaults
    settings.allowAppleServerTranscription = true
    settings.airplaneModeEnabled = true
    var restored = try JSONDecoder().decode(
      AppSettings.self, from: JSONEncoder().encode(settings))
    XCTAssertTrue(restored.allowAppleServerTranscription)
    XCTAssertFalse(restored.appleServerTranscriptionAllowed)
    restored.airplaneModeEnabled = false
    XCTAssertTrue(restored.appleServerTranscriptionAllowed)
    restored.allowAppleServerTranscription = false
    XCTAssertFalse(restored.appleServerTranscriptionAllowed)
  }

  func testDisabledPolicyRejectsServerRequests() {
    let policy = SpeechTranscriptionPolicy()
    XCTAssertThrowsError(try policy.registerServerRequest {}) { error in
      XCTAssertEqual(
        error as? AudioTranscriptionService.TranscriptionError, .serverRecognitionDisabled)
    }
  }

  func testRevokingPermissionCancelsEveryPendingRequestOnlyOnce() throws {
    let policy = SpeechTranscriptionPolicy()
    policy.allowsServerRecognition = true
    var cancelled: [Int] = []
    _ = try policy.registerServerRequest { cancelled.append(1) }
    _ = try policy.registerServerRequest { cancelled.append(2) }
    let completed = try policy.registerServerRequest { cancelled.append(3) }
    policy.removeServerRequest(completed)

    policy.allowsServerRecognition = false
    XCTAssertEqual(cancelled.sorted(), [1, 2])
    policy.allowsServerRecognition = false
    policy.allowsServerRecognition = true
    XCTAssertEqual(cancelled.sorted(), [1, 2])
    _ = try policy.registerServerRequest { cancelled.append(4) }
    policy.allowsServerRecognition = false
    XCTAssertEqual(cancelled.sorted(), [1, 2, 4])
  }

  func testAppSettingsImmediatelyRevokeActiveServerRequests() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = AppStore(persistence: PersistenceStore(localBaseURL: directory))
    let deadline = Date().addingTimeInterval(5)
    while store.draftStorageRevision == 0, Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertGreaterThan(store.draftStorageRevision, 0)
    let policy = store.speechTranscriptionPolicy
    XCTAssertFalse(policy.allowsServerRecognition)

    store.settings.allowAppleServerTranscription = true
    var cancelled = false
    _ = try policy.registerServerRequest { cancelled = true }
    store.settings.airplaneModeEnabled = true
    XCTAssertTrue(cancelled)
    XCTAssertFalse(policy.allowsServerRecognition)
    XCTAssertTrue(store.settings.allowAppleServerTranscription)

    store.settings.airplaneModeEnabled = false
    cancelled = false
    _ = try policy.registerServerRequest { cancelled = true }
    store.settings.allowAppleServerTranscription = false
    XCTAssertTrue(cancelled)
    XCTAssertFalse(policy.allowsServerRecognition)
  }

  func testCancellationBeforeContinuationInstallationIsNotLost() async {
    let box = TranscriptionContinuationBox()
    box.finish(.failure(CancellationError()))
    do {
      _ = try await withCheckedThrowingContinuation { continuation in
        XCTAssertFalse(box.install(continuation))
      }
      XCTFail("Cancelled recognition must not succeed")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
  }

  func testPrivacyChangeResumesPendingContinuationAndIgnoresLateResult() async throws {
    let policy = SpeechTranscriptionPolicy()
    policy.allowsServerRecognition = true
    let box = TranscriptionContinuationBox()
    _ = try policy.registerServerRequest {
      box.finish(.failure(AudioTranscriptionService.TranscriptionError.serverRecognitionDisabled))
    }
    do {
      _ = try await withCheckedThrowingContinuation { continuation in
        XCTAssertTrue(box.install(continuation))
        policy.allowsServerRecognition = false
        box.finish(.success("late server result"))
      }
      XCTFail("A revoked request must not return a transcript")
    } catch {
      XCTAssertEqual(
        error as? AudioTranscriptionService.TranscriptionError, .serverRecognitionDisabled)
    }
  }

  func testFinalResultSurvivesDuplicateCallbacks() async throws {
    let box = TranscriptionContinuationBox()
    let text = try await withCheckedThrowingContinuation { continuation in
      XCTAssertTrue(box.install(continuation))
      box.finish(.success("local transcript"))
      box.finish(.failure(CancellationError()))
      box.finish(.success("duplicate"))
    }
    XCTAssertEqual(text, "local transcript")
  }
}
