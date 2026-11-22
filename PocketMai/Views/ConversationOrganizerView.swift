import SwiftUI

struct ConversationOrganizerView: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var queue: [UUID] = []
  @State private var started = false
  @State private var offset = CGSize.zero
  @State private var isBusy = false
  @State private var showingFolders = false
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
        Text("\(queue.count) remaining · Shuffled for this visit")
          .font(.subheadline)
          .foregroundStyle(.secondary)

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
              DragGesture(minimumDistance: 20)
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
                    togglePin(conversation)
                  }
                }
            )
        }
        .frame(maxWidth: 420, maxHeight: 560)
        .padding(.horizontal, 8)

        VStack(spacing: 12) {
          HStack {
            action("Left: Delete", icon: "arrow.left", color: .red) {
              requestDeletion(conversation)
            }
            action("Right: Keep", icon: "arrow.right", color: .green) {
              advance(conversation.id)
            }
          }
          HStack {
            action("Up: Move", icon: "arrow.up", color: .accentColor) {
              showingFolders = true
            }
            action(conversation.isPinned ? "Down: Unpin" : "Down: Pin",
              icon: "arrow.down", color: .orange
            ) {
              togglePin(conversation)
            }
          }
        }
        .disabled(isBusy)
        Text("Swipe the card or tap an action. Delete asks first. Keep skips until your next visit.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      } else {
        ContentUnavailableView(
          "All Done", systemImage: "checkmark.seal",
          description: Text("Open Organize Chats again for a fresh shuffle."))
      }
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(uiColor: .systemGroupedBackground))
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

  private func action(_ title: String, icon: String, color: Color,
    perform: @escaping () -> Void
  ) -> some View {
    Button(action: perform) {
      Label(title, systemImage: icon)
        .font(.subheadline.weight(.semibold))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
    .buttonStyle(.plain)
    .foregroundStyle(color)
  }

  private func resetCard() {
    withAnimation(spring) { offset = .zero }
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

  private func togglePin(_ conversation: ConversationSummary) {
    isBusy = true
    offset = CGSize(width: 0, height: reduceMotion ? 0 : 45)
    Task {
      await store.togglePin(id: conversation.id)
      isBusy = false
      resetCard()
      if store.conversationSummaries.first(where: { $0.id == conversation.id })?.isPinned
        == conversation.isPinned
      {
        errorMessage = store.errorMessage ?? "The conversation could not be pinned."
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
