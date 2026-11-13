import MaiCore
import MaiDocuments
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private struct PromptShortcutMenuOption: Identifiable, Equatable {
  var commandName: String
  var displayName: String
  var detail: String
  var systemImage: String

  var prefix = "/"

  var id: String { prefix + commandName }
}

struct ChatComposer: View {
  private static let draftAutosaveDelayNanoseconds: UInt64 = 3_000_000_000

  @EnvironmentObject private var ttsPlayer: TTSPlayer
  @Environment(\.scenePhase) private var scenePhase
  let store: AppStore
  let remoteChat: RemoteAgentChat?
  let placeholder: String
  let conversationID: UUID?
  let isResponding: Bool
  let isKeyboardVisible: Bool
  let isCollapsed: Bool
  let onExpand: () -> Void
  @Binding var queuedMessagePendingEdit: QueuedChatMessage?
  @ObservedObject var liveVoiceSession: LiveVoiceSession
  @FocusState private var composerFocused: Bool
  @State private var showingToolMenu = false
  @State private var showingToolPicker = false
  @State private var remoteWorkingFolder: FileBrowserLocation?
  @State private var showingTextFileImporter = false
  @State private var showingWorkingFolderMenu = false
  @State private var showingWorkingFolderImporter = false
  @State private var showingImagePicker = false
  @State private var showingCameraPicker = false
  @State private var showingWebXDCLauncher = false
  @State private var showingWebXDCStopConfirmation = false
  @State private var selectedPhotoItems: [PhotosPickerItem] = []
  @State private var draftText = ""
  @State private var pendingAttachments: [ChatAttachment] = []
  @State private var sharedImportQueue: [SharedInboxItem] = []
  @State private var sharedImportImages: [PendingImageAttachmentImport.Item] = []
  @State private var sharedImportFailures: [String] = []
  @State private var isImportingSharedItems = false
  @State private var isResumingSharedImport = false
  @State private var viewingPendingAttachment: ChatAttachment?
  @State private var viewingPendingImageAttachment: ChatAttachment?
  @State private var pendingImageSizePrompt: PendingImageAttachmentImport?
  @State private var pendingPDFImport: PendingPDFImport?
  @State private var pendingHTMLImport: PendingDocumentImport?
  @State private var pendingWorkspaceImport: PendingDocumentImport?
  @State private var attachmentConversionMessage: String?
  @State private var attachmentNotice: String?
  @State private var attachmentError: String?
  @State private var promptAutocompleteSuppressedCommand: String?
  @State private var localPromptCatalog = PromptCatalog(builtins: [])
  @State private var pendingPromptCompletion: String?
  @State private var composerTextFieldRefreshID = UUID()
  @State private var focusComposerAfterTextFieldRefresh = false
  @State private var draftPersistenceTask: Task<Void, Never>?

  private var inputSession: ChatInputSession {
    ChatInputSession(store: store, remoteChat: remoteChat)
  }

  private var hasDraftText: Bool {
    !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var canSubmitDraft: Bool {
    (!isResponding || isImmediateCommand || remoteChat?.canSubmit == true)
      && (hasDraftText || !pendingAttachments.isEmpty)
      && inputSession.canSubmit
  }

  private var isVersionCommand: Bool {
    remoteChat == nil && draftText.trimmingCharacters(in: .whitespacesAndNewlines) == "/version"
  }

  private var isBTW: Bool {
    remoteChat == nil && BTWQuestion.prompt(in: draftText) != nil
  }

  private var isImmediateCommand: Bool {
    isBTW || isVersionCommand || (remoteChat == nil && AppStore.isThenCommand(draftText))
  }

  private var canQueueDraft: Bool {
    remoteChat == nil && isResponding && hasDraftText && !isImmediateCommand
  }

  private var shouldShowPromptAutocomplete: Bool {
    pendingPromptCompletion == nil && currentPromptCommandFragment != nil
      && !promptShortcutOptions.isEmpty
      && !promptAutocompleteIsSuppressed
  }

  private var promptAutocompleteBinding: Binding<Bool> {
    Binding(
      get: { shouldShowPromptAutocomplete },
      set: { isPresented in
        if !isPresented {
          promptAutocompleteSuppressedCommand = currentPromptCommandFragment
        }
      }
    )
  }

  private var currentPromptCommandFragment: String? {
    guard let first = draftText.first, PromptSlashCommand.prefixes.contains(first) else {
      return nil
    }
    return PromptSlashCommand.fragment(in: draftText)
  }

  private var promptAutocompleteIsSuppressed: Bool {
    guard let promptAutocompleteSuppressedCommand,
      let currentPromptCommandFragment
    else {
      return false
    }
    return PromptSlashCommand.normalized(currentPromptCommandFragment)
      == PromptSlashCommand.normalized(promptAutocompleteSuppressedCommand)
  }

  private var promptShortcutOptions: [PromptShortcutMenuOption] {
    let catalog = inputSession.promptCatalog(local: localPromptCatalog)
    var names = Set<String>()
    let namedOptions = catalog.entries.filter {
      names.insert(PromptSlashCommand.normalized($0.commandName)).inserted
    }.map { entry in
      PromptShortcutMenuOption(commandName: entry.commandName, displayName: entry.name,
        detail: entry.description ?? entry.kind.label,
        systemImage: entry.kind == .skill ? "sparkles" : entry.kind == .system ? "text.bubble" : "text.quote",
        prefix: "$")
    }
    let commands = [
      PromptShortcutMenuOption(
        commandName: "btw", displayName: "Side question",
        detail: "Answers in parallel", systemImage: "bubble.left.and.bubble.right"),
      PromptShortcutMenuOption(
        commandName: "version", displayName: "App version",
        detail: "Version and build", systemImage: "info.circle"),
      PromptShortcutMenuOption(commandName: "then", displayName: "Queue action",
        detail: "Runs after all tasks finish; no arguments lists the queue", systemImage: "text.badge.plus"),
      PromptShortcutMenuOption(commandName: "unthen", displayName: "Clear queued actions",
        detail: "Drops all pending /then lines", systemImage: "trash"),
    ]
    let options = draftText.hasPrefix("$") || remoteChat != nil
      ? namedOptions : commands + namedOptions
    guard let fragment = PromptSlashCommand.fragment(in: draftText),
      !fragment.isEmpty
    else {
      return options
    }
    return options.filter { option in
      option.commandName.localizedCaseInsensitiveContains(fragment)
        || option.displayName.localizedCaseInsensitiveContains(fragment)
    }
  }

  private func refreshLocalPromptCatalog() {
    localPromptCatalog = store.promptCatalog(for: remoteChat == nil ? inputSession.conversation : nil)
  }

  private var canAttachImage: Bool {
    inputSession.supportsImages
  }

  private var canTakePicture: Bool {
    canAttachImage && UIImagePickerController.isSourceTypeAvailable(.camera)
  }

  var body: some View {
    composerImportDialogs
  }

  private var composerPromptUpdates: some View {
    composerControls
      .task(id: conversationID) { refreshLocalPromptCatalog() }
      .task(id: remoteChat?.conversation.cwd) { await remoteChat?.refreshPromptCatalog() }
      .task(id: remoteChat?.connected) { await remoteChat?.refreshPromptCatalog() }
      .onChange(of: draftText.first) { _, first in
        if let first, PromptSlashCommand.prefixes.contains(first) { refreshLocalPromptCatalog() }
      }
      .onChange(of: store.settings.systemPrompts) { _, _ in refreshLocalPromptCatalog() }
      .onChange(of: store.settings.userPrompts) { _, _ in refreshLocalPromptCatalog() }
  }

  private var composerAttachmentDialogs: some View {
    composerPromptUpdates
      .errorAlert("Import failed", message: $attachmentError)
      .confirmationDialog(
        "Save File to Working Folder",
        isPresented: workspaceImportBinding,
        titleVisibility: .visible,
        presenting: pendingWorkspaceImport
      ) { pending in
        Button(filesToolsNeedEnabling ? "Enable Files Tools and Save" : "Save File") {
          saveUnsupportedFile(pending)
        }
        Button("Cancel", role: .cancel) { dismissWorkspaceImport() }
      } message: { pending in
        Text("\(pending.filename) cannot be attached as text. Save it to \(currentWorkspaceName) so this chat can access it?"
          + (filesToolsNeedEnabling ? " This will enable Tools and Files access for this chat." : ""))
      }
      .imageSizeConfirmationDialog(
        isPresented: imageSizePromptBinding,
        presenting: pendingImageSizePrompt,
        message: { pending in pending.imageSizePromptMessage },
        onSelect: { pending, size in attachSharedImages(pending, size: size) },
        onOCR: { pending in extractTextFromImages(pending) },
        onCancel: { dismissImageSizePrompt() }
      )
  }

  private var composerImportDialogs: some View {
    composerAttachmentDialogs
      .confirmationDialog(
        "Import PDF",
        isPresented: pdfImportBinding,
        titleVisibility: .visible,
        presenting: pendingPDFImport
      ) { pending in
        Button("Text as Markdown") { attachPDFAsMarkdown(pending) }
        Button("One Image per Page") { attachPDFAsImages(pending) }
        Button("Cancel", role: .cancel) { dismissPDFImport() }
      } message: { pending in
        Text("How should \(pending.name).pdf be attached?")
      }
      .confirmationDialog(
        "Import HTML",
        isPresented: htmlImportBinding,
        titleVisibility: .visible,
        presenting: pendingHTMLImport
      ) { pending in
        Button("Attach HTML Source") { attachHTML(pending, mode: .source) }
        Button("Convert to Markdown") { attachHTML(pending, mode: .markdown) }
        if remoteChat == nil, store.currentConversation != nil {
          Button("Copy to \(currentWorkspaceName)") { copyHTMLToWorkspace(pending) }
        }
        Button("Cancel", role: .cancel) { dismissHTMLImport() }
      } message: { pending in
        Text("Choose how to import \(pending.filename).")
      }
  }

  /// Keep controls, prompt updates, and import dialogs in separate expressions
  /// to limit the work required by the type checker.
  private var composerControls: some View {
    Group {
      if liveVoiceSession.isActive {
        voiceControls
      } else {
        textControls
      }
    }
    .padding(.horizontal, 12)
    .padding(.top, 8)
    .padding(.bottom, isKeyboardVisible ? 8 : 0)
    .onAppear {
      draftText = store.draftText(for: conversationID)
      if let message = queuedMessagePendingEdit {
        restoreQueuedMessageToComposer(message)
        queuedMessagePendingEdit = nil
      }
      // A share that arrived before the composer was on screen, e.g. when the
      // share sheet launched the app.
      if remoteChat == nil, store.hasQueuedSharedItems {
        onExpand()
        beginSharedImport()
      }
    }
    .onChange(of: isCollapsed) { _, collapsed in
      if collapsed { composerFocused = false }
    }
    .onChange(of: composerFocused) { _, focused in
      if focused { onExpand() }
    }
    .onChange(of: store.sharedImportRequestID) { _, _ in
      if remoteChat == nil { beginSharedImport() }
    }
    .onChange(of: remoteChat?.unsentPrompt) { _, prompt in
      guard let prompt else { return }
      draftText = [prompt, draftText].filter { !$0.isEmpty }.joined(separator: "\n\n")
      persistDraftTextNow()
      remoteChat?.unsentPrompt = nil
    }
    .onChange(of: store.draftStorageRevision) { _, _ in
      let storedDraft = store.draftText(for: conversationID)
      if draftText.isEmpty, !storedDraft.isEmpty {
        draftText = storedDraft
      }
    }
    .onChange(of: store.composerFocusRequestID) { _, _ in
      guard !liveVoiceSession.isActive else { return }
      if let replacement = store.composerDraftReplacement,
        replacement.conversationID == conversationID
      {
        applyComposerDraftReplacement(replacement)
      } else {
        composerFocused = true
      }
    }
    .onChange(of: conversationID) { oldID, newID in
      if oldID != newID, liveVoiceSession.isActive {
        liveVoiceSession.stop(cancelResponse: false)
      }
      persistDraftTextNow(draftText, for: oldID)
      pendingPromptCompletion = nil
      focusComposerAfterTextFieldRefresh = false
      draftText = store.draftText(for: newID)
    }
    .onChange(of: queuedMessagePendingEdit) { _, message in
      guard let message else { return }
      restoreQueuedMessageToComposer(message)
      queuedMessagePendingEdit = nil
    }
    .onDisappear {
      persistDraftTextNow()
      if remoteChat != nil { liveVoiceSession.stop(cancelResponse: false) }
    }
    .onChange(of: scenePhase) { _, phase in
      guard phase == .background else { return }
      guard liveVoiceSession.isActive else { return }
      guard !store.settings.conversation.allowsBackgroundVoiceListening else { return }
      Task { @MainActor in
        if liveVoiceSession.mode == .voiceNoteAttachment {
          await stopVoiceAndAttachTranscript(focusComposer: false)
        } else {
          await stopVoiceAndKeepTranscript(cancelResponse: false, focusComposer: false)
        }
      }
    }
    .photosPicker(
      isPresented: $showingImagePicker,
      selection: $selectedPhotoItems,
      matching: .images
    )
    .onChange(of: selectedPhotoItems) { _, items in
      guard !items.isEmpty else { return }
      Task { await importImageAttachments(items) }
    }
    .sheet(isPresented: $showingCameraPicker) {
      CameraImagePicker(isPresented: $showingCameraPicker) { image in
        importCameraImageAttachment(image)
      }
      .ignoresSafeArea()
    }
    .sheet(item: $viewingPendingAttachment) { attachment in
      MessageTextSelectionSheet(
        title: attachment.displayName,
        text: attachment.text ?? "",
        appearance: store.settings.appearance,
        initialFontSize: store.settings.appearance.fontSize,
        initialLineSpacing: store.settings.appearance.lineSpacing,
        fontFamily: store.settings.appearance.fontFamily(for: .user),
        isEditable: true,
        onSave: { text in
          updatePendingAttachmentText(id: attachment.id, text: text)
        })
    }
    .fullScreenCover(item: $viewingPendingImageAttachment) { attachment in
      MessageImageFullscreenLoader(attachment: attachment)
    }
    .sheet(isPresented: $showingWebXDCLauncher) {
      WebXDCAppLauncherSheet { app in
        store.startWebXDCSession(app: app)
      }
      .environmentObject(store)
    }
  }

  // MARK: - Import questions

  private var imageSizePromptBinding: Binding<Bool> {
    Binding(
      get: { pendingImageSizePrompt != nil },
      set: { isPresented in
        if !isPresented { dismissImageSizePrompt() }
      })
  }

  private var pdfImportBinding: Binding<Bool> {
    Binding(
      get: { pendingPDFImport != nil },
      set: { isPresented in
        if !isPresented { dismissPDFImport() }
      })
  }

  private var htmlImportBinding: Binding<Bool> {
    Binding(
      get: { pendingHTMLImport != nil },
      set: { isPresented in
        if !isPresented { dismissHTMLImport() }
      })
  }

  private var workspaceImportBinding: Binding<Bool> {
    Binding(
      get: { pendingWorkspaceImport != nil },
      set: { if !$0 { dismissWorkspaceImport() } })
  }

  private var filesToolsNeedEnabling: Bool {
    guard let conversation = store.currentConversation else { return true }
    return !conversation.toolsEnabled || !conversation.enabledTools.contains(.files)
      || !store.settings.toolSettings.filesWorkspaceAccessEnabled
  }

  private func dismissWorkspaceImport() {
    pendingWorkspaceImport = nil
    resumeSharedImportAfterAnswer()
  }

  private func saveUnsupportedFile(_ pending: PendingDocumentImport) {
    pendingWorkspaceImport = nil
    defer { resumeSharedImportAfterAnswer() }
    guard remoteChat == nil, let conversation = store.currentConversation else { return }
    do {
      let resolved = try FileWorkspaceTool.context(for: conversation, settings: store.settings)
      if let bookmark = resolved.refreshedBookmarkData {
        store.refreshWorkingFolderBookmark(conversationID: conversation.id, bookmarkData: bookmark)
      }
      let destination = try FileWorkspaceService.importFile(
        data: pending.data, filename: pending.filename, in: resolved.context)
      store.enableFilesTools()
      pendingAttachments.append(.textFile(
        filename: destination.lastPathComponent + ".txt",
        text: "Saved file in the working folder: \(destination.lastPathComponent). Use Files tools to access it. ZIP and XDC archives can be unpacked with files_unzip and repacked with files_zip.",
        mimeType: "text/plain"))
      showAttachmentNotice("Saved \(destination.lastPathComponent) to \(resolved.context.displayName).")
      composerFocused = true
    } catch {
      attachmentError = error.localizedDescription
    }
  }

  private func attachSharedImages(
    _ pending: PendingImageAttachmentImport,
    size: AttachmentImageSize
  ) {
    appendImageAttachment(pending, size: size)
    resumeSharedImportAfterAnswer()
  }

  private func extractTextFromImages(_ pending: PendingImageAttachmentImport) {
    convertImagesToText(pending)
    resumeSharedImportAfterAnswer()
  }

  private func dismissImageSizePrompt() {
    pendingImageSizePrompt = nil
    resumeSharedImportAfterAnswer()
  }

  private func attachPDFAsMarkdown(_ pending: PendingPDFImport) {
    convertPDFToMarkdown(pending)
    resumeSharedImportAfterAnswer()
  }

  private func attachPDFAsImages(_ pending: PendingPDFImport) {
    convertPDFToImages(pending)
    resumeSharedImportAfterAnswer()
  }

  private func dismissPDFImport() {
    pendingPDFImport = nil
    resumeSharedImportAfterAnswer()
  }

  private func attachHTML(_ pending: PendingDocumentImport, mode: HTMLAttachmentMode) {
    pendingHTMLImport = nil
    switch appendDocumentAttachment(
      data: pending.data, filename: pending.filename, mimeType: pending.mimeType, htmlMode: mode)
    {
    case .awaitingAnswer: return
    case .failed(let message): attachmentError = message
    case .attached: break
    }
    resumeSharedImportAfterAnswer()
  }

  private func copyHTMLToWorkspace(_ pending: PendingDocumentImport) {
    pendingHTMLImport = nil
    defer { resumeSharedImportAfterAnswer() }
    guard let conversation = store.currentConversation else {
      attachmentError = "No chat is selected."
      return
    }
    do {
      let resolved = try FileWorkspaceTool.context(for: conversation, settings: store.settings)
      if let bookmark = resolved.refreshedBookmarkData {
        store.refreshWorkingFolderBookmark(
          conversationID: conversation.id, bookmarkData: bookmark)
      }
      let destination = try FileWorkspaceService.importFile(
        data: pending.data, filename: pending.filename, in: resolved.context)
      showAttachmentNotice("Copied \(destination.lastPathComponent) to \(resolved.context.displayName).")
    } catch {
      attachmentError = error.localizedDescription
    }
  }

  private func dismissHTMLImport() {
    pendingHTMLImport = nil
    resumeSharedImportAfterAnswer()
  }

  private var currentWorkspaceName: String {
    guard let conversation = store.currentConversation else {
      return FileWorkspaceService.defaultWorkspaceName
    }
    return store.workingFolderDisplayName(for: conversation)
  }

  private func showAttachmentNotice(_ message: String) {
    attachmentNotice = message
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(3))
      if attachmentNotice == message { attachmentNotice = nil }
    }
  }

  private var textControls: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let attachmentConversionMessage {
        HStack(spacing: 6) {
          ProgressView()
            .controlSize(.small)
          Text(attachmentConversionMessage)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 34)
      }
      if let attachmentNotice {
        Label(attachmentNotice, systemImage: "checkmark.circle.fill")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 34)
      }
      if !pendingAttachments.isEmpty {
        pendingAttachmentStrip
      }
      HStack(alignment: .bottom, spacing: 10) {
        toolMenu

        HStack(alignment: .bottom, spacing: 4) {
          TextField(
            isResponding
              ? (remoteChat == nil ? "Queue a message..." : "Send to running agent...") : placeholder,
            text: draftBinding, axis: .vertical
          )
          .textFieldStyle(.plain)
          .lineLimit(1...5)
          .padding(.leading, 14)
          .padding(.vertical, 8)
          .frame(minHeight: 44, alignment: .center)
          .accessibilityLabel("Message")
          .accessibilityHint("Start with / for commands or $ for prompts and skills.")
          .focused($composerFocused)
          .onAppear {
            guard focusComposerAfterTextFieldRefresh else { return }
            focusComposerAfterTextFieldRefresh = false
            composerFocused = true
          }
          .id(composerTextFieldRefreshID)
          .popover(
            isPresented: promptAutocompleteBinding,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .bottom
          ) {
            promptAutocompletePopover
              .presentationCompactAdaptation(.popover)
          }
          .onKeyPress(.return, phases: .down) { press in
            // Only hardware keyboards reach onKeyPress, so the on-screen Return
            // always inserts a newline. With a hardware keyboard, Shift+Return
            // inserts a newline and a bare Return submits.
            guard !press.modifiers.contains(.shift) else { return .ignored }
            submitDraft()
            return .handled
          }

          if remoteChat != nil, isResponding, canSubmitDraft {
            Button { inputSession.cancelResponse() } label: {
              Image(systemName: "stop.fill")
                .foregroundStyle(.red)
                .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop response")
          }
          Button {
            if canSubmitDraft {
              submitDraft()
            } else if let id = conversationID, isResponding {
              if canQueueDraft {
                queueDraft(in: id)
              } else {
                inputSession.cancelResponse()
              }
            } else {
              liveVoiceSession.start(store: store, ttsPlayer: ttsPlayer, remoteChat: remoteChat)
            }
          } label: {
            Image(systemName: trailingActionSystemImage)
              .font(.title2)
              .symbolRenderingMode(.hierarchical)
              .foregroundStyle(trailingActionColor)
              .frame(width: 44, height: 44)
              .contentShape(Circle())
          }
          .buttonStyle(.plain)
          .disabled(
            !isResponding && (liveVoiceSession.isActive || !inputSession.canSubmit)
          )
          .help(trailingActionHelp)
        }
        .background { composerInputBackground }
      }
    }
  }

  private var composerInputBackground: some View {
    let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
    return Group {
      if #available(iOS 26.0, *) {
        shape
          .fill(.clear)
          .glassEffect(.regular, in: shape)
      } else {
        shape
          .fill(.regularMaterial)
          .overlay {
            shape.strokeBorder(.secondary.opacity(0.3), lineWidth: 1)
          }
      }
    }
    .allowsHitTesting(false)
  }

  private var pendingAttachmentStrip: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(pendingAttachments) { attachment in
          AttachmentPill(
            attachment: attachment,
            onOpen: {
              if attachment.kind == .image {
                viewingPendingImageAttachment = attachment
              } else {
                viewingPendingAttachment = attachment
              }
            },
            onRemove: {
              pendingAttachments.removeAll { $0.id == attachment.id }
            })
        }
        if pendingImageAttachmentCount > 1 {
          Button {
            pendingAttachments.removeAll { $0.kind == .image }
          } label: {
            Image(systemName: "trash")
              .font(.callout.weight(.semibold))
              .foregroundStyle(.secondary)
              .frame(width: 34, height: 34)
              .background(.regularMaterial)
              .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Remove all image attachments")
          .help("Remove all images")
        }
      }
      .padding(.horizontal, 34)
    }
  }

  private var pendingImageAttachmentCount: Int {
    pendingAttachments.filter { $0.kind == .image }.count
  }

  private func updatePendingAttachmentText(id: UUID, text: String) {
    guard let index = pendingAttachments.firstIndex(where: { $0.id == id }) else { return }
    pendingAttachments[index].text = text
  }

  private var trailingActionSystemImage: String {
    if canSubmitDraft { return "arrow.up" }
    if isResponding {
      return canQueueDraft ? "arrow.up.to.line" : "stop.fill"
    }
    if hasDraftText || !pendingAttachments.isEmpty {
      return "arrow.up"
    }
    return "mic"
  }

  private var trailingActionColor: Color {
    if canSubmitDraft { return .accentColor }
    if isResponding {
      return canQueueDraft ? .orange : .red
    }
    return .accentColor
  }

  private var trailingActionHelp: String {
    if isVersionCommand { return "Show app version" }
    if isImmediateCommand && canSubmitDraft { return isBTW ? "Ask a side question now" : "Manage queued actions" }
    if isResponding, remoteChat != nil, canSubmitDraft { return "Send to running agent" }
    if isResponding {
      return canQueueDraft ? "Queue message" : "Stop response"
    }
    if hasDraftText || !pendingAttachments.isEmpty {
      return "Send message"
    }
    return "Start voice conversation"
  }

  private var voiceControls: some View {
    HStack(spacing: 12) {
      voiceLeadingControl

      VStack(alignment: .leading, spacing: 2) {
        Text(voiceStatusTitle)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.primary)
        Text(liveVoiceSession.errorMessage ?? voiceStatusDetail)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      voiceTrailingControl
    }
  }

  @ViewBuilder
  private var voiceLeadingControl: some View {
    if liveVoiceSession.mode == .voiceNoteAttachment {
      Button {
        cancelVoiceNoteAttachment()
      } label: {
        voiceControlImage("xmark.circle.fill", color: .red)
      }
      .adaptiveGlassButtonStyle()
      .help("Cancel voice note")
    } else {
      Button {
        Task { @MainActor in
          await stopVoiceAndKeepTranscript()
        }
      } label: {
        voiceControlImage("stop.fill", color: .red)
      }
      .adaptiveGlassButtonStyle()
      .help("Stop conversation")
    }
  }

  @ViewBuilder
  private var voiceTrailingControl: some View {
    if liveVoiceSession.mode == .voiceNoteAttachment {
      Button {
        Task { @MainActor in
          await stopVoiceAndAttachTranscript()
        }
      } label: {
        voiceControlImage("checkmark.circle.fill", color: .accentColor)
      }
      .adaptiveGlassButtonStyle()
      .disabled(liveVoiceSession.state == .requestingPermission)
      .help("Attach voice note")
    } else {
      Button {
        if hasVoiceTranscript {
          liveVoiceSession.submitCurrentTurn(store: store, ttsPlayer: ttsPlayer)
        } else {
          liveVoiceSession.togglePauseOrRecord(store: store, ttsPlayer: ttsPlayer)
        }
      } label: {
        voiceControlImage(voiceTrailingSystemImage, color: .accentColor)
      }
      .adaptiveGlassButtonStyle()
      .disabled(liveVoiceSession.state == .requestingPermission)
      .help(voiceTrailingHelp)
    }
  }

  private var hasVoiceTranscript: Bool {
    !liveVoiceSession.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var voiceTrailingSystemImage: String {
    hasVoiceTranscript ? "arrow.up" : liveVoiceSession.primaryControlSystemImage
  }

  private var voiceTrailingHelp: String {
    hasVoiceTranscript ? "Send message" : liveVoiceSession.primaryControlHelp
  }

  private func voiceControlImage(_ systemImage: String, color: Color) -> some View {
    Image(systemName: systemImage)
      .font(.title2)
      .symbolRenderingMode(.hierarchical)
      .foregroundStyle(color)
      .frame(width: 28, height: 28)
      .contentShape(Circle())
  }

  private func cancelVoiceNoteAttachment() {
    liveVoiceSession.stop(cancelResponse: false)
    composerFocused = true
  }

  private var voiceStatusTitle: String {
    guard liveVoiceSession.mode == .voiceNoteAttachment else {
      return liveVoiceSession.state.statusText
    }
    switch liveVoiceSession.state {
    case .idle:
      return "Voice note off"
    case .requestingPermission:
      return "Requesting access"
    case .listening:
      return "Recording voice note"
    case .paused:
      return "Voice note ready"
    case .thinking:
      return "Processing voice note"
    case .speaking:
      return "Voice note ready"
    case .error:
      return "Voice note error"
    }
  }

  @MainActor
  private func stopVoiceAndKeepTranscript(
    cancelResponse: Bool = true,
    focusComposer: Bool = true
  ) async {
    if liveVoiceSession.mode == .voiceNoteAttachment {
      await stopVoiceAndAttachTranscript(focusComposer: focusComposer)
      return
    }
    let text = await liveVoiceSession.stopForDraft(cancelResponse: cancelResponse)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    draftText = mergedDraftText(appending: text)
    persistDraftTextNow()
    if focusComposer {
      composerFocused = true
    }
  }

  @MainActor
  private func stopVoiceAndAttachTranscript(focusComposer: Bool = true) async {
    let text = await liveVoiceSession.stopForDraft(cancelResponse: false)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      if focusComposer {
        composerFocused = true
      }
      return
    }
    pendingAttachments.append(
      .textFile(
        filename: voiceNoteAttachmentFilename(),
        text: text,
        mimeType: "text/plain"))
    if focusComposer {
      composerFocused = true
    }
  }

  private func mergedDraftText(appending text: String) -> String {
    let current = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !current.isEmpty else { return text }
    return "\(current)\n\(text)"
  }

  private var voiceStatusDetail: String {
    let trimmed = liveVoiceSession.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
      return trimmed
    }
    return
      "\(store.settings.conversation.speechRecognitionBackend.displayName) · \(liveVoiceSession.languageIdentifier)"
  }

  private var draftBinding: Binding<String> {
    Binding(
      get: { draftText },
      set: { newText in
        if draftText.isEmpty, !newText.isEmpty { inputSession.prepareToSend() }
        draftText = newText
        scheduleDraftPersistence(newText, for: conversationID)
      }
    )
  }

  private func scheduleDraftPersistence(_ text: String, for conversationID: UUID?) {
    draftPersistenceTask?.cancel()
    let store = store
    draftPersistenceTask = Task.detached(priority: .utility) {
      do {
        try await Task.sleep(nanoseconds: Self.draftAutosaveDelayNanoseconds)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      await store.setDraftText(text, for: conversationID)
    }
  }

  private func persistDraftTextNow(_ text: String? = nil, for conversationID: UUID? = nil) {
    draftPersistenceTask?.cancel()
    draftPersistenceTask = nil
    store.setDraftText(text ?? draftText, for: conversationID ?? self.conversationID)
  }

  private func submitDraft() {
    if isResponding, let conversationID, canQueueDraft {
      queueDraft(in: conversationID)
      return
    }
    guard canSubmitDraft else { return }
    composerFocused = false
    let submitted = draftText
    let submittedIsCommand = isBTW || isVersionCommand
    let submittedAttachments = submittedIsCommand ? [] : pendingAttachments
    let submittedConversationID = conversationID
    if !submittedIsCommand { pendingAttachments = [] }
    draftText = ""
    persistDraftTextNow("", for: submittedConversationID)
    Task {
      let sent = await inputSession.send(
        prompt: submitted,
        attachments: submittedAttachments)
      if !sent {
        draftText = submitted
        if !submittedIsCommand { pendingAttachments = submittedAttachments }
        persistDraftTextNow(submitted, for: submittedConversationID)
      }
    }
  }

  private func queueDraft(in conversationID: UUID) {
    guard canQueueDraft else { return }
    composerFocused = false
    let submitted = draftText
    let submittedAttachments = pendingAttachments
    draftText = ""
    pendingAttachments = []
    persistDraftTextNow("", for: conversationID)
    guard
      !store.enqueueUserMessage(
        prompt: submitted,
        attachments: submittedAttachments,
        in: conversationID)
    else {
      return
    }

    // The provider may have completed between the button rendering and this
    // tap. In that race, submit it as the next ordinary turn instead.
    Task {
      let sent = await store.send(
        prompt: submitted,
        attachments: submittedAttachments)
      if !sent {
        draftText = submitted
        pendingAttachments = submittedAttachments
        persistDraftTextNow(submitted, for: conversationID)
      }
    }
  }

  private func restoreQueuedMessageToComposer(_ message: QueuedChatMessage) {
    let current = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
    if current.isEmpty {
      draftText = message.text
    } else if !message.text.isEmpty {
      draftText = "\(message.text)\n\(current)"
    }
    pendingAttachments = message.attachments + pendingAttachments
    persistDraftTextNow()
    composerFocused = true
  }

  private func applyComposerDraftReplacement(_ replacement: ComposerDraftReplacement) {
    Task { @MainActor in
      // A follow-up tap removes its suggestion card in the same update that
      // requests this replacement. Let that teardown finish before changing
      // the native text field, otherwise it keeps displaying its cached text
      // until the user types.
      await Task.yield()
      guard !liveVoiceSession.isActive,
        conversationID == (remoteChat?.conversation.id ?? store.currentConversation?.id),
        store.composerDraftReplacement?.id == replacement.id
      else {
        return
      }
      composerFocused = false
      draftText = replacement.text
      promptAutocompleteSuppressedCommand = nil
      focusComposerAfterTextFieldRefresh = true
      composerTextFieldRefreshID = replacement.id
      store.consumeComposerDraftReplacement(replacement.id)
    }
  }

  private var promptAutocompletePopover: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(promptShortcutOptions) { option in
          Button {
            autocompletePrompt(option)
          } label: {
            HStack(spacing: 10) {
              Image(systemName: option.systemImage)
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)
              VStack(alignment: .leading, spacing: 2) {
                Text("\(option.prefix)\(option.commandName)")
                  .font(.callout.weight(.semibold))
                  .foregroundStyle(.primary)
                HStack(spacing: 6) {
                  Text(option.displayName)
                    .lineLimit(1)
                  Text(option.detail)
                    .foregroundStyle(.tertiary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
              }
              Spacer(minLength: 8)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.vertical, 6)
    }
    .frame(minWidth: 280, idealWidth: 340, maxWidth: 380, maxHeight: 280)
  }

  private func autocompletePrompt(_ option: PromptShortcutMenuOption) {
    let remainder = PromptSlashCommand.parse(draftText)?.remainder ?? ""
    let completed = "\(option.prefix)\(option.commandName) \(remainder)"
    // Rewriting the draft in the same update that dismisses the popover leaves
    // the composer's text view showing the typed fragment until it is tapped
    // again: the text change is swallowed by the presentation teardown. Close
    // the popover first (pendingPromptCompletion keeps it closed without
    // touching the draft, so the half-typed command cannot re-open it), then
    // apply the completion on the next runloop turn.
    promptAutocompleteSuppressedCommand = option.commandName
    pendingPromptCompletion = completed
    Task { @MainActor in
      guard pendingPromptCompletion == completed else { return }
      pendingPromptCompletion = nil
      draftText = completed
      persistDraftTextNow(completed)
      composerFocused = true
    }
  }

  private var toolMenu: some View {
    Button {
      showingToolMenu.toggle()
    } label: {
      Image(systemName: "plus")
        .font(.title2)
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(Color.accentColor)
        .frame(width: 44, height: 44)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .background { composerInputBackground }
    .popover(isPresented: $showingToolMenu, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
      toolMenuPopover
        .presentationCompactAdaptation(.popover)
    }
    .popover(isPresented: $showingToolPicker, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom)
    {
      ToolPickerPopover(remoteChat: remoteChat)
        .environmentObject(store)
        .presentationCompactAdaptation(.popover)
    }
    .sheet(item: $remoteWorkingFolder) { location in
      FileBrowserView(location: location).environmentObject(store)
    }
    .popover(
      isPresented: $showingWorkingFolderMenu, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom
    ) {
      workingFolderMenuPopover
        .presentationCompactAdaptation(.popover)
    }
    .help("Tools")
  }

  private var toolMenuPopover: some View {
    VStack(alignment: .leading, spacing: 4) {
      Toggle(isOn: toolsEnabledBinding) {
        toolMenuRowLabel("Enable Tools", systemImage: "wrench.and.screwdriver")
      }
      .toggleStyle(.switch)
      .padding(.horizontal, 12).padding(.vertical, 9)
      .disabled(remoteToolSettingsUnavailable)
      toolMenuButton(
        "Select Tools...", systemImage: "checklist",
        trailingText: "(\(enabledToolSelectionCount))",
        isEnabled: toolsEnabled,
        action: openToolPicker
      )
      toolMenuButton(
        "Working Folder...", systemImage: "folder.badge.gearshape",
        trailingText: workingFolderMenuText,
        isEnabled: remoteChat.map {
          $0.bookmark.requiresApproval != true
            && !store.settings.isOffline
        } ?? true,
        action: openWorkingFolderMenu)
      Divider()
      toolMenuButton(
        "Attach Document", systemImage: "doc.text",
        action: openTextFileImporter)
      toolMenuButton("Record voice", systemImage: "mic.badge.plus") {
        showingToolMenu = false
        liveVoiceSession.startVoiceNoteAttachment(
          store: store, ttsPlayer: ttsPlayer, remoteChat: remoteChat)
      }
      toolMenuButton("Add images", systemImage: "photo", isEnabled: canAttachImage) {
        showingToolMenu = false
        showingImagePicker = true
      }
      toolMenuButton("Take picture", systemImage: "camera", isEnabled: canTakePicture) {
        showingToolMenu = false
        showingCameraPicker = true
      }
      Divider()
      toolMenuButton("Start App", systemImage: "square.grid.2x2") {
        showingToolMenu = false
        showingWebXDCLauncher = true
      }
    }
    .padding(8).frame(minWidth: 240, idealWidth: 320, maxWidth: 360).background(.regularMaterial)
    .fileImporter(
      isPresented: $showingTextFileImporter,
      allowedContentTypes: Self.documentAttachmentTypes
    ) { result in
      showingToolMenu = false
      importTextAttachment(result)
    }
    .task(id: remoteChat?.connected) { await remoteChat?.refreshConfiguration() }
  }

  private func toolMenuButton(
    _ title: String, systemImage: String, trailingText: String? = nil,
    isEnabled: Bool = true,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      toolMenuRowLabel(title, systemImage: systemImage, trailingText: trailingText)
        .padding(.horizontal, 12).padding(.vertical, 9)
    }
    .buttonStyle(.plain)
    .disabled(!isEnabled)
    .opacity(isEnabled ? 1 : 0.45)
  }

  /// The three ways a chat can resolve its working folder, shown as a popup
  /// from the "Working Folder..." row of the (+) menu.
  private var workingFolderMenuPopover: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Working Folder")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.bottom, 2)

      workingFolderMenuRow("Disable", systemImage: "folder.badge.minus", mode: .disabled) {
        store.disableCurrentConversationWorkingFolder()
      }

      workingFolderMenuRow(
        "Use Default Folder",
        systemImage: "arrow.uturn.backward",
        mode: .inherited,
        trailingText: defaultWorkingFolderName
      ) {
        store.clearCurrentConversationWorkingFolder()
      }

      workingFolderMenuRow(
        "Set Custom Folder...",
        systemImage: "folder.badge.gearshape",
        mode: .custom,
        trailingText: store.currentConversation?.workingFolder?.displayName,
        dismissesMenu: false
      ) {
        openWorkingFolderImporter()
      }
    }
    .padding(8)
    .frame(minWidth: 260)
    .background(.regularMaterial)
    .workingFolderImporter(
      isPresented: $showingWorkingFolderImporter, errorMessage: $attachmentError,
      onCompletion: { showingWorkingFolderMenu = false },
      onSelection: store.setCurrentConversationWorkingFolder)
  }

  private func workingFolderMenuRow(
    _ title: String,
    systemImage: String,
    mode: ConversationWorkingFolderMode,
    trailingText: String? = nil,
    dismissesMenu: Bool = true,
    action: @escaping () -> Void
  ) -> some View {
    Button {
      if dismissesMenu {
        showingWorkingFolderMenu = false
      }
      action()
    } label: {
      HStack(spacing: 10) {
        Image(systemName: workingFolderMode == mode ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(workingFolderMode == mode ? Color.accentColor : Color.secondary)
        toolMenuRowLabel(title, systemImage: systemImage, trailingText: trailingText)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
  }

  private func toolMenuRowLabel(
    _ title: String,
    systemImage: String,
    trailingText: String? = nil
  ) -> some View {
    HStack(spacing: 10) {
      Image(systemName: systemImage)
        .foregroundStyle(.secondary)
        .frame(width: 18)
      Text(title)
        .foregroundStyle(.primary)
      Spacer()
      if let trailingText {
        Text(trailingText)
          .foregroundStyle(.secondary)
          .lineLimit(1).truncationMode(.middle)
      }
    }
    .contentShape(Rectangle())
  }

  private func openToolPicker() {
    guard toolsEnabled else { return }
    showingToolMenu = false
    showingToolPicker = true
  }

  private func openWorkingFolderMenu() {
    showingToolMenu = false
    if let remoteChat {
      remoteWorkingFolder = .remote(remoteChat.bookmark, cwd: remoteChat.conversation.cwd)
    } else {
      showingWorkingFolderMenu = true
    }
  }

  private func openTextFileImporter() {
    showingTextFileImporter = true
  }

  private func openWorkingFolderImporter() {
    showingWorkingFolderImporter = true
  }

  private var workingFolderMode: ConversationWorkingFolderMode {
    guard let conversation = store.currentConversation else { return .inherited }
    return store.workingFolderMode(for: conversation)
  }

  private var defaultWorkingFolderName: String? {
    guard let conversation = store.currentConversation else { return nil }
    return store.conversationFolderDefaults(for: conversation.folderID).workingFolder?.displayName
      ?? FileWorkspaceService.defaultWorkspaceName
  }

  private var workingFolderMenuText: String? {
    if let remoteChat {
      let path = remoteChat.conversation.cwd
      guard !path.isEmpty else { return nil }
      return URL(fileURLWithPath: path).lastPathComponent
    }
    guard let conversation = store.currentConversation else { return nil }
    guard workingFolderMode != .disabled else { return "Off" }
    return store.workingFolderDisplayName(for: conversation)
  }

  private var toolsEnabled: Bool {
    if let remoteChat { return remoteChat.remoteToolsEnabled ?? true }
    return store.currentConversation?.toolsEnabled ?? true
  }

  private var remoteToolSettingsUnavailable: Bool {
    guard let remoteChat else { return false }
    return !remoteChat.connected || remoteChat.busy || remoteChat.settingsLoading
      || remoteChat.remoteToolsEnabled == nil || store.settings.isOffline
  }

  private var enabledToolSelectionCount: Int {
    if let remoteChat { return remoteChat.enabledRemoteToolCount }
    guard let selection = store.currentConversation?.toolSelection else { return 0 }
    return selection.native.subtracting([.memory]).count + store.mcpTools.reduce(0) { count, entry in
      count + entry.value.filter { selection.contains(serverID: entry.key, toolName: $0.name) }.count
    }
  }

  private var toolsEnabledBinding: Binding<Bool> {
    Binding(get: { toolsEnabled }, set: { enabled in
      showingToolPicker = false
      if let remoteChat {
        remoteChat.setConfigurationOption(id: "tools.enabled", value: .bool(enabled))
      } else {
        store.setChatToolsEnabled(enabled)
      }
    })
  }

  private static let textAttachmentByteLimit = 1_500_000

  /// Let Files offer any data file. MaiDocuments inspects its MIME type and
  /// bytes after selection, accepting arbitrary UTF-8 source/text files and
  /// offering to save unsupported binary data to the working folder.
  private static let documentAttachmentTypes: [UTType] = [.data]

  private func importTextAttachment(_ result: Result<URL, Error>) {
    do {
      let url = try result.get()
      let access = url.startAccessingSecurityScopedResource()
      defer {
        if access { url.stopAccessingSecurityScopedResource() }
      }
      guard !AudioTranscriptionService.isAudioFile(url) else {
        transcribePickedAudio(at: url, filename: url.lastPathComponent)
        return
      }
      if case .failed(let message) = importDocument(at: url, filename: url.lastPathComponent) {
        attachmentError = message
      }
    } catch {
      attachmentError = error.localizedDescription
    }
  }

  /// Converts a document into a text attachment, the same way for a file picked
  /// in the app and for one shared from another app: Word, EPUB and JSON become
  /// Markdown or an outline, text files travel as they are. A PDF is worth
  /// reading either way, so it asks first and the caller waits for the answer.
  private func importDocument(at url: URL, filename: String) -> DocumentImportOutcome {
    do {
      let data = try DocumentAttachmentImporter.data(at: url)
      let mimeType = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?
        .preferredMIMEType
      switch DocumentAttachmentImporter.kind(
        for: data, filename: filename, mimeType: mimeType)
      {
      case .pdf:
        let pending = PendingPDFImport(
          name: (filename as NSString).deletingPathExtension,
          data: data,
          canAttachImages: canAttachImage)
        guard pending.canAttachImages else {
          convertPDFToMarkdown(pending)
          return .attached
        }
        pendingPDFImport = pending
        return .awaitingAnswer
      case .html:
        pendingHTMLImport = PendingDocumentImport(
          data: data, filename: filename, mimeType: mimeType)
        return .awaitingAnswer
      default:
        break
      }
      return appendDocumentAttachment(data: data, filename: filename, mimeType: mimeType)
    } catch {
      return .failed(error.localizedDescription)
    }
  }

  @discardableResult
  private func appendDocumentAttachment(
    data: Data,
    filename: String,
    mimeType: String?,
    htmlMode: HTMLAttachmentMode = .source
  ) -> DocumentImportOutcome {
    do {
      let imported = try DocumentAttachmentImporter.attachment(
        data: data, filename: filename, mimeType: mimeType, htmlMode: htmlMode)
      guard case .file(let file) = imported.content, let text = file.text else {
        return .failed("\(filename) does not contain any text.")
      }
      pendingAttachments.append(
        .textFile(filename: imported.name, text: text, mimeType: file.mimeType))
      composerFocused = true
      return .attached
    } catch let error as DocumentImportError {
      switch error {
      case .binaryFile, .notUTF8, .textTooLarge:
        if remoteChat == nil, store.currentConversation != nil {
          pendingWorkspaceImport = PendingDocumentImport(
            data: data, filename: filename, mimeType: mimeType)
          return .awaitingAnswer
        }
      default:
        break
      }
      return .failed(error.localizedDescription)
    } catch {
      return .failed(error.localizedDescription)
    }
  }

  /// Transcribes a recording picked with "Attach Document" and attaches the
  /// text under the recording's own name, the same way a shared voice message
  /// is handled. The file is copied first: recognition outlives the picker's
  /// access to it.
  private func transcribePickedAudio(at url: URL, filename: String) {
    let staged: URL
    do {
      staged = try AudioTranscriptionService.stagedCopy(of: url)
    } catch {
      attachmentError = error.localizedDescription
      return
    }
    attachmentConversionMessage = "Transcribing audio..."
    let localeIdentifier = store.settings.conversation.speechRecognitionLanguageIdentifier
    Task { @MainActor in
      defer {
        attachmentConversionMessage = nil
        try? FileManager.default.removeItem(at: staged)
      }
      do {
        store.speechTranscriptionPolicy.configure(store.settings)
        let transcript = try await AudioTranscriptionService.transcribe(
          fileURL: staged,
          localeIdentifier: localeIdentifier,
          policy: store.speechTranscriptionPolicy)
        pendingAttachments.append(
          .textFile(
            filename: transcriptAttachmentFilename(for: filename),
            text: transcript,
            mimeType: "text/plain"))
        composerFocused = true
      } catch {
        attachmentError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      }
    }
  }

  /// Converts the PDF's text off the main thread: a scanned document has to be
  /// run through OCR, which takes a moment.
  private func convertPDFToMarkdown(_ pending: PendingPDFImport) {
    pendingPDFImport = nil
    attachmentConversionMessage = "Converting PDF..."
    let data = pending.data
    let name = pending.name
    Task {
      let outcome = await Task.detached(priority: .userInitiated) {
        PDFTextImportOutcome.convert(data)
      }.value
      attachmentConversionMessage = nil
      switch outcome {
      case .markdown(let markdown):
        guard markdown.utf8.count <= Self.textAttachmentByteLimit else {
          attachmentError = "Text attachments are limited to 1.5 MB."
          return
        }
        pendingAttachments.append(
          .textFile(filename: name + ".md", text: markdown, mimeType: "text/markdown"))
        composerFocused = true
      case .failure(let message):
        attachmentError = message
      }
    }
  }

  private func convertPDFToImages(_ pending: PendingPDFImport) {
    pendingPDFImport = nil
    attachmentConversionMessage = "Converting PDF..."
    let data = pending.data
    let name = pending.name
    Task {
      let outcome = await Task.detached(priority: .userInitiated) {
        PDFPageImportOutcome.render(data)
      }.value
      attachmentConversionMessage = nil
      switch outcome {
      case .pages(let pages, let truncated):
        await appendPDFPageAttachments(pages, name: name, truncated: truncated)
      case .failure(let message):
        attachmentError = message
      }
    }
  }

  @MainActor
  private func appendPDFPageAttachments(
    _ pages: [Data], name: String, truncated: Bool
  ) async {
    var items: [PendingImageAttachmentImport.Item] = []
    for (index, page) in pages.enumerated() {
      guard let image = await AttachmentImageLoader.decodeImageData(page) else { continue }
      items.append(
        PendingImageAttachmentImport.Item(
          filename: "\(name)-page-\(index + 1).jpg", image: image))
    }
    guard !items.isEmpty else {
      attachmentError = "The PDF pages could not be rendered."
      return
    }

    let note: String? =
      truncated
      ? "Only the first \(PDFImporter.maximumImagePages) pages were attached." : nil
    let imageSize = store.settings.attachmentImageSize
    guard imageSize != .prompt else {
      pendingImageSizePrompt = PendingImageAttachmentImport(
        items: items, failedCount: 0, note: note)
      return
    }
    appendImageAttachments(items, size: imageSize)
    if let note { attachmentError = note }
  }

  @MainActor
  private func importImageAttachments(_ items: [PhotosPickerItem]) async {
    defer { selectedPhotoItems = [] }
    guard !items.isEmpty else { return }
    guard canAttachImage else {
      attachmentError = "The selected provider or model does not support image input."
      return
    }

    var imports: [PendingImageAttachmentImport.Item] = []
    var failedCount = 0
    let timestamp = Int(Date().timeIntervalSince1970)

    for (index, item) in items.enumerated() {
      do {
        guard let data = try await item.loadTransferable(type: Data.self),
          let image = await AttachmentImageLoader.decodeImageData(data)
        else {
          failedCount += 1
          continue
        }
        imports.append(
          PendingImageAttachmentImport.Item(
            filename: imageAttachmentFilename(
              prefix: "image",
              timestamp: timestamp,
              index: items.count == 1 ? nil : index + 1),
            image: image))
      } catch {
        failedCount += 1
      }
    }

    guard !imports.isEmpty else {
      attachmentError =
        items.count == 1
        ? "Could not read the selected image." : "Could not read the selected images."
      return
    }

    let imageSize = store.settings.attachmentImageSize
    guard imageSize != .prompt else {
      pendingImageSizePrompt = PendingImageAttachmentImport(
        items: imports,
        failedCount: failedCount)
      return
    }
    appendImageAttachments(imports, size: imageSize)
    if failedCount > 0 {
      attachmentError = imageImportFailureMessage(count: failedCount)
    }
  }

  @MainActor
  private func importCameraImageAttachment(_ image: UIImage) {
    guard canAttachImage else {
      attachmentError = "The selected provider or model does not support image input."
      return
    }
    let filename = imageAttachmentFilename(
      prefix: "photo",
      timestamp: Int(Date().timeIntervalSince1970))
    let imageSize = store.settings.attachmentImageSize
    guard imageSize != .prompt else {
      pendingImageSizePrompt = PendingImageAttachmentImport(
        items: [.init(filename: filename, image: image)],
        failedCount: 0)
      return
    }
    appendImageAttachment(image, filename: filename, size: imageSize)
  }

  /// Extracts the text instead of attaching the pixels: each image is run
  /// through Vision's on-device recogniser off the main thread and lands as a
  /// Markdown text attachment.
  private func convertImagesToText(_ pending: PendingImageAttachmentImport) {
    pendingImageSizePrompt = nil
    attachmentConversionMessage = "Recognizing text..."
    let items = pending.items
    Task {
      var attachments: [ChatAttachment] = []
      var unreadableCount = 0
      let ocrProvider = try? await PocketMaiPluginHost.shared.makeOCRProvider()
      for item in items {
        let imageData = item.image.jpegData(compressionQuality: 0.95)
        let markdown: String?
        if let imageData, let ocrProvider {
          markdown = try? await ocrProvider.recognize(
            MaiCore.OCRRequest(
              imageData: imageData,
              mimeType: "image/jpeg",
              filename: item.filename)
          ).markdown
        } else {
          markdown = nil
        }
        guard let markdown, markdown.utf8.count <= Self.textAttachmentByteLimit else {
          unreadableCount += 1
          continue
        }
        attachments.append(
          .textFile(
            filename: (item.filename as NSString).deletingPathExtension + ".md",
            text: markdown,
            mimeType: "text/markdown"))
      }
      attachmentConversionMessage = nil
      pendingAttachments.append(contentsOf: attachments)
      if !attachments.isEmpty {
        composerFocused = true
      }
      if unreadableCount > 0 {
        attachmentError =
          items.count == 1
          ? "No text could be recognized in the image."
          : "No text could be recognized in \(unreadableCount) of \(items.count) images."
      } else if pending.failedCount > 0 {
        attachmentError = imageImportFailureMessage(count: pending.failedCount)
      } else if let note = pending.note {
        attachmentError = note
      }
    }
  }

  private func appendImageAttachment(
    _ pending: PendingImageAttachmentImport,
    size: AttachmentImageSize
  ) {
    appendImageAttachments(pending.items, size: size)
    pendingImageSizePrompt = nil
    if pending.failedCount > 0 {
      attachmentError = imageImportFailureMessage(count: pending.failedCount)
    } else if let note = pending.note {
      attachmentError = note
    }
  }

  private func appendImageAttachments(
    _ items: [PendingImageAttachmentImport.Item],
    size: AttachmentImageSize
  ) {
    for item in items {
      appendImageAttachment(item.image, filename: item.filename, size: size)
    }
  }

  private func appendImageAttachment(_ image: UIImage, filename: String, size: AttachmentImageSize)
  {
    let resized = resizeImage(image, maxDimension: size.maxDimension)
    guard let output = resized.image.jpegData(compressionQuality: 0.82) else {
      attachmentError = "Could not encode the selected image."
      return
    }
    pendingAttachments.append(
      .image(
        filename: filename,
        data: output,
        width: Int(resized.size.width.rounded()),
        height: Int(resized.size.height.rounded())))
    composerFocused = true
  }

  private func resizeImage(_ image: UIImage, maxDimension: Int?) -> (image: UIImage, size: CGSize) {
    let pixelSize = CGSize(
      width: image.size.width * image.scale,
      height: image.size.height * image.scale)
    guard let maxDimension, max(pixelSize.width, pixelSize.height) > CGFloat(maxDimension) else {
      return (image, pixelSize)
    }
    let scale = CGFloat(maxDimension) / max(pixelSize.width, pixelSize.height)
    let target = CGSize(
      width: max(1, floor(pixelSize.width * scale)),
      height: max(1, floor(pixelSize.height * scale)))
    let renderer = UIGraphicsImageRenderer(size: target)
    let resized = renderer.image { _ in
      image.draw(in: CGRect(origin: .zero, size: target))
    }
    return (resized, target)
  }

  private func imageAttachmentFilename(prefix: String, timestamp: Int, index: Int? = nil) -> String
  {
    guard let index else { return "\(prefix)-\(timestamp).jpg" }
    return "\(prefix)-\(timestamp)-\(index).jpg"
  }

  // MARK: - Shared content

  /// Imports what another app sent to PocketMai through the share sheet.
  ///
  /// Each item follows the same path it would have taken inside the app: a
  /// picture asks for its size or offers OCR, a PDF asks how it should be
  /// attached, a voice message is transcribed, a document is converted to text,
  /// and shared text or a link is appended to the draft.
  private func beginSharedImport() {
    let items = store.takeQueuedSharedItems()
    guard !items.isEmpty else { return }
    sharedImportQueue.append(contentsOf: items)
    Task { await processSharedImportQueue() }
  }

  @MainActor
  private func processSharedImportQueue() async {
    guard !isImportingSharedItems else { return }
    isImportingSharedItems = true
    defer { isImportingSharedItems = false }
    while !sharedImportQueue.isEmpty {
      let item = sharedImportQueue.removeFirst()
      // An item that puts a question on screen stops the queue; the answer
      // starts it again.
      if await importSharedItem(item) { return }
    }
    finishSharedImport()
  }

  private var hasPendingSharedImports: Bool {
    !sharedImportQueue.isEmpty || !sharedImportImages.isEmpty || !sharedImportFailures.isEmpty
  }

  /// Continues the import once a confirmation dialog has been answered, after
  /// the dialog has had time to dismiss. Dismissing a dialog reports both the
  /// button and the binding, so a resume already on its way is left alone.
  private func resumeSharedImportAfterAnswer() {
    guard hasPendingSharedImports, !isResumingSharedImport else { return }
    isResumingSharedImport = true
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(400))
      isResumingSharedImport = false
      await processSharedImportQueue()
    }
  }

  /// Returns true when the item is waiting on a dialog.
  @MainActor
  private func importSharedItem(_ item: SharedInboxItem) async -> Bool {
    defer { SharedInbox.discard(item) }
    switch item.kind {
    case .text, .link:
      let text = (item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return false }
      draftText = mergedDraftText(appending: text)
      persistDraftTextNow()
      composerFocused = true
      return false
    case .image:
      await collectSharedImage(item)
      return false
    case .audio:
      await transcribeSharedAudio(item)
      return false
    case .document:
      guard let url = SharedInbox.fileURL(for: item) else {
        sharedImportFailures.append("\(item.filename) could not be read.")
        return false
      }
      switch importDocument(at: url, filename: item.filename) {
      case .attached:
        return false
      case .awaitingAnswer:
        return true
      case .failed(let message):
        sharedImportFailures.append(message)
        return false
      }
    }
  }

  @MainActor
  private func collectSharedImage(_ item: SharedInboxItem) async {
    guard let url = SharedInbox.fileURL(for: item),
      let data = try? Data(contentsOf: url),
      let image = await AttachmentImageLoader.decodeImageData(data)
    else {
      sharedImportFailures.append("\(item.filename) could not be read.")
      return
    }
    // The attachment is re-encoded as JPEG, so the name follows.
    let name = (item.filename as NSString).deletingPathExtension
    sharedImportImages.append(
      PendingImageAttachmentImport.Item(
        filename: (name.isEmpty ? "shared-image" : name) + ".jpg",
        image: image))
  }

  @MainActor
  private func transcribeSharedAudio(_ item: SharedInboxItem) async {
    guard let url = SharedInbox.fileURL(for: item) else {
      sharedImportFailures.append("\(item.filename) could not be read.")
      return
    }
    attachmentConversionMessage = "Transcribing audio..."
    defer { attachmentConversionMessage = nil }
    do {
      store.speechTranscriptionPolicy.configure(store.settings)
      let transcript = try await AudioTranscriptionService.transcribe(
        fileURL: url,
        localeIdentifier: store.settings.conversation.speechRecognitionLanguageIdentifier,
        policy: store.speechTranscriptionPolicy)
      pendingAttachments.append(
        .textFile(
          filename: transcriptAttachmentFilename(for: item.filename),
          text: transcript,
          mimeType: "text/plain"))
      composerFocused = true
    } catch {
      sharedImportFailures.append(
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }
  }

  /// Pictures are attached together at the end, the way a multiple-photo pick
  /// asks for one size for the whole batch.
  @MainActor
  private func finishSharedImport() {
    let images = sharedImportImages
    let note = sharedImportFailures.isEmpty ? nil : sharedImportFailures.joined(separator: "\n")
    sharedImportImages = []
    sharedImportFailures = []

    guard !images.isEmpty else {
      if let note { attachmentError = note }
      return
    }
    guard canAttachImage else {
      // The chosen model cannot read pictures, so their text is read instead of
      // dropping the share.
      convertImagesToText(
        PendingImageAttachmentImport(
          items: images,
          failedCount: 0,
          note: note
            ?? "The selected model does not accept images, so their text was attached instead."))
      return
    }
    let imageSize = store.settings.attachmentImageSize
    guard imageSize != .prompt else {
      pendingImageSizePrompt = PendingImageAttachmentImport(
        items: images,
        failedCount: 0,
        note: note)
      return
    }
    appendImageAttachments(images, size: imageSize)
    if let note { attachmentError = note }
  }

  private func transcriptAttachmentFilename(for filename: String) -> String {
    let stem = (filename as NSString).deletingPathExtension
    let base = stem.isEmpty ? "voice-message" : stem
    var name = "\(base).txt"
    var suffix = 2
    while pendingAttachments.contains(where: { $0.filename == name }) {
      name = "\(base)-\(suffix).txt"
      suffix += 1
    }
    return name
  }

  private func voiceNoteAttachmentFilename() -> String {
    let base = "voice-note-\(Int(Date().timeIntervalSince1970))"
    var filename = "\(base).txt"
    var suffix = 2
    while pendingAttachments.contains(where: { $0.filename == filename }) {
      filename = "\(base)-\(suffix).txt"
      suffix += 1
    }
    return filename
  }

  private func imageImportFailureMessage(count: Int) -> String {
    count == 1 ? "1 image could not be read." : "\(count) images could not be read."
  }
}

/// What happened to a document handed to `importDocument`.
private enum DocumentImportOutcome {
  case attached
  /// A dialog is on screen asking how the document should be attached.
  case awaitingAnswer
  case failed(String)
}

private struct PendingPDFImport {
  let name: String
  let data: Data
  let canAttachImages: Bool
}

private struct PendingDocumentImport {
  let data: Data
  let filename: String
  let mimeType: String?
}

/// The importers run off the main actor, so their results travel as values.
private enum PDFTextImportOutcome: Sendable {
  case markdown(String)
  case failure(String)

  static func convert(_ data: Data) -> PDFTextImportOutcome {
    do {
      return .markdown(try PDFImporter.markdown(from: data))
    } catch {
      return .failure(error.localizedDescription)
    }
  }
}

private enum PDFPageImportOutcome: Sendable {
  case pages([Data], truncated: Bool)
  case failure(String)

  static func render(_ data: Data) -> PDFPageImportOutcome {
    do {
      let rendered = try PDFImporter.pageImages(from: data)
      return .pages(rendered.images, truncated: rendered.truncated)
    } catch {
      return .failure(error.localizedDescription)
    }
  }
}

private struct PendingImageAttachmentImport {
  struct Item {
    let filename: String
    let image: UIImage
  }

  let items: [Item]
  let failedCount: Int
  /// Shown once the attachments land, e.g. when a long PDF was truncated.
  var note: String?

  var imageSizePromptMessage: String {
    guard items.count != 1 else {
      return "Choose the image size for \(items[0].filename)."
    }
    return "Choose the image size for \(items.count) images."
  }
}

private struct CameraImagePicker: UIViewControllerRepresentable {
  @Binding var isPresented: Bool
  let onImagePicked: (UIImage) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(isPresented: $isPresented, onImagePicked: onImagePicked)
  }

  func makeUIViewController(context: Context) -> UIImagePickerController {
    let picker = UIImagePickerController()
    picker.sourceType = .camera
    picker.mediaTypes = [UTType.image.identifier]
    picker.allowsEditing = false
    picker.delegate = context.coordinator
    return picker
  }

  func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

  final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate
  {
    @Binding private var isPresented: Bool
    private let onImagePicked: (UIImage) -> Void

    init(isPresented: Binding<Bool>, onImagePicked: @escaping (UIImage) -> Void) {
      _isPresented = isPresented
      self.onImagePicked = onImagePicked
    }

    func imagePickerController(
      _ picker: UIImagePickerController,
      didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
      isPresented = false
      guard let image = info[.originalImage] as? UIImage else { return }
      onImagePicked(image)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
      isPresented = false
    }
  }
}

private struct AttachmentPill: View {
  let attachment: ChatAttachment
  let onOpen: (() -> Void)?
  let onRemove: () -> Void

  var body: some View {
    if attachment.kind == .image {
      imageAttachmentPill
    } else {
      textAttachmentPill
    }
  }

  private var textAttachmentPill: some View {
    HStack(spacing: 6) {
      Image(systemName: "doc.text")
        .foregroundStyle(.secondary)
      Text(attachment.displayName)
        .font(.caption)
        .lineLimit(1)
      removeButton
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .onTapGesture {
      onOpen?()
    }
    .accessibilityHint(onOpen == nil ? "" : "Tap to view and edit the file contents")
  }

  private var imageAttachmentPill: some View {
    HStack(spacing: 7) {
      imageThumbnail
      Text(dimensionsLabel)
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
      removeButton
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 5)
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .onTapGesture {
      onOpen?()
    }
    .accessibilityLabel("\(attachment.displayName), \(dimensionsLabel)")
    .accessibilityHint(onOpen == nil ? "" : "Tap to preview the image")
  }

  @ViewBuilder
  private var imageThumbnail: some View {
    AttachmentImageThumbnail(attachment: attachment, side: 40, cornerRadius: 6)
  }

  private var removeButton: some View {
    Button(action: onRemove) {
      Image(systemName: "xmark.circle.fill")
        .foregroundStyle(.secondary)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Remove attachment")
  }

  private var dimensionsLabel: String {
    if let width = attachment.width, let height = attachment.height {
      return "\(width)x\(height)"
    }
    return "Image"
  }
}
