import SwiftUI

struct ConversationOrganizerView: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dismiss) private var dismiss
  @State private var queue: [UUID] = []
  @State private var started = false
  @State private var offset = CGSize.zero
  @State private var isBusy = false
  @State private var showingFolders = false
  @State private var previewConversation: ConversationSummary?
  @State private var pendingDeletion: PendingConversationDeletion?
  @State private var errorMessage: String?

  private var current: ConversationSummary? {
    guard let id = queue.first else { return nil }
    return store.conversationSummaries.first { $0.id == id }
  }

  private var spring: Animation? {
    reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.55)
  }

  var body: some View {
    VStack(spacing: 16) {
      if let conversation = current {
        VStack(spacing: 8) {
          Text("Swipe the card to take action")
            .font(.headline)
          Text("Left to delete · Right to keep\nUp to move · Down to close")
            .font(.subheadline)
            .foregroundStyle(.secondary)
          Text("\(queue.count) remaining · Shuffled for this visit")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(.top, 8)

        ZStack {
          RoundedRectangle(cornerRadius: 24)
            .fill(Color.accentColor.opacity(0.12))
            .rotationEffect(.degrees(-3))
            .padding(8)
          ConversationOrganizerCard(conversation: conversation)
            .id(conversation.id)
            .offset(offset)
            .rotationEffect(.degrees(reduceMotion ? 0 : Double(offset.width / 24)))
            .gesture(
              DragGesture(minimumDistance: 10)
                .onChanged { value in
                  guard !isBusy else { return }
                  offset = value.translation
                }
                .onEnded { value in
                  guard !isBusy else { return }
                  let drag = value.translation
                  guard max(abs(drag.width), abs(drag.height)) > 80 else {
                    resetCard()
                    return
                  }
                  if abs(drag.width) > abs(drag.height) {
                    if drag.width < 0 {
                      requestDeletion(conversation)
                    } else {
                      advance(conversation.id)
                    }
                  } else if drag.height < 0 {
                    resetCard()
                    showingFolders = true
                  } else {
                    dismiss()
                  }
                }
            )
            .onTapGesture { showPreview(conversation) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(
              "Tap to read the full conversation. Swipe left to delete, up to move, right to keep, or down to close."
            )
            .accessibilityAction { showPreview(conversation) }
            .accessibilityAction(named: "Delete Conversation") { requestDeletion(conversation) }
            .accessibilityAction(named: "Move to Folder") { showingFolders = true }
            .accessibilityAction(named: "Keep Conversation") { advance(conversation.id) }
            .accessibilityAction(named: "Close Organizer") { dismiss() }
            .disabled(isBusy)
        }
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
        .frame(maxWidth: 300, maxHeight: 450)
        .padding(.horizontal, 48)

        Text("Tap the card to read the full conversation")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)

        Spacer(minLength: 16)
      } else {
        ContentUnavailableView(
          "All Done", systemImage: "checkmark.seal",
          description: Text("Open Organize Chats again for a fresh shuffle."))
      }
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(uiColor: .systemGroupedBackground))
    .overlay(alignment: .leading) {
      swipeHint(icon: "trash", color: .red, distance: -offset.width)
        .padding(.leading, 16)
    }
    .overlay(alignment: .top) {
      swipeHint(icon: "folder", color: .accentColor, distance: -offset.height)
        .padding(.top, 16)
    }
    .overlay(alignment: .trailing) {
      swipeHint(icon: "checkmark", color: .green, distance: offset.width)
        .padding(.trailing, 16)
    }
    .navigationTitle("Organize Chats")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      guard !started else { return }
      started = true
      queue = store.conversationSummaries.filter(\.hasMessages).map(\.id).shuffled()
    }
    .onChange(of: store.conversationSummaries.map(\.id)) { _, ids in
      let existing = Set(ids)
      queue.removeAll { !existing.contains($0) }
    }
    .conversationDeletionAlert($pendingDeletion) { ids in
      store.deleteConversations(ids)
      queue.removeAll { ids.contains($0) }
    }
    .errorAlert("Could Not Organize Chat", message: $errorMessage)
    .sheet(item: $previewConversation) { conversation in
      ConversationOrganizerPreview(conversationID: conversation.id)
    }
    .sheet(isPresented: $showingFolders) {
      NavigationStack {
        List(store.conversationFolders) { folder in
          Button {
            guard let conversation = current, !isBusy else { return }
            isBusy = true
            Task {
              await store.moveConversation(id: conversation.id, to: folder.id)
              isBusy = false
              showingFolders = false
              if store.conversationSummaries.first(where: { $0.id == conversation.id })?.folderID
                == folder.id
              {
                advance(conversation.id)
              } else {
                errorMessage = store.errorMessage ?? "The conversation could not be moved."
              }
            }
          } label: {
            Label(folder.displayName,
              systemImage: folder.id == current?.folderID ? "checkmark" : folder.systemImage)
          }
          .disabled(isBusy || !store.canUseConversationFolder(folder.id)
            || folder.id == current?.folderID)
        }
        .navigationTitle("Move to Folder")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { showingFolders = false }.disabled(isBusy)
          }
        }
      }
      .interactiveDismissDisabled(isBusy)
    }
  }

  private func swipeHint(icon: String, color: Color, distance: CGFloat) -> some View {
    let progress = min(1, max(0, distance / 140))
    return Image(systemName: icon)
      .font(.title2.weight(.semibold))
      .foregroundStyle(color)
      .frame(width: 48, height: 48)
      .background(color.opacity(0.14), in: Circle())
      .overlay { Circle().strokeBorder(color.opacity(0.35), lineWidth: 1) }
      .scaleEffect(reduceMotion ? 1 : 0.8 + progress * 0.2)
      .opacity(Double(progress))
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }

  private func resetCard() {
    withAnimation(spring) { offset = .zero }
  }

  private func showPreview(_ conversation: ConversationSummary) {
    guard !isBusy else { return }
    resetCard()
    previewConversation = conversation
  }

  private func requestDeletion(_ conversation: ConversationSummary) {
    resetCard()
    pendingDeletion = .single(conversation)
  }

  private func advance(_ id: UUID) {
    isBusy = true
    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
      offset = CGSize(width: 600, height: 0)
    } completion: {
      queue.removeAll { $0 == id }
      offset = .zero
      isBusy = false
    }
  }
}

private struct ConversationOrganizerPreview: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  let conversationID: UUID
  @State private var conversation: Conversation?
  @State private var errorMessage: String?
  @State private var loadID = UUID()

  var body: some View {
    NavigationStack {
      Group {
        if let conversation {
          ScrollView {
            ConversationImportTranscript(conversation: conversation)
              .padding()
              .textSelection(.enabled)
          }
        } else if let errorMessage {
          ContentUnavailableView {
            Label("Could Not Load Conversation", systemImage: "exclamationmark.triangle")
          } description: {
            Text(errorMessage)
          } actions: {
            Button("Try Again") { loadID = UUID() }
          }
        } else {
          ProgressView("Loading conversation…")
        }
      }
      .navigationTitle("Conversation Preview")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
      }
      .task(id: loadID) {
        errorMessage = nil
        do {
          let loaded = try await store.conversationPreview(id: conversationID)
          guard !Task.isCancelled else { return }
          conversation = loaded
        } catch {
          guard !Task.isCancelled else { return }
          errorMessage = "Could not read the full conversation. Try again after syncing."
        }
      }
    }
  }
}

private struct ConversationOrganizerCard: View {
  @EnvironmentObject private var store: AppStore
  let conversation: ConversationSummary
  @State private var messages: [ConversationPreviewMessage] = []
  @State private var isLoading = true
  @State private var errorMessage: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top) {
        Text(conversation.displayTitle)
          .font(.system(.title3, design: .serif, weight: .bold))
          .lineLimit(2)
        Spacer(minLength: 4)
        Image(systemName: conversation.isPinned ? "pin.fill" : "sparkles")
          .foregroundStyle(.orange)
          .accessibilityLabel(conversation.isPinned ? "Pinned" : "Unpinned")
      }
      Text(ConversationDatePresentation.startedText(conversation.createdAt))
        .font(.caption)
        .foregroundStyle(.secondary)
      Label(store.folderDisplayName(for: conversation.folderID), systemImage: "folder")
        .font(.caption.weight(.semibold))
        .lineLimit(1)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
      Divider()
      if isLoading {
        ProgressView("Reading the beginning…")
      } else if let errorMessage {
        Text(errorMessage).font(.callout).foregroundStyle(.secondary)
      } else if messages.isEmpty {
        Text("No opening messages.").foregroundStyle(.secondary)
      } else {
        ViewThatFits(in: .vertical) {
          openingMessages(limit: 3)
          openingMessages(limit: 1)
        }
      }
      Spacer(minLength: 0)
      Text("POCKETMAI · CONVERSATION")
        .font(.caption2.weight(.semibold))
        .tracking(2)
        .foregroundStyle(.secondary)
    }
    .padding(22)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color(uiColor: .secondarySystemGroupedBackground),
      in: RoundedRectangle(cornerRadius: 22))
    .overlay {
      RoundedRectangle(cornerRadius: 22)
        .strokeBorder(
          LinearGradient(colors: [.orange.opacity(0.8), .accentColor.opacity(0.5), .orange],
            startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 4)
    }
    .shadow(color: .black.opacity(0.18), radius: 14, y: 8)
    .contentShape(RoundedRectangle(cornerRadius: 22))
    .task(id: conversation.id) {
      do {
        let opening = try await store.conversationOpeningMessages(id: conversation.id)
        guard !Task.isCancelled else { return }
        messages = opening
      } catch {
        guard !Task.isCancelled else { return }
        errorMessage = "Could not read this conversation. Try again after syncing."
      }
      isLoading = false
    }
  }

  private func openingMessages(limit: Int) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(messages.prefix(limit)) { message in
        VStack(alignment: .leading, spacing: 3) {
          Text(message.role == .user ? "You" : "Assistant")
            .font(.caption.weight(.bold))
            .foregroundStyle(.secondary)
          let text = MessageContentFilter.markdownPlainText(
            from: message.chatMessage.presentationText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
          Text(text.isEmpty ? "Attachment or empty message" : text)
            .font(.callout)
            .lineLimit(4)
        }
      }
    }
  }
}
