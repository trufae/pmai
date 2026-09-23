import UIKit
import UserNotifications

private let conversationIDUserInfoKey = "conversationID"

/// Local notifications for turns that finish, fail, or stall waiting for the
/// user while PocketMai is in the background or the device is locked. Nothing
/// is posted while the app is on screen; the chat itself shows the outcome.
@MainActor
final class ResponseNotificationService: NSObject, UNUserNotificationCenterDelegate {
  static let shared = ResponseNotificationService()

  enum Kind: String, CaseIterable {
    case completed
    case failed
    case approval
  }

  /// Set by the store so a tapped notification opens the right conversation.
  var openConversationHandler: ((UUID) -> Void)?

  /// Must run before the app finishes launching so a cold start from a tapped
  /// notification still reaches `didReceive`.
  func installDelegate() {
    UNUserNotificationCenter.current().delegate = self
  }

  var isAppInForeground: Bool {
    UIApplication.shared.applicationState == .active
  }

  func authorizationStatus() async -> UNAuthorizationStatus {
    await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
  }

  @discardableResult
  func requestAuthorizationIfNeeded() async -> Bool {
    let center = UNUserNotificationCenter.current()
    switch await center.notificationSettings().authorizationStatus {
    case .notDetermined:
      return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    case .authorized, .provisional, .ephemeral:
      return true
    case .denied:
      return false
    @unknown default:
      return false
    }
  }

  func post(_ kind: Kind, conversationID: UUID, title: String, body: String) {
    guard !isAppInForeground else { return }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    content.threadIdentifier = conversationID.uuidString
    content.userInfo = [conversationIDUserInfoKey: conversationID.uuidString]
    let request = UNNotificationRequest(
      identifier: Self.identifier(kind, conversationID),
      content: content,
      trigger: nil)
    let center = UNUserNotificationCenter.current()
    // A newer outcome for the same chat supersedes whatever is still showing.
    center.removeDeliveredNotifications(withIdentifiers: Self.identifiers(for: conversationID))
    Task {
      try? await center.add(request)
    }
  }

  func clearNotifications(for conversationID: UUID) {
    clear(Self.identifiers(for: conversationID))
  }

  func clearNotification(_ kind: Kind, for conversationID: UUID) {
    clear([Self.identifier(kind, conversationID)])
  }

  private func clear(_ identifiers: [String]) {
    let center = UNUserNotificationCenter.current()
    center.removeDeliveredNotifications(withIdentifiers: identifiers)
    center.removePendingNotificationRequests(withIdentifiers: identifiers)
  }

  private static func identifier(_ kind: Kind, _ conversationID: UUID) -> String {
    "pocketmai.\(kind.rawValue).\(conversationID.uuidString)"
  }

  private static func identifiers(for conversationID: UUID) -> [String] {
    Kind.allCases.map { identifier($0, conversationID) }
  }

  // MARK: - UNUserNotificationCenterDelegate

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler:
      @escaping @Sendable (UNNotificationPresentationOptions) -> Void
  ) {
    // Delivery raced with the app coming back to the foreground; the chat is visible.
    Task { @MainActor in
      completionHandler([])
    }
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping @Sendable () -> Void
  ) {
    let raw = response.notification.request.content.userInfo[conversationIDUserInfoKey] as? String
    let conversationID = raw.flatMap(UUID.init(uuidString:))
    // UIKit's completion can perform state restoration and must also run on the main thread.
    Task { @MainActor in
      defer { completionHandler() }
      guard let conversationID else { return }
      openConversationHandler?(conversationID)
    }
  }
}
