import UserNotifications
import XCTest

@testable import PocketMai

@MainActor
final class ResponseNotificationServiceTests: XCTestCase {
  func testBackgroundResponseRoutesBeforeCompletingOnMainThread() async {
    let service = ResponseNotificationService()
    let conversationID = UUID()
    let opened = expectation(description: "Conversation opened")
    let completed = expectation(description: "Notification completed")
    opened.assertForOverFulfill = true
    completed.assertForOverFulfill = true
    service.openConversationHandler = { id in
      XCTAssertTrue(Thread.isMainThread)
      XCTAssertEqual(id, conversationID)
      opened.fulfill()
    }

    DispatchQueue.global().async {
      do {
        let response = try Self.response(conversationID: conversationID.uuidString)
        let delegate: any UNUserNotificationCenterDelegate = service
        delegate.userNotificationCenter?(.current(), didReceive: response) {
          XCTAssertTrue(Thread.isMainThread)
          completed.fulfill()
        }
      } catch {
        XCTFail("Could not create notification response: \(error)")
      }
    }
    await fulfillment(of: [opened, completed], timeout: 2, enforceOrder: true)
  }

  func testInvalidPayloadAndMissingHandlerStillCompleteOnMainThread() async {
    for raw in [nil, "not-a-uuid", UUID().uuidString] {
      let service = ResponseNotificationService()
      if raw == nil || raw == "not-a-uuid" {
        service.openConversationHandler = { _ in XCTFail("Invalid payload opened a conversation") }
      }
      let completed = expectation(description: "Notification completed")
      completed.assertForOverFulfill = true

      DispatchQueue.global().async {
        do {
          let response = try Self.response(conversationID: raw)
          let delegate: any UNUserNotificationCenterDelegate = service
          delegate.userNotificationCenter?(.current(), didReceive: response) {
            XCTAssertTrue(Thread.isMainThread)
            completed.fulfill()
          }
        } catch {
          XCTFail("Could not create notification response: \(error)")
        }
      }
      await fulfillment(of: [completed], timeout: 2)
    }
  }

  func testForegroundDeliveryIsSuppressedAndCompletesOnMainThread() async {
    let service = ResponseNotificationService()
    let completed = expectation(description: "Presentation completed")
    completed.assertForOverFulfill = true

    DispatchQueue.global().async {
      do {
        let response = try Self.response(conversationID: UUID().uuidString)
        let delegate: any UNUserNotificationCenterDelegate = service
        delegate.userNotificationCenter?(.current(), willPresent: response.notification) {
          options in
          XCTAssertTrue(Thread.isMainThread)
          XCTAssertTrue(options.isEmpty)
          completed.fulfill()
        }
      } catch {
        XCTFail("Could not create notification response: \(error)")
      }
    }
    await fulfillment(of: [completed], timeout: 2)
  }

  nonisolated private static func response(conversationID: String?) throws -> UNNotificationResponse
  {
    let content = UNMutableNotificationContent()
    if let conversationID {
      content.userInfo = ["conversationID": conversationID]
    }
    let request = UNNotificationRequest(identifier: "test", content: content, trigger: nil)
    let notification = try XCTUnwrap(
      UNNotification(coder: NotificationCoder(["request": request, "date": Date()])))
    return try XCTUnwrap(
      UNNotificationResponse(
        coder: NotificationCoder([
          "notification": notification,
          "actionIdentifier": UNNotificationDefaultActionIdentifier,
        ])))
  }
}

// UserNotifications exposes these objects through NSCoding, with no public memberwise initializer.
private final class NotificationCoder: NSCoder {
  private let values: [String: Any]

  init(_ values: [String: Any]) {
    self.values = values
    super.init()
  }

  override var allowsKeyedCoding: Bool { true }
  override func containsValue(forKey key: String) -> Bool { values[key] != nil }
  override func decodeObject(forKey key: String) -> Any? { values[key] }
  override func decodeInt64(forKey key: String) -> Int64 { 0 }
}
