import SwiftUI

struct CorruptedConversationReviewView: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  @State private var documents: [CorruptedConversationDocument] = []
  @State private var isLoading = true

  var body: some View {
    NavigationStack {
      Group {
        if isLoading {
          ProgressView("Loading quarantined files…")
        } else if documents.isEmpty {
          ContentUnavailableView(
            "No Quarantined Chats",
            systemImage: "checkmark.circle",
            description: Text("No unreadable conversation files remain."))
        } else {
          List(documents) { document in
            NavigationLink {
              CorruptedConversationDocumentView(document: document) {
                documents.removeAll { $0.id == document.id }
              }
              .environmentObject(store)
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                Text(document.filename)
                  .font(.body.monospaced())
                  .lineLimit(2)
                Text(
                  "\(document.location) · \(Self.formattedByteCount(document.byteCount)) · \(document.isValidJSON ? "Unsupported conversation format" : "Invalid JSON")"
                )
                .font(.caption)
                .foregroundStyle(document.isValidJSON ? Color.secondary : Color.orange)
              }
              .padding(.vertical, 2)
            }
          }
          .refreshable {
            await reload()
          }
        }
      }
      .navigationTitle("Quarantined Chats")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
      .task {
        await reload()
      }
    }
  }

  private func reload() async {
    let loaded = await store.corruptedConversationDocuments()
    documents = loaded
    isLoading = false
  }

  private static func formattedByteCount(_ count: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
  }
}

private struct CorruptedConversationDocumentView: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  let document: CorruptedConversationDocument
  let onDeleted: () -> Void

  @State private var showingDeleteConfirmation = false
  @State private var isDeleting = false
  @State private var errorMessage: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label {
        Text(
          document.isValidJSON
            ? "This is valid JSON, but PocketMai cannot decode its conversation format."
            : "This file is not valid JSON. Its original bytes are still preserved below."
        )
      } icon: {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
      }
      .font(.callout)
      .padding(.horizontal)

      ScrollView([.horizontal, .vertical]) {
        Text(document.contents)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .padding()
      }
      .background(Color(uiColor: .secondarySystemBackground))
      .clipShape(RoundedRectangle(cornerRadius: 10))
      .padding(.horizontal)
    }
    .padding(.top)
    .navigationTitle(document.filename)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .destructiveAction) {
        Button("Delete", systemImage: "trash", role: .destructive) {
          showingDeleteConfirmation = true
        }
        .disabled(isDeleting)
      }
    }
    .alert("Delete quarantined file?", isPresented: $showingDeleteConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Delete Permanently", role: .destructive) {
        Task { await deleteDocument() }
      }
    } message: {
      Text(
        "\(document.filename) will be permanently removed from \(document.location). This cannot be undone."
      )
    }
    .errorAlert("Could Not Delete File", message: $errorMessage)
  }

  private func deleteDocument() async {
    isDeleting = true
    let result = await store.deleteCorruptedConversation(id: document.id)
    isDeleting = false
    if result.deleted {
      onDeleted()
      dismiss()
    } else {
      errorMessage = result.errorMessage ?? "The quarantined file could not be deleted."
    }
  }
}
