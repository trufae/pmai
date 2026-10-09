import SwiftUI
import UIKit
import UniformTypeIdentifiers

private struct BackupSharedFile: Identifiable {
  let id = UUID()
  let url: URL
}

private struct BackupActivityShareSheet: UIViewControllerRepresentable {
  let activityItems: [Any]

  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
  }

  func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Import Panel

private struct BackupSectionCheckbox: View {
  let section: SettingsBackupSection
  let detail: String
  @Binding var isSelected: Bool

  var body: some View {
    Button {
      isSelected.toggle()
    } label: {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: isSelected ? "checkmark.square.fill" : "square")
          .imageScale(.large)
          .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
          .frame(width: 24)
        VStack(alignment: .leading, spacing: 4) {
          Label(section.title, systemImage: section.systemImage)
            .foregroundStyle(.primary)
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

extension SettingsBackupSection {
  fileprivate var title: String {
    switch self {
    case .providers: "Provider Settings"
    case .prompts: "Prompts"
    case .tools: "Tool Settings"
    case .conversations: "Conversations"
    }
  }

  fileprivate var systemImage: String {
    switch self {
    case .providers: "network"
    case .prompts: "text.bubble"
    case .tools: "wrench.and.screwdriver"
    case .conversations: "bubble.left.and.bubble.right"
    }
  }
}

struct SettingsImportView: View {
  @EnvironmentObject private var store: AppStore

  private let initialFile: PendingConversationImportFile?
  private let onFinish: (() -> Void)?

  @State private var showingFileImporter = false
  @State private var importPreview: SettingsImportFilePreview?
  @State private var selectedSections = SettingsBackupSelection()
  @State private var restoreAudio = false
  @State private var includePictures = false

  @State private var pendingConversationImport: ConversationImportPreview?
  @State private var pendingConversationCollectionImport: PendingConversationImportFile?

  @State private var toast: String?
  @State private var errorMessage: String?

  init(
    initialFile: PendingConversationImportFile? = nil,
    onFinish: (() -> Void)? = nil
  ) {
    self.initialFile = initialFile
    self.onFinish = onFinish
  }

  var body: some View {
    Form {
      Section {
        Button {
          errorMessage = nil
          showingFileImporter = true
        } label: {
          HStack {
            Label(
              importPreview == nil ? "Choose JSON File" : "Choose Different JSON File",
              systemImage: "doc.badge.plus"
            )
            Spacer(minLength: 0)
          }
          .contentShape(Rectangle())
        }
      } header: {
        Text("File")
      }

      if let importPreview {
        importInfoSection(importPreview)
        importContentsSection(importPreview)
        importOptionsSection(importPreview)
        Section {
          Button {
            importSelected(from: importPreview)
          } label: {
            Label("Import Selected", systemImage: "square.and.arrow.down")
          }
          .disabled(selectedSections.intersection(importPreview.availableSelection).isEmpty)
        }
      }

      if let errorMessage {
        Section {
          Label(errorMessage, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
        }
      }
    }
    .navigationTitle("Import")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if initialFile != nil {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { onFinish?() }
        }
      }
    }
    .fileImporter(
      isPresented: $showingFileImporter,
      allowedContentTypes: [.json]
    ) { result in
      handleFilePick(result)
    }
    .sheet(item: $pendingConversationImport) { preview in
      ConversationImportConfirmationView(
        preview: preview,
        onCancel: {
          pendingConversationImport = nil
        },
        onImportAsNew: { title in
          finishConversationImport(preview, resolution: .create(title: title))
        },
        onUpdateExisting: {
          finishConversationImport(preview, resolution: .updateExisting)
        }
      )
    }
    .sheet(item: $pendingConversationCollectionImport) { file in
      ConversationCollectionImportView(file: file) {
        pendingConversationCollectionImport = nil
        importPreview = nil
        selectedSections = SettingsBackupSelection()
        onFinish?()
      }
      .environmentObject(store)
    }
    .task(id: initialFile?.id) {
      guard let initialFile else { return }
      prepareImportPreview(from: initialFile)
    }
    .settingsToast($toast, style: .success)
  }

  @ViewBuilder
  private func importInfoSection(_ preview: SettingsImportFilePreview) -> some View {
    Section {
      infoRow("File", preview.filename)
      infoRow("Type", previewType(preview))
      infoRow("Created by", preview.pocketMaiVersion)
      infoRow("Exported", formattedDate(preview.exportedAt))
      switch preview.kind {
      case .backup(let envelope):
        infoRow("Backup format", "\(envelope.version)")
      case .conversation(let envelope):
        if envelope.exportedConversations.count == 1 {
          infoRow("Title", envelope.title)
          infoRow("Provider", envelope.providerDisplayName)
          infoRow("Model", envelope.model)
          infoRow("Messages", "\(envelope.conversation.messages.count)")
        } else {
          infoRow("Conversations", "\(envelope.exportedConversations.count)")
        }
      case .portable(let archive):
        infoRow("Archive format", "\(archive.version)")
        if let agents = archive.settings?.agents {
          infoRow("pmai agents", "\(agents.count) (not imported on iOS)")
        }
        if let skills = archive.skills {
          infoRow("Skills", "\(skills.count)")
        }
      }
    } header: {
      Text("File Info")
    }
  }

  @ViewBuilder
  private func importContentsSection(_ preview: SettingsImportFilePreview) -> some View {
    let available = preview.availableSelection
    Section {
      ForEach(SettingsBackupSection.allCases) { section in
        if available.contains(section) {
          BackupSectionCheckbox(
            section: section,
            detail: importDetail(for: section, preview: preview),
            isSelected: selectionBinding(section, available: available))
        }
      }
    } header: {
      Text("Contents")
    }
  }

  @ViewBuilder
  private func importOptionsSection(_ preview: SettingsImportFilePreview) -> some View {
    if selectedSections.intersection(preview.availableSelection).conversations {
      Section {
        if backupHasVoiceAudio(preview) {
          Toggle(isOn: $restoreAudio) {
            VStack(alignment: .leading, spacing: 2) {
              Label("Restore voice audio", systemImage: "waveform")
              Text("Write embedded m4a files back to the voice-recordings folder.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
        Toggle(isOn: $includePictures) {
          VStack(alignment: .leading, spacing: 2) {
            Label("Import pictures", systemImage: "photo")
            Text("Keep embedded image attachments in imported conversations.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      } header: {
        Text("Conversation Options")
      }
    }
  }

  private func handleFilePick(_ result: Result<URL, Error>) {
    switch result {
    case .success(let url):
      Task { await prepareImportPreview(from: url) }
    case .failure(let error):
      errorMessage = error.localizedDescription
    }
  }

  @MainActor
  private func prepareImportPreview(from url: URL) async {
    do {
      let preview = try await store.previewSettingsImportFile(from: url)
      importPreview = preview
      selectedSections = preview.availableSelection
      restoreAudio = false
      includePictures = false
      errorMessage = nil
    } catch {
      importPreview = nil
      selectedSections = SettingsBackupSelection()
      errorMessage = error.localizedDescription
    }
  }

  @MainActor
  private func prepareImportPreview(from file: PendingConversationImportFile) {
    do {
      let preview = try store.previewSettingsImportFile(filename: file.filename, data: file.data)
      importPreview = preview
      selectedSections = preview.availableSelection
      restoreAudio = false
      includePictures = false
      errorMessage = nil
    } catch {
      importPreview = nil
      selectedSections = SettingsBackupSelection()
      errorMessage = error.localizedDescription
    }
  }

  private func importSelected(from preview: SettingsImportFilePreview) {
    let selection = selectedSections.intersection(preview.availableSelection)
    guard !selection.isEmpty else {
      errorMessage = SettingsBackupError.emptySelection.localizedDescription
      return
    }
    switch preview.kind {
    case .backup(let envelope):
      do {
        let summary = try store.importSettingsBackup(
          envelope,
          selection: selection,
          restoreAudio: restoreAudio,
          includePictures: includePictures)
        errorMessage = nil
        showToast(summary)
      } catch {
        errorMessage = error.localizedDescription
      }
    case .portable(let archive):
      do {
        let summary = try store.importPortableArchive(
          archive,
          selection: selection,
          includePictures: includePictures)
        errorMessage = nil
        showToast(summary)
      } catch {
        errorMessage = error.localizedDescription
      }
    case .conversation(let envelope):
      guard selection.conversations else {
        errorMessage = SettingsBackupError.emptySelection.localizedDescription
        return
      }
      if envelope.exportedConversations.count > 1, let data = preview.sourceData {
        pendingConversationCollectionImport = PendingConversationImportFile(
          filename: preview.filename,
          data: data)
        return
      }
      Task { await prepareConversationImport(from: envelope) }
    }
  }

  @MainActor
  private func prepareConversationImport(from envelope: ConversationExportEnvelope) async {
    let preview = await store.previewConversationImport(
      from: envelope, includePictures: includePictures)
    if preview.conflict == nil {
      _ = finishConversationImport(preview, resolution: .create(title: preview.envelope.title))
    } else {
      pendingConversationImport = preview
    }
  }

  private func finishConversationImport(
    _ preview: ConversationImportPreview,
    resolution: ConversationImportResolution
  ) -> String? {
    do {
      try store.importConversation(preview, resolution: resolution)
      pendingConversationImport = nil
      errorMessage = nil
      showToast("Imported conversation.")
      return nil
    } catch {
      return error.localizedDescription
    }
  }

  private func showToast(_ message: String) {
    withAnimation(.snappy) {
      toast = message
    }
    if let onFinish {
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(900))
        onFinish()
      }
    }
  }

  private func selectionBinding(
    _ section: SettingsBackupSection,
    available: SettingsBackupSelection
  ) -> Binding<Bool> {
    Binding(
      get: { selectedSections.contains(section) && available.contains(section) },
      set: { isSelected in
        selectedSections.set(section, isSelected: isSelected && available.contains(section))
      })
  }

  private func importDetail(
    for section: SettingsBackupSection,
    preview: SettingsImportFilePreview
  ) -> String {
    switch preview.kind {
    case .backup(let envelope):
      switch section {
      case .providers:
        let count = envelope.providers?.endpoints.count ?? 0
        return "\(count) provider \(itemLabel(count, singular: "endpoint"))."
      case .prompts:
        let systemCount = envelope.prompts?.prompts.count ?? 0
        let userCount = envelope.prompts?.userPrompts?.count ?? 0
        return
          "\(systemCount) system \(itemLabel(systemCount, singular: "prompt")), \(userCount) user \(itemLabel(userCount, singular: "prompt"))."
      case .tools:
        let serverCount = envelope.tools?.mcpServers.count ?? 0
        return "Tool settings and \(serverCount) MCP \(itemLabel(serverCount, singular: "server"))."
      case .conversations:
        let count = envelope.conversations?.count ?? 0
        return "\(count) \(itemLabel(count, singular: "conversation"))."
      }
    case .conversation(let envelope):
      let conversations = envelope.exportedConversations
      if conversations.count > 1 {
        return "\(conversations.count) conversations."
      }
      return
        "\(displayValue(envelope.title)) · \(envelope.conversation.messages.count) \(itemLabel(envelope.conversation.messages.count, singular: "message"))."
    case .portable(let archive):
      switch section {
      case .providers:
        let count = archive.settings?.providers?.count ?? 0
        return "\(count) provider \(itemLabel(count, singular: "endpoint"))."
      case .prompts:
        let prompts = archive.settings?.prompts
        let systemCount = prompts?.system.count ?? 0
        let userCount = prompts?.user.count ?? 0
        return
          "\(systemCount) system \(itemLabel(systemCount, singular: "prompt")), \(userCount) user \(itemLabel(userCount, singular: "prompt"))."
      case .tools:
        let count = archive.settings?.mcpServers?.count ?? 0
        return "\(count) MCP \(itemLabel(count, singular: "server")), \(archive.skills?.count ?? 0) skills."
      case .conversations:
        let count = archive.chats?.count ?? 0
        return "\(count) \(itemLabel(count, singular: "conversation"))."
      }
    }
  }

  private func previewType(_ preview: SettingsImportFilePreview) -> String {
    switch preview.kind {
    case .backup: return "PocketMai backup"
    case .conversation(let envelope):
      return envelope.exportedConversations.count == 1 ? "Single conversation" : "Conversation pack"
    case .portable: return "Mai archive"
    }
  }

  private func backupHasVoiceAudio(_ preview: SettingsImportFilePreview) -> Bool {
    if case .backup(let envelope) = preview.kind {
      return !(envelope.voiceRecordings ?? []).isEmpty
    }
    return false
  }
}

// MARK: - Export Panel

struct SettingsExportView: View {
  @EnvironmentObject private var store: AppStore

  @State private var shareFile: BackupSharedFile?
  @State private var errorMessage: String?
  @State private var selectedSections = SettingsBackupSelection(scope: .everything)
  @State private var includeAudio = false
  @State private var includePictures = false

  var body: some View {
    Form {
      Section {
        ForEach(SettingsBackupSection.allCases) { section in
          BackupSectionCheckbox(
            section: section,
            detail: exportDetail(for: section),
            isSelected: exportSelectionBinding(section))
        }
      } header: {
        Text("Contents")
      }

      if selectedSections.conversations {
        Section {
          Toggle(isOn: $includeAudio) {
            VStack(alignment: .leading, spacing: 2) {
              Label("Include voice audio", systemImage: "waveform")
              Text("Embed m4a recordings as base64.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          Toggle(isOn: $includePictures) {
            VStack(alignment: .leading, spacing: 2) {
              Label("Include pictures", systemImage: "photo")
              Text("Embed image attachments in conversation backups.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        } header: {
          Text("Options")
        }
      }

      Section {
        Button {
          exportSelected()
        } label: {
          Label("Export Selected", systemImage: "square.and.arrow.up")
        }
        .disabled(selectedSections.isEmpty)
      } header: {
        Text("Save to File")
      } footer: {
        Text(
          "Exports a PocketMai JSON backup you can save or send to another device. Provider exports include API keys; treat the file like a secret."
        )
      }

      if let errorMessage {
        Section {
          Label(errorMessage, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
        }
      }
    }
    .navigationTitle("Export")
    .navigationBarTitleDisplayMode(.inline)
    .sheet(item: $shareFile) { file in
      BackupActivityShareSheet(activityItems: [file.url])
    }
  }

  private func exportSelected() {
    errorMessage = nil
    Task {
      if let url = await store.exportSettingsBackupFile(
        selection: selectedSections,
        includeAudio: includeAudio,
        includePictures: includePictures)
      {
        shareFile = BackupSharedFile(url: url)
      } else {
        errorMessage = store.errorMessage ?? "Could not export."
      }
    }
  }

  private func exportSelectionBinding(_ section: SettingsBackupSection) -> Binding<Bool> {
    Binding(
      get: { selectedSections.contains(section) },
      set: { isSelected in
        selectedSections.set(section, isSelected: isSelected)
        if !selectedSections.conversations {
          includeAudio = false
          includePictures = false
        }
      })
  }

  private func exportDetail(for section: SettingsBackupSection) -> String {
    switch section {
    case .providers:
      let count = store.settings.openAIEndpoints.count
      return "\(count) provider \(itemLabel(count, singular: "endpoint"))."
    case .prompts:
      let systemCount = store.settings.systemPrompts.count
      let userCount = store.settings.userPrompts.count
      return
        "\(systemCount) system \(itemLabel(systemCount, singular: "prompt")), \(userCount) user \(itemLabel(userCount, singular: "prompt"))."
    case .tools:
      let serverCount = store.settings.mcpServers.count
      return "Tool settings and \(serverCount) MCP \(itemLabel(serverCount, singular: "server"))."
    case .conversations:
      let count = store.conversationSummaries.count
      return "\(count) \(itemLabel(count, singular: "conversation"))."
    }
  }
}

private func itemLabel(_ count: Int, singular: String) -> String {
  count == 1 ? singular : "\(singular)s"
}

private func formattedDate(_ date: Date) -> String {
  date.formatted(date: .abbreviated, time: .shortened)
}

private func infoRow(_ title: String, _ value: String) -> some View {
  HStack(alignment: .firstTextBaseline) {
    Text(title)
    Spacer(minLength: 12)
    Text(displayValue(value))
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.trailing)
  }
}

private func displayValue(_ value: String) -> String {
  let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
  return trimmed.isEmpty ? "Not specified" : trimmed
}

// MARK: - Destroy Panel

private enum DestroyAction: Identifiable {
  case conversations
  case memory
  case downloadedModels
  case filesWorkspace
  case providers
  case prompts
  case toolSettings
  case mcpServers
  case factoryReset

  var id: String {
    switch self {
    case .conversations: "conversations"
    case .memory: "memory"
    case .downloadedModels: "downloadedModels"
    case .filesWorkspace: "filesWorkspace"
    case .providers: "providers"
    case .prompts: "prompts"
    case .toolSettings: "toolSettings"
    case .mcpServers: "mcpServers"
    case .factoryReset: "factoryReset"
    }
  }

  var title: String {
    switch self {
    case .conversations: "Clear all conversations?"
    case .memory: "Clear memory?"
    case .downloadedModels: "Clear downloaded models?"
    case .filesWorkspace: "Clear files workspace?"
    case .providers: "Clear provider settings?"
    case .prompts: "Reset prompts?"
    case .toolSettings: "Reset tool settings?"
    case .mcpServers: "Remove all MCP servers?"
    case .factoryReset: "Factory reset PocketMai?"
    }
  }

  var confirmButtonTitle: String {
    switch self {
    case .conversations: "Clear Conversations"
    case .memory: "Clear Memory"
    case .downloadedModels: "Delete Models"
    case .filesWorkspace: "Clear Files"
    case .providers: "Clear Providers"
    case .prompts: "Reset Prompts"
    case .toolSettings: "Reset Tools"
    case .mcpServers: "Remove Servers"
    case .factoryReset: "Factory Reset"
    }
  }

  var message: String {
    switch self {
    case .conversations:
      return "Every chat and its messages will be deleted. This cannot be undone."
    case .memory:
      return "Saved memory will be removed from this device. This cannot be undone."
    case .downloadedModels:
      return
        "All locally downloaded MLX models will be deleted. They can be re-downloaded later."
    case .filesWorkspace:
      return "Every file in the workspace (FilesData) will be deleted. This cannot be undone."
    case .providers:
      return
        "All OpenAI-compatible endpoints and their stored API keys will be removed from this device."
    case .prompts:
      return
        "Custom prompts will be removed, and the stock system, user, and compact prompts restored."
    case .toolSettings:
      return
        "Tool settings, voices, todos, imported tool files, and tool-calling preferences will be reset to defaults."
    case .mcpServers:
      return "All configured MCP servers and their tool selections will be removed."
    case .factoryReset:
      return
        "All conversations, settings, providers, API keys, memory, tools, and local app data will be removed from this device. This cannot be undone."
    }
  }
}

struct SettingsDestroyView: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss

  let dismissSettings: () -> Void

  @State private var pendingAction: DestroyAction?
  @State private var toast: String?

  var body: some View {
    Form {
      Section {
        destroyRow(
          title: "Conversations",
          systemImage: "bubble.left.and.bubble.right",
          description: "Delete every chat on this device (archived chats are kept).",
          action: .conversations)
        destroyRow(
          title: "Memory",
          systemImage: "brain",
          description: "Remove the saved long-term memory.",
          action: .memory)
        destroyRow(
          title: "Downloaded Models",
          systemImage: "arrow.down.circle",
          description: "Delete locally downloaded MLX models from the cache.",
          action: .downloadedModels)
        destroyRow(
          title: "Files Workspace",
          systemImage: "folder",
          description: "Erase everything in the FilesData workspace.",
          action: .filesWorkspace)
      } header: {
        Text("Clear Data")
      }

      Section {
        destroyRow(
          title: "Provider Settings",
          systemImage: "network",
          description: "Remove all endpoints and their stored API keys.",
          action: .providers)
        destroyRow(
          title: "Prompts",
          systemImage: "text.bubble",
          description: "Restore stock prompts and remove custom prompts.",
          action: .prompts)
        destroyRow(
          title: "Tool Settings",
          systemImage: "wrench.and.screwdriver",
          description: "Reset built-in tools, voices, todos, and tool-calling preferences.",
          action: .toolSettings)
        destroyRow(
          title: "MCP Servers",
          systemImage: "server.rack",
          description: "Remove every configured MCP server.",
          action: .mcpServers)
      } header: {
        Text("Reset Settings")
      }

      Section {
        destroyRow(
          title: "Factory Reset",
          systemImage: "arrow.counterclockwise.circle",
          description: "Wipe every local file: conversations, settings, models, and workspace.",
          action: .factoryReset,
          tint: .red)
      } header: {
        Text("Nuclear Option")
      } footer: {
        Text("Each destructive action shows a confirmation prompt before it runs.")
      }
    }
    .navigationTitle("Destroy")
    .navigationBarTitleDisplayMode(.inline)
    .alert(
      pendingAction?.title ?? "Are you sure?",
      isPresented: pendingActionBinding,
      presenting: pendingAction
    ) { action in
      Button("Cancel", role: .cancel) {
        pendingAction = nil
      }
      Button(action.confirmButtonTitle, role: .destructive) {
        perform(action)
      }
    } message: { action in
      Text(action.message)
    }
    .settingsToast($toast)
  }

  private var pendingActionBinding: Binding<Bool> {
    Binding(
      get: { pendingAction != nil },
      set: { isPresented in
        if !isPresented { pendingAction = nil }
      })
  }

  @ViewBuilder
  private func destroyRow(
    title: String,
    systemImage: String,
    description: String,
    action: DestroyAction,
    tint: Color = .primary
  ) -> some View {
    Button {
      pendingAction = action
    } label: {
      VStack(alignment: .leading, spacing: 4) {
        Label(title, systemImage: systemImage)
          .foregroundStyle(tint)
        Text(description)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func perform(_ action: DestroyAction) {
    pendingAction = nil
    switch action {
    case .conversations:
      store.clearAllConversations()
      showToast("Conversations cleared.")
    case .memory:
      store.clearMemory()
      showToast("Memory cleared.")
    case .downloadedModels:
      let summary = store.clearDownloadedMLXModels()
      showToast(summary)
    case .filesWorkspace:
      let summary = store.clearFilesWorkspace()
      showToast(summary)
    case .providers:
      store.clearProviderSettings()
      showToast("Providers cleared.")
    case .prompts:
      store.clearSystemPrompts()
      showToast("Prompts reset.")
    case .toolSettings:
      store.clearToolSettings()
      showToast("Tool settings reset.")
    case .mcpServers:
      store.clearMCPServers()
      showToast("MCP servers cleared.")
    case .factoryReset:
      store.factoryReset()
      dismissSettings()
    }
  }

  private func showToast(_ message: String) {
    withAnimation(.snappy) {
      toast = message
    }
  }
}
