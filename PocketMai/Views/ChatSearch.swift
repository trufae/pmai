import SwiftUI

struct MessageSearchMatch: Hashable, Sendable {
  let messageID: UUID
  let visiblePartIndex: Int
  let range: NSRange

  func attributedText(in text: String) -> AttributedString {
    var attributed = AttributedString(text)
    guard let range = Range(range, in: text),
      let lowerBound = AttributedString.Index(range.lowerBound, within: attributed),
      let upperBound = AttributedString.Index(range.upperBound, within: attributed)
    else {
      return attributed
    }
    attributed[lowerBound..<upperBound].backgroundColor = Color.yellow.opacity(0.78)
    attributed[lowerBound..<upperBound].foregroundColor = Color.black
    return attributed
  }
}

struct ChatSearchState {
  var isActive = false
  var query = ""
  private(set) var matches: [MessageSearchMatch] = []
  private(set) var selectedIndex = 0
  private var corpus: [Part] = []

  var currentMatch: MessageSearchMatch? {
    guard isActive, matches.indices.contains(selectedIndex) else { return nil }
    return matches[selectedIndex]
  }

  mutating func begin(messages: [ChatMessage]) {
    self = Self()
    corpus = Self.makeCorpus(from: messages)
    isActive = true
  }

  mutating func cancel() {
    self = Self()
  }

  mutating func rebuild(messages: [ChatMessage]) {
    corpus = Self.makeCorpus(from: messages)
    refresh()
  }

  mutating func refresh() {
    let previous = currentMatch
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    matches = needle.isEmpty ? [] : corpus.flatMap { $0.matches(for: needle) }
    selectedIndex =
      previous.flatMap { previous in
        matches.firstIndex {
          $0.messageID == previous.messageID
            && $0.visiblePartIndex == previous.visiblePartIndex
            && $0.range.location == previous.range.location
        }
      } ?? 0
  }

  mutating func move(by offset: Int) {
    guard !matches.isEmpty else { return }
    selectedIndex = (selectedIndex + offset + matches.count) % matches.count
  }

  private static func makeCorpus(from messages: [ChatMessage]) -> [Part] {
    messages.flatMap { message in
      let visibleText: [String] = MessageContentFilter.render(message.presentationText).parts
        .compactMap {
          guard case .visible(let text) = $0.kind else { return nil }
          return MessageContentFilter.markdownPlainText(from: text)
        }
      return visibleText.enumerated().compactMap { index, text in
        text.isEmpty ? nil : Part(messageID: message.id, visiblePartIndex: index, text: text)
      }
    }
  }

  private struct Part {
    let messageID: UUID
    let visiblePartIndex: Int
    let text: String

    func matches(for query: String) -> [MessageSearchMatch] {
      var start = text.startIndex
      var matches: [MessageSearchMatch] = []
      while start < text.endIndex,
        let range = text.range(
          of: query,
          options: [.caseInsensitive, .diacriticInsensitive],
          range: start..<text.endIndex)
      {
        matches.append(
          MessageSearchMatch(
            messageID: messageID,
            visiblePartIndex: visiblePartIndex,
            range: NSRange(range, in: text)))
        start = range.upperBound
      }
      return matches
    }
  }
}

struct ChatSearchBar: View {
  @Binding var search: ChatSearchState
  var onClose: () -> Void = {}
  @FocusState private var isFocused: Bool

  var body: some View {
    HStack(spacing: 6) {
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
        TextField("Search in chat", text: $search.query)
          .textFieldStyle(.plain)
          .disableAutocorrection(true)
          .textInputAutocapitalization(.never)
          .submitLabel(.search)
          .focused($isFocused)
          .onSubmit { search.move(by: 1) }
        if !search.query.isEmpty {
          Button {
            search.query = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Clear search")
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 10)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      .layoutPriority(1)

      Text(resultLabel)
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(minWidth: 32)

      searchButton("chevron.up", label: "Previous match", disabled: search.matches.count < 2) {
        search.move(by: -1)
      }
      searchButton("chevron.down", label: "Next match", disabled: search.matches.count < 2) {
        search.move(by: 1)
      }
      searchButton("xmark", label: "Close search") {
        withAnimation(.snappy) { search.cancel() }
        onClose()
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(minHeight: 58)
    .transition(.move(edge: .bottom).combined(with: .opacity))
    .task {
      await Task.yield()
      isFocused = true
    }
  }

  private var resultLabel: String {
    guard !search.query.isEmpty else { return "" }
    return search.matches.isEmpty ? "0/0" : "\(search.selectedIndex + 1)/\(search.matches.count)"
  }

  private func searchButton(
    _ systemImage: String,
    label: String,
    disabled: Bool = false,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemImage).frame(width: 18, height: 18)
    }
    .adaptiveGlassButtonStyle()
    .controlSize(.small)
    .disabled(disabled)
    .accessibilityLabel(label)
  }
}
