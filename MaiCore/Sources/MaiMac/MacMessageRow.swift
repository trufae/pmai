import AppKit
import MaiACP
import MaiUI
import SwiftUI

struct MacMessageRun: Identifiable, Equatable {
  var id: UUID { messages[0].id }
  var messages: [ACPConversationMessage]
  let isActivity: Bool

  static func grouped(_ messages: [ACPConversationMessage]) -> [Self] {
    var runs: [Self] = []
    for message in messages {
      let activity = message.role == "tool" || message.role == "thought"
      if activity, runs.last?.isActivity == true {
        runs[runs.count - 1].messages.append(message)
      } else {
        runs.append(Self(messages: [message], isActivity: activity))
      }
    }
    return runs
  }
}

struct MacActivityRow: View, @MainActor Equatable {
  let run: MacMessageRun
  let conversation: MacConversation
  var searchQuery = ""
  var selectedSearchID: UUID?
  @State private var expanded = false
  private var typography = MacChatTypography()
  private var appearance = MacAppearance()

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.run == rhs.run && lhs.conversation === rhs.conversation
      && lhs.searchQuery == rhs.searchQuery && lhs.selectedSearchID == rhs.selectedSearchID
  }

  private var revealsSearch: Bool { run.messages.contains { $0.id == selectedSearchID } }

  var body: some View {
    DisclosureGroup(isExpanded: $expanded) {
      // Do not instantiate or parse hidden tool output.
      if expanded {
        ScrollViewReader { proxy in
          ActivityScrollView {
            ForEach(run.messages) { message in
              MacMessageRow(message: message, conversation: conversation,
                searchQuery: searchQuery, isSearchSelected: message.id == selectedSearchID).equatable()
            }
          }
          .onChange(of: selectedSearchID, initial: true) { _, id in
            if let id { proxy.scrollTo(id, anchor: .top) }
          }
        }
        .activityScrollFrame(accentColor: appearance.accentColor)
        .padding(.top, 8)
      }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "wrench.and.screwdriver")
        Text("Activity · \(run.messages.count) updates")
        let failed = run.messages.filter { $0.status == "failed" }.count
        if failed > 0 { Text("· \(failed) failed").foregroundStyle(.red) }
        if conversation.busy, run.messages.contains(where: { $0.status == "in_progress" || $0.status == "pending" }) {
          Text("· Running")
        }
      }
      .font(typography.font(.callout)).foregroundStyle(.secondary).lineLimit(1)
    }
    .disclosureGroupStyle(ActivityDisclosureStyle())
    .onChange(of: selectedSearchID, initial: true) { _, _ in
      if revealsSearch { expanded = true }
    }
  }
}

struct MacMessageRow: View, @MainActor Equatable {
  let message: ACPConversationMessage
  let conversation: MacConversation
  var searchQuery = ""
  var isSearchSelected = false
  var isStreaming = false
  @State private var expanded = false
  private var typography = MacChatTypography()
  private var appearance = MacAppearance()

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.message == rhs.message && lhs.conversation === rhs.conversation
      && lhs.searchQuery == rhs.searchQuery && lhs.isSearchSelected == rhs.isSearchSelected
      && lhs.isStreaming == rhs.isStreaming
  }

  var body: some View {
    MessageBubbleLayout(fitsContent: message.role == "user") {
      VStack(alignment: .leading, spacing: 9) {
        if message.role == "tool" || message.role == "thought" {
          DisclosureGroup(isExpanded: $expanded) {
            if expanded { MacMessageDetails(message: message, searchQuery: searchQuery) }
          } label: {
            HStack {
              Text(MacSearchHighlight.text(
                message.toolName ?? (message.role == "thought" ? "Reasoning" : "Tool details"), query: searchQuery))
                .lineLimit(1)
              Spacer()
              if let status = message.status {
                Text(status.capitalized).font(typography.font(.caption1))
                  .foregroundStyle(status == "failed" ? Color.red : .secondary)
              }
            }
          }
          .disclosureGroupStyle(ActivityDisclosureStyle())
          .onChange(of: isSearchSelected, initial: true) { _, selected in
            if selected { expanded = true }
          }
        } else {
          Label(message.role == "user" ? "You" : message.role == "assistant" ? "pmai" : message.role.capitalized,
            systemImage: message.role == "user" ? "person.crop.circle" : "sparkle")
            .font(typography.font(.callout).weight(.semibold)).foregroundStyle(.secondary)
          MacMarkdown(text: message.text, searchQuery: searchQuery, role: message.role).equatable()
            .environment(\.isStreamingResponse,
              message.role == "assistant" && isStreaming && searchQuery.isEmpty)
        }
      }
    }
    .font(typography.font())
    .padding(message.role == "user" ? 16 : 0)
    .background {
      if message.role == "user" {
        RoundedRectangle(cornerRadius: 14).fill(appearance.accentColor.opacity(0.12))
      }
    }
    .padding(.leading, message.role == "user" ? 36 : 0)
    .frame(maxWidth: .infinity, alignment: message.role == "user" ? .trailing : .leading)
    .contextMenu {
      Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text, forType: .string) }
      if message.role == "user", conversation.canRewind, message.remoteID != nil {
        Button("Edit from Here…") { conversation.rewind(message) }.disabled(conversation.busy)
      }
    }
    .id("message-\(message.id)")
  }
}

private struct MacMessageDetails: View {
  let message: ACPConversationMessage
  let searchQuery: String
  @State private var inputText: String?
  private var typography = MacChatTypography()

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let inputText {
        Text(MacSearchHighlight.text(inputText, query: searchQuery))
          .font(typography.font(.caption1, design: .monospaced)).textSelection(.enabled)
      }
      MacMarkdown(text: message.text, searchQuery: searchQuery, role: message.role).equatable()
    }
    .task(id: message.toolInput) {
      let input = message.toolInput
      let text = await Task.detached(priority: .userInitiated) {
        input.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
      }.value
      if !Task.isCancelled { inputText = text }
    }
  }
}
