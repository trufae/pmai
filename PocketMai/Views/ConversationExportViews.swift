import SwiftUI
import UIKit

struct ExportedFile: Identifiable {
  let id = UUID()
  let url: URL
}

struct PendingExportImageSizeSelection: Identifiable {
  let id = UUID()
  let format: ConversationExportFormat
  let conversationID: UUID
}

@MainActor
final class ConversationExportCoordinator: ObservableObject {
  @Published var exportShareFile: ExportedFile?
  @Published var pendingImageSizeSelection: PendingExportImageSizeSelection?
  @Published var showingAudioExport = false
  @Published var audioExportError: String?

  let audioExporter = TTSExporter()

  var isExporting: Bool {
    audioExporter.isExporting
  }

  func share(
    format: ConversationExportFormat,
    conversationID: UUID,
    store: AppStore,
    imageSize: AttachmentImageSize = .full
  ) async {
    guard
      let url = await exportFileURL(
        for: format,
        conversationID: conversationID,
        store: store,
        imageSize: imageSize)
    else {
      return
    }
    exportShareFile = ExportedFile(url: url)
  }

  func share(conversationIDs: Set<UUID>, store: AppStore) async {
    guard let url = await store.exportConversationCollectionFile(ids: conversationIDs) else {
      return
    }
    exportShareFile = ExportedFile(url: url)
  }

  func shareDocument(format: ConversationExportFormat, conversationID: UUID, store: AppStore) {
    Task { @MainActor in
      guard let conversation = await store.conversationForExport(id: conversationID) else {
        return
      }
      guard Self.containsImageAttachments(conversation) else {
        await share(format: format, conversationID: conversationID, store: store, imageSize: .full)
        return
      }
      pendingImageSizeSelection = PendingExportImageSizeSelection(
        format: format,
        conversationID: conversationID)
    }
  }

  private func exportFileURL(
    for format: ConversationExportFormat,
    conversationID: UUID,
    store: AppStore,
    imageSize: AttachmentImageSize
  ) async -> URL? {
    switch format {
    case .audio:
      guard let conversation = await store.conversationForExport(id: conversationID) else {
        return nil
      }
      return await exportAudioFile(conversation: conversation, store: store)
    case .debug:
      return await store.exportConversationDebugJSONFile(id: conversationID)
    case .markdown, .json:
      return await store.exportConversationFile(id: conversationID, format: format)
    case .html, .epub, .docx:
      return await store.exportConversationFile(
        id: conversationID,
        format: format,
        imageSize: imageSize)
    }
  }

  private func exportAudioFile(conversation: Conversation, store: AppStore) async -> URL? {
    showingAudioExport = true
    do {
      let url = try ConversationExportFiles.url(for: conversation, format: .audio)
      try await audioExporter.export(
        messages: conversation.messages,
        voices: store.effectiveToolSettings(for: conversation).voices,
        skipTechnicalContent: store.settings.conversation.skipTechnicalContentInTTS,
        to: url)
      showingAudioExport = false
      try? await Task.sleep(for: .milliseconds(250))
      return url
    } catch is CancellationError {
      showingAudioExport = false
      return nil
    } catch {
      showingAudioExport = false
      audioExportError =
        (error as? LocalizedError)?.errorDescription
        ?? error.localizedDescription
      return nil
    }
  }

  private static func containsImageAttachments(_ conversation: Conversation) -> Bool {
    conversation.messages.contains { message in
      message.attachments.contains { $0.kind == .image }
    }
  }
}

struct ConversationExportMenu: View {
  @EnvironmentObject private var store: AppStore

  let conversationID: UUID?
  @ObservedObject var coordinator: ConversationExportCoordinator
  let title: String

  init(
    conversationID: UUID?,
    coordinator: ConversationExportCoordinator,
    title: String = "Share / Export"
  ) {
    self.conversationID = conversationID
    self.coordinator = coordinator
    self.title = title
  }

  var body: some View {
    Menu {
      ConversationExportMenuItems(isExporting: coordinator.isExporting) { format in
        guard let conversationID else { return }
        if format == .html || format == .epub || format == .docx {
          coordinator.shareDocument(format: format, conversationID: conversationID, store: store)
          return
        }
        Task {
          await coordinator.share(format: format, conversationID: conversationID, store: store)
        }
      }
    } label: {
      Label(title, systemImage: "square.and.arrow.up")
    }
    .disabled(conversationID == nil || coordinator.isExporting)
  }
}

private struct ConversationExportMenuItems: View {
  let isExporting: Bool
  let onSelect: (ConversationExportFormat) -> Void

  var body: some View {
    Section("Continue in PocketMai or pmai") {
      exportButton(.json)
    }
    Section("Readable Copy") {
      ForEach(ConversationExportFormat.shareMenuFormats) { format in
        exportButton(format)
      }
    }
    Section("Troubleshooting") {
      exportButton(.debug)
    }
  }

  private func exportButton(_ format: ConversationExportFormat) -> some View {
    Button {
      onSelect(format)
    } label: {
      Label(format.exportMenuTitle, systemImage: format.systemImage)
    }
    .disabled(isExporting)
  }
}

struct ConversationExportPresentations: ViewModifier {
  @EnvironmentObject private var store: AppStore
  @ObservedObject var coordinator: ConversationExportCoordinator

  func body(content: Content) -> some View {
    content
      .sheet(item: exportShareFileBinding) { file in
        ActivityShareSheet(activityItems: [file.url])
      }
      .sheet(isPresented: showingAudioExportBinding) {
        AudioExportProgressView(exporter: coordinator.audioExporter) {
          coordinator.audioExporter.cancel()
        }
      }
      .alert(
        "Audio export failed",
        isPresented: audioExportErrorPresentedBinding,
        presenting: coordinator.audioExportError
      ) { _ in
        Button("OK", role: .cancel) { coordinator.audioExportError = nil }
      } message: { message in
        Text(message)
      }
      .imageSizeConfirmationDialog(
        isPresented: imageSizeSelectionPresentedBinding,
        presenting: coordinator.pendingImageSizeSelection,
        message: { pending in
          "Choose the maximum image size for this \(pending.format.displayName) export."
        },
        onSelect: { pending, size in
          coordinator.pendingImageSizeSelection = nil
          Task {
            await coordinator.share(
              format: pending.format,
              conversationID: pending.conversationID,
              store: store,
              imageSize: size)
          }
        },
        onCancel: {
          coordinator.pendingImageSizeSelection = nil
        })
  }

  private var exportShareFileBinding: Binding<ExportedFile?> {
    Binding {
      coordinator.exportShareFile
    } set: { file in
      coordinator.exportShareFile = file
    }
  }

  private var showingAudioExportBinding: Binding<Bool> {
    Binding {
      coordinator.showingAudioExport
    } set: { isPresented in
      coordinator.showingAudioExport = isPresented
    }
  }

  private var audioExportErrorPresentedBinding: Binding<Bool> {
    Binding {
      coordinator.audioExportError != nil
    } set: { isPresented in
      if !isPresented {
        coordinator.audioExportError = nil
      }
    }
  }

  private var imageSizeSelectionPresentedBinding: Binding<Bool> {
    Binding {
      coordinator.pendingImageSizeSelection != nil
    } set: { isPresented in
      if !isPresented {
        coordinator.pendingImageSizeSelection = nil
      }
    }
  }
}

extension View {
  func imageSizeConfirmationDialog<Selection>(
    isPresented: Binding<Bool>,
    presenting selection: Selection?,
    message: @escaping (Selection) -> String,
    onSelect: @escaping (Selection, AttachmentImageSize) -> Void,
    onOCR: ((Selection) -> Void)? = nil,
    onCancel: @escaping () -> Void
  ) -> some View {
    confirmationDialog(
      "Image Size",
      isPresented: isPresented,
      titleVisibility: .visible,
      presenting: selection
    ) { selection in
      ForEach(AttachmentImageSize.concreteCases) { size in
        Button(size.imageSizeDialogTitle) {
          onSelect(selection, size)
        }
      }
      if let onOCR {
        Button("Text (OCR)") {
          onOCR(selection)
        }
      }
      Button("Cancel", role: .cancel, action: onCancel)
    } message: { selection in
      Text(message(selection))
    }
  }
}

extension AttachmentImageSize {
  var imageSizeDialogTitle: String {
    guard let maxDimension else {
      return displayName
    }
    return "\(displayName) (\(maxDimension) px)"
  }
}

private struct AudioExportProgressView: View {
  @ObservedObject var exporter: TTSExporter
  let onCancel: () -> Void

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "waveform")
        .font(.system(size: 32))
        .foregroundStyle(.secondary)
      ProgressView(value: exporter.progress)
        .progressViewStyle(.linear)
      Text(exporter.phase)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Button("Cancel", role: .cancel, action: onCancel)
    }
    .padding(24)
    .frame(maxWidth: .infinity)
    .presentationDetents([.height(220)])
    .interactiveDismissDisabled()
  }
}

struct ActivityShareSheet: UIViewControllerRepresentable {
  let activityItems: [Any]

  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
  }

  func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private extension ConversationExportFormat {
  static var shareMenuFormats: [ConversationExportFormat] {
    [.markdown, .html, .epub, .docx, .audio]
  }

  var exportMenuTitle: String {
    switch self {
    case .markdown: "Markdown (.md)"
    case .html: "HTML (.html)"
    case .epub: "EPUB (.epub)"
    case .docx: "Word (.docx)"
    case .audio: "Audio (.m4a)"
    case .json: "PocketMai Conversation (.pocketmai)"
    case .debug: "Debug Report (.json)"
    }
  }
}
