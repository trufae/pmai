import Foundation
import MLXLMCommon
import SwiftUI

@MainActor
final class LocalLLMViewModel: ObservableObject {
  static let defaultModelId = AppSettings.localMLXDefaultModelID

  @Published var selectedModelId = LocalLLMViewModel.defaultModelId
  @Published var customModelId = ""
  @Published var status = "Choose an MLX-ready Hugging Face repo."
  @Published var isLoading = false
  @Published var isReady = false
  @Published var downloadProgress: Double?
  @Published var downloadProgressText: String?
  @Published var cachedModels: [CachedMLXModel] = []

  let presets = LocalMLXModels.presets

  private var loadedModelId: String?
  private var loadTask: Task<Void, Never>?
  private var activeLoadID: UUID?

  init() {
    refreshCachedModels()
  }

  var activeModelId: String {
    let custom = customModelId.trimmingCharacters(in: .whitespacesAndNewlines)
    return custom.isEmpty ? selectedModelId : custom
  }

  var isUsingCustomModelId: Bool {
    !customModelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var isActiveModelReady: Bool {
    isReady && loadedModelId == activeModelId
  }

  var loadButtonTitle: String {
    if isLoading {
      return "Cancel Download"
    }
    if isActiveModelReady { return "Reload Model" }
    return LocalMLXModelCache.containsRepository(activeModelId) ? "Load Model" : "Download & Load Model"
  }

  var loadButtonSystemImage: String {
    if isLoading {
      return "xmark.circle"
    }
    return isActiveModelReady ? "arrow.clockwise" : "arrow.down.circle"
  }

  func toggleModelLoad() {
    if isLoading {
      cancelModelLoad()
      return
    }
    let modelId = activeModelId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard LocalMLXRepoIDValidator.isValid(modelId) else {
      showFailure(LocalMLXError.invalidModelID(modelId), action: "Model load", modelId: modelId)
      return
    }
    isLoading = true
    isReady = false
    downloadProgress = nil
    downloadProgressText = nil
    status = LocalMLXModelCache.containsRepository(modelId)
      ? "Loading model into memory..."
      : "Preparing Hugging Face download for \(modelId)..."
    let loadID = UUID()
    activeLoadID = loadID
    loadTask = Task { [weak self] in
      await self?.loadModel(modelId: modelId, loadID: loadID)
    }
  }

  func cancelModelLoad() {
    guard isLoading else { return }
    let task = loadTask
    activeLoadID = nil
    loadTask = nil
    isLoading = false
    downloadProgress = nil
    downloadProgressText = nil
    status = "Model download cancelled."
    task?.cancel()
  }

  private func canUpdateLoadState(loadID: UUID) -> Bool {
    activeLoadID == loadID || activeLoadID == nil
  }

  private func isCurrentLoad(loadID: UUID) -> Bool {
    activeLoadID == loadID
  }

  private func loadModel(modelId: String, loadID: UUID) async {
    guard isCurrentLoad(loadID: loadID), !Task.isCancelled else { return }
    let previousLoadedModelId = loadedModelId
    let wasCachedBeforeLoad = LocalMLXModelCache.containsRepository(modelId)
    isLoading = true
    isReady = false
    downloadProgress = nil
    downloadProgressText = nil
    status = wasCachedBeforeLoad
      ? "Loading model into memory..."
      : "Preparing Hugging Face download for \(modelId)..."
    defer {
      if isCurrentLoad(loadID: loadID) {
        isLoading = false
        downloadProgress = nil
        downloadProgressText = nil
        loadTask = nil
        activeLoadID = nil
      }
      refreshCachedModels()
    }

    do {
      try Task.checkCancellation()
      let progressHandler: @Sendable (Progress) -> Void = { [weak self] progress in
        let total = progress.totalUnitCount
        let completed = max(progress.completedUnitCount, 0)
        let fraction =
          total > 0
          ? min(max(Double(completed) / Double(total), 0), 1)
          : nil
        let progressText = Self.downloadProgressText(
          completedBytes: completed,
          totalBytes: total > 0 ? total : nil,
          bytesPerSecond: progress.userInfo[.throughputKey] as? Double)
        Task { @MainActor in
          guard let self, self.isCurrentLoad(loadID: loadID), self.isLoading,
            self.loadTask?.isCancelled != true
          else {
            return
          }
          self.downloadProgress = fraction
          self.downloadProgressText = progressText
          if let fraction {
            self.status =
              fraction >= 1
              ? "Loading model into memory..."
              : "Downloading model files... \(Int(fraction * 100))%"
          } else if progressText != nil {
            self.status = "Downloading model files..."
          } else {
            self.status = "Checking model files..."
          }
        }
      }

      try await LocalMLXProvider.shared.load(
        modelID: modelId,
        allowDownload: true,
        progressHandler: progressHandler)
      try Task.checkCancellation()
      guard isCurrentLoad(loadID: loadID) else {
        restorePreviousModel(loadedModelId: previousLoadedModelId)
        return
      }
      loadedModelId = modelId
      isReady = true
      status = "Model ready: \(modelId)"
    } catch is CancellationError {
      restorePreviousModel(loadedModelId: previousLoadedModelId)
      let cleanupError =
        activeLoadID == nil
        ? removePartialDownloadIfNeeded(for: modelId, wasCachedBeforeLoad: wasCachedBeforeLoad)
        : nil
      if canUpdateLoadState(loadID: loadID) {
        status = "Model download cancelled.\(cleanupError.map { " \($0)" } ?? "")"
      }
    } catch {
      if Self.isCancellation(error) {
        restorePreviousModel(loadedModelId: previousLoadedModelId)
        let cleanupError =
          activeLoadID == nil
          ? removePartialDownloadIfNeeded(for: modelId, wasCachedBeforeLoad: wasCachedBeforeLoad)
          : nil
        if canUpdateLoadState(loadID: loadID) {
          status = "Model download cancelled.\(cleanupError.map { " \($0)" } ?? "")"
        }
        return
      }
      restorePreviousModel(loadedModelId: previousLoadedModelId)
      let cleanupError =
        activeLoadID == nil || activeLoadID == loadID
        ? removePartialDownloadIfNeeded(for: modelId, wasCachedBeforeLoad: wasCachedBeforeLoad)
        : nil
      if canUpdateLoadState(loadID: loadID) {
        showFailure(error, action: "Model load", modelId: modelId)
        if let cleanupError {
          status += " \(cleanupError)"
        }
      }
    }
  }

  func refreshCachedModels() {
    cachedModels = LocalMLXModelCache.listModels()
  }

  func deleteCachedModel(_ model: CachedMLXModel) async {
    do {
      await LocalMLXProvider.shared.unload(modelID: model.repoID)
      try LocalMLXModelCache.delete(model)
      if loadedModelId == model.repoID {
        loadedModelId = nil
        isReady = false
      }
      refreshCachedModels()
      status = "Deleted cached model: \(model.repoID)"
    } catch {
      status = "Could not delete \(model.repoID): \(error.localizedDescription)"
    }
  }

  private func showFailure(_ error: Error, action: String, modelId: String) {
    let message = Self.message(for: error, action: action, modelId: modelId)
    isReady = loadedModelId == activeModelId
    status = message
  }

  private static func message(for error: Error, action: String, modelId: String) -> String {
    if let localError = error as? LocalMLXError {
      return localError.localizedDescription
    }

    if let factoryError = error as? ModelFactoryError {
      switch factoryError {
      case .unsupportedModelType:
        return
          "Unsupported model format for \(modelId). Use a Hugging Face repo that is already converted to MLX and supported by mlx-swift-lm."
      case .noModelFactoryAvailable:
        return "MLX LLM support is not available in this build. Check that MLXLLM is linked."
      case .configurationFileError, .configurationDecodingError, .invalidConfiguration,
        .unsupportedProcessorType:
        return
          "Unsupported MLX model configuration for \(modelId): \(factoryError.localizedDescription)"
      }
    }

    let nsError = error as NSError
    let detail = error.localizedDescription
    let lowercasedDetail = detail.lowercased()

    if nsError.domain == NSURLErrorDomain || error is URLError
      || lowercasedDetail.contains("network")
      || lowercasedDetail.contains("timed out")
      || lowercasedDetail.contains("could not connect")
    {
      return "Download failed for \(modelId): \(detail)"
    }

    if lowercasedDetail.contains("out of memory")
      || lowercasedDetail.contains("memory allocation")
      || lowercasedDetail.contains("failed to allocate")
      || lowercasedDetail.contains("resource exhausted")
    {
      return "Out of memory while using \(modelId). Try a smaller 4-bit MLX model."
    }

    if lowercasedDetail.contains("not found")
      || lowercasedDetail.contains("404")
      || lowercasedDetail.contains("repository")
    {
      return
        "Invalid model id or unavailable Hugging Face repo: \(modelId). Use an MLX-ready repo id such as org/model-name."
    }

    if lowercasedDetail.contains("safetensor")
      || lowercasedDetail.contains("config.json")
      || lowercasedDetail.contains("unsupported")
    {
      return "Unsupported model format for \(modelId): \(detail)"
    }

    return "\(action) failed for \(modelId): \(detail)"
  }

  private static func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError {
      return true
    }
    let nsError = error as NSError
    return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
  }

  private nonisolated static func downloadProgressText(
    completedBytes: Int64,
    totalBytes: Int64?,
    bytesPerSecond: Double?
  ) -> String? {
    guard completedBytes > 0 || totalBytes != nil else { return nil }
    let completed = byteCountText(completedBytes)
    let base: String
    if let totalBytes, totalBytes > 0 {
      let total = byteCountText(totalBytes)
      base = "\(completed) of \(total)"
    } else {
      base = "\(completed) downloaded"
    }

    guard let bytesPerSecond, bytesPerSecond > 0 else { return base }
    let speed = byteCountText(Int64(bytesPerSecond))
    return "\(base) - \(speed)/s"
  }

  private nonisolated static func byteCountText(_ bytes: Int64) -> String {
    if bytes == 0 { return "0 KB" }
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }

  private func restorePreviousModel(loadedModelId: String?) {
    self.loadedModelId = loadedModelId
    isReady = loadedModelId == activeModelId
  }

  private func removePartialDownloadIfNeeded(
    for modelId: String,
    wasCachedBeforeLoad: Bool
  ) -> String? {
    guard !wasCachedBeforeLoad else { return nil }
    do {
      try LocalMLXModelCache.deleteRepository(modelId)
      return nil
    } catch {
      return "Could not remove partial files: \(error.localizedDescription)"
    }
  }
}

struct LocalLLMView: View {
  @EnvironmentObject private var store: AppStore
  @StateObject private var vm = LocalLLMViewModel()
  @State private var pendingModelDeletion: CachedMLXModel?

  var body: some View {
    Form {
      Section {
        Picker("Preset", selection: $vm.selectedModelId) {
          ForEach(vm.presets, id: \.self) { id in
            Text(id).tag(id)
          }
        }
        .pickerStyle(.menu)
        .onChange(of: vm.selectedModelId) {
          vm.customModelId = ""
        }
        .disabled(vm.isUsingCustomModelId)

        TextField("Custom Hugging Face MLX repo id", text: $vm.customModelId)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .font(.callout.monospaced())

        if vm.isLoading {
          VStack(alignment: .leading, spacing: 4) {
            if let progress = vm.downloadProgress {
              ProgressView(value: progress)
            } else {
              ProgressView()
            }
            if let progressText = vm.downloadProgressText {
              Text(progressText)
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
        }

        Button {
          vm.toggleModelLoad()
        } label: {
          Label(vm.loadButtonTitle, systemImage: vm.loadButtonSystemImage)
        }

        Text(vm.status)
          .font(.caption)
          .foregroundStyle(vm.isActiveModelReady ? Color.secondary : Color.primary)
      } header: {
        Text("MLX LLM Model")
      }

      Section {
        if vm.cachedModels.isEmpty {
          Text("No downloaded models")
            .foregroundStyle(.secondary)
        } else {
          ForEach(vm.cachedModels) { model in
            cachedModelRow(model)
          }
        }

        Button {
          vm.refreshCachedModels()
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(vm.isLoading)
      } header: {
        Text("Downloaded MLX LLM Models")
      }
    }
    .navigationTitle("Local MLX LLM")
    .onAppear {
      store.refreshLocalMLXModels()
    }
    .onChange(of: vm.cachedModels) { _, _ in
      store.refreshLocalMLXModels()
    }
    .alert(
      "Delete Downloaded Model?",
      isPresented: Binding(
        get: { pendingModelDeletion != nil },
        set: { if !$0 { pendingModelDeletion = nil } }
      ),
      presenting: pendingModelDeletion
    ) { model in
      Button("Delete", role: .destructive) {
        Task { await vm.deleteCachedModel(model) }
      }
      Button("Cancel", role: .cancel) {}
    } message: { model in
      Text(
        "\(model.repoID) will be removed from the local Hugging Face cache and must be downloaded again before use."
      )
    }
  }

  private func cachedModelRow(_ model: CachedMLXModel) -> some View {
    let isCurrentModel = vm.isActiveModelReady && model.repoID == vm.activeModelId

    return HStack(spacing: 12) {
      Image(systemName: isCurrentModel ? "checkmark.circle.fill" : "shippingbox")
        .foregroundStyle(isCurrentModel ? Color.green : Color.secondary)
        .frame(width: 20)

      VStack(alignment: .leading, spacing: 3) {
        Text(model.repoID)
          .font(.body)
          .lineLimit(2)
        Text(model.detailText)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .swipeActions(edge: .trailing) {
      Button(role: .destructive) {
        pendingModelDeletion = model
      } label: {
        Label("Delete", systemImage: "trash")
      }
      .disabled(vm.isLoading)
    }
  }

}
