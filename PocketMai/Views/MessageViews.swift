import MaiCore
import Photos
import ImageIO
import SwiftUI
import UIKit

private struct FullChatScreenshotRenderingKey: EnvironmentKey {
  static let defaultValue = false
}

private struct MarkdownRenderImagesKey: EnvironmentKey {
  static let defaultValue = true
}

extension EnvironmentValues {
  var isFullChatScreenshotRendering: Bool {
    get { self[FullChatScreenshotRenderingKey.self] }
    set { self[FullChatScreenshotRenderingKey.self] = newValue }
  }

  var markdownRenderImages: Bool {
    get { self[MarkdownRenderImagesKey.self] }
    set { self[MarkdownRenderImagesKey.self] = newValue }
  }
}

private struct ImageSaveNotice: Identifiable, Equatable {
  enum Kind: Equatable {
    case success
    case failure
  }

  let id = UUID()
  let kind: Kind
  let message: String

  static func success() -> ImageSaveNotice {
    ImageSaveNotice(kind: .success, message: "Saved to Photos")
  }

  static func failure(_ message: String) -> ImageSaveNotice {
    ImageSaveNotice(kind: .failure, message: message)
  }

  var systemImage: String {
    switch kind {
    case .success: "checkmark.circle.fill"
    case .failure: "exclamationmark.triangle.fill"
    }
  }

  var backgroundColor: Color {
    switch kind {
    case .success: .green
    case .failure: .red
    }
  }
}

/// Identity for the reply sheet: presenting it carries the quoted text that
/// pre-fills the editor, so the draft is rebuilt from the message each time.
private struct MessageReplyDraft: Identifiable {
  let id = UUID()
  let text: String
}

private struct ImageSaveNoticeModifier: ViewModifier {
  @Binding var notice: ImageSaveNotice?

  func body(content: Content) -> some View {
    content
      .overlay(alignment: .top) {
        if let notice {
          Label(notice.message, systemImage: notice.systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 340)
            .background(notice.backgroundColor, in: Capsule())
            .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
            .padding(.top, 12)
            .padding(.horizontal, 16)
            .transition(.move(edge: .top).combined(with: .opacity))
            .zIndex(1)
        }
      }
      .animation(.snappy, value: notice)
      .onChange(of: notice) { _, newValue in
        guard let newValue else { return }
        Task { @MainActor in
          try? await Task.sleep(for: .milliseconds(2500))
          guard notice?.id == newValue.id else { return }
          notice = nil
        }
      }
  }
}

private extension View {
  func imageSaveNotice(_ notice: Binding<ImageSaveNotice?>) -> some View {
    modifier(ImageSaveNoticeModifier(notice: notice))
  }
}

private extension Error {
  var imageSaveMessage: String {
    (self as? LocalizedError)?.errorDescription ?? localizedDescription
  }
}

struct MessageBubble: View {
  @EnvironmentObject private var streamingTextStore: StreamingTextStore

  let message: ChatMessage
  let toolSettings: NativeToolSettings
  let openAIEndpoints: [OpenAIEndpoint]
  var skipTechnicalContentInTTS: Bool = true
  let appearance: AppearanceSettings
  var renderMarkdown: Bool = true
  var renderImages: Bool = true
  var searchHighlight: MessageSearchMatch? = nil
  var isBookmarked: Bool = false
  var onDelete: (() -> Void)? = nil
  var onToggleBookmark: (() -> Void)? = nil
  var onBeginSelection: (() -> Void)? = nil
  var onEdit: ((String) -> Void)? = nil
  var onEditAttachment: ((UUID, String) -> Void)? = nil
  var onResubmit: (() -> Void)? = nil
  var onTrimFromHere: (() -> Void)? = nil
  var onRestartFresh: (() -> Void)? = nil
  var onNewChatWithMessage: (() -> Void)? = nil
  var onSpeakFromHere: (() -> Void)? = nil
  var onReply: ((String) -> Void)? = nil
  var conversationCreatedAt: Date? = nil
  var showUserTimestamp: Bool = false
  var showThinking: Bool = false
  var isWaitingForResponse: Bool = false
  var onStreamingTextChange: ((String) -> Void)? = nil

  var body: some View {
    StreamingMessageBubble(
      message: message,
      streamingText: streamingTextStore.textObject(for: message.id),
      toolSettings: toolSettings,
      openAIEndpoints: openAIEndpoints,
      skipTechnicalContentInTTS: skipTechnicalContentInTTS,
      appearance: appearance,
      renderMarkdown: renderMarkdown,
      renderImages: renderImages,
      searchHighlight: searchHighlight,
      isBookmarked: isBookmarked,
      onDelete: onDelete,
      onToggleBookmark: onToggleBookmark,
      onBeginSelection: onBeginSelection,
      onEdit: onEdit,
      onEditAttachment: onEditAttachment,
      onResubmit: onResubmit,
      onTrimFromHere: onTrimFromHere,
      onRestartFresh: onRestartFresh,
      onNewChatWithMessage: onNewChatWithMessage,
      onSpeakFromHere: onSpeakFromHere,
      onReply: onReply,
      conversationCreatedAt: conversationCreatedAt,
      showUserTimestamp: showUserTimestamp,
      showThinking: showThinking,
      isWaitingForResponse: isWaitingForResponse,
      onStreamingTextChange: onStreamingTextChange
    )
  }
}

private struct StreamingMessageBubble: View {
  @Environment(\.colorScheme) private var colorScheme

  let message: ChatMessage
  @ObservedObject var streamingText: StreamingText
  let toolSettings: NativeToolSettings
  let openAIEndpoints: [OpenAIEndpoint]
  var skipTechnicalContentInTTS: Bool = true
  let appearance: AppearanceSettings
  var renderMarkdown: Bool = true
  var renderImages: Bool = true
  var searchHighlight: MessageSearchMatch? = nil
  var isBookmarked: Bool = false
  var onDelete: (() -> Void)? = nil
  var onToggleBookmark: (() -> Void)? = nil
  var onBeginSelection: (() -> Void)? = nil
  var onEdit: ((String) -> Void)? = nil
  var onEditAttachment: ((UUID, String) -> Void)? = nil
  var onResubmit: (() -> Void)? = nil
  var onTrimFromHere: (() -> Void)? = nil
  var onRestartFresh: (() -> Void)? = nil
  var onNewChatWithMessage: (() -> Void)? = nil
  var onSpeakFromHere: (() -> Void)? = nil
  var onReply: ((String) -> Void)? = nil
  var conversationCreatedAt: Date? = nil
  var showUserTimestamp: Bool = false
  var showThinking: Bool = false
  var isWaitingForResponse: Bool = false
  var onStreamingTextChange: ((String) -> Void)? = nil

  var body: some View {
    MessageBubbleContent(
      message: message,
      messageRenderKey: ChatMessageRenderKey(message),
      streamingOverride: streamingText.text,
      toolSettings: toolSettings,
      openAIEndpoints: openAIEndpoints,
      skipTechnicalContentInTTS: skipTechnicalContentInTTS,
      appearance: appearance,
      renderMarkdown: renderMarkdown,
      renderImages: renderImages,
      searchHighlight: searchHighlight,
      isBookmarked: isBookmarked,
      onDelete: onDelete,
      onToggleBookmark: onToggleBookmark,
      onBeginSelection: onBeginSelection,
      onEdit: onEdit,
      onEditAttachment: onEditAttachment,
      onResubmit: onResubmit,
      onTrimFromHere: onTrimFromHere,
      onRestartFresh: onRestartFresh,
      onNewChatWithMessage: onNewChatWithMessage,
      onSpeakFromHere: onSpeakFromHere,
      onReply: onReply,
      conversationCreatedAt: conversationCreatedAt,
      showUserTimestamp: showUserTimestamp,
      showThinking: showThinking,
      isWaitingForResponse: isWaitingForResponse,
      colorScheme: colorScheme
    )
    .equatable()
    .onChange(of: streamingText.text) { _, newText in
      guard let newText else { return }
      onStreamingTextChange?(newText)
    }
  }
}

private struct MessageBubbleContent: View, Equatable {
  @AppStorage("thinkingDisplay") private var thinkingDisplay: ThinkingDisplay = .five
  let message: ChatMessage
  let messageRenderKey: ChatMessageRenderKey
  var streamingOverride: String? = nil
  let toolSettings: NativeToolSettings
  let openAIEndpoints: [OpenAIEndpoint]
  var skipTechnicalContentInTTS: Bool = true
  let appearance: AppearanceSettings
  var renderMarkdown: Bool = true
  var renderImages: Bool = true
  var searchHighlight: MessageSearchMatch? = nil
  var isBookmarked: Bool = false
  var onDelete: (() -> Void)? = nil
  var onToggleBookmark: (() -> Void)? = nil
  var onBeginSelection: (() -> Void)? = nil
  var onEdit: ((String) -> Void)? = nil
  var onEditAttachment: ((UUID, String) -> Void)? = nil
  var onResubmit: (() -> Void)? = nil
  var onTrimFromHere: (() -> Void)? = nil
  var onRestartFresh: (() -> Void)? = nil
  var onNewChatWithMessage: (() -> Void)? = nil
  var onSpeakFromHere: (() -> Void)? = nil
  var onReply: ((String) -> Void)? = nil
  var conversationCreatedAt: Date? = nil
  var showUserTimestamp: Bool = false
  var showThinking: Bool = false
  var isWaitingForResponse: Bool = false
  var colorScheme: ColorScheme
  @State private var showingTextSelection = false
  @State private var showingRawTextSelection = false
  @State private var selectedTextAttachment: ChatAttachment?
  @State private var selectedImageAttachment: ChatAttachment?
  @State private var imageSaveNotice: ImageSaveNotice?
  @State private var replyDraft: MessageReplyDraft?

  private var isUser: Bool { message.role == .user }
  private var displayText: String { streamingOverride ?? message.presentationText }
  private var isStreaming: Bool { streamingOverride != nil }
  private var isLiveAssistantResponse: Bool {
    message.role == .assistant && (isWaitingForResponse || isStreaming)
  }

  /// Identity for SwiftUI's EquatableView: skip body re-evaluation when neither
  /// the canonical message nor the streaming override has changed. Closure
  /// equality is irrelevant because actions are invoked only from fresh menus.
  nonisolated static func == (lhs: MessageBubbleContent, rhs: MessageBubbleContent) -> Bool {
    lhs.messageRenderKey == rhs.messageRenderKey
      && lhs.streamingOverride == rhs.streamingOverride
      && lhs.toolSettings == rhs.toolSettings
      && lhs.openAIEndpoints == rhs.openAIEndpoints
      && lhs.skipTechnicalContentInTTS == rhs.skipTechnicalContentInTTS
      && lhs.appearance == rhs.appearance
      && lhs.renderMarkdown == rhs.renderMarkdown
      && lhs.renderImages == rhs.renderImages
      && lhs.searchHighlight == rhs.searchHighlight
      && lhs.isBookmarked == rhs.isBookmarked
      && lhs.conversationCreatedAt == rhs.conversationCreatedAt
      && lhs.showUserTimestamp == rhs.showUserTimestamp
      && lhs.showThinking == rhs.showThinking
      && lhs.isWaitingForResponse == rhs.isWaitingForResponse
      && lhs.colorScheme == rhs.colorScheme
  }

  var body: some View {
    let prepared = MessageRenderCache.preparedContent(
      messageID: message.id,
      text: displayText
    )
    let canRenderMarkdown = renderMarkdown && (!isStreaming || appearance.liveMarkdown)

    VStack(alignment: .leading, spacing: 6) {
      ForEach(Array(prepared.parts.enumerated()), id: \.element.id) { index, part in
        switch part {
        case .visible(_, let visibleText):
          let usesMarkdown = usesMarkdown(for: visibleText, canRenderMarkdown: canRenderMarkdown)
          let markdownBlocks = markdownBlocks(
            for: visibleText,
            usesMarkdown: usesMarkdown,
            partID: part.id)
          bubble(
            visibleText: visibleText,
            rawText: displayText,
            markdownBlocks: markdownBlocks,
            usesMarkdown: usesMarkdown,
            visiblePartIndex: prepared.visiblePartIndex(at: index),
            actionText: prepared.visibleText,
            includeMessageExtras: index == prepared.firstVisiblePartIndex
          )
        case .tool(let partID, let entry, let section):
          ToolCallRow(
            entry: entry,
            onEdit: toolEditAction(for: entry, partID: partID, in: prepared),
            onDelete: toolDeleteAction(
              for: entry, section: section, partID: partID, in: prepared))
        case .reasoning(_, let section):
          let compactDisplay = isStreaming && thinkingDisplay == .full ? .five : thinkingDisplay
          FoldableMetaSection(
            title: "Reasoning",
            systemImage: "brain",
            content: section.content,
            monospaced: false,
            detail: Self.reasoningSize(section.content),
            collapsedStatus: showThinking && compactDisplay == .status && isStreaming
              ? "Thinking…" : nil,
            collapsedPreviewLines: showThinking && compactDisplay != .status
              && compactDisplay != .full ? compactDisplay.lineCount : 0,
            dimmedContent: true,
            initiallyExpanded: showThinking && thinkingDisplay == .full && !isStreaming,
            italicContent: true,
            markdownAppearance: canRenderMarkdown ? appearance : nil,
            renderImages: renderImages,
            onDelete: hiddenSectionDeleteAction(
              for: section, partID: part.id, in: prepared)
          )
        case .transcript(_, let section):
          FoldableMetaSection(
            title: "Prompt Transcript",
            systemImage: "text.bubble",
            content: section.content,
            monospaced: true,
            initiallyExpanded: false
          )
        }
      }
      if prepared.parts.isEmpty && !prepared.hideBubble {
        let usesMarkdown = usesMarkdown(
          for: prepared.visibleText,
          canRenderMarkdown: canRenderMarkdown)
        let markdownBlocks = markdownBlocks(
          for: prepared.visibleText,
          usesMarkdown: usesMarkdown,
          partID: 0)
        bubble(
          visibleText: prepared.visibleText,
          rawText: displayText,
          markdownBlocks: markdownBlocks,
          usesMarkdown: usesMarkdown,
          visiblePartIndex: 0,
          actionText: prepared.visibleText,
          includeMessageExtras: true
        )
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .frame(maxWidth: 720, alignment: .leading)
    .padding(.leading, isUser ? 36 : 0)
    .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
  }

  private static func reasoningSize(_ content: String) -> String {
    let characters = content.count
    let tokens = GenerationStats.estimatedTokenCount(forCharacterCount: characters)
    return "\(ModelUsageFormat.tokens(tokens, estimated: true)) · \(ModelUsageFormat.count(characters)) chars"
  }

  @ViewBuilder
  private func bubble(
    visibleText: String,
    rawText: String,
    markdownBlocks: [MarkdownBlock],
    usesMarkdown: Bool,
    visiblePartIndex: Int,
    actionText: String? = nil,
    includeMessageExtras: Bool = true
  )
    -> some View
  {
    let messageFont = appearance.swiftUIFont(for: message.role)
    let messageFontFamily = appearance.fontFamily(for: message.role)
    let messageText = actionText ?? visibleText
    let hasIncludedExtras = includeMessageExtras && hasDisplayedAttachmentContent
    let bubbleView = VStack(alignment: .leading, spacing: 8) {
      if includeMessageExtras && showsSenderHeader {
        HStack(spacing: 6) {
          Image(systemName: iconName)
            .foregroundStyle(iconColor)
          Text(message.role.displayName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
      }
      if includeMessageExtras {
        ForEach(textAttachments) { attachment in
          MessageAttachmentRow(attachment: attachment) {
            if attachment.kind == .textFile {
              selectedTextAttachment = attachment
            }
          }
        }
      }
      if visibleText.isEmpty {
        if isLiveAssistantResponse {
          AssistantTypingIndicator(fontSize: appearance.fontSize)
        } else if !hasIncludedExtras {
          Text("...")
            .font(messageFont)
            .foregroundStyle(.secondary)
        }
      } else if let searchHighlight,
        searchHighlight.visiblePartIndex == visiblePartIndex
      {
        Text(
          searchHighlight.attributedText(
            in: MessageContentFilter.markdownPlainText(from: visibleText))
        )
        .font(messageFont)
        .lineSpacing(CGFloat(appearance.lineSpacing))
        .foregroundStyleIfPresent(plainBodyForegroundStyle)
        .fixedSize(horizontal: false, vertical: true)
        .id(searchHighlight)
      } else if usesMarkdown {
        MarkdownContentView(
          blocks: markdownBlocks,
          appearance: appearance,
          fontFamily: messageFontFamily,
          allowsTextSelection: false,
          renderImages: renderImages
        )
        .fixedSize(horizontal: false, vertical: true)
      } else {
        Text(visibleText)
          .font(messageFont)
          .lineSpacing(CGFloat(appearance.lineSpacing))
          .foregroundStyleIfPresent(plainBodyForegroundStyle)
          .fixedSize(horizontal: false, vertical: true)
      }
      if includeMessageExtras && hasVoiceRecording {
        VoiceRecordingPlaybackButton(message: message)
      }
      if includeMessageExtras {
        ForEach(imageAttachments) { attachment in
          MessageImageAttachmentView(
            attachment: attachment,
            onOpen: { selectedImageAttachment = attachment },
            onSave: { saveImageAttachment(attachment) }
          )
        }
      }
      if includeMessageExtras && showUserTimestamp {
        Text(ConversationDatePresentation.timestamp(message.createdAt))
          .font(.caption2)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(backgroundStyle)
    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

    let bubbleWithSheet =
      bubbleView
      .sheet(isPresented: $showingTextSelection) {
        // Only the prose of the message: tool calls and reasoning are edited
        // from their own rows, and are spliced back untouched on save.
        MessageTextSelectionSheet(
          title: onEdit == nil ? message.role.displayName : "",
          text: messageText,
          appearance: appearance,
          initialFontSize: appearance.fontSize,
          initialLineSpacing: appearance.lineSpacing,
          fontFamily: appearance.fontFamily(for: message.role),
          isEditable: onEdit != nil,
          onSave: messageEditAction(rawText: rawText))
      }
      .sheet(isPresented: $showingRawTextSelection) {
        // Escape hatch for the whole stored message, tags included.
        MessageTextSelectionSheet(
          title: "Raw Message",
          text: rawText,
          canFilter: rawText != messageText,
          appearance: appearance,
          initialFontSize: appearance.fontSize,
          initialLineSpacing: appearance.lineSpacing,
          fontFamily: appearance.fontFamily(for: message.role),
          isEditable: onEdit != nil,
          onSave: onEdit)
      }
      .sheet(item: $selectedTextAttachment) { attachment in
        MessageTextSelectionSheet(
          title: attachment.displayName,
          text: attachment.text ?? "",
          appearance: appearance,
          initialFontSize: appearance.fontSize,
          initialLineSpacing: appearance.lineSpacing,
          fontFamily: appearance.fontFamily(for: message.role),
          isEditable: onEditAttachment != nil,
          onSave: { text in onEditAttachment?(attachment.id, text) })
      }
      .sheet(item: $replyDraft) { draft in
        MessageTextSelectionSheet(
          title: "Reply",
          text: draft.text,
          appearance: appearance,
          initialFontSize: appearance.fontSize,
          initialLineSpacing: appearance.lineSpacing,
          fontFamily: appearance.fontFamily(for: message.role),
          isEditable: true,
          saveTitle: "Send",
          saveConfirmation: "Send this reply?",
          onSave: { text in onReply?(text) })
      }
      .fullScreenCover(item: $selectedImageAttachment) { attachment in
        MessageImageFullscreenLoader(attachment: attachment)
      }
      .imageSaveNotice($imageSaveNotice)
    if !isLiveAssistantResponse {
      bubbleWithSheet
        .contextMenu {
          messageContextMenu(visibleText: messageText, rawText: rawText)
        } preview: {
          Color.clear
            .frame(width: 1, height: 1)
            .accessibilityHidden(true)
        }
    } else {
      bubbleWithSheet
    }
  }

  private func usesMarkdown(for visibleText: String, canRenderMarkdown: Bool) -> Bool {
    canRenderMarkdown
      && (appearance.justifyText || MarkdownParser.mayContainMarkdown(visibleText))
  }

  @MainActor
  private func markdownBlocks(
    for visibleText: String,
    usesMarkdown: Bool,
    partID: Int
  ) -> [MarkdownBlock] {
    guard usesMarkdown, !visibleText.isEmpty else { return [] }
    return MessageRenderCache.markdownBlocks(
      messageID: message.id,
      partID: partID,
      text: visibleText,
      isStreaming: isStreaming)
  }

  /// Applies an edit made on the bubble text back onto the whole message, keeping
  /// the tool and reasoning blocks the bubble does not show.
  private func messageEditAction(rawText: String) -> ((String) -> Void)? {
    guard let onEdit else { return nil }
    return { edited in
      onEdit(MessageContentFilter.replacingVisibleText(in: rawText, with: edited))
    }
  }

  /// Writes an edited tool block back into the message, leaving the prose and the
  /// other tool blocks untouched. Nil while the response streams, when the message
  /// is not editable, or when the block can no longer be located in the message.
  private func toolEditAction(
    for entry: ToolEntry,
    partID: Int,
    in prepared: PreparedMessageContent
  ) -> ((String) -> Void)? {
    guard let onEdit, !isLiveAssistantResponse, !entry.rawBlock.isEmpty else { return nil }
    let rawText = displayText
    // A message may repeat an identical block, so edit the occurrence this row
    // was built from rather than the first textual match.
    var occurrence = 0
    for part in prepared.parts {
      guard case .tool(let id, let other, _) = part else { continue }
      if id == partID { break }
      if other.rawBlock == entry.rawBlock { occurrence += 1 }
    }
    let block = entry.rawBlock
    guard let range = Self.range(ofOccurrence: occurrence, of: block, in: rawText) else {
      return nil
    }
    return { edited in
      onEdit(rawText.replacingCharacters(in: range, with: edited))
    }
  }

  /// Deletes the selected tool row. A one-row wrapper is removed as a whole;
  /// when a legacy wrapper contains several rows, only the exact row pressed
  /// is removed and its siblings stay intact.
  private func toolDeleteAction(
    for entry: ToolEntry,
    section: HiddenMessageSection,
    partID: Int,
    in prepared: PreparedMessageContent
  ) -> (() -> Void)? {
    guard let onEdit, !isLiveAssistantResponse, !entry.rawBlock.isEmpty else { return nil }
    let rawText = displayText
    let entries = ToolCallParser.parse(section.content)
    if entries.count == 1,
      let edited = removingHiddenSection(
        section, partID: partID, in: prepared, rawText: rawText)
    {
      return { onEdit(edited) }
    }

    var occurrence = 0
    for part in prepared.parts {
      guard case .tool(let id, let other, _) = part else { continue }
      if id == partID { break }
      if other.rawBlock == entry.rawBlock { occurrence += 1 }
    }
    guard let range = Self.range(ofOccurrence: occurrence, of: entry.rawBlock, in: rawText)
    else { return nil }
    return { onEdit(rawText.replacingCharacters(in: range, with: "")) }
  }

  private func hiddenSectionDeleteAction(
    for section: HiddenMessageSection,
    partID: Int,
    in prepared: PreparedMessageContent
  ) -> (() -> Void)? {
    guard let onEdit, !isLiveAssistantResponse,
      let edited = removingHiddenSection(
        section, partID: partID, in: prepared, rawText: displayText)
    else { return nil }
    return { onEdit(edited) }
  }

  private func removingHiddenSection(
    _ section: HiddenMessageSection,
    partID: Int,
    in prepared: PreparedMessageContent,
    rawText: String
  ) -> String? {
    var occurrence = 0
    for part in prepared.parts {
      let id: Int
      let other: HiddenMessageSection
      switch part {
      case .tool(let candidateID, _, let candidate):
        id = candidateID
        other = candidate
      case .reasoning(let candidateID, let candidate),
        .transcript(let candidateID, let candidate):
        id = candidateID
        other = candidate
      case .visible:
        continue
      }
      if id == partID { break }
      if other.tag == section.tag && other.content == section.content { occurrence += 1 }
    }
    return MessageContentFilter.removingHiddenSection(
      tag: section.tag,
      content: section.content,
      occurrence: occurrence,
      from: rawText)
  }

  private static func range(
    ofOccurrence occurrence: Int,
    of block: String,
    in text: String
  ) -> Range<String.Index>? {
    var searchStart = text.startIndex
    var remaining = occurrence
    while let range = text.range(of: block, range: searchStart..<text.endIndex) {
      if remaining == 0 { return range }
      remaining -= 1
      searchStart = range.upperBound
    }
    return nil
  }

  /// MaiCore's spelling of the call(s) behind the message, the same one the
  /// pmai REPL uses.
  private var generationStatsText: String? {
    message.stats?.summary
  }

  @ViewBuilder
  private func messageContextMenu(visibleText: String, rawText: String) -> some View {
    if let conversationCreatedAt {
      Text(ConversationDatePresentation.startedText(conversationCreatedAt))
        .font(.system(size: 8))
        .foregroundStyle(.secondary)
      Divider()
    }
    if let statsText = generationStatsText {
      Text(statsText)
        .font(.system(size: 8))
        .foregroundStyle(.secondary)
      Divider()
    }

    if let onBeginSelection {
      Button(action: onBeginSelection) {
        Label("Select...", systemImage: "checkmark.circle")
      }
    }

    if let onToggleBookmark {
      Button(action: onToggleBookmark) {
        Label(
          isBookmarked ? "Unbookmark" : "Bookmark",
          systemImage: isBookmarked ? "bookmark.slash" : "bookmark")
      }
    }

    ForEach(Array(imageAttachments.enumerated()), id: \.element.id) { index, attachment in
      Button {
        saveImageAttachment(attachment)
      } label: {
        Label(imageSaveMenuTitle(at: index), systemImage: "square.and.arrow.down")
      }
    }
    if !imageAttachments.isEmpty {
      Divider()
    }

    Button {
      showingTextSelection = true
    } label: {
      Label(
        onEdit == nil ? "View Text" : "Edit Message",
        systemImage: onEdit == nil ? "text.cursor" : "square.and.pencil")
    }
    Button {
      UIPasteboard.general.string = visibleText
    } label: {
      Label("Copy Message", systemImage: "doc.on.doc")
    }
    if rawText != visibleText {
      Button {
        showingRawTextSelection = true
      } label: {
        Label(
          onEdit == nil ? "View Raw Message" : "Edit Raw Message",
          systemImage: "chevron.left.forwardslash.chevron.right")
      }
    }
    if message.role == .assistant, onReply != nil {
      Button {
        replyDraft = MessageReplyDraft(text: MarkdownQuote.quote(visibleText) + "\n\n")
      } label: {
        Label("Reply…", systemImage: "arrowshape.turn.up.left")
      }
    }

    Divider()

    Button {
      _ = TextToSpeechTool.speak(
        arguments: ["text": .string(visibleText)],
        settings: toolSettings,
        skipTechnicalContent: skipTechnicalContentInTTS,
        openAIEndpoints: openAIEndpoints,
        role: message.role == .user ? .user : .assistant,
        title: message.role.displayName,
        messageID: message.id)
    } label: {
      Label("Speak Message", systemImage: "speaker.wave.2")
    }

    if let onSpeakFromHere {
      Button(action: onSpeakFromHere) {
        Label("Speak From Here", systemImage: "speaker.wave.2.fill")
      }
    }

    if message.role != .assistant {
      if let resend = onTrimFromHere ?? (isUser ? onResubmit : nil) {
        Button(action: resend) {
          Label("Retry From Here", systemImage: "arrow.clockwise")
        }
      }
      if let onRestartFresh {
        Button(action: onRestartFresh) {
          Label("Reset Chat From Here", systemImage: "arrow.triangle.2.circlepath")
        }
      }
    }

    if let onDelete {
      Divider()
      Button(role: .destructive, action: onDelete) {
        Label("Delete Message", systemImage: "trash")
      }
    }
  }

  private var textAttachments: [ChatAttachment] {
    message.attachments.filter { $0.kind == .textFile }
  }

  private var imageAttachments: [ChatAttachment] {
    message.attachments.filter { $0.kind == .image }
  }

  private var hasDisplayedAttachmentContent: Bool {
    hasVoiceRecording || !message.attachments.isEmpty
  }

  private func imageSaveMenuTitle(at index: Int) -> String {
    imageAttachments.count == 1 ? "Save Image" : "Save Image \(index + 1)"
  }

  private func saveImageAttachment(_ attachment: ChatAttachment) {
    Task {
      do {
        try await MessageAttachmentImage.saveToPhotoLibrary(attachment)
        await MainActor.run {
          imageSaveNotice = .success()
        }
      } catch {
        await MainActor.run {
          imageSaveNotice = .failure(error.imageSaveMessage)
        }
      }
    }
  }

  private var iconName: String {
    switch message.role {
    case .user: "person.crop.circle"
    case .assistant: "sparkles"
    case .system: "gearshape"
    case .tool: "wrench.and.screwdriver"
    case .error: "exclamationmark.triangle"
    }
  }

  private var showsSenderHeader: Bool {
    switch message.role {
    case .user, .assistant:
      false
    case .system, .tool, .error:
      true
    }
  }

  private var iconColor: Color {
    message.role == .error ? .red : .accentColor
  }

  private var hasVoiceRecording: Bool {
    guard isUser, let filename = message.voiceRecordingFilename,
      let url = PocketMaiDirectories.voiceRecordingURL(filename: filename)
    else {
      return false
    }
    return FileManager.default.fileExists(atPath: url.path)
  }

  private var plainBodyForegroundStyle: Color? {
    message.role == .assistant ? markdownBodyColor : nil
  }

  private var backgroundStyle: some ShapeStyle {
    if message.role == .error {
      return AnyShapeStyle(.red.opacity(0.14))
    }
    if isUser {
      guard appearance.solidBubbles.includes(.user) else {
        return AnyShapeStyle(Color.clear)
      }
      return MessageBubblePalette.selectedRowBackground()
    }
    if message.role == .assistant {
      guard appearance.solidBubbles.includes(.assistant) else {
        return AnyShapeStyle(Color.clear)
      }
      if colorScheme == .dark {
        return MessageBubblePalette.accentBackground(
          tint: appearance.tint,
          colorScheme: colorScheme,
          lightOpacity: 0.14,
          systemDarkOpacity: 0.20)
      }
    }
    return AnyShapeStyle(.regularMaterial)
  }

}

private enum MessageBubblePalette {
  static func selectedRowBackground() -> AnyShapeStyle {
    AnyShapeStyle(Color.accentColor.opacity(0.22))
  }

  static func accentBackground(
    tint: AppearanceTint,
    colorScheme: ColorScheme,
    lightOpacity: Double,
    systemDarkOpacity: Double
  ) -> AnyShapeStyle {
    guard colorScheme == .dark else {
      return AnyShapeStyle(Color.accentColor.opacity(lightOpacity))
    }
    guard let baseColor = tint.uiColor else {
      return AnyShapeStyle(Color.accentColor.opacity(systemDarkOpacity))
    }
    return AnyShapeStyle(Color(uiColor: darkBubbleColor(from: baseColor)))
  }

  private static func darkBubbleColor(from color: UIColor) -> UIColor {
    var hue: CGFloat = 0
    var saturation: CGFloat = 0
    var brightness: CGFloat = 0
    var alpha: CGFloat = 0
    guard color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else {
      return UIColor(white: 0.20, alpha: 1)
    }
    return UIColor(
      hue: hue,
      saturation: min(max(saturation, 0.58), 0.78),
      brightness: min(max(brightness * 0.48, 0.34), 0.46),
      alpha: 1)
  }
}

extension AppearanceTint {
  fileprivate var uiColor: UIColor? {
    switch self {
    case .system: nil
    case .blue: UIColor.systemBlue
    case .purple: UIColor.systemPurple
    case .pink: UIColor(red: 1.0, green: 0.45, blue: 0.72, alpha: 1)
    case .red: UIColor.systemRed
    case .orange: UIColor.systemOrange
    case .yellow: UIColor.systemYellow
    case .green: UIColor.systemGreen
    case .mint: UIColor.systemMint
    case .teal: UIColor.systemTeal
    case .cyan: UIColor.systemCyan
    case .indigo: UIColor.systemIndigo
    }
  }
}

private struct MessageAttachmentRow: View {
  let attachment: ChatAttachment
  let onTap: () -> Void

  var body: some View {
    Button(action: onTap) {
      HStack(spacing: 10) {
        preview
        VStack(alignment: .leading, spacing: 2) {
          Text(attachment.displayName)
            .font(.callout.weight(.semibold))
            .lineLimit(1)
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background(Color(uiColor: .secondarySystemBackground).opacity(0.72))
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .buttonStyle(.plain)
    .disabled(attachment.kind != .textFile)
  }

  @ViewBuilder
  private var preview: some View {
    if attachment.kind == .image {
      AttachmentImageThumbnail(attachment: attachment, side: 34, cornerRadius: 6)
    } else {
      Image(systemName: attachment.kind == .image ? "photo" : "doc.text")
        .font(.title3)
        .foregroundStyle(Color.accentColor)
        .frame(width: 34, height: 34)
        .background(Color.accentColor.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
  }

  private var subtitle: String {
    switch attachment.kind {
    case .textFile:
      let count = attachment.text?.count ?? 0
      return "\(count) character\(count == 1 ? "" : "s")"
    case .image:
      if let width = attachment.width, let height = attachment.height {
        return "\(width)x\(height)"
      }
      return "Image"
    }
  }
}

private struct MessageImageAttachmentView: View {
  @Environment(\.displayScale) private var displayScale
  @State private var uiImage: UIImage?

  let attachment: ChatAttachment
  let onOpen: () -> Void
  let onSave: () -> Void

  var body: some View {
    Group {
      if let uiImage {
        let preview = previewMetrics(for: uiImage)
        Button(action: onOpen) {
          Image(uiImage: uiImage)
            .resizable()
            .interpolation(.high)
            .aspectRatio(uiImage.size, contentMode: .fit)
            .frame(
              maxWidth: preview.size.width,
              maxHeight: preview.size.height,
              alignment: .center
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
              Text(dimensionsLabel(for: uiImage))
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(.regularMaterial, in: Capsule())
                .padding(5)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Attached image")
        .contextMenu {
          Button(action: onSave) {
            Label("Save Image", systemImage: "square.and.arrow.down")
          }
        }
      } else {
        Image(systemName: "photo")
          .font(.title2)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 140, alignment: .leading)
          .background(Color.secondary.opacity(0.08))
          .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
          .accessibilityLabel("Image loading")
      }
    }
    .task(id: AttachmentImageLoader.cacheIdentity(for: attachment, maxPixelDimension: 1_260)) {
      uiImage = await AttachmentImageLoader.shared.image(
        for: attachment,
        maxPixelDimension: 1_260)
    }
  }

  private func dimensionsLabel(for image: UIImage) -> String {
    let width = attachment.width ?? Int((image.size.width * image.scale).rounded())
    let height = attachment.height ?? Int((image.size.height * image.scale).rounded())
    return "\(width)x\(height)"
  }

  private func nativeDisplaySize(for image: UIImage) -> CGSize {
    let width = CGFloat(attachment.width ?? Int((image.size.width * image.scale).rounded()))
    let height = CGFloat(attachment.height ?? Int((image.size.height * image.scale).rounded()))
    let scale = max(displayScale, 1)
    return CGSize(width: max(1, width / scale), height: max(1, height / scale))
  }

  private func previewMetrics(for image: UIImage) -> (size: CGSize, isUpscaled: Bool) {
    let nativeSize = nativeDisplaySize(for: image)
    let longEdge = max(nativeSize.width, nativeSize.height)
    let shortEdge = min(nativeSize.width, nativeSize.height)
    guard longEdge > 0, shortEdge > 0 else {
      return (CGSize(width: 1, height: 1), false)
    }

    let minimumLongEdge: CGFloat = 180
    let minimumShortEdge: CGFloat = 72
    let maximumLongEdge: CGFloat = 420
    let maximumHeight: CGFloat = 380

    var scale: CGFloat = 1
    if longEdge < minimumLongEdge {
      scale = max(scale, minimumLongEdge / longEdge)
    }
    if shortEdge * scale < minimumShortEdge {
      scale = max(scale, minimumShortEdge / shortEdge)
    }
    scale = min(scale, maximumLongEdge / longEdge)

    var size = CGSize(width: nativeSize.width * scale, height: nativeSize.height * scale)
    if size.height > maximumHeight {
      let heightScale = maximumHeight / size.height
      size = CGSize(width: size.width * heightScale, height: maximumHeight)
    }
    return (
      CGSize(width: max(1, size.width.rounded()), height: max(1, size.height.rounded())),
      scale > 1.01
    )
  }
}

struct MessageImageFullscreenView: View {
  @Environment(\.dismiss) private var dismiss
  let image: UIImage
  let imageData: Data
  @State private var imageSaveNotice: ImageSaveNotice?

  var body: some View {
    ZStack(alignment: .top) {
      Color(uiColor: .systemBackground)
        .ignoresSafeArea()
      ZoomableUIImageView(image: image) {
        dismiss()
      }
      .ignoresSafeArea()
      HStack {
        Button {
          dismiss()
        } label: {
          Image(systemName: "xmark")
            .font(.headline)
            .foregroundStyle(.primary)
            .frame(width: 42, height: 42)
            .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel("Close")

        Spacer()

        Button {
          saveImage()
        } label: {
          Image(systemName: "square.and.arrow.down")
            .font(.headline)
            .foregroundStyle(.primary)
            .frame(width: 42, height: 42)
            .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel("Save Image")
      }
      .padding(.horizontal, 18)
      .padding(.top, 12)
    }
    .statusBarHidden()
    .imageSaveNotice($imageSaveNotice)
  }

  private func saveImage() {
    Task {
      do {
        try await MessageAttachmentImage.saveImageDataToPhotoLibrary(imageData)
        await MainActor.run {
          imageSaveNotice = .success()
        }
      } catch {
        await MainActor.run {
          imageSaveNotice = .failure(error.imageSaveMessage)
        }
      }
    }
  }
}

struct MessageImageFullscreenLoader: View {
  private let maximumDisplayPixelDimension = 4_096
  let attachment: ChatAttachment
  @State private var image: UIImage?
  @State private var imageData: Data?

  var body: some View {
    Group {
      if let image, let imageData {
        MessageImageFullscreenView(image: image, imageData: imageData)
      } else {
        ZStack {
          Color(uiColor: .systemBackground).ignoresSafeArea()
          ProgressView()
        }
      }
    }
    .task(
      id: AttachmentImageLoader.cacheIdentity(
        for: attachment,
        maxPixelDimension: maximumDisplayPixelDimension)
    ) {
      async let loadedImage = AttachmentImageLoader.shared.image(
        for: attachment,
        maxPixelDimension: maximumDisplayPixelDimension)
      async let loadedData = AttachmentImageLoader.shared.data(for: attachment)
      image = await loadedImage
      imageData = await loadedData
    }
  }
}

struct ZoomableUIImageView: UIViewRepresentable {
  let image: UIImage
  let onSwipeDown: () -> Void

  func makeUIView(context: Context) -> UIScrollView {
    let scrollView = UIScrollView()
    scrollView.delegate = context.coordinator
    scrollView.backgroundColor = .systemBackground
    scrollView.minimumZoomScale = 1
    scrollView.maximumZoomScale = 8
    scrollView.bouncesZoom = true
    scrollView.alwaysBounceVertical = true
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.showsVerticalScrollIndicator = false

    let imageView = UIImageView(image: image)
    imageView.contentMode = .scaleAspectFit
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.isUserInteractionEnabled = true
    scrollView.addSubview(imageView)
    context.coordinator.imageView = imageView

    NSLayoutConstraint.activate([
      imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
      imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
      imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
      imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
    ])

    let doubleTap = UITapGestureRecognizer(
      target: context.coordinator,
      action: #selector(Coordinator.handleDoubleTap(_:)))
    doubleTap.numberOfTapsRequired = 2
    scrollView.addGestureRecognizer(doubleTap)
    scrollView.panGestureRecognizer.addTarget(
      context.coordinator,
      action: #selector(Coordinator.handlePan(_:)))

    return scrollView
  }

  func updateUIView(_ scrollView: UIScrollView, context: Context) {
    context.coordinator.imageView?.image = image
    context.coordinator.onSwipeDown = onSwipeDown
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(onSwipeDown: onSwipeDown)
  }

  final class Coordinator: NSObject, UIScrollViewDelegate {
    weak var imageView: UIImageView?
    var onSwipeDown: () -> Void

    init(onSwipeDown: @escaping () -> Void) {
      self.onSwipeDown = onSwipeDown
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
      imageView
    }

    @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
      guard let scrollView = recognizer.view as? UIScrollView else { return }
      if scrollView.zoomScale > scrollView.minimumZoomScale {
        scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
      } else {
        let point = recognizer.location(in: imageView)
        let targetScale = min(3, scrollView.maximumZoomScale)
        let size = CGSize(
          width: scrollView.bounds.width / targetScale,
          height: scrollView.bounds.height / targetScale)
        let rect = CGRect(
          x: point.x - size.width / 2,
          y: point.y - size.height / 2,
          width: size.width,
          height: size.height)
        scrollView.zoom(to: rect, animated: true)
      }
    }

    @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
      guard recognizer.state == .ended,
        let scrollView = recognizer.view as? UIScrollView,
        scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01
      else {
        return
      }

      let translation = recognizer.translation(in: scrollView)
      let velocity = recognizer.velocity(in: scrollView)
      guard translation.y > 120,
        velocity.y > 450,
        abs(translation.x) < translation.y
      else {
        return
      }
      onSwipeDown()
    }
  }
}

enum MessageAttachmentImage {
  static func saveToPhotoLibrary(_ attachment: ChatAttachment) async throws {
    guard let data = await AttachmentImageLoader.shared.data(for: attachment) else {
      throw MessageImageSaveError("This image could not be decoded.")
    }
    try await saveImageDataToPhotoLibrary(data)
  }

  static func saveImageDataToPhotoLibrary(_ data: Data) async throws {
    guard await AttachmentImageLoader.isImageData(data) else {
      throw MessageImageSaveError("This image could not be decoded.")
    }
    let status = await photoLibraryAddAuthorizationStatus()
    guard isAuthorized(status) else {
      throw MessageImageSaveError("Allow photo library access to save this image.")
    }

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      PHPhotoLibrary.shared().performChanges {
        let request = PHAssetCreationRequest.forAsset()
        request.addResource(with: .photo, data: data, options: nil)
      } completionHandler: { success, error in
        if let error {
          continuation.resume(throwing: error)
        } else if success {
          continuation.resume()
        } else {
          continuation.resume(throwing: MessageImageSaveError("The image was not saved."))
        }
      }
    }
  }

  private static func photoLibraryAddAuthorizationStatus() async -> PHAuthorizationStatus {
    let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    guard status == .notDetermined else { return status }
    return await withCheckedContinuation { continuation in
      PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
        continuation.resume(returning: status)
      }
    }
  }

  private static func isAuthorized(_ status: PHAuthorizationStatus) -> Bool {
    switch status {
    case .authorized, .limited:
      return true
    case .denied, .notDetermined, .restricted:
      return false
    @unknown default:
      return false
    }
  }
}

struct AttachmentImageThumbnail: View {
  let attachment: ChatAttachment
  let side: CGFloat
  let cornerRadius: CGFloat
  @State private var image: UIImage?

  var body: some View {
    Group {
      if let image {
        Image(uiImage: image)
          .resizable()
          .interpolation(.high)
          .scaledToFill()
      } else {
        Image(systemName: "photo")
          .foregroundStyle(.secondary)
          .background(Color.secondary.opacity(0.12))
      }
    }
    .frame(width: side, height: side)
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    .task(id: AttachmentImageLoader.cacheIdentity(for: attachment, maxPixelDimension: pixelSide)) {
      image = await AttachmentImageLoader.shared.image(
        for: attachment,
        maxPixelDimension: pixelSide)
    }
  }

  private var pixelSide: Int {
    max(64, Int((side * 3).rounded(.up)))
  }
}

actor AttachmentImageLoader {
  static let shared = AttachmentImageLoader()

  struct DecodedImage: @unchecked Sendable {
    let value: UIImage
  }

  private struct AttachmentKey: Hashable, Sendable {
    let id: UUID
    let encodedLength: Int
  }

  private struct ImageKey: Hashable, Sendable {
    let attachment: AttachmentKey
    let maxPixelDimension: Int?
  }

  private struct CacheEntry<Value> {
    let value: Value
    let cost: Int
    var access: UInt64
  }

  private var dataCache: [AttachmentKey: CacheEntry<Data>] = [:]
  private var imageCache: [ImageKey: CacheEntry<DecodedImage>] = [:]
  private var dataTasks: [AttachmentKey: Task<Data?, Never>] = [:]
  private var imageTasks: [ImageKey: Task<DecodedImage?, Never>] = [:]
  private var dataCacheCost = 0
  private var imageCacheCost = 0
  private var accessCounter: UInt64 = 0

  private let maximumDataCacheCost = 16 * 1_024 * 1_024
  private let maximumImageCacheCost = 56 * 1_024 * 1_024
  private let maximumImageCount = 80

  nonisolated static func cacheIdentity(
    for attachment: ChatAttachment,
    maxPixelDimension: Int?
  ) -> String {
    "\(attachment.id.uuidString):\(attachment.dataBase64?.count ?? 0):\(maxPixelDimension ?? 0)"
  }

  func data(for attachment: ChatAttachment) async -> Data? {
    guard attachment.kind == .image,
      let encoded = attachment.dataBase64,
      !encoded.isEmpty
    else {
      return nil
    }
    let key = AttachmentKey(id: attachment.id, encodedLength: encoded.count)
    if var cached = dataCache[key] {
      cached.access = nextAccess()
      dataCache[key] = cached
      return cached.value
    }
    if let task = dataTasks[key] {
      return await task.value
    }

    let task = Task.detached(priority: .userInitiated) {
      Data(base64Encoded: encoded)
    }
    dataTasks[key] = task
    let result = await task.value
    dataTasks[key] = nil
    if let result {
      insertData(result, for: key)
    }
    return result
  }

  func image(for attachment: ChatAttachment, maxPixelDimension: Int?) async -> UIImage? {
    guard attachment.kind == .image else { return nil }
    let attachmentKey = AttachmentKey(
      id: attachment.id,
      encodedLength: attachment.dataBase64?.count ?? 0)
    let key = ImageKey(attachment: attachmentKey, maxPixelDimension: maxPixelDimension)
    if var cached = imageCache[key] {
      cached.access = nextAccess()
      imageCache[key] = cached
      return cached.value.value
    }
    if let task = imageTasks[key] {
      return await task.value?.value
    }
    guard let data = await data(for: attachment) else { return nil }

    let task = Task.detached(priority: .userInitiated) {
      AttachmentImageLoader.decode(data: data, maxPixelDimension: maxPixelDimension)
    }
    imageTasks[key] = task
    let result = await task.value
    imageTasks[key] = nil
    if let result {
      insertImage(result, for: key)
    }
    return result?.value
  }

  nonisolated static func decodeImageData(
    _ data: Data,
    maxPixelDimension: Int? = nil
  ) async -> UIImage? {
    await Task.detached(priority: .userInitiated) {
      AttachmentImageLoader.decode(data: data, maxPixelDimension: maxPixelDimension)?.value
    }.value
  }

  nonisolated static func isImageData(_ data: Data) async -> Bool {
    await Task.detached(priority: .utility) {
      CGImageSourceCreateWithData(data as CFData, nil) != nil
    }.value
  }

  private nonisolated static func decode(
    data: Data,
    maxPixelDimension: Int?
  ) -> DecodedImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let sourceWidth = sourceProperties?[kCGImagePropertyPixelWidth] as? Int ?? 1
    let sourceHeight = sourceProperties?[kCGImagePropertyPixelHeight] as? Int ?? 1
    let target = max(1, maxPixelDimension ?? max(sourceWidth, sourceHeight))
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: target,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceShouldCache: true,
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    else {
      return nil
    }
    return DecodedImage(value: UIImage(cgImage: cgImage, scale: 1, orientation: .up))
  }

  private func nextAccess() -> UInt64 {
    accessCounter &+= 1
    return accessCounter
  }

  private func insertData(_ data: Data, for key: AttachmentKey) {
    let cost = data.count
    guard cost <= maximumDataCacheCost else { return }
    if let old = dataCache.updateValue(
      CacheEntry(value: data, cost: cost, access: nextAccess()),
      forKey: key)
    {
      dataCacheCost -= old.cost
    }
    dataCacheCost += cost
    while dataCacheCost > maximumDataCacheCost,
      let oldest = dataCache.min(by: { $0.value.access < $1.value.access })?.key
    {
      dataCacheCost -= dataCache.removeValue(forKey: oldest)?.cost ?? 0
    }
  }

  private func insertImage(_ image: DecodedImage, for key: ImageKey) {
    let cgImage = image.value.cgImage
    let cost = max(1, (cgImage?.bytesPerRow ?? 0) * (cgImage?.height ?? 0))
    guard cost <= maximumImageCacheCost else { return }
    if let old = imageCache.updateValue(
      CacheEntry(value: image, cost: cost, access: nextAccess()),
      forKey: key)
    {
      imageCacheCost -= old.cost
    }
    imageCacheCost += cost
    while imageCacheCost > maximumImageCacheCost || imageCache.count > maximumImageCount,
      let oldest = imageCache.min(by: { $0.value.access < $1.value.access })?.key
    {
      imageCacheCost -= imageCache.removeValue(forKey: oldest)?.cost ?? 0
    }
  }
}

private struct MessageImageSaveError: LocalizedError {
  let message: String

  init(_ message: String) {
    self.message = message
  }

  var errorDescription: String? {
    message
  }
}

private struct AssistantTypingIndicator: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let fontSize: Double

  private var dotDiameter: CGFloat {
    min(8, max(5, CGFloat(fontSize) * 0.36))
  }

  private var waveAmplitude: CGFloat {
    dotDiameter * 0.55
  }

  var body: some View {
    Group {
      if reduceMotion {
        dots(progress: 0)
      } else {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
          dots(progress: timeline.date.timeIntervalSinceReferenceDate)
        }
      }
    }
    .frame(height: dotDiameter + waveAmplitude * 2)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Assistant is thinking")
  }

  private func dots(progress: TimeInterval) -> some View {
    HStack(spacing: dotDiameter * 0.75) {
      ForEach(0..<3, id: \.self) { index in
        let phase = progress * 2.0 * Double.pi / 1.15 - Double(index) * 0.48
        let lift = max(0, sin(phase))
        Circle()
          .fill(Color.secondary.opacity(reduceMotion ? 0.55 : 0.38 + lift * 0.24))
          .frame(width: dotDiameter, height: dotDiameter)
          .offset(y: reduceMotion ? 0 : -CGFloat(lift) * waveAmplitude)
      }
    }
    .padding(.vertical, waveAmplitude)
  }
}

struct MessageTextSelectionSheet: View {
  @Environment(\.dismiss) private var dismiss

  let title: String
  // The full, unfiltered message text. The editable buffer always operates on
  // this raw form; the filtered view is derived from it on demand.
  let text: String
  // Whether the raw text has hidden sections, i.e. a filtered form that differs
  // from the raw form. Drives whether the Raw/Filtered toggle is offered.
  let canFilter: Bool
  let appearance: AppearanceSettings
  let fontFamily: AppearanceFontFamily
  let lineSpacing: Double
  let isEditable: Bool
  // Title of the button that commits the draft.
  let saveTitle: String
  // When set, committing asks for confirmation with this question first and is
  // offered even for an untouched draft — the reply composer, where the quoted
  // text alone is a valid message.
  let saveConfirmation: String?
  let onSave: ((String) -> Void)?
  @State private var draftText: String
  @State private var fontSize: Double
  @State private var showingPreview = false
  // When true the raw text is shown/edited; when false the derived filtered text
  // is shown read-only. Saving is always tied to the raw draft.
  @State private var showingRaw: Bool
  @State private var shareItem: TextShareItem?
  @State private var showingSaveConfirmation = false

  private struct TextShareItem: Identifiable {
    let id = UUID()
    let items: [Any]
  }

  init(
    title: String,
    text: String,
    canFilter: Bool = false,
    appearance: AppearanceSettings = .defaults,
    initialFontSize: Double = AppearanceSettings.defaults.fontSize,
    initialLineSpacing: Double = AppearanceSettings.defaults.lineSpacing,
    fontFamily: AppearanceFontFamily = .system,
    isEditable: Bool = false,
    saveTitle: String = "Save",
    saveConfirmation: String? = nil,
    onSave: ((String) -> Void)? = nil
  ) {
    self.title = title
    self.text = text
    self.canFilter = canFilter
    self.appearance = appearance
    self.fontFamily = fontFamily
    self.lineSpacing = AppearanceSettings.clampedLineSpacing(initialLineSpacing)
    self.isEditable = isEditable
    self.saveTitle = saveTitle
    self.saveConfirmation = saveConfirmation
    self.onSave = onSave
    _draftText = State(initialValue: text)
    _fontSize = State(initialValue: AppearanceSettings.clampedFontSize(initialFontSize))
    // Editing starts on the raw text; read-only viewing starts on the cleaner
    // filtered text when one is available.
    _showingRaw = State(initialValue: isEditable || !canFilter)
  }

  // Editing uses a monospaced font so markdown source is easy to read and align.
  private var editorFontFamily: AppearanceFontFamily {
    isEditable ? .monospaced : fontFamily
  }

  // The text currently presented: the live raw draft, or its filtered form.
  private var displayedText: String {
    showingRaw ? draftText : MessageContentFilter.render(draftText).visibleText
  }

  var body: some View {
    NavigationStack {
      Group {
        if showingPreview {
          ScrollView {
            MarkdownContentView(
              text: displayedText,
              appearance: appearance,
              fontFamily: fontFamily,
              allowsTextSelection: true
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 18)
          }
        } else if isEditable && showingRaw {
          SelectableMessageTextView(
            text: $draftText,
            fontSize: $fontSize,
            lineSpacing: lineSpacing,
            fontFamily: editorFontFamily,
            isEditable: true
          )
        } else {
          // Read-only: viewing a message, or showing the derived filtered text
          // while editing (edits are made on the raw draft only).
          SelectableMessageTextView(
            text: .constant(displayedText),
            fontSize: $fontSize,
            lineSpacing: lineSpacing,
            fontFamily: editorFontFamily,
            isEditable: false
          )
        }
      }
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        if isEditable {
          ToolbarItem(placement: .topBarLeading) {
            Button("Cancel") {
              dismiss()
            }
          }
          if canFilter {
            ToolbarItem(placement: .topBarLeading) {
              rawToggleButton
            }
          }
          ToolbarItem(placement: .topBarTrailing) {
            Button {
              showingPreview.toggle()
            } label: {
              Label(
                showingPreview ? "Edit" : "Preview",
                systemImage: showingPreview ? "square.and.pencil" : "eye")
            }
          }
          ToolbarItem(placement: .topBarTrailing) {
            Button {
              UIPasteboard.general.string = displayedText
            } label: {
              Label("Copy All", systemImage: "doc.on.doc")
            }
          }
          ToolbarItem(placement: .topBarTrailing) {
            shareButton
          }
          ToolbarItem(placement: .confirmationAction) {
            Button(saveTitle) {
              if saveConfirmation == nil {
                saveEdits()
              } else {
                showingSaveConfirmation = true
              }
            }
            .disabled(saveConfirmation == nil && draftText == text)
          }
        } else {
          ToolbarItem(placement: .topBarLeading) {
            Button("Done") {
              dismiss()
            }
          }
          if canFilter {
            ToolbarItem(placement: .topBarLeading) {
              rawToggleButton
            }
          }
          ToolbarItem(placement: .topBarTrailing) {
            Button {
              UIPasteboard.general.string = displayedText
            } label: {
              Label("Copy All", systemImage: "doc.on.doc")
            }
          }
          ToolbarItem(placement: .topBarTrailing) {
            shareButton
          }
        }
      }
      .sheet(item: $shareItem) { item in
        ActivityShareSheet(activityItems: item.items)
      }
      .confirmationDialog(
        saveConfirmation ?? "",
        isPresented: $showingSaveConfirmation,
        titleVisibility: .visible
      ) {
        Button(saveTitle) {
          commitEdits()
        }
        Button("Cancel", role: .cancel) {}
      }
    }
  }

  private var shareButton: some View {
    Button {
      shareItem = TextShareItem(items: [exportFileURL() ?? displayedText])
    } label: {
      Label("Share", systemImage: "square.and.arrow.up")
    }
  }

  /// Writes the displayed text to a temp file named after the sheet title so
  /// the share sheet exports a real file; falls back to sharing plain text.
  private func exportFileURL() -> URL? {
    var filename = title
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .components(separatedBy: CharacterSet(charactersIn: "/\\:"))
      .joined(separator: "-")
    if filename.isEmpty { filename = "message" }
    if !filename.dropFirst().contains(".") { filename += ".md" }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
    do {
      try Data(displayedText.utf8).write(to: url, options: .atomic)
      return url
    } catch {
      return nil
    }
  }

  // Toggles between the raw message text and its filtered form. Highlighted
  // (filled icon) while the raw text is shown.
  private var rawToggleButton: some View {
    Button {
      showingRaw.toggle()
    } label: {
      Label("Raw", systemImage: showingRaw ? "doc.text.fill" : "doc.text")
    }
  }

  private func saveEdits() {
    guard draftText != text else {
      dismiss()
      return
    }
    commitEdits()
  }

  private func commitEdits() {
    onSave?(draftText)
    dismiss()
  }
}

private struct SelectableMessageTextView: UIViewRepresentable {
  @Binding var text: String
  @Binding var fontSize: Double
  let lineSpacing: Double
  let fontFamily: AppearanceFontFamily
  let isEditable: Bool

  func makeCoordinator() -> Coordinator {
    Coordinator(
      text: $text,
      fontSize: $fontSize,
      fontFamily: fontFamily,
      lineSpacing: lineSpacing)
  }

  func makeUIView(context: Context) -> UITextView {
    let textView = UITextView()
    textView.delegate = context.coordinator
    textView.isEditable = isEditable
    textView.isSelectable = true
    applyBareTextInputTraits(to: textView)
    textView.backgroundColor = .clear
    textView.font = fontFamily.uiFont(size: fontSize)
    textView.adjustsFontForContentSizeCategory = true
    textView.textContainerInset = UIEdgeInsets(top: 18, left: 14, bottom: 18, right: 14)
    textView.text = text
    context.coordinator.installPinchGesture(in: textView)
    context.coordinator.applyTextStyle(to: textView, size: fontSize)
    if isEditable {
      DispatchQueue.main.async {
        textView.becomeFirstResponder()
      }
    }
    return textView
  }

  func updateUIView(_ textView: UITextView, context: Context) {
    context.coordinator.text = $text
    context.coordinator.fontSize = $fontSize
    context.coordinator.fontFamily = fontFamily
    context.coordinator.lineSpacing = lineSpacing
    textView.isEditable = isEditable
    applyBareTextInputTraits(to: textView)
    if textView.text != text {
      textView.text = text
    }
    // Skip when the gesture handler already applied the style this run-loop cycle.
    // SwiftUI fires updateUIView after the binding write in updateFontSize, which
    // would cause a second full text-storage re-attribution for every gesture tick.
    if context.coordinator.pendingStyleFromGesture {
      context.coordinator.pendingStyleFromGesture = false
      return
    }
    context.coordinator.applyTextStyle(to: textView, size: fontSize)
  }

  private func applyBareTextInputTraits(to textView: UITextView) {
    textView.smartQuotesType = .no
    textView.smartDashesType = .no
    textView.smartInsertDeleteType = .no
    textView.autocorrectionType = .no
    textView.spellCheckingType = .no
  }

  final class Coordinator: NSObject, UIGestureRecognizerDelegate, UITextViewDelegate {
    var text: Binding<String>
    var fontSize: Binding<Double>
    var fontFamily: AppearanceFontFamily
    var lineSpacing: Double

    private weak var textView: UITextView?
    private var pinchGesture: UIPinchGestureRecognizer?
    private var pinchBaseFontSize: Double?
    private var pinchAnchor: TextViewPinchAnchor?
    private var pinchViewportY: CGFloat?
    // Set when applyTextStyle is called directly from the gesture handler so that
    // the redundant updateUIView→applyTextStyle call in the same SwiftUI pass can be skipped.
    var pendingStyleFromGesture = false
    private var originalShowsVerticalScrollIndicator: Bool?
    private var originalShowsHorizontalScrollIndicator: Bool?

    init(
      text: Binding<String>,
      fontSize: Binding<Double>,
      fontFamily: AppearanceFontFamily,
      lineSpacing: Double
    ) {
      self.text = text
      self.fontSize = fontSize
      self.fontFamily = fontFamily
      self.lineSpacing = lineSpacing
    }

    func installPinchGesture(in textView: UITextView) {
      guard pinchGesture == nil else { return }
      let gesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
      gesture.cancelsTouchesInView = false
      gesture.delaysTouchesBegan = false
      gesture.delaysTouchesEnded = false
      gesture.delegate = self
      textView.addGestureRecognizer(gesture)
      self.textView = textView
      pinchGesture = gesture
    }

    func textViewDidChange(_ textView: UITextView) {
      text.wrappedValue = textView.text
    }

    func applyTextStyle(to textView: UITextView, size: Double) {
      let nextFont = fontFamily.uiFont(size: size)
      let paragraphStyle = NSMutableParagraphStyle()
      paragraphStyle.lineSpacing = CGFloat(lineSpacing)
      textView.font = nextFont
      textView.typingAttributes[.font] = nextFont
      textView.typingAttributes[.paragraphStyle] = paragraphStyle
      if textView.textStorage.length > 0 {
        textView.textStorage.addAttributes(
          [
            .font: nextFont,
            .paragraphStyle: paragraphStyle,
          ],
          range: NSRange(location: 0, length: textView.textStorage.length))
      }
      textView.setNeedsLayout()
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
      guard let textView else { return }

      switch recognizer.state {
      case .began:
        pinchBaseFontSize = fontSize.wrappedValue
        hideScrollIndicators(in: textView)
        updateFontSize(for: recognizer, in: textView)
      case .changed:
        updateFontSize(for: recognizer, in: textView)
      case .ended, .cancelled, .failed:
        pinchBaseFontSize = nil
        pinchAnchor = nil
        pinchViewportY = nil
        restoreScrollIndicators()
      default:
        break
      }
    }

    private func updateFontSize(
      for recognizer: UIPinchGestureRecognizer,
      in textView: UITextView
    ) {
      let baseSize = pinchBaseFontSize ?? fontSize.wrappedValue
      pinchBaseFontSize = baseSize
      let rawSize = baseSize * max(Double(recognizer.scale), 0.1)
      let steppedSize =
        (rawSize / AppearanceSettings.fontSizeStep).rounded() * AppearanceSettings.fontSizeStep
      let clampedSize = AppearanceSettings.clampedFontSize(steppedSize)
      guard fontSize.wrappedValue != clampedSize else { return }

      // Capture anchor and viewport position once per gesture — the layout lookup
      // (layoutIfNeeded + layoutManager queries) only runs on the first tick.
      let contentPoint = recognizer.location(in: textView)
      let viewportY: CGFloat
      let anchor: TextViewPinchAnchor
      if let cachedAnchor = pinchAnchor, let cachedViewportY = pinchViewportY {
        anchor = cachedAnchor
        viewportY = cachedViewportY
      } else {
        viewportY = contentPoint.y - textView.contentOffset.y
        anchor = makePinchAnchor(in: textView, at: contentPoint)
        pinchAnchor = anchor
        pinchViewportY = viewportY
      }

      fontSize.wrappedValue = clampedSize
      // Mark before applyTextStyle so updateUIView can skip the redundant call that
      // SwiftUI will fire in the same run-loop cycle after the binding write above.
      pendingStyleFromGesture = true
      applyTextStyle(to: textView, size: clampedSize)
      preservePinchPosition(in: textView, anchor: anchor, viewportY: viewportY)
    }

    private func preservePinchPosition(
      in textView: UITextView,
      anchor: TextViewPinchAnchor,
      viewportY: CGFloat
    ) {
      textView.layoutIfNeeded()
      let targetContentY = resolvedContentY(for: anchor, in: textView)
      let targetY = targetContentY - viewportY
      textView.setContentOffset(
        CGPoint(x: textView.contentOffset.x, y: clampedScrollOffsetY(targetY, in: textView)),
        animated: false)
    }

    private func makePinchAnchor(
      in textView: UITextView,
      at contentPoint: CGPoint
    ) -> TextViewPinchAnchor {
      textView.layoutIfNeeded()
      let fallbackContentHeight = max(textView.contentSize.height, 1)
      guard textView.textStorage.length > 0 else {
        return TextViewPinchAnchor(
          characterIndex: nil,
          unitY: 0,
          fallbackContentY: contentPoint.y,
          fallbackContentHeight: fallbackContentHeight)
      }

      let textContainerPoint = CGPoint(
        x: contentPoint.x - textView.textContainerInset.left,
        y: contentPoint.y - textView.textContainerInset.top)
      let layoutManager = textView.layoutManager
      layoutManager.ensureLayout(for: textView.textContainer)
      let characterIndex = layoutManager.characterIndex(
        for: textContainerPoint,
        in: textView.textContainer,
        fractionOfDistanceBetweenInsertionPoints: nil)
      let clampedIndex = min(max(characterIndex, 0), textView.textStorage.length - 1)
      let glyphIndex = layoutManager.glyphIndexForCharacter(at: clampedIndex)
      var lineRange = NSRange()
      let lineRect = layoutManager.lineFragmentUsedRect(
        forGlyphAt: glyphIndex,
        effectiveRange: &lineRange)
      let unitY =
        lineRect.height > 1
        ? min(max((textContainerPoint.y - lineRect.minY) / lineRect.height, 0), 1)
        : 0

      return TextViewPinchAnchor(
        characterIndex: clampedIndex,
        unitY: unitY,
        fallbackContentY: contentPoint.y,
        fallbackContentHeight: fallbackContentHeight)
    }

    private func resolvedContentY(
      for anchor: TextViewPinchAnchor,
      in textView: UITextView
    ) -> CGFloat {
      if let characterIndex = anchor.characterIndex, textView.textStorage.length > 0 {
        let layoutManager = textView.layoutManager
        layoutManager.ensureLayout(for: textView.textContainer)
        let clampedIndex = min(max(characterIndex, 0), textView.textStorage.length - 1)
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: clampedIndex)
        let lineRect = layoutManager.lineFragmentUsedRect(
          forGlyphAt: glyphIndex, effectiveRange: nil)
        return textView.textContainerInset.top + lineRect.minY + lineRect.height * anchor.unitY
      }

      let newContentHeight = max(textView.contentSize.height, 1)
      return anchor.fallbackContentY * newContentHeight / anchor.fallbackContentHeight
    }

    private func clampedScrollOffsetY(_ y: CGFloat, in textView: UITextView) -> CGFloat {
      let minimumY = -textView.adjustedContentInset.top
      let maximumY = max(
        minimumY,
        textView.contentSize.height - textView.bounds.height + textView.adjustedContentInset.bottom)
      return min(max(y, minimumY), maximumY)
    }

    private func hideScrollIndicators(in textView: UITextView) {
      if originalShowsVerticalScrollIndicator == nil {
        originalShowsVerticalScrollIndicator = textView.showsVerticalScrollIndicator
      }
      if originalShowsHorizontalScrollIndicator == nil {
        originalShowsHorizontalScrollIndicator = textView.showsHorizontalScrollIndicator
      }
      textView.showsVerticalScrollIndicator = false
      textView.showsHorizontalScrollIndicator = false
    }

    private func restoreScrollIndicators() {
      guard let textView else { return }
      if let originalShowsVerticalScrollIndicator {
        textView.showsVerticalScrollIndicator = originalShowsVerticalScrollIndicator
      }
      if let originalShowsHorizontalScrollIndicator {
        textView.showsHorizontalScrollIndicator = originalShowsHorizontalScrollIndicator
      }
      originalShowsVerticalScrollIndicator = nil
      originalShowsHorizontalScrollIndicator = nil
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
      guard let pinch = gestureRecognizer as? UIPinchGestureRecognizer else { return true }
      return pinch.numberOfTouches >= 2
    }

    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
      true
    }
  }
}

private struct TextViewPinchAnchor {
  let characterIndex: Int?
  let unitY: CGFloat
  let fallbackContentY: CGFloat
  let fallbackContentHeight: CGFloat
}

extension View {
  @ViewBuilder
  fileprivate func textSelectionIfEnabled(_ enabled: Bool) -> some View {
    if enabled {
      textSelection(.enabled)
    } else {
      self
    }
  }

  @ViewBuilder
  fileprivate func foregroundStyleIfPresent(_ color: Color?) -> some View {
    if let color {
      foregroundStyle(color)
    } else {
      self
    }
  }
}

private struct PreparedMessageContent {
  let visibleText: String
  let parts: [MessageRenderPart]
  let hideBubble: Bool

  var firstVisiblePartIndex: Int? {
    parts.firstIndex(where: \.isVisible)
  }

  func visiblePartIndex(at partIndex: Int) -> Int {
    parts[..<partIndex].count(where: \.isVisible)
  }
}

private enum MessageRenderPart: Identifiable {
  case visible(id: Int, text: String)
  case tool(id: Int, entry: ToolEntry, section: HiddenMessageSection)
  case reasoning(id: Int, section: HiddenMessageSection)
  case transcript(id: Int, section: HiddenMessageSection)

  var id: Int {
    switch self {
    case .visible(let id, _), .tool(let id, _, _), .reasoning(let id, _),
      .transcript(let id, _):
      return id
    }
  }

  var isVisible: Bool {
    if case .visible = self { return true }
    return false
  }
}

private enum MessageRenderCache {
  private struct MarkdownCacheKey: Hashable {
    let messageID: UUID
    let partID: Int
  }

  private struct PreparedEntry {
    let text: String
    let content: PreparedMessageContent
    let incrementalBaseText: String
    let incrementalBaseContent: PreparedMessageContent?
  }

  private struct MarkdownEntry {
    let text: String
    let blocks: [MarkdownBlock]
  }

  private struct StreamingMarkdownEntry {
    let text: String
    let stableEndOffset: Int
    let stableBlocks: [MarkdownBlock]
  }

  private static let maxEntries = 160
  @MainActor private static var preparedEntries: [UUID: PreparedEntry] = [:]
  @MainActor private static var markdownEntries: [MarkdownCacheKey: MarkdownEntry] = [:]
  @MainActor private static var streamingMarkdownEntries:
    [MarkdownCacheKey: StreamingMarkdownEntry] = [:]
  @MainActor private static var preparedAccessOrder: [UUID] = []
  @MainActor private static var markdownAccessOrder: [MarkdownCacheKey] = []

  @MainActor
  static func preparedContent(messageID: UUID, text: String) -> PreparedMessageContent {
    if let entry = preparedEntries[messageID], entry.text == text {
      markAccessed(messageID)
      return entry.content
    }

    // Reasoning closed by a bare `</think>` reaches back into the prefix that was
    // already shown as prose, so that case re-parses the whole message instead.
    if let entry = preparedEntries[messageID],
      let baseContent = entry.incrementalBaseContent,
      !entry.incrementalBaseText.isEmpty,
      text.hasPrefix(entry.incrementalBaseText),
      case let suffix = substring(
        text,
        fromUTF16Offset: entry.incrementalBaseText.utf16.count,
        toUTF16Offset: text.utf16.count),
      !MessageContentFilter.beginsWithUnopenedReasoning(suffix)
    {
      let suffixContent = buildPreparedContent(
        text: suffix,
        partIDOffset: baseContent.parts.count)
      let content = mergedPreparedContent(baseContent, suffixContent)
      let isBoundary = isPreparedIncrementalBoundary(text)
      preparedEntries[messageID] = PreparedEntry(
        text: text,
        content: content,
        incrementalBaseText: isBoundary ? text : entry.incrementalBaseText,
        incrementalBaseContent: isBoundary ? content : baseContent)
      markAccessed(messageID)
      pruneIfNeeded()
      return content
    }

    let content = buildPreparedContent(text: text)
    let isBoundary = isPreparedIncrementalBoundary(text)
    preparedEntries[messageID] = PreparedEntry(
      text: text,
      content: content,
      incrementalBaseText: isBoundary ? text : "",
      incrementalBaseContent: isBoundary ? content : nil)
    markAccessed(messageID)
    pruneIfNeeded()
    return content
  }

  private static func buildPreparedContent(
    text: String,
    partIDOffset: Int = 0
  ) -> PreparedMessageContent {
    let rendered = MessageContentFilter.render(text)
    var parts: [MessageRenderPart] = []
    for part in rendered.parts {
      switch part.kind {
      case .visible(let visibleText):
        parts.append(.visible(id: partIDOffset + parts.count, text: visibleText))
      case .hidden(let section):
        switch section.tag {
        case "context", "tool_context", "tool_run":
          for entry in ToolCallParser.parse(section.content) {
            parts.append(
              .tool(id: partIDOffset + parts.count, entry: entry, section: section))
          }
        case "think":
          parts.append(.reasoning(id: partIDOffset + parts.count, section: section))
        case "conversation":
          parts.append(.transcript(id: partIDOffset + parts.count, section: section))
        default:
          break
        }
      }
    }
    let visibleEmpty = rendered.visibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let hasMeta = parts.contains {
      switch $0 {
      case .visible:
        return false
      case .tool, .reasoning, .transcript:
        return true
      }
    }
    let content = PreparedMessageContent(
      visibleText: rendered.visibleText,
      parts: parts,
      hideBubble: visibleEmpty && hasMeta
    )
    return content
  }

  @MainActor
  static func markdownBlocks(
    messageID: UUID,
    partID: Int = 0,
    text: String,
    isStreaming: Bool = false
  ) -> [MarkdownBlock] {
    let key = MarkdownCacheKey(messageID: messageID, partID: partID)
    if isStreaming {
      return streamingMarkdownBlocks(for: key, text: text)
    }

    if let entry = markdownEntries[key], entry.text == text {
      markAccessed(key)
      return entry.blocks
    }

    let blocks = MarkdownParser.blocks(from: text)
    markdownEntries[key] = MarkdownEntry(text: text, blocks: blocks)
    markAccessed(key)
    pruneIfNeeded()
    return blocks
  }

  @MainActor
  private static func streamingMarkdownBlocks(
    for key: MarkdownCacheKey,
    text: String
  ) -> [MarkdownBlock] {
    if let entry = streamingMarkdownEntries[key], text.hasPrefix(entry.text) {
      let newStableEndOffset = streamingStableEndOffset(in: text)
      if newStableEndOffset >= entry.stableEndOffset {
        var stableBlocks = entry.stableBlocks
        if newStableEndOffset > entry.stableEndOffset {
          let delta = substring(
            text,
            fromUTF16Offset: entry.stableEndOffset,
            toUTF16Offset: newStableEndOffset)
          stableBlocks.append(
            contentsOf: visibleMarkdownBlocks(from: delta, idOffset: stableBlocks.count))
        }
        let tail = substring(
          text,
          fromUTF16Offset: newStableEndOffset,
          toUTF16Offset: text.utf16.count)
        let blocks =
          stableBlocks + visibleMarkdownBlocks(from: tail, idOffset: stableBlocks.count)
        streamingMarkdownEntries[key] = StreamingMarkdownEntry(
          text: text,
          stableEndOffset: newStableEndOffset,
          stableBlocks: stableBlocks)
        markAccessed(key)
        pruneIfNeeded()
        return blocks
      }
    }

    let stableEndOffset = streamingStableEndOffset(in: text)
    let stableText = substring(
      text,
      fromUTF16Offset: 0,
      toUTF16Offset: stableEndOffset)
    let tailText = substring(
      text,
      fromUTF16Offset: stableEndOffset,
      toUTF16Offset: text.utf16.count)
    let stableBlocks = visibleMarkdownBlocks(from: stableText, idOffset: 0)
    let blocks =
      stableBlocks + visibleMarkdownBlocks(from: tailText, idOffset: stableBlocks.count)
    streamingMarkdownEntries[key] = StreamingMarkdownEntry(
      text: text,
      stableEndOffset: stableEndOffset,
      stableBlocks: stableBlocks)
    markAccessed(key)
    pruneIfNeeded()
    return blocks
  }

  @MainActor
  private static func markAccessed(_ id: UUID) {
    preparedAccessOrder.removeAll { $0 == id }
    preparedAccessOrder.append(id)
  }

  @MainActor
  private static func markAccessed(_ key: MarkdownCacheKey) {
    markdownAccessOrder.removeAll { $0 == key }
    markdownAccessOrder.append(key)
  }

  @MainActor
  private static func pruneIfNeeded() {
    while preparedAccessOrder.count > maxEntries, let oldest = preparedAccessOrder.first {
      preparedAccessOrder.removeFirst()
      preparedEntries.removeValue(forKey: oldest)
    }
    while markdownAccessOrder.count > maxEntries, let oldest = markdownAccessOrder.first {
      markdownAccessOrder.removeFirst()
      markdownEntries.removeValue(forKey: oldest)
      streamingMarkdownEntries.removeValue(forKey: oldest)
    }
  }

  private static func mergedPreparedContent(
    _ base: PreparedMessageContent,
    _ suffix: PreparedMessageContent
  ) -> PreparedMessageContent {
    let parts = base.parts + suffix.parts
    let visibleText = joinedVisibleText(base.visibleText, suffix.visibleText)
    let visibleEmpty = visibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let hasMeta = parts.contains {
      switch $0 {
      case .visible:
        return false
      case .tool, .reasoning, .transcript:
        return true
      }
    }
    return PreparedMessageContent(
      visibleText: visibleText,
      parts: parts,
      hideBubble: visibleEmpty && hasMeta)
  }

  private static func joinedVisibleText(_ first: String, _ second: String) -> String {
    let firstTrimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
    let secondTrimmed = second.trimmingCharacters(in: .whitespacesAndNewlines)
    if firstTrimmed.isEmpty { return secondTrimmed }
    if secondTrimmed.isEmpty { return firstTrimmed }
    return "\(firstTrimmed)\n\n\(secondTrimmed)"
  }

  private static func visibleMarkdownBlocks(from text: String, idOffset: Int) -> [MarkdownBlock] {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
    return MarkdownParser.blocks(from: text, idOffset: idOffset).filter { !$0.isVisiblyEmpty }
  }

  private static func streamingStableEndOffset(in text: String) -> Int {
    guard !text.isEmpty else { return 0 }

    var lineStart = text.startIndex
    var cursor = text.startIndex
    var inCode = false
    var stableEnd = text.startIndex

    while cursor < text.endIndex {
      var lineEnd = cursor
      while lineEnd < text.endIndex, text[lineEnd] != "\n", text[lineEnd] != "\r" {
        text.formIndex(after: &lineEnd)
      }

      let line = text[lineStart..<lineEnd]
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("```") {
        inCode.toggle()
      }

      var nextLineStart = lineEnd
      if nextLineStart < text.endIndex {
        if text[nextLineStart] == "\r" {
          text.formIndex(after: &nextLineStart)
          if nextLineStart < text.endIndex, text[nextLineStart] == "\n" {
            text.formIndex(after: &nextLineStart)
          }
        } else if text[nextLineStart] == "\n" {
          text.formIndex(after: &nextLineStart)
        }
      }

      if !inCode, trimmed.isEmpty {
        stableEnd = nextLineStart
      }

      guard nextLineStart > lineStart else { break }
      lineStart = nextLineStart
      cursor = nextLineStart
    }

    return stableEnd.utf16Offset(in: text)
  }

  private static func isPreparedIncrementalBoundary(_ text: String) -> Bool {
    guard !text.isEmpty else { return false }
    let tail = String(text.suffix(96)).lowercased()
    guard tail.contains("\n\n") || tail.contains("</") else { return false }
    guard !hasUnclosedHiddenTag(in: text) else { return false }
    if text.hasSuffix("\n\n") || text.hasSuffix("\r\n\r\n") {
      return true
    }
    let trimmedTail = tail.trimmingCharacters(in: .whitespacesAndNewlines)
    return hiddenClosingTags.contains { trimmedTail.hasSuffix($0) }
  }

  private static func hasUnclosedHiddenTag(in text: String) -> Bool {
    let lowercased = text.lowercased()
    for tag in hiddenTagNames {
      guard let opening = lowercased.range(of: "<\(tag)", options: .backwards) else {
        continue
      }
      let closing = lowercased.range(of: "</\(tag)>", options: .backwards)
      if closing == nil || opening.lowerBound > closing!.lowerBound {
        return true
      }
    }
    return false
  }

  private static func substring(
    _ text: String,
    fromUTF16Offset lowerOffset: Int,
    toUTF16Offset upperOffset: Int
  ) -> String {
    let lowerBound = String.Index(utf16Offset: lowerOffset, in: text)
    let upperBound = String.Index(utf16Offset: upperOffset, in: text)
    return String(text[lowerBound..<upperBound])
  }

  private static let hiddenTagNames = [
    "context", "tool_context", "tool_run", "tool_call", "think", "conversation", "speech",
  ]
  private static let hiddenClosingTags = hiddenTagNames.map { "</\($0)>" }
}

private struct FoldableMetaSection: View {
  let title: String
  let systemImage: String
  let content: String
  var monospaced: Bool
  var detail: String? = nil
  var collapsedStatus: String? = nil
  var collapsedPreviewLines: Int = 0
  var dimmedContent: Bool = false
  var initiallyExpanded: Bool = false
  var italicContent: Bool = false
  var markdownAppearance: AppearanceSettings? = nil
  var renderImages: Bool = true
  var onDelete: (() -> Void)? = nil

  @State private var expanded: Bool = false
  @State private var previewWidth: CGFloat = 280

  init(
    title: String,
    systemImage: String,
    content: String,
    monospaced: Bool,
    detail: String? = nil,
    collapsedStatus: String? = nil,
    collapsedPreviewLines: Int = 0,
    dimmedContent: Bool = false,
    initiallyExpanded: Bool = false,
    italicContent: Bool = false,
    markdownAppearance: AppearanceSettings? = nil,
    renderImages: Bool = true,
    onDelete: (() -> Void)? = nil
  ) {
    self.title = title
    self.systemImage = systemImage
    self.content = content
    self.monospaced = monospaced
    self.detail = detail
    self.collapsedStatus = collapsedStatus
    self.collapsedPreviewLines = max(0, collapsedPreviewLines)
    self.dimmedContent = dimmedContent
    self.initiallyExpanded = initiallyExpanded
    self.italicContent = italicContent
    self.markdownAppearance = markdownAppearance
    self.renderImages = renderImages
    self.onDelete = onDelete
    self._expanded = State(initialValue: initiallyExpanded)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(.snappy(duration: 0.18)) { expanded.toggle() }
      } label: {
        HStack(spacing: 8) {
          Image(systemName: systemImage)
            .imageScale(.small)
            .foregroundStyle(.secondary)
          Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          Spacer(minLength: 8)
          if let detail {
            Text(detail)
              .font(.caption2.monospacedDigit())
              .foregroundStyle(.tertiary)
              .lineLimit(1)
              .minimumScaleFactor(0.75)
          }
          Image(systemName: expanded ? "chevron.down" : "chevron.right")
            .imageScale(.small)
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      if !expanded, let collapsedStatus {
        Divider().opacity(0.4)
        Text(collapsedStatus)
          .font(.caption.italic())
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
      } else if !expanded, collapsedPreviewLines > 0 {
        Divider().opacity(0.4)
        let lines = ThinkingPreview.lines(
          content, count: collapsedPreviewLines,
          width: max(
            1,
            Int(
              previewWidth
                / (UIFont.preferredFont(forTextStyle: .caption1).pointSize * 0.65))))
        VStack(alignment: .leading, spacing: 2) {
          ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
            Text(line)
              .font(.system(.caption, design: .monospaced))
              .italic()
              .foregroundStyle(.secondary)
              .opacity(Double(index + 1) / Double(lines.count))
              .lineLimit(1)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onGeometryChange(for: CGFloat.self) {
          $0.size.width
        } action: {
          previewWidth = $0
        }
      } else if expanded {
        Divider().opacity(0.4)
        Group {
          if let markdownAppearance, MarkdownParser.mayContainMarkdown(content) {
            MarkdownContentView(
              text: content, appearance: markdownAppearance,
              allowsTextSelection: true,
              foregroundStyle: dimmedContent ? Color.secondary : nil,
              renderImages: renderImages,
              italic: italicContent)
          } else {
            let contentFont =
              (monospaced ? Font.system(.footnote, design: .monospaced) : Font.callout)
              .italicizedIf(italicContent)
            Text(content)
              .font(contentFont)
              .foregroundStyle(dimmedContent ? Color.secondary : Color.primary)
              .textSelection(.enabled)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
      }
    }
    .background(.thinMaterial.opacity(0.55))
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(.secondary.opacity(0.18), lineWidth: 0.5)
    )
    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .contextMenu {
      Button {
        UIPasteboard.general.string = content
      } label: {
        Label("Copy \(title)", systemImage: "doc.on.doc")
      }
      if let onDelete {
        Divider()
        Button(role: .destructive, action: onDelete) {
          Label("Delete \(title)", systemImage: "trash")
        }
      }
    } preview: {
      Color.clear
        .frame(width: 1, height: 1)
        .accessibilityHidden(true)
    }
    .onChange(of: initiallyExpanded) { _, expandedByDefault in
      expanded = expandedByDefault
    }
  }
}

private struct VoiceRecordingPlaybackButton: View {
  @EnvironmentObject private var ttsPlayer: TTSPlayer

  let message: ChatMessage

  private var isCurrent: Bool {
    ttsPlayer.currentMessageID == message.id && ttsPlayer.currentRole == .user
  }

  private var isPlaying: Bool {
    isCurrent && ttsPlayer.isSpeaking && !ttsPlayer.isPaused
  }

  private var systemImage: String {
    isPlaying ? "pause.circle.fill" : "play.circle.fill"
  }

  private var title: String {
    if isPlaying { return "Pause recording" }
    if isCurrent && ttsPlayer.isPaused { return "Resume recording" }
    return "Play recording"
  }

  var body: some View {
    Button {
      ttsPlayer.toggleRecordingPlayback(for: message, title: "User Recording")
    } label: {
      HStack(spacing: 8) {
        Image(systemName: systemImage)
          .font(.system(size: 30, weight: .semibold))
          .symbolRenderingMode(.hierarchical)
        Text(title)
          .font(.callout.weight(.semibold))
      }
      .padding(.vertical, 6)
      .padding(.horizontal, 8)
      .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .buttonStyle(.borderless)
    .foregroundStyle(Color.accentColor)
    .accessibilityLabel(title)
  }
}

private struct ToolCallRow: View {
  let entry: ToolEntry
  /// Applies an edited tool block back onto the message. Nil while the response
  /// is still streaming, or when the message itself is not editable.
  var onEdit: ((String) -> Void)? = nil
  var onDelete: (() -> Void)? = nil
  @State private var expanded = false
  @State private var previewDocument: ToolPreviewDocument?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(.snappy(duration: 0.18)) { expanded.toggle() }
      } label: {
        HStack(spacing: 8) {
          Image(systemName: entry.systemImage)
            .imageScale(.small)
            .foregroundStyle(Color.accentColor)
          Text(entry.name)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
          if !entry.params.isEmpty {
            Text(Self.collapsedParams(for: entry.params))
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          Spacer(minLength: 8)
          Image(systemName: expanded ? "chevron.down" : "chevron.right")
            .imageScale(.small)
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      if expanded {
        Divider().opacity(0.4)
        VStack(alignment: .leading, spacing: 8) {
          toolSection(label: "Input", value: entry.params, emptyText: "(no input)")
          toolSection(label: "Output", value: entry.body, emptyText: "(no output)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
      }
    }
    .sheet(item: $previewDocument) { document in
      MessageTextSelectionSheet(
        title: document.title,
        text: document.text,
        initialFontSize: 13,
        initialLineSpacing: 2,
        fontFamily: .monospaced,
        isEditable: document.isEditable,
        onSave: document.isEditable ? onEdit : nil)
    }
    .background(.thinMaterial.opacity(0.55))
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(Color.accentColor.opacity(0.18), lineWidth: 0.5)
    )
    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .contextMenu {
      toolContextMenu()
    } preview: {
      Color.clear
        .frame(width: 1, height: 1)
        .accessibilityHidden(true)
    }
  }

  @ViewBuilder
  private func toolContextMenu() -> some View {
    Button {
      UIPasteboard.general.string = entry.copyText
    } label: {
      Label("Copy Tool Call", systemImage: "doc.on.doc")
    }
    if !entry.params.isEmpty {
      Button {
        UIPasteboard.general.string = entry.params
      } label: {
        Label("Copy Input", systemImage: "arrow.down.doc")
      }
    }
    if Self.hasVisibleContent(entry.body) {
      Button {
        UIPasteboard.general.string = entry.body
      } label: {
        Label("Copy Output", systemImage: "arrow.up.doc")
      }
    }

    Divider()

    Button {
      previewDocument = ToolPreviewDocument(
        title: entry.name,
        text: entry.rawBlock,
        isEditable: onEdit != nil)
    } label: {
      Label(
        onEdit == nil ? "View Tool Call" : "Edit Tool Call",
        systemImage: onEdit == nil ? "text.cursor" : "square.and.pencil")
    }
    if Self.hasVisibleContent(entry.body) {
      Button {
        previewDocument = ToolPreviewDocument(title: "Output", text: entry.body)
      } label: {
        Label("View Output", systemImage: "doc.text.magnifyingglass")
      }
    }
    if let onDelete {
      Divider()
      Button(role: .destructive, action: onDelete) {
        Label("Delete Tool Call", systemImage: "trash")
      }
    }
  }

  @ViewBuilder
  private func toolSection(label: String, value: String, emptyText: String) -> some View {
    let hasValue = Self.hasVisibleContent(value)
    let byteCount = value.utf8.count
    let isLarge = byteCount > Self.largeValueThreshold
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Text(label)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        if hasValue, isLarge {
          Text(Self.sizeLabel(byteCount: byteCount))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
        }
        Spacer(minLength: 8)
        if hasValue, isLarge {
          Button {
            previewDocument = ToolPreviewDocument(title: label, text: value)
          } label: {
            Image(systemName: "doc.text.magnifyingglass")
          }
          .buttonStyle(.borderless)
          .help("View full \(label.lowercased())")

          Button {
            UIPasteboard.general.string = value
          } label: {
            Image(systemName: "doc.on.doc")
          }
          .buttonStyle(.borderless)
          .help("Copy \(label.lowercased())")
        }
      }

      if !hasValue {
        Text(emptyText)
          .font(.system(.footnote, design: .monospaced))
          .foregroundStyle(Color.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else if isLarge {
        Text(Self.previewText(for: value))
          .font(.system(.footnote, design: .monospaced))
          .foregroundStyle(Color.secondary)
          .lineLimit(Self.previewLineLimit)
          .truncationMode(.tail)
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        Text(value)
          .font(.system(.footnote, design: .monospaced))
          .foregroundStyle(Color.primary)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private static let largeValueThreshold = 12_000
  private static let collapsedParamsLimit = 180
  private static let previewCharacterLimit = 4_000
  private static let previewLineLimit = 80

  private static func hasVisibleContent(_ value: String) -> Bool {
    value.contains { !$0.isWhitespace }
  }

  private static func collapsedParams(for value: String) -> String {
    let prefix = value.prefix(collapsedParamsLimit)
    guard prefix.endIndex < value.endIndex else { return value }
    return String(prefix) + "..."
  }

  private static func sizeLabel(byteCount: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
  }

  private static func previewText(for value: String) -> String {
    var output = ""
    var characterCount = 0
    var lineCount = 0
    var index = value.startIndex

    while index < value.endIndex,
      characterCount < previewCharacterLimit,
      lineCount < previewLineLimit
    {
      let character = value[index]
      output.append(character)
      characterCount += 1
      value.formIndex(after: &index)
      if character == "\n" {
        lineCount += 1
      }
    }

    if index < value.endIndex {
      if !output.hasSuffix("\n") {
        output.append("\n")
      }
      output.append("...")
    }
    return output
  }
}

private struct ToolPreviewDocument: Identifiable {
  let id = UUID()
  let title: String
  let text: String
  var isEditable: Bool = false
}

struct ToolEntry: Identifiable {
  let id: String
  let name: String
  let params: String
  let body: String
  let systemImage: String
  /// Verbatim slice of the message this entry was parsed from, so edits can be
  /// written back into the message without touching the surrounding text.
  let rawBlock: String

  var copyText: String {
    let header = params.isEmpty ? "\(name) tool:" : "\(name) tool (\(params)):"
    return body.isEmpty ? header : "\(header)\n\(body)"
  }
}

enum ToolCallParser {
  static func parse(_ text: String) -> [ToolEntry] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }

    var entries: [ToolEntry] = []
    var currentHeader: String? = nil
    var currentBody: [String] = []
    var currentRawLines: [String] = []

    func flush() {
      guard let header = currentHeader else { return }
      let body = currentBody.joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if let entry = makeEntry(
        index: entries.count,
        header: header,
        body: body,
        rawBlock: currentRawLines.joined(separator: "\n"))
      {
        entries.append(entry)
      }
      currentHeader = nil
      currentBody.removeAll()
      currentRawLines.removeAll()
    }

    for line in trimmed.components(separatedBy: "\n") {
      if isToolHeader(line) {
        flush()
        currentHeader = line.trimmingCharacters(in: .whitespaces)
        currentRawLines.append(line)
      } else if currentHeader != nil {
        currentBody.append(line)
        currentRawLines.append(line)
      }
    }
    flush()
    return entries
  }

  private static func isToolHeader(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasSuffix(":") else { return false }
    let stem = String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)
    guard let toolRange = stem.range(of: " tool", options: [.caseInsensitive]) else {
      return false
    }
    let name = String(stem[..<toolRange.lowerBound]).trimmingCharacters(in: .whitespaces)
    let suffix = String(stem[toolRange.upperBound...]).trimmingCharacters(in: .whitespaces)
    return !name.isEmpty && (suffix.isEmpty || (suffix.hasPrefix("(") && suffix.hasSuffix(")")))
  }

  private static func makeEntry(
    index: Int,
    header: String,
    body: String,
    rawBlock: String
  ) -> ToolEntry? {
    guard let toolRange = header.range(of: " tool", options: [.caseInsensitive]) else {
      return nil
    }
    let name = String(header[..<toolRange.lowerBound])
      .trimmingCharacters(in: .whitespaces)
    let after = String(header[toolRange.upperBound...])
      .trimmingCharacters(in: CharacterSet(charactersIn: " \t:"))
    var params = ""
    if after.hasPrefix("(") && after.hasSuffix(")") {
      params = String(after.dropFirst().dropLast())
    } else if !after.isEmpty {
      params = after
    }
    return ToolEntry(
      id: "\(index):\(header)",
      name: name.isEmpty ? "Tool" : name,
      params: params,
      body: body,
      systemImage: icon(for: name),
      rawBlock: rawBlock
    )
  }

  private static func icon(for name: String) -> String {
    if name.lowercased().hasPrefix("github") {
      return "arrow.triangle.branch"
    }
    if name.lowercased().hasPrefix("agent_") {
      return "person.2"
    }
    switch name.lowercased() {
    case "date & time": return "clock"
    case "location": return "location"
    case "weather": return "cloud.sun"
    case "web search": return "magnifyingglass"
    case "todo": return "checklist"
    case "files": return "folder"
    case "clipboard": return "doc.on.clipboard"
    case "alarms": return "alarm"
    case "webxdc apps": return "square.grid.2x2"
    case "memory": return "brain"
    default: return "wrench.and.screwdriver"
    }
  }
}

struct MarkdownContentView: View {
  let blocks: [MarkdownBlock]
  let appearance: AppearanceSettings
  let fontFamily: AppearanceFontFamily
  let allowsTextSelection: Bool
  let foregroundStyle: Color?
  let uiForegroundColor: UIColor?
  let renderImages: Bool
  let italic: Bool

  init(
    text: String,
    appearance: AppearanceSettings = .defaults,
    fontFamily: AppearanceFontFamily? = nil,
    allowsTextSelection: Bool = true,
    foregroundStyle: Color? = nil,
    uiForegroundColor: UIColor? = nil,
    renderImages: Bool = true,
    italic: Bool = false
  ) {
    self.blocks = MarkdownParser.blocks(from: text)
    self.appearance = appearance
    self.fontFamily = fontFamily ?? appearance.assistantFontFamily
    self.allowsTextSelection = allowsTextSelection
    self.foregroundStyle = foregroundStyle
    self.uiForegroundColor = uiForegroundColor
    self.renderImages = renderImages
    self.italic = italic
  }

  init(
    blocks: [MarkdownBlock],
    appearance: AppearanceSettings = .defaults,
    fontFamily: AppearanceFontFamily? = nil,
    allowsTextSelection: Bool = true,
    foregroundStyle: Color? = nil,
    uiForegroundColor: UIColor? = nil,
    renderImages: Bool = true,
    italic: Bool = false
  ) {
    self.blocks = blocks
    self.appearance = appearance
    self.fontFamily = fontFamily ?? appearance.assistantFontFamily
    self.allowsTextSelection = allowsTextSelection
    self.foregroundStyle = foregroundStyle
    self.uiForegroundColor = uiForegroundColor
    self.renderImages = renderImages
    self.italic = italic
  }

  var body: some View {
    VStack(alignment: .leading, spacing: appearance.markdownMetric(10)) {
      ForEach(blocks) { block in
        switch block.kind {
        case .heading(let level, let value):
          MarkdownInlineText(
            value: value,
            appearance: appearance,
            font: headingFont(level: level),
            uiFont: headingUIFont(level: level),
            allowsTextSelection: allowsTextSelection,
            foregroundStyle: foregroundStyle,
            uiForegroundColor: uiForegroundColor,
            italic: italic
          )
          .fixedSize(horizontal: false, vertical: true)
        case .text(let value):
          MarkdownInlineText(
            value: value,
            appearance: appearance,
            font: fontFamily.swiftUIFont(size: appearance.fontSize),
            uiFont: fontFamily.uiFont(size: appearance.fontSize),
            allowsTextSelection: allowsTextSelection,
            foregroundStyle: bodyForegroundStyle,
            uiForegroundColor: bodyUIForegroundColor,
            italic: italic
          )
          .fixedSize(horizontal: false, vertical: true)
        case .blockquote(let value):
          BlockquoteView(
            text: value,
            appearance: appearance,
            fontFamily: fontFamily,
            allowsTextSelection: allowsTextSelection,
            italic: italic)
        case .horizontalRule:
          MarkdownHorizontalRuleView(appearance: appearance)
        case .code(let language, let code):
          CodeBlockView(
            language: language,
            code: code,
            appearance: appearance,
            allowsTextSelection: allowsTextSelection)
        case .mermaid(let source):
          MermaidBlockView(
            source: source,
            appearance: appearance,
            allowsTextSelection: allowsTextSelection)
        case .table(let headers, let rows, let alignments):
          MarkdownTableView(
            headers: headers,
            rows: rows,
            alignments: alignments,
            appearance: appearance,
            fontFamily: fontFamily,
            allowsTextSelection: allowsTextSelection,
            foregroundStyle: bodyForegroundStyle,
            uiForegroundColor: bodyUIForegroundColor,
            italic: italic
          )
        case .taskList(let items):
          TaskListView(
            items: items,
            appearance: appearance,
            fontFamily: fontFamily,
            allowsTextSelection: allowsTextSelection,
            foregroundStyle: bodyForegroundStyle,
            uiForegroundColor: bodyUIForegroundColor,
            italic: italic)
        case .bulletList(let items):
          BulletListView(
            items: items,
            appearance: appearance,
            fontFamily: fontFamily,
            allowsTextSelection: allowsTextSelection,
            foregroundStyle: bodyForegroundStyle,
            uiForegroundColor: bodyUIForegroundColor,
            italic: italic)
        case .orderedList(let items):
          OrderedListView(
            items: items,
            appearance: appearance,
            fontFamily: fontFamily,
            allowsTextSelection: allowsTextSelection,
            foregroundStyle: bodyForegroundStyle,
            uiForegroundColor: bodyUIForegroundColor,
            italic: italic)
        case .footnotes(let items):
          FootnotesView(
            items: items,
            appearance: appearance,
            fontFamily: fontFamily,
            allowsTextSelection: allowsTextSelection,
            foregroundStyle: bodyForegroundStyle,
            uiForegroundColor: bodyUIForegroundColor,
            italic: italic)
        }
      }
    }
    .environment(\.markdownRenderImages, renderImages)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // Body copy is dimmed by default so headings and bold runs stand out; an
  // explicit caller-provided color (e.g. a blockquote's secondary tint) wins.
  private var bodyForegroundStyle: Color { foregroundStyle ?? markdownBodyColor }
  private var bodyUIForegroundColor: UIColor { uiForegroundColor ?? markdownBodyUIColor }

  private func headingMetrics(level: Int) -> (scale: Double, heavy: Bool) {
    let clampedLevel = min(max(level, 1), 6)
    let scale: Double =
      switch clampedLevel {
      case 1: 1.55
      case 2: 1.32
      case 3: 1.16
      case 4: 1.04
      case 5: 0.96
      default: 0.88
      }
    return (scale, clampedLevel == 1)
  }

  private func headingFont(level: Int) -> Font {
    let metrics = headingMetrics(level: level)
    return fontFamily.swiftUIFont(size: appearance.fontSize * metrics.scale)
      .weight(metrics.heavy ? .bold : .semibold)
  }

  private func headingUIFont(level: Int) -> UIFont {
    let metrics = headingMetrics(level: level)
    return fontFamily.uiFont(size: appearance.fontSize * metrics.scale)
      .withWeight(metrics.heavy ? .bold : .semibold)
  }
}

private struct MarkdownHorizontalRuleView: View {
  let appearance: AppearanceSettings

  var body: some View {
    Rectangle()
      .fill(Color.secondary.opacity(0.5))
      .frame(height: max(CGFloat(0.5), appearance.markdownMetric(0.75)))
      .frame(maxWidth: .infinity)
      .padding(.vertical, appearance.markdownMetric(7))
      .accessibilityHidden(true)
  }
}

private struct MarkdownInlineText: View {
  @Environment(\.markdownRenderImages) private var renderMarkdownImages

  let value: String
  let appearance: AppearanceSettings
  let font: Font
  let uiFont: UIFont
  let allowsTextSelection: Bool
  var textAlignment: TextAlignment = .leading
  var foregroundStyle: Color? = nil
  var uiForegroundColor: UIColor? = nil
  var strikethrough: Bool = false
  var allowsJustification: Bool = true
  var allowsPlatformTextView: Bool = true
  var italic: Bool = false

  var body: some View {
    let segments = renderMarkdownImages ? MarkdownInlineImageScanner.segments(in: value) : []
    if renderMarkdownImages && segments.containsImage {
      MarkdownInlineSegmentedText(
        segments: segments,
        appearance: appearance,
        font: font,
        uiFont: uiFont,
        allowsTextSelection: allowsTextSelection,
        textAlignment: textAlignment,
        foregroundStyle: foregroundStyle,
        uiForegroundColor: uiForegroundColor,
        strikethrough: strikethrough,
        allowsJustification: allowsJustification,
        allowsPlatformTextView: allowsPlatformTextView,
        italic: italic)
    } else {
      MarkdownPlainInlineText(
        value: value,
        appearance: appearance,
        font: font,
        uiFont: uiFont,
        allowsTextSelection: allowsTextSelection,
        textAlignment: textAlignment,
        foregroundStyle: foregroundStyle,
        uiForegroundColor: uiForegroundColor,
        strikethrough: strikethrough,
        allowsJustification: allowsJustification,
        allowsPlatformTextView: allowsPlatformTextView,
        italic: italic)
    }
  }
}

private struct MarkdownInlineSegmentedText: View {
  let segments: [MarkdownInlineSegment]
  let appearance: AppearanceSettings
  let font: Font
  let uiFont: UIFont
  let allowsTextSelection: Bool
  let textAlignment: TextAlignment
  let foregroundStyle: Color?
  let uiForegroundColor: UIColor?
  let strikethrough: Bool
  let allowsJustification: Bool
  let allowsPlatformTextView: Bool
  let italic: Bool

  var body: some View {
    VStack(alignment: frameAlignment, spacing: appearance.markdownMetric(6)) {
      ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
        switch segment {
        case .text(let text):
          if !text.trimmingCharacters(in: .newlines).isEmpty {
            MarkdownPlainInlineText(
              value: text,
              appearance: appearance,
              font: font,
              uiFont: uiFont,
              allowsTextSelection: allowsTextSelection,
              textAlignment: textAlignment,
              foregroundStyle: foregroundStyle,
              uiForegroundColor: uiForegroundColor,
              strikethrough: strikethrough,
              allowsJustification: allowsJustification,
              allowsPlatformTextView: allowsPlatformTextView,
              italic: italic
            )
            .frame(maxWidth: .infinity, alignment: swiftUIAlignment)
          }
        case .image(let image):
          MarkdownImageView(image: image, appearance: appearance)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
  }

  private var frameAlignment: HorizontalAlignment {
    switch textAlignment {
    case .center: return .center
    case .trailing: return .trailing
    default: return .leading
    }
  }

  private var swiftUIAlignment: Alignment {
    switch textAlignment {
    case .center: return .center
    case .trailing: return .trailing
    default: return .leading
    }
  }
}

private struct MarkdownPlainInlineText: View {
  @Environment(\.isFullChatScreenshotRendering) private var isFullChatScreenshotRendering

  let value: String
  let appearance: AppearanceSettings
  let font: Font
  let uiFont: UIFont
  let allowsTextSelection: Bool
  var textAlignment: TextAlignment = .leading
  var foregroundStyle: Color? = nil
  var uiForegroundColor: UIColor? = nil
  var strikethrough: Bool = false
  var allowsJustification: Bool = true
  var allowsPlatformTextView: Bool = true
  var italic: Bool = false

  var body: some View {
    let justified = allowsJustification && appearance.justifyText && textAlignment.isLeading
    let containsLink = MarkdownInlineLinkScanner.containsLink(value)
    // Links are rendered through the UITextView-backed view so taps and
    // link long-presses are handled before the bubble background menu.
    if textAlignment.isLeading && allowsPlatformTextView && !isFullChatScreenshotRendering
      && (justified || containsLink)
    {
      JustifiedMarkdownTextView(
        value: value,
        font: uiFont.italicizedIf(italic),
        lineSpacing: appearance.lineSpacing,
        alignment: justified ? .justified : .natural,
        allowsTextSelection: allowsTextSelection,
        allowsLinkInteraction: containsLink,
        foregroundColor: uiForegroundColor ?? .label,
        strikethrough: strikethrough
      )
      .frame(maxWidth: .infinity, alignment: .leading)
      .alignmentGuide(.firstTextBaseline) { dimensions in
        dimensions[.top] + uiFont.ascender
      }
    } else {
      let effectiveFont = font.italicizedIf(italic)
      Text(attributedInlineMarkdown(value, strongFont: effectiveFont.bold()))
        .font(effectiveFont)
        .lineSpacing(CGFloat(appearance.lineSpacing))
        .multilineTextAlignment(textAlignment)
        .foregroundStyleIfPresent(foregroundStyle)
        .strikethrough(strikethrough, color: .secondary)
        .textSelectionIfEnabled(allowsTextSelection)
    }
  }
}

private struct MarkdownImageView: View {
  let image: MarkdownInlineImage
  let appearance: AppearanceSettings

  var body: some View {
    if let url = image.url {
      MarkdownRemoteImageView(image: image, url: url, appearance: appearance)
    } else {
      MarkdownImageFailureView(image: image, appearance: appearance)
        .accessibilityLabel(accessibilityLabel)
    }
  }

  private var accessibilityLabel: String {
    image.altText.isEmpty ? "Markdown image" : image.altText
  }
}

private struct MarkdownRemoteImageView: View {
  let image: MarkdownInlineImage
  let url: URL
  let appearance: AppearanceSettings

  @StateObject private var loader = MarkdownRemoteImageLoader()
  @State private var imageSaveNotice: ImageSaveNotice?
  @State private var showingFullscreenImage = false

  var body: some View {
    Group {
      switch loader.phase {
      case .idle, .loading:
        MarkdownImagePlaceholderView()
      case .success(let uiImage, let data):
        Button {
          showingFullscreenImage = true
        } label: {
          Image(uiImage: uiImage)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: 320, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
          Button {
            saveImage()
          } label: {
            Label("Save Image", systemImage: "square.and.arrow.down")
          }
        }
        .fullScreenCover(isPresented: $showingFullscreenImage) {
          MessageImageFullscreenView(image: uiImage, imageData: data)
        }
      case .failure:
        MarkdownImageFailureView(image: image, appearance: appearance)
      }
    }
    .task(id: url) {
      await loader.load(url)
    }
    .accessibilityLabel(accessibilityLabel)
    .imageSaveNotice($imageSaveNotice)
  }

  private var accessibilityLabel: String {
    image.altText.isEmpty ? "Markdown image" : image.altText
  }

  private func saveImage() {
    Task {
      do {
        let data = try await loader.imageData(for: url)
        try await MessageAttachmentImage.saveImageDataToPhotoLibrary(data)
        await MainActor.run {
          imageSaveNotice = .success()
        }
      } catch {
        await MainActor.run {
          imageSaveNotice = .failure(error.imageSaveMessage)
        }
      }
    }
  }
}

private struct MarkdownImagePlaceholderView: View {
  var body: some View {
    ProgressView()
      .controlSize(.regular)
      .frame(maxWidth: .infinity, minHeight: 96)
      .background(Color.secondary.opacity(0.08))
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      .overlay(border)
  }

  private var border: some View {
    RoundedRectangle(cornerRadius: 10, style: .continuous)
      .strokeBorder(.secondary.opacity(0.18), lineWidth: 1)
  }
}

private struct MarkdownImageFailureView: View {
  let image: MarkdownInlineImage
  let appearance: AppearanceSettings

  var body: some View {
    if let url = image.url {
      Link(destination: url) {
        HStack(spacing: appearance.markdownMetric(10)) {
          Image(systemName: "link")
            .font(.system(size: appearance.fontSize * 1.25, weight: .medium))
            .foregroundStyle(Color.accentColor)
            .frame(width: appearance.markdownMetric(34), height: appearance.markdownMetric(34))

          VStack(alignment: .leading, spacing: 2) {
            Text(image.altText.isEmpty ? "Open link" : image.altText)
              .font(.system(size: appearance.fontSize * 0.92, weight: .semibold))
              .foregroundStyle(.primary)
              .lineLimit(2)
            Text(image.source)
              .font(.system(size: max(10, appearance.fontSize * 0.76)))
              .foregroundStyle(Color.accentColor)
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }
        .padding(.horizontal, appearance.markdownMetric(10))
        .padding(.vertical, appearance.markdownMetric(9))
        .frame(maxWidth: .infinity, minHeight: appearance.markdownMetric(58), alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(border)
      }
      .buttonStyle(.plain)
    } else {
      HStack(spacing: appearance.markdownMetric(10)) {
        ZStack(alignment: .bottomTrailing) {
          Image(systemName: "photo")
            .font(.system(size: appearance.fontSize * 1.45, weight: .regular))
            .foregroundStyle(.secondary)
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: max(9, appearance.fontSize * 0.58), weight: .semibold))
            .foregroundStyle(.orange)
            .background(Circle().fill(Color(uiColor: .systemBackground)))
            .offset(x: 4, y: 3)
        }
        .frame(width: appearance.markdownMetric(34), height: appearance.markdownMetric(34))

        VStack(alignment: .leading, spacing: 2) {
          Text(image.altText.isEmpty ? "Image unavailable" : image.altText)
            .font(.system(size: appearance.fontSize * 0.92, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(2)
          Text(image.source)
            .font(.system(size: max(10, appearance.fontSize * 0.76)))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      .padding(.horizontal, appearance.markdownMetric(10))
      .padding(.vertical, appearance.markdownMetric(9))
      .frame(maxWidth: .infinity, minHeight: appearance.markdownMetric(58), alignment: .leading)
      .background(Color.secondary.opacity(0.08))
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      .overlay(border)
    }
  }

  private var border: some View {
    RoundedRectangle(cornerRadius: 10, style: .continuous)
      .strokeBorder(.secondary.opacity(0.18), lineWidth: 1)
  }
}

@MainActor
private final class MarkdownRemoteImageLoader: ObservableObject {
  enum Phase {
    case idle
    case loading
    case success(UIImage, Data)
    case failure
  }

  @Published private(set) var phase: Phase = .idle
  private var currentURL: URL?

  func load(_ url: URL) async {
    if currentURL == url {
      switch phase {
      case .loading, .success:
        return
      case .idle, .failure:
        break
      }
    }

    currentURL = url
    phase = .loading

    do {
      let imageData = try await Self.imageDataAndDecodedImage(from: url)
      guard currentURL == url else { return }
      phase = .success(imageData.image, imageData.data)
    } catch is CancellationError {
    } catch {
      guard currentURL == url else { return }
      phase = .failure
    }
  }

  func imageData(for url: URL) async throws -> Data {
    if currentURL == url, case .success(_, let data) = phase {
      return data
    }
    return try await Self.imageDataAndDecodedImage(from: url).data
  }

  private static func imageDataAndDecodedImage(from url: URL) async throws -> (
    data: Data, image: UIImage
  ) {
    let (data, response) = try await URLSession.shared.data(from: url)
    if let httpResponse = response as? HTTPURLResponse,
      !(200..<300).contains(httpResponse.statusCode)
    {
      throw MessageImageSaveError("The image could not be downloaded.")
    }
    guard let image = UIImage(data: data) else {
      throw MessageImageSaveError("This image could not be decoded.")
    }
    return (data, image)
  }
}

private enum MarkdownInlineSegment: Equatable {
  case text(String)
  case image(MarkdownInlineImage)
}

extension [MarkdownInlineSegment] {
  fileprivate var containsImage: Bool {
    contains {
      if case .image = $0 { return true }
      return false
    }
  }
}

private struct MarkdownInlineImage: Equatable {
  let altText: String
  let source: String

  var url: URL? {
    MarkdownWebURL.url(from: source)
  }
}

private enum MarkdownInlineImageScanner {
  @MainActor private static var cachedSegments: [String: [MarkdownInlineSegment]] = [:]

  @MainActor
  static func segments(in value: String) -> [MarkdownInlineSegment] {
    guard value.contains("![") else { return [.text(value)] }
    if let cached = cachedSegments[value] { return cached }

    let chars = Array(value)
    var segments: [MarkdownInlineSegment] = []
    var textStart = 0
    var index = 0

    while index < chars.count {
      if let codeSpan = MarkdownInlineCodeSpan.span(in: chars, at: index) {
        index = codeSpan.end
        continue
      }

      guard let image = imageToken(in: chars, at: index) else {
        index += 1
        continue
      }

      appendText(chars, range: textStart..<index, to: &segments)
      segments.append(.image(image.value))
      index = image.end
      textStart = index
    }

    appendText(chars, range: textStart..<chars.count, to: &segments)
    let result = segments.isEmpty ? [.text(value)] : segments
    if cachedSegments.count >= 128 {
      cachedSegments.removeAll(keepingCapacity: true)
    }
    cachedSegments[value] = result
    return result
  }

  private static func imageToken(in chars: [Character], at index: Int)
    -> (value: MarkdownInlineImage, end: Int)?
  {
    guard index + 1 < chars.count,
      chars[index] == "!",
      chars[index + 1] == "[",
      !isEscaped(chars, at: index),
      let altEnd = findImageAltEnd(in: chars, start: index + 2),
      altEnd + 1 < chars.count,
      chars[altEnd + 1] == "(",
      let destinationEnd = findImageDestinationEnd(in: chars, start: altEnd + 2)
    else {
      return nil
    }

    let alt = String(chars[(index + 2)..<altEnd])
    let destination = String(chars[(altEnd + 2)..<destinationEnd])
    guard let source = imageSource(from: destination) else { return nil }
    return (MarkdownInlineImage(altText: alt, source: source), destinationEnd + 1)
  }

  private static func appendText(
    _ chars: [Character],
    range: Range<Int>,
    to segments: inout [MarkdownInlineSegment]
  ) {
    guard !range.isEmpty else { return }
    segments.append(.text(String(chars[range])))
  }

  private static func imageSource(from destination: String) -> String? {
    let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if trimmed.first == "<", let close = trimmed.firstIndex(of: ">") {
      let start = trimmed.index(after: trimmed.startIndex)
      guard start <= close else { return nil }
      return String(trimmed[start..<close])
    }

    let chars = Array(trimmed)
    var end = 0
    while end < chars.count, !chars[end].isWhitespace {
      end += 1
    }
    guard end > 0 else { return nil }
    return String(chars[0..<end])
      .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
  }

  private static func findImageAltEnd(in chars: [Character], start: Int) -> Int? {
    var index = start
    while index < chars.count {
      if chars[index] == "\\" {
        index += 2
        continue
      }
      if chars[index] == "]" {
        return index
      }
      if chars[index] == "\n" || chars[index] == "\r" {
        return nil
      }
      index += 1
    }
    return nil
  }

  private static func findImageDestinationEnd(in chars: [Character], start: Int) -> Int? {
    var depth = 0
    var index = start
    while index < chars.count {
      if chars[index] == "\\" {
        index += 2
        continue
      }
      if chars[index] == "\n" || chars[index] == "\r" {
        return nil
      }
      if chars[index] == "(" {
        depth += 1
      } else if chars[index] == ")" {
        if depth == 0 {
          return index
        }
        depth -= 1
      }
      index += 1
    }
    return nil
  }

  private static func isEscaped(_ chars: [Character], at index: Int) -> Bool {
    guard index > 0 else { return false }
    var slashCount = 0
    var cursor = index - 1
    while cursor >= 0, chars[cursor] == "\\" {
      slashCount += 1
      cursor -= 1
    }
    return slashCount % 2 == 1
  }
}

extension TextAlignment {
  fileprivate var isLeading: Bool {
    switch self {
    case .leading: true
    default: false
    }
  }
}

private struct JustifiedMarkdownTextView: UIViewRepresentable {
  let value: String
  let font: UIFont
  let lineSpacing: Double
  var alignment: NSTextAlignment = .justified
  let allowsTextSelection: Bool
  let allowsLinkInteraction: Bool
  let foregroundColor: UIColor
  let strikethrough: Bool

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> LinkHitTestingTextView {
    let textView = LinkHitTestingTextView()
    textView.backgroundColor = .clear
    textView.isEditable = false
    textView.isScrollEnabled = false
    textView.textContainerInset = .zero
    textView.textContainer.lineFragmentPadding = 0
    textView.textContainer.lineBreakMode = .byWordWrapping
    textView.adjustsFontForContentSizeCategory = true
    textView.delegate = context.coordinator
    // Links keep the app tint but are also underlined.
    textView.linkTextAttributes = [
      .foregroundColor: UIColor.tintColor,
      .underlineStyle: NSUnderlineStyle.single.rawValue,
    ]
    textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    textView.setContentHuggingPriority(.defaultHigh, for: .vertical)
    return textView
  }

  func updateUIView(_ textView: LinkHitTestingTextView, context: Context) {
    configure(textView, coordinator: context.coordinator)
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize,
    uiView textView: LinkHitTestingTextView,
    context: Context
  )
    -> CGSize?
  {
    configure(textView, coordinator: context.coordinator)
    guard let width = proposal.width, width.isFinite, width > 0 else {
      return nil
    }
    let height = textView.sizeThatFits(
      CGSize(width: width, height: .greatestFiniteMagnitude)
    ).height
    return CGSize(width: width, height: ceil(height))
  }

  private func configure(_ textView: LinkHitTestingTextView, coordinator: Coordinator) {
    if coordinator.needsAttributedTextUpdate(
      value: value,
      font: font,
      lineSpacing: lineSpacing,
      alignment: alignment,
      foregroundColor: foregroundColor,
      strikethrough: strikethrough)
    {
      textView.attributedText = nsAttributedInlineMarkdown(
        value,
        font: font,
        lineSpacing: lineSpacing,
        alignment: alignment,
        foregroundColor: foregroundColor,
        strikethrough: strikethrough)
    }
    textView.allowsTextInteraction = allowsTextSelection
    textView.allowsLinkInteraction = allowsLinkInteraction
    textView.textDragInteraction?.isEnabled = allowsTextSelection
    textView.isSelectable = allowsTextSelection || allowsLinkInteraction
    textView.isUserInteractionEnabled = allowsTextSelection || allowsLinkInteraction
  }

  final class Coordinator: NSObject, UITextViewDelegate {
    private var value: String?
    private var font: UIFont?
    private var lineSpacing: Double?
    private var alignment: NSTextAlignment?
    private var foregroundColor: UIColor?
    private var strikethrough: Bool?

    func needsAttributedTextUpdate(
      value: String,
      font: UIFont,
      lineSpacing: Double,
      alignment: NSTextAlignment,
      foregroundColor: UIColor,
      strikethrough: Bool
    ) -> Bool {
      guard self.value == value,
        self.font?.isEqual(font) == true,
        self.lineSpacing == lineSpacing,
        self.alignment == alignment,
        self.foregroundColor?.isEqual(foregroundColor) == true,
        self.strikethrough == strikethrough
      else {
        self.value = value
        self.font = font
        self.lineSpacing = lineSpacing
        self.alignment = alignment
        self.foregroundColor = foregroundColor
        self.strikethrough = strikethrough
        return true
      }
      return false
    }

    func textView(
      _ textView: UITextView,
      primaryActionFor textItem: UITextItem,
      defaultAction: UIAction
    ) -> UIAction? {
      return defaultAction
    }

    // Long-pressing a link offers a "Copy Link" action only. Returning a
    // configuration without a preview avoids the default link preview, which
    // would otherwise fetch the URL over the network.
    func textView(
      _ textView: UITextView,
      menuConfigurationFor textItem: UITextItem,
      defaultMenu: UIMenu
    ) -> UITextItem.MenuConfiguration? {
      guard case .link(let url) = textItem.content else { return nil }
      let copy = UIAction(
        title: "Copy Link",
        image: UIImage(systemName: "doc.on.doc")
      ) { _ in
        UIPasteboard.general.url = url
      }
      return UITextItem.MenuConfiguration(menu: UIMenu(children: [copy]))
    }
  }
}

private final class LinkHitTestingTextView: UITextView {
  var allowsTextInteraction = false
  var allowsLinkInteraction = false

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    guard super.point(inside: point, with: event) else { return false }
    if allowsTextInteraction { return true }
    return allowsLinkInteraction && linkURL(at: point) != nil
  }

  private func linkURL(at point: CGPoint) -> URL? {
    guard textStorage.length > 0 else { return nil }
    layoutManager.ensureLayout(for: textContainer)

    let textContainerPoint = CGPoint(
      x: point.x - textContainerInset.left,
      y: point.y - textContainerInset.top
    )
    let glyphRange = layoutManager.glyphRange(for: textContainer)
    guard glyphRange.length > 0 else { return nil }

    let glyphIndex = layoutManager.glyphIndex(for: textContainerPoint, in: textContainer)
    guard NSLocationInRange(glyphIndex, glyphRange) else { return nil }

    let glyphRect = layoutManager.boundingRect(
      forGlyphRange: NSRange(location: glyphIndex, length: 1),
      in: textContainer)
    guard glyphRect.insetBy(dx: -3, dy: -6).contains(textContainerPoint) else {
      return nil
    }

    let characterIndex = layoutManager.characterIndex(
      for: textContainerPoint,
      in: textContainer,
      fractionOfDistanceBetweenInsertionPoints: nil)
    guard characterIndex < textStorage.length else { return nil }

    let value = textStorage.attribute(.link, at: characterIndex, effectiveRange: nil)
    if let url = value as? URL {
      return url
    }
    if let url = value as? NSURL {
      return url as URL
    }
    if let string = value as? String {
      return URL(string: string)
    }
    return nil
  }
}

extension AppearanceSettings {
  fileprivate var markdownMetricScale: CGFloat {
    CGFloat(fontSize / AppearanceSettings.defaults.fontSize)
  }

  fileprivate func markdownMetric(_ value: CGFloat) -> CGFloat {
    value * markdownMetricScale
  }

  fileprivate func markdownListMarkerWidth(markerLength: Int, minimum: CGFloat = 18) -> CGFloat {
    max(markdownMetric(minimum), CGFloat(markerLength) * CGFloat(fontSize) * 0.64)
  }
}

private enum MarkdownInlineLinkScanner {
  @MainActor private static var cachedResults: [String: Bool] = [:]

  /// Reports whether the inline markdown resolves to one or more links.
  /// A cheap textual pre-check avoids parsing strings that cannot contain a
  /// markdown link or autolink.
  @MainActor
  static func containsLink(_ value: String) -> Bool {
    if let cached = cachedResults[value] { return cached }
    let result = containsUncachedLink(value)
    if cachedResults.count >= 384 {
      cachedResults.removeAll(keepingCapacity: true)
    }
    cachedResults[value] = result
    return result
  }

  @MainActor
  private static func containsUncachedLink(_ value: String) -> Bool {
    if value.contains("](") || value.contains("<http") {
      if attributedInlineMarkdown(value).runs.contains(where: { $0.link != nil }) {
        return true
      }
    }
    return MarkdownBareURLDetector.containsLink(in: value)
  }
}

@MainActor
private enum MarkdownInlineAttributedCache {
  private static let maxEntries = 384
  private static var entries: [String: AttributedString] = [:]
  private static var accessOrder: [String] = []

  static func baseAttributedString(for value: String) -> AttributedString {
    if let cached = entries[value] {
      markAccessed(value)
      return cached
    }

    let normalized = MarkdownInlineSymbols.displayString(value)
    var attributed =
      (try? AttributedString(
        markdown: normalized,
        options: AttributedString.MarkdownParsingOptions(
          interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      ?? AttributedString(normalized)
    for run in attributed.runs.reversed() {
      let text = String(attributed.characters[run.range])
      if run.inlinePresentationIntent?.contains(.inlineHTML) == true,
        text.range(of: "^<br\\s*/?>$", options: [.regularExpression, .caseInsensitive]) != nil
      {
        attributed.replaceSubrange(run.range, with: AttributedString("\n"))
      }
    }

    let result = MarkdownInlineStyleApplier.styled(
      MarkdownInlineTokenColorizer.colorized(attributed))
    entries[value] = result
    markAccessed(value)
    if accessOrder.count > maxEntries, let oldest = accessOrder.first {
      accessOrder.removeFirst()
      entries.removeValue(forKey: oldest)
    }
    return result
  }

  private static func markAccessed(_ value: String) {
    accessOrder.removeAll { $0 == value }
    accessOrder.append(value)
  }
}

@MainActor
private func attributedInlineMarkdown(_ value: String, strongFont: Font? = nil) -> AttributedString
{
  var attributed = MarkdownInlineAttributedCache.baseAttributedString(for: value)
  guard let strongFont else { return attributed }
  let strongRanges = attributed.runs.compactMap { run in
    run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true ? run.range : nil
  }
  for range in strongRanges {
    attributed[range].font = strongFont
  }
  return attributed
}

@MainActor
private func nsAttributedInlineMarkdown(
  _ value: String,
  font: UIFont,
  lineSpacing: Double,
  alignment: NSTextAlignment,
  foregroundColor: UIColor,
  strikethrough: Bool
) -> NSAttributedString {
  let attributed = attributedInlineMarkdown(value)
  let string = String(attributed.characters)
  let result = NSMutableAttributedString(attributedString: NSAttributedString(attributed))
  let fullRange = NSRange(location: 0, length: result.length)

  let paragraphStyle = NSMutableParagraphStyle()
  paragraphStyle.alignment = alignment
  paragraphStyle.lineBreakMode = .byWordWrapping
  paragraphStyle.lineSpacing = CGFloat(lineSpacing)

  result.addAttributes(
    [
      .font: font,
      .foregroundColor: foregroundColor,
      .paragraphStyle: paragraphStyle,
    ],
    range: fullRange)

  for run in attributed.runs {
    guard let nsRange = nsAttributedRange(for: run.range, in: attributed, string: string),
      nsRange.length > 0
    else {
      continue
    }

    if let intent = run.inlinePresentationIntent {
      var runFont = font
      if intent.contains(.code) {
        runFont = UIFont.monospacedSystemFont(
          ofSize: max(font.pointSize * 0.94, 1),
          weight: .regular)
        result.addAttribute(
          .foregroundColor,
          value: MarkdownInlineStyleApplier.inlineCodeUIColor,
          range: nsRange)
      } else {
        if intent.contains(.stronglyEmphasized) {
          runFont = runFont.withWeight(.bold)
        }
        if intent.contains(.emphasized) {
          runFont = runFont.italicized()
        }
      }
      result.addAttribute(.font, value: runFont, range: nsRange)

      if intent.contains(.strikethrough) {
        result.addAttribute(
          .strikethroughStyle,
          value: NSUnderlineStyle.single.rawValue,
          range: nsRange)
      }
    }

    if let color = run.foregroundColor {
      result.addAttribute(.foregroundColor, value: UIColor(color), range: nsRange)
    }
  }

  MarkdownBareURLDetector.addLinks(to: result, string: string)

  if strikethrough {
    result.addAttribute(
      .strikethroughStyle,
      value: NSUnderlineStyle.single.rawValue,
      range: fullRange)
  }

  return result
}

private enum MarkdownBareURLDetector {
  static func containsLink(in string: String) -> Bool {
    guard !string.isEmpty, let detector = linkDetector else { return false }
    let range = NSRange(string.startIndex..<string.endIndex, in: string)
    return detector.firstMatch(in: string, options: [], range: range) != nil
  }

  static func addLinks(to attributed: NSMutableAttributedString, string: String) {
    guard !string.isEmpty, let detector = linkDetector else { return }
    let fullRange = NSRange(location: 0, length: attributed.length)
    detector.enumerateMatches(in: string, options: [], range: fullRange) { match, _, _ in
      guard let match, let url = match.url, match.range.length > 0,
        NSMaxRange(match.range) <= attributed.length,
        attributed.attribute(.link, at: match.range.location, effectiveRange: nil) == nil
      else {
        return
      }
      attributed.addAttributes(
        [
          .link: url,
          .underlineStyle: NSUnderlineStyle.single.rawValue,
        ],
        range: match.range)
    }
  }

  private static let linkDetector =
    try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
}

private func nsAttributedRange(
  for range: Range<AttributedString.Index>,
  in attributed: AttributedString,
  string: String
) -> NSRange? {
  let lowerOffset = attributed.characters.distance(
    from: attributed.characters.startIndex,
    to: range.lowerBound)
  let upperOffset = attributed.characters.distance(
    from: attributed.characters.startIndex,
    to: range.upperBound)
  guard
    let lowerBound = string.index(
      string.startIndex,
      offsetBy: lowerOffset,
      limitedBy: string.endIndex),
    let upperBound = string.index(
      string.startIndex,
      offsetBy: upperOffset,
      limitedBy: string.endIndex)
  else {
    return nil
  }
  return NSRange(lowerBound..<upperBound, in: string)
}

extension UIFont {
  fileprivate func withWeight(_ weight: UIFont.Weight) -> UIFont {
    var traits =
      fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any] ?? [:]
    traits[.weight] = weight.rawValue
    let descriptor = fontDescriptor.addingAttributes([.traits: traits])
    return UIFont(descriptor: descriptor, size: pointSize)
  }

  fileprivate func italicized() -> UIFont {
    guard
      let descriptor = fontDescriptor.withSymbolicTraits(
        fontDescriptor.symbolicTraits.union(.traitItalic))
    else {
      return self
    }
    return UIFont(descriptor: descriptor, size: pointSize)
  }

  fileprivate func italicizedIf(_ italic: Bool) -> UIFont {
    italic ? italicized() : self
  }
}

extension Font {
  fileprivate func italicizedIf(_ italic: Bool) -> Font {
    italic ? self.italic() : self
  }
}

private enum MarkdownInlineStyleApplier {
  static func styled(_ attributed: AttributedString, strongFont: Font? = nil) -> AttributedString {
    var result = attributed
    let runs = result.runs.map { ($0.range, $0.inlinePresentationIntent, $0.link) }

    for (range, intent, link) in runs {
      // Links are underlined (in addition to their tint) so they remain
      // distinguishable from surrounding text by more than color alone.
      if link != nil {
        result[range].underlineStyle = .single
      }
      guard let intent else { continue }
      if intent.contains(.code) {
        result[range].foregroundColor = inlineCodeColor
      } else if intent.contains(.stronglyEmphasized) {
        // Bold runs are pulled back to full contrast so they stand out from the
        // dimmed body copy (see markdownBodyColor).
        result[range].foregroundColor = .primary
        if let strongFont {
          result[range].font = strongFont
        }
      }
      if intent.contains(.strikethrough) {
        result[range].strikethroughStyle = .single
      }
    }

    return result
  }

  static let inlineCodeUIColor = UIColor { traits in
    traits.userInterfaceStyle == .dark
      ? UIColor(red: 1.0, green: 0.48, blue: 0.62, alpha: 1)
      : UIColor(red: 0.70, green: 0.08, blue: 0.24, alpha: 1)
  }

  private static let inlineCodeColor = Color(
    uiColor: inlineCodeUIColor)
}

/// Body copy in markdown is rendered a touch dimmer than headings and bold runs
/// so the latter read as emphasis: light grey on dark, dark grey on light.
/// Headings and bold text keep full `.label`/`.primary` contrast.
private let markdownBodyUIColor = UIColor { traits in
  traits.userInterfaceStyle == .dark
    ? UIColor(white: 0.88, alpha: 1)
    : UIColor(white: 0.30, alpha: 1)
}
private let markdownBodyColor = Color(uiColor: markdownBodyUIColor)

private enum MarkdownInlineTokenColorizer {
  static func colorized(_ attributed: AttributedString) -> AttributedString {
    var result = attributed
    var cursor = result.characters.startIndex

    while cursor != result.characters.endIndex {
      let character = result.characters[cursor]
      guard isMarker(character), isTokenStart(in: result, at: cursor) else {
        cursor = result.characters.index(after: cursor)
        continue
      }

      let next = result.characters.index(after: cursor)
      guard next != result.characters.endIndex, isTokenBody(result.characters[next]) else {
        cursor = next
        continue
      }

      var end = result.characters.index(after: next)
      while end != result.characters.endIndex, isTokenBody(result.characters[end]) {
        end = result.characters.index(after: end)
      }

      result[cursor..<end].foregroundColor = Color.accentColor
      cursor = end
    }

    return result
  }

  private static func isMarker(_ character: Character) -> Bool {
    character == "@" || character == "#"
  }

  private static func isTokenStart(
    in attributed: AttributedString, at index: AttributedString.Index
  )
    -> Bool
  {
    guard index != attributed.characters.startIndex else { return true }
    let previous = attributed.characters.index(before: index)
    return !isTokenBody(attributed.characters[previous])
  }

  private static func isTokenBody(_ character: Character) -> Bool {
    character.isLetter || character.isNumber || character == "_" || character == "-"
  }
}

enum MarkdownInlineSymbols {
  static func displayString(_ raw: String) -> String {
    rewriteDelimitedMath(in: rewriteCitationRefs(in: raw))
  }

  static func toSuperscript(_ key: String) -> String {
    let map: [Character: Character] = [
      "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
      "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
    ]
    return String(key.map { map[$0] ?? $0 })
  }

  private static func rewriteCitationRefs(in raw: String) -> String {
    guard raw.contains("[^") else { return raw }
    var output = ""
    var idx = raw.startIndex
    while idx < raw.endIndex {
      guard raw[idx] == "[" else {
        output.append(raw[idx])
        idx = raw.index(after: idx)
        continue
      }
      let afterBracket = raw.index(after: idx)
      guard afterBracket < raw.endIndex, raw[afterBracket] == "^" else {
        output.append(raw[idx])
        idx = raw.index(after: idx)
        continue
      }
      var searchIdx = raw.index(after: afterBracket)
      var key = ""
      var found = false
      while searchIdx < raw.endIndex {
        let c = raw[searchIdx]
        if c == "]" {
          found = true
          break
        }
        if c == "\n" || c == "[" { break }
        key.append(c)
        searchIdx = raw.index(after: searchIdx)
      }
      if found, !key.isEmpty {
        // Skip definition lines [^key]: ...
        let afterClose = raw.index(after: searchIdx)
        if afterClose < raw.endIndex, raw[afterClose] == ":" {
          output.append(raw[idx])
          idx = raw.index(after: idx)
          continue
        }
        output += toSuperscript(key)
        idx = raw.index(after: searchIdx)
      } else {
        output.append(raw[idx])
        idx = raw.index(after: idx)
      }
    }
    return output
  }

  static func containsMathSyntax(_ raw: String) -> Bool {
    let chars = Array(raw)
    var index = 0

    while index < chars.count {
      if let codeSpan = MarkdownInlineCodeSpan.span(in: chars, at: index) {
        index = codeSpan.end
        continue
      }
      if mathReplacement(in: chars, at: index) != nil {
        return true
      }
      index += 1
    }

    return false
  }

  private static func rewriteDelimitedMath(in raw: String) -> String {
    let chars = Array(raw)
    var result = ""
    var index = 0

    while index < chars.count {
      if let codeSpan = MarkdownInlineCodeSpan.span(in: chars, at: index) {
        result += String(chars[index..<codeSpan.end])
        index = codeSpan.end
        continue
      }

      if let replacement = mathReplacement(in: chars, at: index) {
        result += markdownEscaped(replacement.text)
        index = replacement.end
        continue
      }

      result.append(chars[index])
      index += 1
    }

    return result
  }

  private static func mathReplacement(in chars: [Character], at index: Int)
    -> (text: String, end: Int)?
  {
    if chars[index] == "$", !isEscaped(chars, at: index) {
      if index + 1 < chars.count, chars[index + 1] == "$",
        let end = findUnescapedDoubleDollar(in: chars, start: index + 2),
        let rewritten = rewrittenMathContent(String(chars[(index + 2)..<end]))
      {
        return (rewritten, end + 2)
      }
      if let end = findUnescapedDollar(in: chars, start: index + 1),
        let rewritten = rewrittenMathContent(String(chars[(index + 1)..<end]))
      {
        return (rewritten, end + 1)
      }
    }

    guard chars[index] == "\\", index + 1 < chars.count else { return nil }
    let opener = chars[index + 1]
    guard opener == "(" || opener == "[",
      let end = findEscapedMathClose(in: chars, start: index + 2, opener: opener),
      let rewritten = rewrittenMathContent(String(chars[(index + 2)..<end]))
    else { return nil }
    return (rewritten, end + 2)
  }

  private static func rewrittenMathContent(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard looksLikeLatexMath(trimmed) else { return nil }
    let rewritten = normalizedLatexMath(trimmed)
    return rewritten.isEmpty ? nil : rewritten
  }

  private static func looksLikeLatexMath(_ raw: String) -> Bool {
    guard !raw.isEmpty else { return false }
    if raw.contains("\\") || raw.contains("^") || raw.contains("_")
      || raw.contains("{") || raw.contains("}")
    {
      return true
    }
    if raw.count == 1, raw.first?.isLetter == true {
      return true
    }

    let chars = Array(raw)
    if isCompactMathAtom(chars) {
      return true
    }

    let operators: Set<Character> = ["=", "+", "*", "/", "<", ">", "|", "±", "×", "÷"]
    for (index, char) in chars.enumerated() {
      if operators.contains(char) {
        return true
      }
      if char == "-", hasNonNumericNeighbor(in: chars, at: index) {
        return true
      }
    }

    return false
  }

  private static func isCompactMathAtom(_ chars: [Character]) -> Bool {
    var hasLetter = false
    var hasNumber = false
    var hasGrouping = false

    for char in chars {
      if char.isLetter {
        hasLetter = true
      } else if char.isNumber {
        hasNumber = true
      } else if char == "(" || char == ")" || char == "," {
        hasGrouping = true
      } else {
        return false
      }
    }

    guard hasLetter else {
      return false
    }

    // Treat "$2n$" and "$T(n)$" as math, but leave pure values like "$20" alone.
    return hasNumber || hasGrouping
  }

  private static func hasNonNumericNeighbor(in chars: [Character], at index: Int) -> Bool {
    let previous = nearestNonWhitespace(in: chars, before: index)
    let next = nearestNonWhitespace(in: chars, after: index)
    guard let previous, let next else { return false }
    return !previous.isNumber || !next.isNumber
  }

  private static func nearestNonWhitespace(in chars: [Character], before index: Int) -> Character? {
    guard index > 0 else { return nil }
    var cursor = index - 1
    while cursor >= 0 {
      if !chars[cursor].isWhitespace {
        return chars[cursor]
      }
      cursor -= 1
    }
    return nil
  }

  private static func nearestNonWhitespace(in chars: [Character], after index: Int) -> Character? {
    var cursor = index + 1
    while cursor < chars.count {
      if !chars[cursor].isWhitespace {
        return chars[cursor]
      }
      cursor += 1
    }
    return nil
  }

  private static func normalizedLatexMath(_ raw: String) -> String {
    var output = raw
    output = replacingLatexEnvironments(in: output)
    output = replacingLatexLineBreaks(in: output)
    output = replacingLatexAlignmentMarkers(in: output)
    output = replacingLatexFontCommands(in: output)
    output = replacingLatexTextCommands(in: output)
    output = replacingLatexFractions(in: output)
    output = replacingLatexSquareRoots(in: output)
    output = replacingLatexSpacing(in: output)
    output = replacingLatexCommands(in: output)
    output = replacingLatexNamedOperators(in: output)
    output = removingStandaloneLatexCommands(
      in: output,
      commands: textCommandNames.union(mathAlphabetCommandNames).union(["left", "right", "middle"])
    )
    output = replacingLatexScripts(in: output)
    output = unescapingLatexPunctuation(in: output)
    output = output.replacingOccurrences(of: "{", with: "")
      .replacingOccurrences(of: "}", with: "")
    return output.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  private static func replacingLatexCommands(in raw: String) -> String {
    var output = raw
    for symbol in symbolsByLength {
      output = output.replacingOccurrences(of: symbol.marker, with: symbol.value)
    }
    return output
  }

  private static func replacingLatexTextCommands(in raw: String) -> String {
    replacingSingleArgumentCommands(in: raw, commands: textCommandNames) { content in
      normalizedLatexText(content)
    }
  }

  private static func normalizedLatexText(_ raw: String) -> String {
    var output = raw
    output = replacingLatexFontCommands(in: output)
    output = replacingLatexTextCommands(in: output)
    output = replacingLatexSpacing(in: output)
    output = replacingLatexCommands(in: output)
    output = replacingLatexNamedOperators(in: output)
    output = unescapingLatexPunctuation(in: output)
    return output.replacingOccurrences(of: "{", with: "")
      .replacingOccurrences(of: "}", with: "")
  }

  private static func replacingLatexEnvironments(in raw: String) -> String {
    let chars = Array(raw)
    var output = ""
    var index = 0

    while index < chars.count {
      guard chars[index] == "\\",
        let begin = bracedCommandArgument(in: chars, command: "begin", at: index),
        let end = latexEnvironmentEnd(in: chars, name: begin.value, start: begin.end)
      else {
        output.append(chars[index])
        index += 1
        continue
      }

      let content = String(chars[begin.end..<end.contentEnd])
      output += normalizedLatexEnvironment(begin.value, content: content)
      index = end.end
    }

    return output
  }

  private static func normalizedLatexEnvironment(_ name: String, content: String) -> String {
    let rows = splitLatexRows(content).compactMap { row -> String? in
      let cells = splitLatexCells(row).map { cell in
        normalizedLatexMath(cell).trimmingCharacters(in: .whitespacesAndNewlines)
      }.filter { !$0.isEmpty }
      guard !cells.isEmpty else { return nil }
      if name == "cases", cells.count > 1 {
        return "\(cells[0]) if \(cells.dropFirst().joined(separator: " "))"
      }
      return cells.joined(separator: " ")
    }
    guard !rows.isEmpty else { return "" }

    let body = rows.joined(separator: "; ")
    switch name {
    case "cases":
      return "{ \(body) }"
    case "pmatrix":
      return "(\(body))"
    case "bmatrix":
      return "[\(body)]"
    case "vmatrix":
      return "|\(body)|"
    case "Vmatrix":
      return "‖\(body)‖"
    default:
      return body
    }
  }

  private static func bracedCommandArgument(
    in chars: [Character],
    command: String,
    at index: Int
  ) -> (value: String, end: Int)? {
    guard commandName(in: chars, at: index) == command else { return nil }
    var cursor = index + command.count + 1
    while cursor < chars.count, chars[cursor].isWhitespace {
      cursor += 1
    }
    guard cursor < chars.count, chars[cursor] == "{",
      let close = findBalancedClose(in: chars, start: cursor, open: "{", close: "}")
    else {
      return nil
    }
    return (String(chars[(cursor + 1)..<close]), close + 1)
  }

  private static func latexEnvironmentEnd(
    in chars: [Character],
    name: String,
    start: Int
  ) -> (contentEnd: Int, end: Int)? {
    var cursor = start
    var depth = 1

    while cursor < chars.count {
      if chars[cursor] == "\\" {
        if let begin = bracedCommandArgument(in: chars, command: "begin", at: cursor),
          begin.value == name
        {
          depth += 1
          cursor = begin.end
          continue
        }
        if let end = bracedCommandArgument(in: chars, command: "end", at: cursor),
          end.value == name
        {
          depth -= 1
          if depth == 0 {
            return (cursor, end.end)
          }
          cursor = end.end
          continue
        }
      }
      cursor += 1
    }

    return nil
  }

  private static func replacingLatexLineBreaks(in raw: String) -> String {
    splitLatexRows(raw).joined(separator: "; ")
  }

  private static func replacingLatexAlignmentMarkers(in raw: String) -> String {
    splitLatexCells(raw).joined(separator: " ")
  }

  private static func splitLatexRows(_ raw: String) -> [String] {
    splitLatexTopLevel(raw) { chars, index in
      index + 1 < chars.count && chars[index] == "\\" && chars[index + 1] == "\\"
        && !isEscaped(chars, at: index) ? 2 : nil
    }
  }

  private static func splitLatexCells(_ raw: String) -> [String] {
    splitLatexTopLevel(raw) { chars, index in
      chars[index] == "&" && !isEscaped(chars, at: index) ? 1 : nil
    }
  }

  private static func splitLatexTopLevel(
    _ raw: String,
    separatorLength: ([Character], Int) -> Int?
  ) -> [String] {
    let chars = Array(raw)
    var fields: [String] = []
    var start = 0
    var index = 0
    var depth = 0

    while index < chars.count {
      if depth == 0, let length = separatorLength(chars, index) {
        fields.append(String(chars[start..<index]))
        index += length
        start = index
        continue
      }
      if (chars[index] == "{" || chars[index] == "[") && !isEscaped(chars, at: index) {
        depth += 1
      } else if (chars[index] == "}" || chars[index] == "]") && !isEscaped(chars, at: index) {
        depth = max(0, depth - 1)
      }
      index += 1
    }

    fields.append(String(chars[start..<chars.count]))
    return fields
  }

  private static func replacingLatexFontCommands(in raw: String) -> String {
    var output = replacingSingleArgumentCommands(in: raw, commands: ["mathbb"]) { content in
      doubleStruck(normalizedLatexText(content))
    }
    output = replacingSingleArgumentCommands(
      in: output,
      commands: mathAlphabetCommandNames.subtracting(["mathbb"])
    ) { content in
      normalizedLatexText(content)
    }
    return output
  }

  private static func doubleStruck(_ raw: String) -> String {
    var output = ""
    for char in raw {
      output.append(doubleStruckCharacters[char] ?? char)
    }
    return output
  }

  private static func replacingLatexNamedOperators(in raw: String) -> String {
    let chars = Array(raw)
    var output = ""
    var index = 0

    while index < chars.count {
      guard chars[index] == "\\", let command = commandName(in: chars, at: index),
        let value = namedOperatorCommands[command]
      else {
        output.append(chars[index])
        index += 1
        continue
      }

      output += spacedNamedOperatorCommands.contains(command) ? " \(value) " : value
      index += command.count + 1
    }

    return output
  }

  private static func replacingSingleArgumentCommands(
    in raw: String,
    commands: Set<String>,
    transform: (String) -> String
  ) -> String {
    let chars = Array(raw)
    var output = ""
    var index = 0

    while index < chars.count {
      guard chars[index] == "\\", let command = commandName(in: chars, at: index) else {
        output.append(chars[index])
        index += 1
        continue
      }

      var cursor = index + command.count + 1
      while cursor < chars.count, chars[cursor].isWhitespace {
        cursor += 1
      }

      if commands.contains(command), cursor < chars.count, chars[cursor] == "{",
        let close = findBalancedClose(in: chars, start: cursor, open: "{", close: "}")
      {
        output += transform(String(chars[(cursor + 1)..<close]))
        index = close + 1
        continue
      }

      output.append(chars[index])
      index += 1
    }

    return output
  }

  private static func replacingLatexFractions(in raw: String) -> String {
    let chars = Array(raw)
    var output = ""
    var index = 0
    let fractionCommands: Set<String> = ["frac", "dfrac", "tfrac"]

    while index < chars.count {
      guard chars[index] == "\\", let command = commandName(in: chars, at: index),
        fractionCommands.contains(command)
      else {
        output.append(chars[index])
        index += 1
        continue
      }

      var cursor = index + command.count + 1
      while cursor < chars.count, chars[cursor].isWhitespace {
        cursor += 1
      }
      guard cursor < chars.count, chars[cursor] == "{",
        let numeratorEnd = findBalancedClose(in: chars, start: cursor, open: "{", close: "}")
      else {
        output.append(chars[index])
        index += 1
        continue
      }

      var denominatorStart = numeratorEnd + 1
      while denominatorStart < chars.count, chars[denominatorStart].isWhitespace {
        denominatorStart += 1
      }
      guard denominatorStart < chars.count, chars[denominatorStart] == "{",
        let denominatorEnd = findBalancedClose(
          in: chars,
          start: denominatorStart,
          open: "{",
          close: "}"
        )
      else {
        output.append(chars[index])
        index += 1
        continue
      }

      let numerator = normalizedLatexMath(String(chars[(cursor + 1)..<numeratorEnd]))
      let denominator = normalizedLatexMath(
        String(chars[(denominatorStart + 1)..<denominatorEnd])
      )
      output += "\(parenthesizedIfNeeded(numerator))/\(parenthesizedIfNeeded(denominator))"
      index = denominatorEnd + 1
    }

    return output
  }

  private static func replacingLatexSquareRoots(in raw: String) -> String {
    let chars = Array(raw)
    var output = ""
    var index = 0

    while index < chars.count {
      guard chars[index] == "\\", commandName(in: chars, at: index) == "sqrt" else {
        output.append(chars[index])
        index += 1
        continue
      }

      var cursor = index + 5
      var degree = ""
      if cursor < chars.count, chars[cursor] == "[",
        let close = findBalancedClose(in: chars, start: cursor, open: "[", close: "]")
      {
        degree = normalizedLatexMath(String(chars[(cursor + 1)..<close]))
        cursor = close + 1
      }
      while cursor < chars.count, chars[cursor].isWhitespace {
        cursor += 1
      }
      guard cursor < chars.count, chars[cursor] == "{",
        let close = findBalancedClose(in: chars, start: cursor, open: "{", close: "}")
      else {
        output.append(chars[index])
        index += 1
        continue
      }

      let radicand = normalizedLatexMath(String(chars[(cursor + 1)..<close]))
      output += "\(scripted(degree, superscript: true) ?? degree)√\(radicand)"
      index = close + 1
    }

    return output
  }

  private static func replacingLatexSpacing(in raw: String) -> String {
    let replacements = [
      ("\\qquad", "  "),
      ("\\quad", " "),
      ("\\,", " "),
      ("\\;", " "),
      ("\\:", " "),
      ("\\ ", " "),
      ("\\!", ""),
      ("~", " "),
    ]
    var output = raw
    for (marker, value) in replacements {
      output = output.replacingOccurrences(of: marker, with: value)
    }
    return output
  }

  private static func removingStandaloneLatexCommands(
    in raw: String,
    commands: Set<String>
  ) -> String {
    let chars = Array(raw)
    var output = ""
    var index = 0

    while index < chars.count {
      if chars[index] == "\\", let command = commandName(in: chars, at: index),
        commands.contains(command)
      {
        index += command.count + 1
        continue
      }

      output.append(chars[index])
      index += 1
    }

    return output
  }

  private static func replacingLatexScripts(in raw: String) -> String {
    let chars = Array(raw)
    var output = ""
    var index = 0

    while index < chars.count {
      let char = chars[index]
      if char == "^" || char == "_",
        let body = scriptBody(in: chars, start: index + 1)
      {
        let superscript = char == "^"
        if let scripted = scripted(body.value, superscript: superscript) {
          output += scripted
        } else {
          output.append(char)
          output += body.value
        }
        index = body.end
        continue
      }

      output.append(char)
      index += 1
    }

    return output
  }

  private static func scriptBody(in chars: [Character], start: Int) -> (value: String, end: Int)? {
    guard start < chars.count else { return nil }
    if chars[start] == "{",
      let close = findBalancedClose(in: chars, start: start, open: "{", close: "}")
    {
      return (String(chars[(start + 1)..<close]), close + 1)
    }
    return (String(chars[start]), start + 1)
  }

  private static func scripted(_ raw: String, superscript: Bool) -> String? {
    guard !raw.isEmpty else { return "" }
    let table = superscript ? superscriptCharacters : subscriptCharacters
    var output = ""
    for char in raw {
      guard let mapped = table[char] else { return nil }
      output.append(mapped)
    }
    return output
  }

  private static func unescapingLatexPunctuation(in raw: String) -> String {
    let replacements = [
      ("\\{", "{"),
      ("\\}", "}"),
      ("\\$", "$"),
      ("\\%", "%"),
      ("\\_", "_"),
      ("\\#", "#"),
      ("\\&", "&"),
    ]
    var output = raw
    for (marker, value) in replacements {
      output = output.replacingOccurrences(of: marker, with: value)
    }
    return output
  }

  private static func markdownEscaped(_ raw: String) -> String {
    var output = ""
    for char in raw {
      if "\\`*_{}[]()#+-.!".contains(char) {
        output.append("\\")
      }
      output.append(char)
    }
    return output
  }

  private static func parenthesizedIfNeeded(_ raw: String) -> String {
    let needsParens = raw.contains { char in
      char.isWhitespace || char == "+" || char == "-" || char == "="
    }
    return needsParens ? "(\(raw))" : raw
  }

  private static func commandName(in chars: [Character], at index: Int) -> String? {
    guard index < chars.count, chars[index] == "\\", index + 1 < chars.count,
      chars[index + 1].isLetter
    else {
      return nil
    }

    var cursor = index + 1
    while cursor < chars.count, chars[cursor].isLetter {
      cursor += 1
    }
    return String(chars[(index + 1)..<cursor])
  }

  private static func findBalancedClose(
    in chars: [Character],
    start: Int,
    open: Character,
    close: Character
  ) -> Int? {
    guard start < chars.count, chars[start] == open else { return nil }
    var depth = 0
    var cursor = start
    while cursor < chars.count {
      if chars[cursor] == open, !isEscaped(chars, at: cursor) {
        depth += 1
      } else if chars[cursor] == close, !isEscaped(chars, at: cursor) {
        depth -= 1
        if depth == 0 {
          return cursor
        }
      }
      cursor += 1
    }
    return nil
  }

  private static func findUnescapedDollar(in chars: [Character], start: Int) -> Int? {
    var cursor = start
    while cursor < chars.count {
      if chars[cursor] == "$", !isEscaped(chars, at: cursor) {
        return cursor
      }
      cursor += 1
    }
    return nil
  }

  private static func findUnescapedDoubleDollar(in chars: [Character], start: Int) -> Int? {
    var cursor = start
    while cursor + 1 < chars.count {
      if chars[cursor] == "$", chars[cursor + 1] == "$", !isEscaped(chars, at: cursor) {
        return cursor
      }
      cursor += 1
    }
    return nil
  }

  private static func findUnescapedBacktick(in chars: [Character], start: Int) -> Int? {
    var cursor = start
    while cursor < chars.count {
      if chars[cursor] == "`", !isEscaped(chars, at: cursor) {
        return cursor
      }
      cursor += 1
    }
    return nil
  }

  private static func findEscapedMathClose(
    in chars: [Character], start: Int, opener: Character
  ) -> Int? {
    let closer: Character = opener == "(" ? ")" : "]"
    var cursor = start
    while cursor + 1 < chars.count {
      if chars[cursor] == "\\", chars[cursor + 1] == closer {
        return cursor
      }
      cursor += 1
    }
    return nil
  }

  private static func isEscaped(_ chars: [Character], at index: Int) -> Bool {
    guard index > 0 else { return false }
    var slashCount = 0
    var cursor = index - 1
    while cursor >= 0, chars[cursor] == "\\" {
      slashCount += 1
      cursor -= 1
    }
    return !slashCount.isMultiple(of: 2)
  }

  private static let textCommandNames: Set<String> = [
    "text", "textrm", "textnormal", "textit", "textbf", "texttt", "mathrm", "mathit",
    "mathbf", "mathsf", "mathtt", "operatorname",
  ]

  private static let mathAlphabetCommandNames: Set<String> = [
    "mathbb", "mathbfit", "mathcal", "mathds", "mathfrak", "mathnormal", "mathscr",
  ]

  private static let namedOperatorCommands: [String: String] = [
    "Pr": "Pr", "arg": "arg", "arccos": "arccos", "arcsin": "arcsin", "arctan": "arctan",
    "bmod": "mod", "cos": "cos", "cosh": "cosh", "cot": "cot", "coth": "coth", "csc": "csc",
    "deg": "deg", "det": "det", "dim": "dim", "exp": "exp", "gcd": "gcd", "hom": "hom",
    "inf": "inf", "ker": "ker", "lg": "lg", "lim": "lim", "liminf": "liminf",
    "limsup": "limsup", "ln": "ln", "log": "log", "max": "max", "min": "min",
    "mod": "mod", "pmod": "mod", "sec": "sec", "sin": "sin", "sinh": "sinh", "sup": "sup",
    "tan": "tan", "tanh": "tanh",
  ]

  private static let spacedNamedOperatorCommands: Set<String> = ["bmod", "mod", "pmod"]

  private static let doubleStruckCharacters: [Character: Character] = [
    "C": "ℂ", "H": "ℍ", "N": "ℕ", "P": "ℙ", "Q": "ℚ", "R": "ℝ", "Z": "ℤ",
    "c": "ℂ", "h": "ℍ", "n": "ℕ", "p": "ℙ", "q": "ℚ", "r": "ℝ", "z": "ℤ",
  ]

  private static let superscriptCharacters: [Character: Character] = [
    "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷",
    "8": "⁸", "9": "⁹", "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾",
    "a": "ᵃ", "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ", "f": "ᶠ", "g": "ᵍ",
    "h": "ʰ", "i": "ⁱ", "j": "ʲ", "k": "ᵏ", "l": "ˡ", "m": "ᵐ", "n": "ⁿ",
    "o": "ᵒ", "p": "ᵖ", "r": "ʳ", "s": "ˢ", "t": "ᵗ", "u": "ᵘ", "v": "ᵛ",
    "w": "ʷ", "x": "ˣ", "y": "ʸ", "z": "ᶻ",
  ]

  private static let subscriptCharacters: [Character: Character] = [
    "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇",
    "8": "₈", "9": "₉", "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎",
    "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ", "l": "ₗ",
    "m": "ₘ", "n": "ₙ", "o": "ₒ", "p": "ₚ", "r": "ᵣ", "s": "ₛ", "t": "ₜ",
    "u": "ᵤ", "v": "ᵥ", "x": "ₓ",
  ]

  private static let symbolsByLength = symbols.sorted { $0.marker.count > $1.marker.count }

  private static let symbols: [(marker: String, value: String)] = [
    ("\\Longleftrightarrow", "⟺"),
    ("\\Longrightarrow", "⟹"),
    ("\\Longleftarrow", "⟸"),
    ("\\longleftrightarrow", "⟷"),
    ("\\longrightarrow", "⟶"),
    ("\\longleftarrow", "⟵"),
    ("\\Leftrightarrow", "⇔"),
    ("\\leftrightarrow", "↔"),
    ("\\nleftrightarrow", "↮"),
    ("\\hookrightarrow", "↪"),
    ("\\hookleftarrow", "↩"),
    ("\\rightharpoonup", "⇀"),
    ("\\leftharpoonup", "↼"),
    ("\\rightharpoondown", "⇁"),
    ("\\leftharpoondown", "↽"),
    ("\\rightleftharpoons", "⇌"),
    ("\\leftrightharpoons", "⇋"),
    ("\\rightarrow", "→"),
    ("\\leftarrow", "←"),
    ("\\Rightarrow", "⇒"),
    ("\\Leftarrow", "⇐"),
    ("\\nrightarrow", "↛"),
    ("\\nleftarrow", "↚"),
    ("\\uparrow", "↑"),
    ("\\downarrow", "↓"),
    ("\\updownarrow", "↕"),
    ("\\Uparrow", "⇑"),
    ("\\Downarrow", "⇓"),
    ("\\Updownarrow", "⇕"),
    ("\\mapsto", "↦"),
    ("\\nearrow", "↗"),
    ("\\searrow", "↘"),
    ("\\swarrow", "↙"),
    ("\\nwarrow", "↖"),
    ("\\gets", "←"),
    ("\\to", "→"),

    ("\\varepsilon", "ϵ"),
    ("\\vartheta", "ϑ"),
    ("\\varkappa", "ϰ"),
    ("\\varlambda", "λ"),
    ("\\varrho", "ϱ"),
    ("\\varsigma", "ς"),
    ("\\varphi", "ϕ"),
    ("\\varpi", "ϖ"),
    ("\\Gamma", "Γ"),
    ("\\Delta", "Δ"),
    ("\\Theta", "Θ"),
    ("\\Lambda", "Λ"),
    ("\\Xi", "Ξ"),
    ("\\Pi", "Π"),
    ("\\Sigma", "Σ"),
    ("\\Upsilon", "Υ"),
    ("\\Phi", "Φ"),
    ("\\Psi", "Ψ"),
    ("\\Omega", "Ω"),
    ("\\alpha", "α"),
    ("\\beta", "β"),
    ("\\gamma", "γ"),
    ("\\delta", "δ"),
    ("\\epsilon", "ε"),
    ("\\zeta", "ζ"),
    ("\\eta", "η"),
    ("\\theta", "θ"),
    ("\\iota", "ι"),
    ("\\kappa", "κ"),
    ("\\lambda", "λ"),
    ("\\mu", "μ"),
    ("\\nu", "ν"),
    ("\\xi", "ξ"),
    ("\\omicron", "ο"),
    ("\\pi", "π"),
    ("\\rho", "ρ"),
    ("\\sigma", "σ"),
    ("\\tau", "τ"),
    ("\\upsilon", "υ"),
    ("\\phi", "φ"),
    ("\\chi", "χ"),
    ("\\psi", "ψ"),
    ("\\omega", "ω"),

    ("\\nsubseteq", "⊈"),
    ("\\nsupseteq", "⊉"),
    ("\\subseteq", "⊆"),
    ("\\supseteq", "⊇"),
    ("\\subsetneq", "⊊"),
    ("\\supsetneq", "⊋"),
    ("\\subset", "⊂"),
    ("\\supset", "⊃"),
    ("\\notin", "∉"),
    ("\\in", "∈"),
    ("\\ni", "∋"),
    ("\\owns", "∋"),
    ("\\emptyset", "∅"),
    ("\\varnothing", "∅"),
    ("\\cup", "∪"),
    ("\\cap", "∩"),
    ("\\setminus", "∖"),
    ("\\smallsetminus", "∖"),
    ("\\forall", "∀"),
    ("\\exists", "∃"),
    ("\\nexists", "∄"),
    ("\\therefore", "∴"),
    ("\\because", "∵"),
    ("\\land", "∧"),
    ("\\wedge", "∧"),
    ("\\lor", "∨"),
    ("\\vee", "∨"),
    ("\\neg", "¬"),
    ("\\lnot", "¬"),
    ("\\top", "⊤"),
    ("\\bot", "⊥"),
    ("\\models", "⊨"),
    ("\\vdash", "⊢"),
    ("\\dashv", "⊣"),

    ("\\leq", "≤"),
    ("\\le", "≤"),
    ("\\geq", "≥"),
    ("\\ge", "≥"),
    ("\\neq", "≠"),
    ("\\ne", "≠"),
    ("\\equiv", "≡"),
    ("\\not\\equiv", "≢"),
    ("\\approx", "≈"),
    ("\\approxeq", "≊"),
    ("\\simeq", "≃"),
    ("\\sim", "∼"),
    ("\\cong", "≅"),
    ("\\propto", "∝"),
    ("\\ll", "≪"),
    ("\\gg", "≫"),
    ("\\prec", "≺"),
    ("\\succ", "≻"),
    ("\\preceq", "≼"),
    ("\\succeq", "≽"),
    ("\\parallel", "∥"),
    ("\\nparallel", "∦"),
    ("\\perp", "⟂"),
    ("\\asymp", "≍"),

    ("\\times", "×"),
    ("\\div", "÷"),
    ("\\pm", "±"),
    ("\\mp", "∓"),
    ("\\cdot", "·"),
    ("\\circ", "∘"),
    ("\\bullet", "•"),
    ("\\ast", "∗"),
    ("\\star", "★"),
    ("\\oplus", "⊕"),
    ("\\ominus", "⊖"),
    ("\\otimes", "⊗"),
    ("\\oslash", "⊘"),
    ("\\odot", "⊙"),
    ("\\sqrt", "√"),
    ("\\partial", "∂"),
    ("\\nabla", "∇"),
    ("\\int", "∫"),
    ("\\iint", "∬"),
    ("\\iiint", "∭"),
    ("\\oint", "∮"),
    ("\\sum", "∑"),
    ("\\prod", "∏"),
    ("\\coprod", "∐"),
    ("\\infty", "∞"),
    ("\\prime", "′"),
    ("\\doubleprime", "″"),
    ("\\ldots", "…"),
    ("\\dots", "…"),
    ("\\cdots", "⋯"),
    ("\\vdots", "⋮"),
    ("\\ddots", "⋱"),
    ("\\degree", "°"),

    ("\\angle", "∠"),
    ("\\measuredangle", "∡"),
    ("\\triangle", "△"),
    ("\\triangleleft", "◁"),
    ("\\triangleright", "▷"),
    ("\\diamond", "⋄"),
    ("\\Diamond", "◇"),
    ("\\square", "□"),
    ("\\Box", "□"),
    ("\\blacksquare", "■"),
    ("\\langle", "⟨"),
    ("\\rangle", "⟩"),
    ("\\lfloor", "⌊"),
    ("\\rfloor", "⌋"),
    ("\\lceil", "⌈"),
    ("\\rceil", "⌉"),
    ("\\Re", "ℜ"),
    ("\\Im", "ℑ"),
    ("\\aleph", "ℵ"),
    ("\\hbar", "ℏ"),
    ("\\ell", "ℓ"),
    ("\\wp", "℘"),
    ("\\dagger", "†"),
    ("\\ddagger", "‡"),
  ]
}

struct MarkdownTableView: View {
  @Environment(\.isFullChatScreenshotRendering) private var isFullChatScreenshotRendering

  let headers: [String]
  let rows: [[String]]
  let alignments: [TextAlignment]
  let appearance: AppearanceSettings
  var fontFamily: AppearanceFontFamily
  let allowsTextSelection: Bool
  let foregroundStyle: Color?
  let uiForegroundColor: UIColor?
  let italic: Bool

  init(
    headers: [String],
    rows: [[String]],
    alignments: [TextAlignment],
    appearance: AppearanceSettings,
    fontFamily: AppearanceFontFamily? = nil,
    allowsTextSelection: Bool = true,
    foregroundStyle: Color? = nil,
    uiForegroundColor: UIColor? = nil,
    italic: Bool = false
  ) {
    self.headers = headers
    self.rows = rows
    self.alignments = alignments
    self.appearance = appearance
    self.fontFamily = fontFamily ?? appearance.assistantFontFamily
    self.allowsTextSelection = allowsTextSelection
    self.foregroundStyle = foregroundStyle
    self.uiForegroundColor = uiForegroundColor
    self.italic = italic
  }

  var body: some View {
    if appearance.unwrappedTables && !isFullChatScreenshotRendering {
      ScrollView(.horizontal, showsIndicators: true) {
        unwrappedTable
      }
    } else {
      wrappedTable
    }
  }

  private var wrappedTable: some View {
    let tableRows = [headers] + rows
    let rowCount = tableRows.count
    // The message and its follow-up card need the full height, including
    // wrapped rows outside the viewport; a lazy grid only estimates those.
    return styledTable(
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(tableRows.enumerated()), id: \.offset) { rowIndex, row in
          HStack(spacing: 0) {
            ForEach(headers.indices, id: \.self) { columnIndex in
              cellView(
                columnIndex < row.count ? row[columnIndex] : "",
                columnIndex: columnIndex,
                isHeader: rowIndex == 0,
                unwrapped: false
              )
            }
          }
          .background(
            rowIndex == 0
              ? Color.secondary.opacity(0.10)
              : rowIndex.isMultiple(of: 2)
                ? Color.secondary.opacity(0.05)
                : Color.clear
          )
          .overlay(alignment: .bottom) {
            if rowIndex < rowCount - 1 {
              Divider().opacity(rowIndex == 0 ? 0.5 : 0.25)
            }
          }
        }
      })
  }

  private var unwrappedTable: some View {
    styledTable(
      Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
        GridRow {
          ForEach(Array(headers.enumerated()), id: \.offset) { columnIndex, header in
            cellView(
              header,
              columnIndex: columnIndex,
              isHeader: true,
              unwrapped: true)
          }
        }
        .background(Color.secondary.opacity(0.10))
        Divider().opacity(0.5)
        ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
          GridRow {
            ForEach(headers.indices, id: \.self) { columnIndex in
              cellView(
                columnIndex < row.count ? row[columnIndex] : "",
                columnIndex: columnIndex,
                isHeader: false,
                unwrapped: true)
            }
          }
          .background(rowIndex.isMultiple(of: 2) ? Color.clear : Color.secondary.opacity(0.05))
          if rowIndex < rows.count - 1 {
            Divider().opacity(0.25)
          }
        }
      })
  }

  private func cellView(
    _ value: String,
    columnIndex: Int,
    isHeader: Bool,
    unwrapped: Bool
  ) -> some View {
    let alignment = textAlignment(for: columnIndex)
    return MarkdownInlineText(
      value: value,
      appearance: appearance,
      font: isHeader
        ? fontFamily.swiftUIFont(size: appearance.fontSize).weight(.semibold)
        : fontFamily.swiftUIFont(size: appearance.fontSize),
      uiFont: isHeader
        ? fontFamily.uiFont(size: appearance.fontSize).withWeight(.semibold)
        : fontFamily.uiFont(size: appearance.fontSize),
      allowsTextSelection: allowsTextSelection,
      textAlignment: alignment,
      foregroundStyle: foregroundStyle,
      uiForegroundColor: uiForegroundColor,
      allowsJustification: !unwrapped,
      allowsPlatformTextView: false,
      italic: italic
    )
    .fixedSize(horizontal: unwrapped, vertical: !unwrapped)
    .padding(.horizontal, appearance.markdownMetric(10))
    .padding(.vertical, appearance.markdownMetric(8))
    .frame(
      minWidth: unwrapped ? nil : 0,
      maxWidth: unwrapped ? nil : .infinity,
      alignment: frameAlignment(alignment))
  }

  private func styledTable<Content: View>(_ content: Content) -> some View {
    content
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(.secondary.opacity(0.25), lineWidth: 0.5))
  }

  private func textAlignment(for columnIndex: Int) -> TextAlignment {
    alignments.indices.contains(columnIndex) ? alignments[columnIndex] : .leading
  }

  private func frameAlignment(_ alignment: TextAlignment) -> Alignment {
    switch alignment {
    case .leading: return .leading
    case .center: return .center
    case .trailing: return .trailing
    }
  }
}

struct CodeBlockView: View {
  @Environment(\.isFullChatScreenshotRendering) private var isFullChatScreenshotRendering

  let language: String
  let code: String
  let appearance: AppearanceSettings
  let allowsTextSelection: Bool

  @State private var showingCodePreview = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: appearance.markdownMetric(8)) {
        Text(language.isEmpty ? "code" : language)
          .font(.caption.monospaced().weight(.semibold))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
          .frame(maxWidth: .infinity, alignment: .leading)
        if !isFullChatScreenshotRendering {
          HStack(spacing: appearance.markdownMetric(8)) {
            Button {
              showingCodePreview = true
            } label: {
              Image(systemName: "eye")
            }
            .adaptiveGlassButtonStyle()
            .help("View code")
            Button {
              UIPasteboard.general.string = code
            } label: {
              Image(systemName: "doc.on.doc")
            }
            .adaptiveGlassButtonStyle()
            .help("Copy code")
          }
          .fixedSize(horizontal: true, vertical: false)
          .layoutPriority(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, appearance.markdownMetric(10))
      .padding(.vertical, appearance.markdownMetric(7))
      Divider()
      if isFullChatScreenshotRendering {
        Text(SyntaxHighlighter.highlight(code, language: language))
          .font(appearance.codeFont)
          .lineSpacing(CGFloat(appearance.lineSpacing))
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(appearance.markdownMetric(12))
      } else {
        ScrollView(.horizontal, showsIndicators: true) {
          Text(SyntaxHighlighter.highlight(code, language: language))
            .font(appearance.codeFont)
            .lineSpacing(CGFloat(appearance.lineSpacing))
            .textSelectionIfEnabled(allowsTextSelection)
            .padding(appearance.markdownMetric(12))
            .fixedSize(horizontal: true, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .sheet(isPresented: $showingCodePreview) {
      MessageTextSelectionSheet(
        title: codePreviewTitle,
        text: code,
        initialFontSize: AppearanceSettings.clampedFontSize(appearance.fontSize - 1),
        initialLineSpacing: appearance.lineSpacing,
        fontFamily: .monospaced)
    }
    .background(.thinMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(.secondary.opacity(0.18), lineWidth: 1)
    }
  }

  private var codePreviewTitle: String {
    let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Code" : trimmed
  }
}

private struct MermaidBlockView: View {
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.displayScale) private var displayScale
  @Environment(\.isFullChatScreenshotRendering) private var isFullChatScreenshotRendering

  let source: String
  let appearance: AppearanceSettings
  let allowsTextSelection: Bool

  @State private var rendered: MarkdownMermaidRenderedPNG?
  @State private var renderError: String?
  @State private var isRendering = false
  @State private var showingFullscreenImage = false

  private var renderStyle: MarkdownMermaidRenderStyle {
    colorScheme == .dark ? .dark : .light
  }

  private var renderScale: Double {
    Double(displayScale)
  }

  private var renderID: RenderID {
    RenderID(source: source, style: renderStyle, scaleKey: Int((renderScale * 100).rounded()))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("mermaid")
          .font(.caption.monospaced().weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        if !isFullChatScreenshotRendering {
          Button {
            showingFullscreenImage = true
          } label: {
            Image(systemName: "eye")
          }
          .adaptiveGlassButtonStyle()
          .help("View diagram")
          .disabled(renderedImage == nil)
          Button {
            UIPasteboard.general.string = source
          } label: {
            Image(systemName: "doc.on.doc")
          }
          .adaptiveGlassButtonStyle()
          .help("Copy Mermaid source")
        }
      }
      .padding(.horizontal, appearance.markdownMetric(10))
      .padding(.vertical, appearance.markdownMetric(7))
      Divider()
      content
    }
    .task(id: renderID) {
      await renderDiagram(style: renderStyle, scale: renderScale)
    }
    .fullScreenCover(isPresented: $showingFullscreenImage) {
      if let renderedImage, let rendered {
        MessageImageFullscreenView(image: renderedImage, imageData: rendered.data)
      }
    }
    .background(.thinMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(.secondary.opacity(0.18), lineWidth: 1)
    }
  }

  @ViewBuilder
  private var content: some View {
    if let rendered, let image = renderedImage {
      Button {
        showingFullscreenImage = true
      } label: {
        Image(uiImage: image)
          .resizable()
          .interpolation(.high)
          .aspectRatio(rendered.aspectRatio, contentMode: .fit)
          .frame(maxWidth: rendered.displayWidth, alignment: .leading)
          .padding(appearance.markdownMetric(12))
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Mermaid diagram")
      .accessibilityHint("Opens full screen")
    } else if isRendering {
      HStack(spacing: appearance.markdownMetric(8)) {
        ProgressView()
        Text("Rendering diagram")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, minHeight: appearance.markdownMetric(74), alignment: .center)
      .padding(appearance.markdownMetric(12))
    } else if let renderError {
      VStack(alignment: .leading, spacing: appearance.markdownMetric(8)) {
        Text("Could not render Mermaid diagram.")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Text(renderError)
          .font(.caption2)
          .foregroundStyle(.secondary)
        ScrollView(.horizontal, showsIndicators: true) {
          Text(SyntaxHighlighter.highlight(source, language: "mermaid"))
            .font(appearance.codeFont)
            .lineSpacing(CGFloat(appearance.lineSpacing))
            .textSelectionIfEnabled(allowsTextSelection)
            .fixedSize(horizontal: true, vertical: true)
        }
      }
      .padding(appearance.markdownMetric(12))
    }
  }

  private var renderedImage: UIImage? {
    guard let rendered else { return nil }
    return UIImage(data: rendered.data)
  }

  @MainActor
  private func renderDiagram(style: MarkdownMermaidRenderStyle, scale: Double) async {
    rendered = nil
    renderError = nil
    isRendering = true
    do {
      let output = try await MarkdownMermaidRenderCache.shared.renderedPNG(
        source: source,
        style: style,
        scale: scale)
      guard !Task.isCancelled else { return }
      rendered = output
      renderError = output == nil ? "The diagram source produced no image." : nil
    } catch {
      guard !Task.isCancelled else { return }
      renderError = error.localizedDescription
    }
    isRendering = false
  }

  private struct RenderID: Hashable {
    let source: String
    let style: MarkdownMermaidRenderStyle
    let scaleKey: Int
  }
}

struct TaskListItem: Identifiable {
  let id = UUID()
  let text: String
  let checked: Bool
}

struct OrderedListItem: Identifiable {
  let id = UUID()
  let number: Int
  let delimiter: String
  let text: String
}

extension OrderedListItem {
  var marker: String { "\(number)\(delimiter)" }
}

struct TaskListView: View {
  let items: [TaskListItem]
  let appearance: AppearanceSettings
  var fontFamily: AppearanceFontFamily
  let allowsTextSelection: Bool
  let foregroundStyle: Color?
  let uiForegroundColor: UIColor?
  let italic: Bool

  init(
    items: [TaskListItem],
    appearance: AppearanceSettings,
    fontFamily: AppearanceFontFamily? = nil,
    allowsTextSelection: Bool = true,
    foregroundStyle: Color? = nil,
    uiForegroundColor: UIColor? = nil,
    italic: Bool = false
  ) {
    self.items = items
    self.appearance = appearance
    self.fontFamily = fontFamily ?? appearance.assistantFontFamily
    self.allowsTextSelection = allowsTextSelection
    self.foregroundStyle = foregroundStyle
    self.uiForegroundColor = uiForegroundColor
    self.italic = italic
  }

  var body: some View {
    let textFont = fontFamily.swiftUIFont(size: appearance.fontSize)
    let markerWidth = appearance.markdownListMarkerWidth(markerLength: 1, minimum: 20)
    VStack(alignment: .leading, spacing: appearance.markdownMetric(6)) {
      ForEach(items) { item in
        HStack(alignment: .firstTextBaseline, spacing: appearance.markdownMetric(8)) {
          Image(systemName: item.checked ? "checkmark.square.fill" : "square")
            .font(.system(size: appearance.fontSize * 0.95))
            .foregroundStyle(item.checked ? Color.accentColor : Color.secondary)
            .imageScale(.medium)
            .frame(width: markerWidth, alignment: .trailing)
            .accessibilityLabel(item.checked ? "Checked" : "Unchecked")
          MarkdownInlineText(
            value: item.text,
            appearance: appearance,
            font: textFont,
            uiFont: fontFamily.uiFont(size: appearance.fontSize),
            allowsTextSelection: allowsTextSelection,
            foregroundStyle: item.checked ? .secondary : foregroundStyle,
            uiForegroundColor: item.checked ? .secondaryLabel : uiForegroundColor,
            strikethrough: item.checked,
            italic: italic
          )
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
}

struct BulletListView: View {
  let items: [String]
  let appearance: AppearanceSettings
  var fontFamily: AppearanceFontFamily
  let allowsTextSelection: Bool
  let foregroundStyle: Color?
  let uiForegroundColor: UIColor?
  let italic: Bool

  init(
    items: [String],
    appearance: AppearanceSettings,
    fontFamily: AppearanceFontFamily? = nil,
    allowsTextSelection: Bool = true,
    foregroundStyle: Color? = nil,
    uiForegroundColor: UIColor? = nil,
    italic: Bool = false
  ) {
    self.items = items
    self.appearance = appearance
    self.fontFamily = fontFamily ?? appearance.assistantFontFamily
    self.allowsTextSelection = allowsTextSelection
    self.foregroundStyle = foregroundStyle
    self.uiForegroundColor = uiForegroundColor
    self.italic = italic
  }

  var body: some View {
    let textFont = fontFamily.swiftUIFont(size: appearance.fontSize)
    let markerWidth = appearance.markdownListMarkerWidth(markerLength: 1)
    VStack(alignment: .leading, spacing: appearance.markdownMetric(6)) {
      ForEach(Array(items.enumerated()), id: \.offset) { _, item in
        HStack(alignment: .firstTextBaseline, spacing: appearance.markdownMetric(8)) {
          Text("•")
            .font(textFont.italicizedIf(italic))
            .foregroundStyle(.secondary)
            .frame(width: markerWidth, alignment: .trailing)
          MarkdownInlineText(
            value: item,
            appearance: appearance,
            font: textFont,
            uiFont: fontFamily.uiFont(size: appearance.fontSize),
            allowsTextSelection: allowsTextSelection,
            foregroundStyle: foregroundStyle,
            uiForegroundColor: uiForegroundColor,
            italic: italic
          )
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
}

struct OrderedListView: View {
  let items: [OrderedListItem]
  let appearance: AppearanceSettings
  var fontFamily: AppearanceFontFamily
  let allowsTextSelection: Bool
  let foregroundStyle: Color?
  let uiForegroundColor: UIColor?
  let italic: Bool

  init(
    items: [OrderedListItem],
    appearance: AppearanceSettings,
    fontFamily: AppearanceFontFamily? = nil,
    allowsTextSelection: Bool = true,
    foregroundStyle: Color? = nil,
    uiForegroundColor: UIColor? = nil,
    italic: Bool = false
  ) {
    self.items = items
    self.appearance = appearance
    self.fontFamily = fontFamily ?? appearance.assistantFontFamily
    self.allowsTextSelection = allowsTextSelection
    self.foregroundStyle = foregroundStyle
    self.uiForegroundColor = uiForegroundColor
    self.italic = italic
  }

  var body: some View {
    let textFont = fontFamily.swiftUIFont(size: appearance.fontSize)
    let markerLength = items.map { $0.marker.count }.max() ?? 2
    let markerWidth = appearance.markdownListMarkerWidth(markerLength: markerLength)
    VStack(alignment: .leading, spacing: appearance.markdownMetric(6)) {
      ForEach(items) { item in
        HStack(alignment: .firstTextBaseline, spacing: appearance.markdownMetric(8)) {
          Text(item.marker)
            .font(textFont.italicizedIf(italic))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(width: markerWidth, alignment: .trailing)
          MarkdownInlineText(
            value: item.text,
            appearance: appearance,
            font: textFont,
            uiFont: fontFamily.uiFont(size: appearance.fontSize),
            allowsTextSelection: allowsTextSelection,
            foregroundStyle: foregroundStyle,
            uiForegroundColor: uiForegroundColor,
            italic: italic
          )
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
}

struct BlockquoteView: View {
  @Environment(\.markdownRenderImages) private var renderImages

  let text: String
  let appearance: AppearanceSettings
  var fontFamily: AppearanceFontFamily
  let allowsTextSelection: Bool
  let italic: Bool

  init(
    text: String,
    appearance: AppearanceSettings,
    fontFamily: AppearanceFontFamily? = nil,
    allowsTextSelection: Bool = true,
    italic: Bool = false
  ) {
    self.text = text
    self.appearance = appearance
    self.fontFamily = fontFamily ?? appearance.assistantFontFamily
    self.allowsTextSelection = allowsTextSelection
    self.italic = italic
  }

  var body: some View {
    HStack(alignment: .top, spacing: appearance.markdownMetric(10)) {
      RoundedRectangle(cornerRadius: 1.5, style: .continuous)
        .fill(Color.secondary.opacity(0.45))
        .frame(width: appearance.markdownMetric(3))
      MarkdownContentView(
        text: text,
        appearance: appearance,
        fontFamily: fontFamily,
        allowsTextSelection: allowsTextSelection,
        foregroundStyle: .secondary,
        uiForegroundColor: .secondaryLabel,
        renderImages: renderImages,
        italic: italic
      )
      .frame(maxWidth: .infinity, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, appearance.markdownMetric(2))
  }
}

private struct FootnotesView: View {
  let items: [(key: String, text: String)]
  let appearance: AppearanceSettings
  let fontFamily: AppearanceFontFamily
  let allowsTextSelection: Bool
  let foregroundStyle: Color?
  let uiForegroundColor: UIColor?
  let italic: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: appearance.markdownMetric(3)) {
      Divider()
        .overlay(Color.secondary.opacity(0.25))
      ForEach(Array(items.enumerated()), id: \.offset) { _, item in
        MarkdownInlineText(
          value: "\(MarkdownInlineSymbols.toSuperscript(item.key)) \(item.text)",
          appearance: appearance,
          font: fontFamily.swiftUIFont(size: appearance.fontSize * 0.82),
          uiFont: fontFamily.uiFont(size: appearance.fontSize * 0.82),
          allowsTextSelection: allowsTextSelection,
          foregroundStyle: foregroundStyle ?? Color.secondary,
          uiForegroundColor: uiForegroundColor ?? .secondaryLabel,
          italic: italic)
      }
    }
  }
}

struct MarkdownBlock: Identifiable {
  enum Kind {
    case heading(level: Int, text: String)
    case text(String)
    case blockquote(String)
    case horizontalRule
    case code(language: String, code: String)
    case mermaid(String)
    case table(headers: [String], rows: [[String]], alignments: [TextAlignment])
    case taskList(items: [TaskListItem])
    case bulletList(items: [String])
    case orderedList(items: [OrderedListItem])
    case footnotes(items: [(key: String, text: String)])
  }

  let id: Int
  var kind: Kind

  init(id: Int = 0, kind: Kind) {
    self.id = id
    self.kind = kind
  }
}

extension MarkdownBlock {
  fileprivate var isVisiblyEmpty: Bool {
    switch kind {
    case .text(let value), .blockquote(let value):
      return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .heading(_, let text):
      return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .code(_, let code):
      return code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .mermaid(let source):
      return source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .table(let headers, let rows, _):
      return headers.isEmpty && rows.isEmpty
    case .taskList(let items):
      return items.isEmpty
    case .bulletList(let items):
      return items.isEmpty
    case .orderedList(let items):
      return items.isEmpty
    case .footnotes(let items):
      return items.isEmpty
    case .horizontalRule:
      return false
    }
  }
}

enum MarkdownParser {
  @MainActor
  static func mayContainMarkdown(_ text: String) -> Bool {
    guard !text.isEmpty else { return false }
    if MarkdownInlineLinkScanner.containsLink(text) {
      return true
    }
    if containsBlockquoteLine(text) || containsHorizontalRuleLine(text)
      || containsOrderedListLine(text)
      || MarkdownInlineSymbols.containsMathSyntax(text)
      || text.range(of: "<br", options: .caseInsensitive) != nil
    {
      return true
    }
    let markers = ["```", "`", "**", "__", "- ", "* ", "+ ", "- [", "* [", "|", "[", "#"]
    return markers.contains { text.contains($0) }
  }

  static func blocks(from text: String, idOffset: Int = 0) -> [MarkdownBlock] {
    let lines = text.components(separatedBy: .newlines)
    var blocks: [MarkdownBlock] = []
    var textBuffer: [String] = []
    var codeBuffer: [String] = []
    var language = ""
    var inCode = false
    var index = 0

    func appendBlock(_ kind: MarkdownBlock.Kind) {
      blocks.append(MarkdownBlock(id: idOffset + blocks.count, kind: kind))
    }

    func flushText() {
      let value = textBuffer.joined(separator: "\n").trimmingCharacters(in: .newlines)
      if !value.isEmpty {
        appendBlock(.text(value))
      }
      textBuffer.removeAll()
    }

    func flushCode(fenceClosed: Bool) {
      let code = codeBuffer.joined(separator: "\n")
      if !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        if fenceClosed, MarkdownMermaidRenderer.isMermaidLanguage(language) {
          appendBlock(.mermaid(code))
        } else {
          appendBlock(.code(language: language, code: code))
        }
      }
      codeBuffer.removeAll()
      language = ""
    }

    func collectItems<T>(
      first: T,
      after index: Int,
      parse: (String) -> T?
    ) -> (items: [T], nextIndex: Int) {
      var items: [T] = [first]
      var cursor = index + 1
      while cursor < lines.count {
        guard let item = parse(lines[cursor]) else { break }
        items.append(item)
        cursor += 1
      }
      return (items, cursor)
    }

    func parseTrimmed<T>(_ line: String, with parser: (String) -> T?) -> T? {
      parser(line.trimmingCharacters(in: .whitespaces))
    }

    while index < lines.count {
      let line = lines[index]
      let trimmed = line.trimmingCharacters(in: .whitespaces)

      if trimmed.hasPrefix("```") {
        if inCode {
          flushCode(fenceClosed: true)
          inCode = false
        } else {
          flushText()
          language = String(trimmed.dropFirst(3))
          inCode = true
        }
        index += 1
        continue
      }

      if inCode {
        codeBuffer.append(line)
        index += 1
        continue
      }

      if let firstLine = blockquoteLine(line) {
        flushText()
        let block = collectItems(first: firstLine, after: index, parse: blockquoteLine)
        appendBlock(.blockquote(block.items.joined(separator: "\n")))
        index = block.nextIndex
        continue
      }

      if let heading = heading(trimmed) {
        flushText()
        appendBlock(.heading(level: heading.level, text: heading.text))
        index += 1
        continue
      }

      if isHorizontalRule(trimmed) {
        flushText()
        appendBlock(.horizontalRule)
        index += 1
        continue
      }

      if let firstItem = taskListItem(trimmed) {
        flushText()
        let block = collectItems(first: firstItem, after: index) {
          parseTrimmed($0, with: taskListItem)
        }
        appendBlock(.taskList(items: block.items))
        index = block.nextIndex
        continue
      }

      if let firstItem = orderedListItem(trimmed) {
        flushText()
        let block = collectItems(first: firstItem, after: index) {
          parseTrimmed($0, with: orderedListItem)
        }
        appendBlock(.orderedList(items: block.items))
        index = block.nextIndex
        continue
      }

      if let firstItem = bulletListItem(trimmed) {
        flushText()
        let block = collectItems(first: firstItem, after: index) {
          parseTrimmed($0, with: bulletListItem)
        }
        appendBlock(.bulletList(items: block.items))
        index = block.nextIndex
        continue
      }

      if let firstItem = footnoteDefinition(trimmed) {
        flushText()
        let block = collectItems(first: firstItem, after: index) {
          parseTrimmed($0, with: footnoteDefinition)
        }
        appendBlock(.footnotes(items: block.items))
        index = block.nextIndex
        continue
      }

      if Self.containsTablePipe(trimmed),
        index + 1 < lines.count,
        let alignments = tableAlignments(
          lines[index + 1].trimmingCharacters(in: .whitespaces)
        )
      {
        let headers = splitTableRow(trimmed)
        if headers.count == alignments.count, !headers.isEmpty {
          flushText()
          var rows: [[String]] = []
          var cursor = index + 2
          while cursor < lines.count {
            let rowTrimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
            guard Self.containsTablePipe(rowTrimmed), tableAlignments(rowTrimmed) == nil else {
              break
            }
            var cells = splitTableRow(rowTrimmed)
            while cells.count < headers.count { cells.append("") }
            if cells.count > headers.count { cells = Array(cells.prefix(headers.count)) }
            rows.append(cells)
            cursor += 1
          }
          appendBlock(.table(headers: headers, rows: rows, alignments: alignments))
          index = cursor
          continue
        }
      }

      textBuffer.append(line)
      index += 1
    }
    if inCode {
      flushCode(fenceClosed: false)
    }
    flushText()
    return blocks.isEmpty ? [MarkdownBlock(id: idOffset, kind: .text(text))] : blocks
  }

  private static func footnoteDefinition(_ trimmed: String) -> (key: String, text: String)? {
    guard trimmed.hasPrefix("[^") else { return nil }
    guard let closeBracket = trimmed.firstIndex(of: "]") else { return nil }
    let afterClose = trimmed.index(after: closeBracket)
    guard afterClose < trimmed.endIndex, trimmed[afterClose] == ":" else { return nil }
    let key = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<closeBracket])
    guard !key.isEmpty else { return nil }
    var textStart = trimmed.index(after: afterClose)
    if textStart < trimmed.endIndex, trimmed[textStart] == " " {
      textStart = trimmed.index(after: textStart)
    }
    return (key: key, text: String(trimmed[textStart...]))
  }

  private static func containsBlockquoteLine(_ text: String) -> Bool {
    text.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
      line.drop(while: { $0 == " " || $0 == "\t" }).first == ">"
    }
  }

  private static func containsHorizontalRuleLine(_ text: String) -> Bool {
    text.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
      isHorizontalRule(String(line).trimmingCharacters(in: .whitespaces))
    }
  }

  private static func containsOrderedListLine(_ text: String) -> Bool {
    text.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
      orderedListItem(String(line).trimmingCharacters(in: .whitespaces)) != nil
    }
  }

  private static func blockquoteLine(_ line: String) -> String? {
    var text = line.drop(while: { $0 == " " || $0 == "\t" })
    guard text.first == ">" else { return nil }
    text = text.dropFirst()
    if text.first == " " {
      text = text.dropFirst()
    }
    return String(text)
  }

  private static func heading(_ trimmed: String) -> (level: Int, text: String)? {
    guard trimmed.hasPrefix("#") else { return nil }
    let level = trimmed.prefix(while: { $0 == "#" }).count
    guard (1...6).contains(level), trimmed.count > level else { return nil }
    let separatorIndex = trimmed.index(trimmed.startIndex, offsetBy: level)
    guard trimmed[separatorIndex] == " " else { return nil }
    let text = trimmed[trimmed.index(after: separatorIndex)...]
      .trimmingCharacters(in: .whitespaces)
    return text.isEmpty ? nil : (level, text)
  }

  private static func isHorizontalRule(_ trimmed: String) -> Bool {
    guard trimmed.count >= 3, let first = trimmed.first,
      first == "-" || first == "_" || first == "*"
    else { return false }
    return trimmed.allSatisfy { $0 == first }
  }

  private static func taskListItem(_ trimmed: String) -> TaskListItem? {
    let bulletMarkers: [Character] = ["-", "*", "+"]
    guard let first = trimmed.first, bulletMarkers.contains(first) else { return nil }
    var rest = trimmed.dropFirst()
    guard rest.first == " " else { return nil }
    rest = rest.drop(while: { $0 == " " })
    guard rest.first == "[", rest.count >= 3 else { return nil }
    let mark = rest[rest.index(after: rest.startIndex)]
    let closeIndex = rest.index(rest.startIndex, offsetBy: 2)
    guard rest[closeIndex] == "]" else { return nil }
    let checked: Bool
    switch mark {
    case " ": checked = false
    case "x", "X": checked = true
    default: return nil
    }
    var text = rest.dropFirst(3)
    if let space = text.first, space != " " && !text.isEmpty { return nil }
    text = text.drop(while: { $0 == " " })
    return TaskListItem(text: String(text), checked: checked)
  }

  private static func bulletListItem(_ trimmed: String) -> String? {
    let bulletMarkers: [Character] = ["-", "*", "+"]
    guard let first = trimmed.first, bulletMarkers.contains(first) else { return nil }
    var rest = trimmed.dropFirst()
    guard rest.first == " " else { return nil }
    rest = rest.drop(while: { $0 == " " })
    guard !rest.isEmpty else { return nil }
    return String(rest)
  }

  private static func orderedListItem(_ trimmed: String) -> OrderedListItem? {
    var cursor = trimmed.startIndex
    var digits = ""
    while cursor < trimmed.endIndex, trimmed[cursor].isNumber, digits.count < 9 {
      digits.append(trimmed[cursor])
      cursor = trimmed.index(after: cursor)
    }
    guard !digits.isEmpty, cursor < trimmed.endIndex else { return nil }
    let delimiter = trimmed[cursor]
    guard delimiter == "." || delimiter == ")" else { return nil }
    cursor = trimmed.index(after: cursor)
    guard cursor < trimmed.endIndex, trimmed[cursor].isWhitespace else { return nil }
    let text = trimmed[cursor...].drop(while: \.isWhitespace)
    guard !text.isEmpty, let number = Int(digits) else { return nil }
    return OrderedListItem(number: number, delimiter: String(delimiter), text: String(text))
  }

  private static func normalizeTablePipes(_ line: String) -> String {
    var result = line
    for ch in ["\u{2502}", "\u{2503}", "\u{FF5C}"] {
      if result.contains(ch) {
        result = result.replacingOccurrences(of: ch, with: "|")
      }
    }
    return result
  }

  static func containsTablePipe(_ line: String) -> Bool {
    line.contains("|") || line.contains("\u{2502}") || line.contains("\u{2503}")
      || line.contains("\u{FF5C}")
  }

  private static func splitTableRow(_ line: String) -> [String] {
    var s = normalizeTablePipes(line)
    if s.hasPrefix("|") { s.removeFirst() }
    if s.hasSuffix("|") { s.removeLast() }
    let placeholder = "\u{1}"
    s = s.replacingOccurrences(of: "\\|", with: placeholder)
    return s.components(separatedBy: "|").map {
      $0.replacingOccurrences(of: placeholder, with: "|")
        .trimmingCharacters(in: .whitespaces)
    }
  }

  private static func tableAlignments(_ line: String) -> [TextAlignment]? {
    let normalized = normalizeTablePipes(line)
    guard normalized.contains("|"), normalized.contains("-") else { return nil }
    let cells = splitTableRow(normalized)
    guard !cells.isEmpty else { return nil }
    var alignments: [TextAlignment] = []
    for cell in cells {
      let trimmed = cell.trimmingCharacters(in: .whitespaces)
      let leading = trimmed.hasPrefix(":")
      let trailing = trimmed.hasSuffix(":")
      let core = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
      guard !core.isEmpty, core.allSatisfy({ $0 == "-" }) else { return nil }
      if leading && trailing {
        alignments.append(.center)
      } else if trailing {
        alignments.append(.trailing)
      } else {
        alignments.append(.leading)
      }
    }
    return alignments
  }
}
