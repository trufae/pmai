import SwiftUI

/// A read-only transcript: importing never needs the live chat's actions or tool UI.
struct ConversationImportTranscript: View {
  let conversation: Conversation

  var body: some View {
    LazyVStack(alignment: .leading, spacing: 20) {
      Text(conversation.displayTitle)
        .font(.title2.bold())
        .accessibilityAddTraits(.isHeader)

      if conversation.messages.isEmpty {
        Text("No messages in this conversation.")
          .foregroundStyle(.secondary)
      }

      ForEach(conversation.messages) { message in
        let text = ConversationExportContent.messageContent(for: message).visibleText
        if message.role != .tool, !text.isEmpty || !message.attachments.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            Text(message.role.displayName)
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(.secondary)
            if !text.isEmpty {
              MarkdownContentView(text: text, renderImages: false)
            }
            ForEach(message.attachments) { attachment in
              HStack {
                if attachment.kind == .image {
                  AttachmentImageThumbnail(attachment: attachment, side: 64, cornerRadius: 8)
                } else {
                  Image(systemName: "paperclip")
                }
                Text(attachment.displayName)
                  .font(.subheadline)
                  .foregroundStyle(.secondary)
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding()
          .background(
            message.role == .user ? Color(.secondarySystemBackground) : Color.clear,
            in: RoundedRectangle(cornerRadius: 16))
        }
      }
    }
  }
}

struct ConversationCollectionImportView: View {
  private enum DestinationMode: String, CaseIterable, Identifiable {
    case newFolder
    case existingFolder

    var id: String { rawValue }

    var title: String {
      switch self {
      case .newFolder: "New Folder"
      case .existingFolder: "Existing Folder"
      }
    }
  }

  @EnvironmentObject private var store: AppStore

  let file: PendingConversationImportFile
  let onFinish: () -> Void

  @State private var preview: ConversationCollectionImportPreview?
  @State private var destinationMode = DestinationMode.newFolder
  @State private var newFolderName = "Imported Conversations"
  @State private var existingFolderID = ConversationFolder.defaultID
  @State private var isImporting = false
  @State private var toast: String?
  @State private var errorMessage: String?

  var body: some View {
    NavigationStack {
      Form {
        if let preview {
          contentsSection(preview)
          destinationSection
        } else if let errorMessage {
          Section {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
              .foregroundStyle(.red)
          }
        } else {
          Section {
            HStack(spacing: 10) {
              ProgressView()
              Text("Reading \(file.filename)...")
            }
          }
        }

        if let errorMessage, preview != nil {
          Section {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
              .foregroundStyle(.red)
          }
        }
      }
      .navigationTitle("Import Conversations")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            onFinish()
          }
        }
        if let preview {
          ToolbarItem(placement: .confirmationAction) {
            Button {
              importConversations(preview)
            } label: {
              if isImporting {
                ProgressView()
                  .accessibilityLabel("Importing")
              } else {
                Text("Import")
                  .fontWeight(.semibold)
              }
            }
            .disabled(isImporting || !canImport)
          }
        }
      }
      .disabled(isImporting)
    }
    .interactiveDismissDisabled(isImporting)
    .task(id: file.id) {
      preparePreview()
    }
    .settingsToast($toast, style: .success)
  }

  private func contentsSection(_ preview: ConversationCollectionImportPreview) -> some View {
    Section {
      ForEach(preview.conversations) { conversation in
        NavigationLink {
          ScrollView {
            ConversationImportTranscript(conversation: conversation)
              .padding()
          }
          .navigationTitle("Preview")
          .navigationBarTitleDisplayMode(.inline)
        } label: {
          Label(conversation.displayTitle, systemImage: "bubble.left")
        }
      }
    } header: {
      Text("Contents")
    }
  }

  private var destinationSection: some View {
    Section {
      Picker("Destination", selection: $destinationMode) {
        ForEach(DestinationMode.allCases) { mode in
          Text(mode.title).tag(mode)
        }
      }
      .pickerStyle(.segmented)

      switch destinationMode {
      case .newFolder:
        TextField("Folder name", text: $newFolderName)
          .textInputAutocapitalization(.words)
      case .existingFolder:
        Picker("Folder", selection: $existingFolderID) {
          ForEach(availableFolders) { folder in
            Label(folder.displayName, systemImage: folder.systemImage)
              .tag(folder.id)
          }
        }
      }
    } header: {
      Text("Import Into")
    } footer: {
      Text("Every conversation in the file will be placed in this folder.")
    }
  }

  private var availableFolders: [ConversationFolder] {
    store.conversationFolders.filter {
      $0.id != ConversationFolder.archivedID && store.canUseConversationFolder($0.id)
    }
  }

  private var canImport: Bool {
    switch destinationMode {
    case .newFolder:
      !newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .existingFolder:
      availableFolders.contains { $0.id == existingFolderID }
    }
  }

  private func preparePreview() {
    do {
      let preview = try store.previewConversationCollectionImport(file)
      self.preview = preview
      newFolderName = store.suggestedConversationImportFolderName(
        conversationCount: preview.conversations.count)
      if availableFolders.contains(where: { $0.id == store.selectedConversationFolderID }) {
        existingFolderID = store.selectedConversationFolderID
      } else {
        existingFolderID = availableFolders.first?.id ?? ConversationFolder.defaultID
      }
      errorMessage = nil
    } catch {
      preview = nil
      errorMessage = error.localizedDescription
    }
  }

  private func importConversations(_ preview: ConversationCollectionImportPreview) {
    guard !isImporting else { return }
    isImporting = true
    errorMessage = nil
    let destination: ConversationCollectionImportDestination =
      switch destinationMode {
      case .newFolder:
        .newFolder(name: newFolderName)
      case .existingFolder:
        .existingFolder(id: existingFolderID)
      }
    Task { @MainActor in
      do {
        let count = try await store.importConversationCollection(
          preview, destination: destination)
        withAnimation(.snappy) {
          toast = "Imported \(count) conversation\(count == 1 ? "" : "s")."
        }
        try? await Task.sleep(for: .milliseconds(900))
        onFinish()
      } catch {
        errorMessage = error.localizedDescription
        isImporting = false
      }
    }
  }
}
