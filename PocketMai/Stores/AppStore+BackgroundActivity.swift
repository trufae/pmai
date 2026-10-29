import SwiftUI
import UIKit

/// Glue between the assistant turn lifecycle and the pieces that report on it
/// while the app is not on screen. Status reporting does not extend runtime.
extension AppStore {
  // MARK: - Turn lifecycle

  func activityTurnStarted(conversationID: UUID) {
    responseOutcomes[conversationID] = nil
    guard settings.background.liveActivityEnabled else { return }
    assistantActivity.begin(
      id: conversationID,
      title: activityTitle(for: conversationID),
      phase: .thinking)
  }

  func activityPhaseChanged(
    conversationID: UUID,
    phase: AssistantActivityTask.Phase,
    detail: String = ""
  ) {
    guard settings.background.liveActivityEnabled else { return }
    assistantActivity.setPhase(id: conversationID, phase: phase, detail: detail)
  }

  /// Called per streamed chunk; the controller samples the text, so the only
  /// work here is mapping the message back to its conversation.
  func activityStreamingText(_ text: String, messageID: UUID) {
    for conversationID in respondingConversationIDs {
      guard let index = conversationIndex(for: conversationID),
        conversations[index].messages.last?.id == messageID
      else {
        continue
      }
      if settings.background.liveActivityEnabled {
        assistantActivity.setStreamingText(id: conversationID, text: text)
      }
      return
    }
  }

  func activityTurnFinished(conversationID: UUID) {
    let outcome = responseOutcomes.removeValue(forKey: conversationID) ?? .completed
    let conversation = conversation(withID: conversationID)
    let summary = Self.finishedSummary(for: conversation)
    if settings.background.liveActivityEnabled {
      assistantActivity.finish(id: conversationID, phase: outcome, detail: summary)
    }
    if outcome != .stopped, settings.background.notifyWhenResponseFinishes {
      let fallback = outcome == .failed ? "The reply failed." : "The reply is ready."
      ResponseNotificationService.shared.post(
        outcome == .failed ? .failed : .completed,
        conversationID: conversationID,
        title: conversation?.displayTitle ?? "PocketMai",
        body: summary.isEmpty ? fallback : summary)
    }
  }

  /// A turn that was dropped without finishing (edited, regenerated, deleted).
  func activityTurnAbandoned(conversationID: UUID) {
    cancelVoiceover(in: conversationID)
    responseOutcomes[conversationID] = nil
    assistantActivity.remove(id: conversationID)
    ResponseNotificationService.shared.clearNotification(.approval, for: conversationID)
  }

  func activityApprovalRequested(conversationID: UUID, toolName: String) {
    activityPhaseChanged(conversationID: conversationID, phase: .awaitingApproval, detail: toolName)
    guard settings.background.notifyWhenApprovalNeeded else { return }
    ResponseNotificationService.shared.post(
      .approval,
      conversationID: conversationID,
      title: activityTitle(for: conversationID),
      body: "Approve running \(toolName) to continue.")
  }

  func activityApprovalResolved(
    conversationID: UUID,
    toolName: String,
    decision: ToolCallApprovalDecision
  ) {
    ResponseNotificationService.shared.clearNotification(.approval, for: conversationID)
    if case .approved = decision {
      activityPhaseChanged(conversationID: conversationID, phase: .runningTool, detail: toolName)
    } else {
      activityPhaseChanged(conversationID: conversationID, phase: .thinking)
    }
  }

  // MARK: - App state

  func handleScenePhaseChange(_ phase: ScenePhase) {
    switch phase {
    case .active:
      isInBackground = false
      for task in responseBackgroundTasks.values {
        task.renewFiniteTask()
      }
      assistantActivity.appDidBecomeActive()
      if let selectedConversationID {
        ResponseNotificationService.shared.clearNotifications(for: selectedConversationID)
      }
      drainThenQueue()
    case .background:
      isInBackground = true
      for task in responseBackgroundTasks.values {
        task.renewFiniteTask()
      }
      checkpointBackgroundResponses()
    case .inactive:
      break
    @unknown default:
      break
    }
  }

  func applyBackgroundActivitySettings() {
    assistantActivity.isEnabled = settings.background.liveActivityEnabled
  }

  // MARK: - Helpers

  private func activityTitle(for conversationID: UUID) -> String {
    conversation(withID: conversationID)?.displayTitle
      ?? conversationSummaries.first(where: { $0.id == conversationID })?.displayTitle
      ?? "PocketMai"
  }

  /// Plain-text opening of the final assistant message: no reasoning, tool
  /// envelopes, or Markdown syntax.
  private static func finishedSummary(for conversation: Conversation?) -> String {
    guard
      let message = conversation?.messages.last(where: {
        $0.role == .assistant || $0.role == .error
      })
    else {
      return ""
    }
    let visible = MessageContentFilter.render(message.text).visibleText
    let plain = MessageContentFilter.markdownPlainText(from: visible)
    return AssistantActivityTask.leadingSummary(plain, limit: 200)
  }
}
