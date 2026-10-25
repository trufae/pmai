import SwiftUI
import UIKit

/// The categories of media surfaced by the gallery. Images and text-file
/// attachments come from `ChatAttachment`s; voice comes from a message's
/// `voiceRecordingFilename`.
enum GalleryMediaKind: String, CaseIterable, Identifiable {
  case image
  case document
  case voice

  var id: String { rawValue }

  var pluralTitle: String {
    switch self {
    case .image: "Images"
    case .document: "Documents"
    case .voice: "Voice"
    }
  }

  var systemImage: String {
    switch self {
    case .image: "photo"
    case .document: "doc.text"
    case .voice: "waveform"
    }
  }
}

/// One row in the gallery. A media file plus the conversation it belongs to and
/// when it was created. `attachment` is present for images/documents; `message`
/// carries the voice recording for `.voice` items.
struct GalleryItem: Identifiable {
  let id: UUID
  let kind: GalleryMediaKind
  let conversationID: UUID
  let conversationTitle: String
  let date: Date
  let displayName: String
  /// Lower-cased haystack for the search field: filename, document text, title.
  let searchText: String
  let attachment: ChatAttachment?
  let message: ChatMessage?
}

/// A single place to browse every file (pictures, documents, voice) across all
/// conversations, with search and per-item preview + share.
struct GalleryView: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss

  @State private var items: [GalleryItem] = []
  @State private var isLoading = true
  @State private var searchText = ""
  @State private var filter: GalleryFilter = .all

  @State private var imagePreview: GalleryItem?
  @State private var documentPreview: GalleryItem?
  @State private var voicePreview: GalleryItem?
  @State private var shareItem: GalleryShareItem?

  enum GalleryFilter: String, CaseIterable, Identifiable {
    case all
    case images
    case documents
    case voice

    var id: String { rawValue }

    var title: String {
      switch self {
      case .all: "All"
      case .images: "Images"
      case .documents: "Docs"
      case .voice: "Voice"
      }
    }

    func matches(_ kind: GalleryMediaKind) -> Bool {
      switch self {
      case .all: true
      case .images: kind == .image
      case .documents: kind == .document
      case .voice: kind == .voice
      }
    }
  }

  var body: some View {
    NavigationStack {
      Group {
        if isLoading {
          ProgressView("Loading media…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredItems.isEmpty {
          emptyState
        } else {
          List {
            Section {
              Picker("Filter", selection: $filter) {
                ForEach(GalleryFilter.allCases) { option in
                  Text(option.title).tag(option)
                }
              }
              .pickerStyle(.segmented)
              .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
              .listRowSeparator(.hidden)
            }
            ForEach(filteredItems) { item in
              Button {
                open(item)
              } label: {
                GalleryRow(item: item)
              }
              .buttonStyle(.plain)
              .contextMenu {
                Button {
                  share(item)
                } label: {
                  Label("Share", systemImage: "square.and.arrow.up")
                }
              }
            }
          }
          .listStyle(.plain)
        }
      }
      .navigationTitle("Gallery")
      .navigationBarTitleDisplayMode(.inline)
      .searchable(text: $searchText, prompt: "Search filenames and contents")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    .task { await loadItems() }
    .fullScreenCover(item: $imagePreview) { item in
      if let attachment = item.attachment {
        MessageImageFullscreenLoader(attachment: attachment)
      }
    }
    .sheet(item: $documentPreview) { item in
      if let attachment = item.attachment {
        MessageTextSelectionSheet(
          title: attachment.displayName,
          text: attachment.text ?? "",
          appearance: store.settings.appearance,
          initialFontSize: store.settings.appearance.fontSize,
          initialLineSpacing: store.settings.appearance.lineSpacing,
          fontFamily: store.settings.appearance.fontFamily(for: .user),
          isEditable: false)
      }
    }
    .sheet(item: $voicePreview) { item in
      if let message = item.message {
        GalleryVoicePlayerView(
          message: message,
          title: item.displayName,
          conversationTitle: item.conversationTitle,
          date: item.date,
          onShare: { share(item) })
      }
    }
    .sheet(item: $shareItem) { item in
      ActivityShareSheet(activityItems: item.items)
    }
  }

  private var filteredItems: [GalleryItem] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return items.filter { item in
      guard filter.matches(item.kind) else { return false }
      guard !query.isEmpty else { return true }
      return item.searchText.contains(query)
    }
  }

  @ViewBuilder
  private var emptyState: some View {
    VStack(spacing: 10) {
      Image(systemName: "photo.on.rectangle.angled")
        .font(.system(size: 42))
        .foregroundStyle(.secondary)
      Text(searchText.isEmpty ? "No media yet" : "No matches")
        .font(.headline)
      Text(
        searchText.isEmpty
          ? "Files you attach or record in conversations appear here."
          : "Try a different search or filter.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func open(_ item: GalleryItem) {
    switch item.kind {
    case .image: imagePreview = item
    case .document: documentPreview = item
    case .voice: voicePreview = item
    }
  }

  private func share(_ item: GalleryItem) {
    guard let items = GalleryShareBuilder.activityItems(for: item) else { return }
    shareItem = GalleryShareItem(items: items)
  }

  private func loadItems() async {
    await store.loadStoredConversationsForSearch()
    let built = GalleryItemBuilder.items(from: store.conversations)
    await MainActor.run {
      items = built
      isLoading = false
    }
  }
}

/// Builds the flat, newest-first list of gallery items from full conversations.
private enum GalleryItemBuilder {
  static func items(from conversations: [Conversation]) -> [GalleryItem] {
    var result: [GalleryItem] = []
    for conversation in conversations {
      let title = conversation.displayTitle
      for message in conversation.messages {
        for attachment in message.attachments {
          let kind: GalleryMediaKind = attachment.kind == .image ? .image : .document
          let contents = kind == .document ? (attachment.text ?? "") : ""
          result.append(
            GalleryItem(
              id: attachment.id,
              kind: kind,
              conversationID: conversation.id,
              conversationTitle: title,
              date: message.createdAt,
              displayName: attachment.displayName,
              searchText: "\(attachment.filename)\n\(contents)\n\(title)".lowercased(),
              attachment: attachment,
              message: nil))
        }
        if let filename = message.voiceRecordingFilename?
          .trimmingCharacters(in: .whitespacesAndNewlines),
          !filename.isEmpty,
          PocketMaiDirectories.voiceRecordingURL(filename: filename) != nil
        {
          result.append(
            GalleryItem(
              id: message.id,
              kind: .voice,
              conversationID: conversation.id,
              conversationTitle: title,
              date: message.createdAt,
              displayName: filename,
              searchText: "\(filename)\n\(title)".lowercased(),
              attachment: nil,
              message: message))
        }
      }
    }
    return result.sorted { $0.date > $1.date }
  }
}

/// Assembles share-sheet payloads: a real file where possible, falling back to text.
private enum GalleryShareBuilder {
  static func activityItems(for item: GalleryItem) -> [Any]? {
    switch item.kind {
    case .image:
      guard let base64 = item.attachment?.resolvedDataBase64,
        let data = Data(base64Encoded: base64)
      else { return nil }
      if let url = tempFile(named: item.displayName, data: data) { return [url] }
      if let image = UIImage(data: data) { return [image] }
      return nil
    case .document:
      let text = item.attachment?.text ?? ""
      if let url = tempFile(named: item.displayName, data: Data(text.utf8)) { return [url] }
      return [text]
    case .voice:
      guard let url = PocketMaiDirectories.voiceRecordingURL(filename: item.displayName) else {
        return nil
      }
      return [url]
    }
  }

  private static func tempFile(named name: String, data: Data) -> URL? {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let base = trimmed.isEmpty ? "attachment" : trimmed
    let safe = base.components(separatedBy: CharacterSet(charactersIn: "/\\:")).joined(separator: "-")
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(safe)
    do {
      try data.write(to: url, options: .atomic)
      return url
    } catch {
      return nil
    }
  }
}

struct GalleryShareItem: Identifiable {
  let id = UUID()
  let items: [Any]
}

private struct GalleryRow: View {
  let item: GalleryItem

  var body: some View {
    HStack(spacing: 12) {
      thumbnail
      VStack(alignment: .leading, spacing: 3) {
        Text(item.displayName)
          .font(.subheadline.weight(.semibold))
          .lineLimit(1)
          .truncationMode(.middle)
        Text(item.conversationTitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Text(item.date.formatted(date: .abbreviated, time: .shortened))
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      Spacer(minLength: 0)
      Image(systemName: "chevron.right")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.tertiary)
    }
    .padding(.vertical, 4)
    .contentShape(Rectangle())
  }

  @ViewBuilder
  private var thumbnail: some View {
    if item.kind == .image, let attachment = item.attachment {
      AttachmentImageThumbnail(attachment: attachment, side: 48, cornerRadius: 8)
    } else {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color.secondary.opacity(0.12))
        .frame(width: 48, height: 48)
        .overlay(
          Image(systemName: item.kind.systemImage)
            .font(.system(size: 20, weight: .regular))
            .foregroundStyle(.secondary))
    }
  }
}

/// A compact preview screen for a voice recording: play/pause plus share.
private struct GalleryVoicePlayerView: View {
  @EnvironmentObject private var ttsPlayer: TTSPlayer
  @Environment(\.dismiss) private var dismiss

  let message: ChatMessage
  let title: String
  let conversationTitle: String
  let date: Date
  let onShare: () -> Void

  private var isCurrent: Bool {
    ttsPlayer.currentMessageID == message.id && ttsPlayer.currentRole == .user
  }

  private var isPlaying: Bool {
    isCurrent && ttsPlayer.isSpeaking && !ttsPlayer.isPaused
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 20) {
        Spacer()
        Image(systemName: "waveform")
          .font(.system(size: 54, weight: .regular))
          .foregroundStyle(.secondary)
        VStack(spacing: 4) {
          Text(title)
            .font(.headline)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .truncationMode(.middle)
          Text(conversationTitle)
            .font(.subheadline)
            .foregroundStyle(.secondary)
          Text(date.formatted(date: .abbreviated, time: .shortened))
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        Button {
          ttsPlayer.toggleRecordingPlayback(for: message, title: "User Recording")
        } label: {
          Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
            .font(.system(size: 72, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPlaying ? "Pause recording" : "Play recording")
        Spacer()
      }
      .padding(32)
      .frame(maxWidth: .infinity)
      .navigationTitle("Voice")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") {
            if isCurrent { ttsPlayer.stop() }
            dismiss()
          }
        }
        ToolbarItem(placement: .primaryAction) {
          Button {
            onShare()
          } label: {
            Image(systemName: "square.and.arrow.up")
          }
          .accessibilityLabel("Share")
        }
      }
    }
  }
}
