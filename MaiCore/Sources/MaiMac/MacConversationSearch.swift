import Foundation
import MaiACP
import Observation
import SwiftUI

@MainActor @Observable
final class MacConversationSearch {
  var isPresented = false { didSet { refresh() } }
  var query = "" { didSet { selectedID = nil; refresh() } }
  private(set) var matches: [UUID] = []
  private(set) var selectedID: UUID?
  private(set) var searching = false
  private(set) var focusRequest = 0
  private(set) var navigationRequest = 0
  @ObservationIgnored private var messages: [ACPConversationMessage] = []
  @ObservationIgnored private var work: Task<Void, Never>?

  var activeQuery: String { isPresented ? query.trimmingCharacters(in: .whitespacesAndNewlines) : "" }
  var position: Int { selectedID.flatMap { matches.firstIndex(of: $0) }.map { $0 + 1 } ?? 0 }

  func show() { isPresented = true; focusRequest += 1 }
  func close() { isPresented = false }

  func update(_ messages: [ACPConversationMessage]) {
    self.messages = messages
    refresh()
  }

  func advance(backwards: Bool = false) {
    guard !matches.isEmpty else { return }
    let index = selectedID.flatMap { matches.firstIndex(of: $0) } ?? (backwards ? 0 : -1)
    selectedID = matches[(index + (backwards ? -1 : 1) + matches.count) % matches.count]
    navigationRequest += 1
  }

  private func refresh() {
    work?.cancel()
    let query = activeQuery
    guard !query.isEmpty else {
      matches = []; selectedID = nil; searching = false
      return
    }
    searching = true
    let snapshot = messages
    work = Task {
      guard let result = try? await MacConversationSearchWorker.shared.find(query, in: snapshot),
        !Task.isCancelled else { return }
      matches = result
      searching = false
      if selectedID == nil || !result.contains(selectedID!) {
        selectedID = result.first
        navigationRequest += 1
      }
    }
  }
}

private actor MacConversationSearchWorker {
  static let shared = MacConversationSearchWorker()

  func find(_ query: String, in messages: [ACPConversationMessage]) throws -> [UUID] {
    try messages.compactMap { message in
      try Task.checkCancellation()
      var text = message.text + "\n" + (message.toolName ?? "")
      if let input = message.toolInput, let data = try? JSONEncoder().encode(input) {
        text += "\n" + String(decoding: data, as: UTF8.self)
      }
      return text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) == nil ? nil : message.id
    }
  }
}

enum MacSearchHighlight {
  static func text(_ text: String, query: String) -> AttributedString {
    apply(to: AttributedString(text), query: query)
  }

  static func apply(to text: AttributedString, query: String) -> AttributedString {
    guard !query.isEmpty else { return text }
    var result = text
    let plain = String(text.characters)
    var start = plain.startIndex
    while start < plain.endIndex,
      let range = plain.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: start..<plain.endIndex) {
      if let lower = AttributedString.Index(range.lowerBound, within: result),
        let upper = AttributedString.Index(range.upperBound, within: result) {
        result[lower..<upper].backgroundColor = .yellow.opacity(0.8)
        result[lower..<upper].foregroundColor = .black
      }
      start = range.upperBound
    }
    return result
  }
}

struct MacFindCommands: Commands {
  @FocusedValue(\.macWorkspace) private var workspace
  @FocusedBinding(\.macSidebarVisibility) private var sidebarVisibility

  var body: some Commands {
    CommandGroup(after: .textEditing) {
      Divider()
      Button("Find in Conversation…") { workspace?.selected?.find.show() }
        .keyboardShortcut("f", modifiers: .command).disabled(workspace?.selected == nil)
      Button("Find Next") { workspace?.selected?.find.advance() }
        .keyboardShortcut("g", modifiers: .command)
        .disabled(workspace?.selected?.find.isPresented != true || workspace?.selected?.find.matches.isEmpty != false)
      Button("Find Previous") { workspace?.selected?.find.advance(backwards: true) }
        .keyboardShortcut("g", modifiers: [.command, .shift])
        .disabled(workspace?.selected?.find.isPresented != true || workspace?.selected?.find.matches.isEmpty != false)
      Button("Search Conversations…") {
        sidebarVisibility = .all
        workspace?.sidebarSection = .conversations
        workspace?.focusConversationSearch = true
      }
      .keyboardShortcut("f", modifiers: [.command, .shift])
      .disabled(workspace == nil || workspace?.cwd.isEmpty == true)
    }
  }
}
