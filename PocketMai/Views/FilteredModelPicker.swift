import MaiCore
import SwiftUI

/// One settings row; all discovery, search, and refresh controls live in the browser.
struct FilteredModelPicker: View {
  @EnvironmentObject private var store: AppStore
  @Binding var selection: String
  var models: [ModelDescriptor] = []
  var endpoint: OpenAIEndpoint? = nil
  var title: String = "Model"
  var emptySelectionTitle: String? = nil
  var initialFeatures: Set<ModelFeature> = []
  var requiredCapabilities: ProviderCapabilities = []
  var refresh: (() async -> Void)? = nil
  var onSelect: (ModelDescriptor) -> Void = { _ in }
  @State private var showingBrowser = false

  private var catalog: [ModelDescriptor] {
    guard let endpoint else { return models }
    return store.endpointModelDescriptors[endpoint.id]
      ?? (store.endpointModels[endpoint.id] ?? []).map { ModelDescriptor(id: $0) }
  }

  var body: some View {
    Button { showingBrowser = true } label: {
      HStack(spacing: 12) {
        Text(title).foregroundStyle(.primary)
        Spacer(minLength: 8)
        Text(selection.isEmpty ? (emptySelectionTitle ?? "Select a model") : selection)
          .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
      }
      .frame(minHeight: 44)
      .contentShape(Rectangle())
    }
    .accessibilityLabel("\(title), \(selection.isEmpty ? "Select a model" : selection)")
    .accessibilityHint("Opens the model browser")
    .fullScreenCover(isPresented: $showingBrowser) {
      ModelBrowser(
        selection: $selection, models: catalog, title: title,
        emptySelectionTitle: emptySelectionTitle,
        initialFilter: .init(features: initialFeatures, requiredCapabilities: requiredCapabilities),
        status: endpoint.flatMap { store.endpointStatuses[$0.id] },
        refresh: refresh ?? endpoint.map { endpoint in
          { await store.refreshEndpoint(endpoint, force: true) }
        }, onSelect: onSelect)
      .task {
        if let endpoint { await store.refreshEndpoint(endpoint) }
      }
    }
  }
}

struct ModelBrowser: View {
  @Environment(\.dismiss) private var dismiss
  @Binding var selection: String
  let models: [ModelDescriptor]
  let title: String
  var emptySelectionTitle: String? = nil
  var initialFilter = ModelCatalogFilter()
  var status: EndpointConnectionState? = nil
  var refresh: (() async -> Void)? = nil
  var onSelect: (ModelDescriptor) -> Void = { _ in }
  @State private var filter = ModelCatalogFilter()
  @State private var refreshing = false
  @State private var manualModel = ""
  @FocusState private var searchFocused: Bool

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        featureFilters
        List {
          if isLoading && models.isEmpty { ProgressView("Loading models…") }
          if let emptySelectionTitle, filter.search.isEmpty {
            Button(emptySelectionTitle) { selection = ""; dismiss() }
          }
          ForEach(filter.applying(to: models)) { model in
            Button { choose(model) } label: { modelRow(model) }
              .buttonStyle(.plain)
              .accessibilityAddTraits(model.id == selection ? .isSelected : [])
          }
          if filter.applying(to: models).isEmpty {
            ContentUnavailableView {
              Label(models.isEmpty ? "No models loaded" : "No matching models", systemImage: "cpu")
            } description: {
              Text(models.isEmpty ? "Refresh to load the provider’s models, or enter a model ID below."
                : "Try another search or fewer filters. Models with unknown features are excluded by feature filters.")
            } actions: {
              if !models.isEmpty {
                Button("Clear Filters") { filter = .init() }
              }
            }
            .listRowBackground(Color.clear)
          }
          if case .failed(let message) = status {
            Text(message).font(.callout).foregroundStyle(.red)
          }
          Section {
            DisclosureGroup("Use a model ID") {
              TextField("Model ID", text: $manualModel)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
              Button("Use Model") {
                choose(models.first { $0.id == manualModel.trimmingCharacters(in: .whitespacesAndNewlines) }
                  ?? .init(id: manualModel.trimmingCharacters(in: .whitespacesAndNewlines)))
              }
              .disabled(manualModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
          } footer: {
            Text("Features and context limits are reported by the provider. Missing information is unknown.")
          }
        }
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
      }
      .navigationTitle(title == "Model" ? "Select Model" : title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
        ToolbarItem(placement: .primaryAction) {
          if refresh != nil {
            Button {
              Task { await reload() }
            } label: {
              if isLoading { ProgressView() }
              else { Label("Refresh Models", systemImage: "arrow.clockwise") }
            }
            .disabled(isLoading)
          }
        }
      }
      .safeAreaInset(edge: .bottom) {
        FloatingSearchField(text: $filter.search, isFocused: $searchFocused, placeholder: "Search models") {
          filter.search = ""
          searchFocused = false
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
      }
      .onAppear { filter = initialFilter; manualModel = selection }
    }
  }

  private var isLoading: Bool {
    if case .checking? = status { return true }
    return refreshing
  }

  private var featureFilters: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(ModelFeature.allCases, id: \.self) { feature in
          Button {
            if filter.features.contains(feature) {
              filter.features.remove(feature)
              if feature == .voice { filter.requiredCapabilities.remove(.audioOutput) }
            } else {
              filter.features.insert(feature)
              if feature == .voice { filter.requiredCapabilities.formUnion(initialFilter.requiredCapabilities) }
            }
          } label: {
            Text(feature.title).font(.subheadline.weight(.medium))
              .padding(.horizontal, 14).frame(minHeight: 44)
              .foregroundStyle(filter.features.contains(feature) ? Color.white : feature.color)
              .background(filter.features.contains(feature) ? feature.color : feature.color.opacity(0.12), in: Capsule())
          }
          .accessibilityAddTraits(filter.features.contains(feature) ? .isSelected : [])
        }
        Menu {
          Button("Any context size") { filter.minimumContextWindow = nil }
          ForEach([32768, 131072, 1048576], id: \.self) { size in
            Button("At least \(size / 1024)K") { filter.minimumContextWindow = size }
          }
        } label: {
          Text(filter.minimumContextWindow.map { "\($0 / 1024)K+ context" } ?? "Context size")
            .font(.subheadline.weight(.medium)).padding(.horizontal, 14).frame(minHeight: 44)
            .background(.quaternary, in: Capsule())
        }
        if filter != ModelCatalogFilter() {
          Button("Reset") { filter = .init() }.frame(minHeight: 44)
        }
      }
      .padding(.horizontal, 18).padding(.vertical, 8)
    }
  }

  private func modelRow(_ model: ModelDescriptor) -> some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 8) {
        Text(model.displayName).font(.body.weight(.medium)).foregroundStyle(.primary)
          .fixedSize(horizontal: false, vertical: true)
        if model.displayName != model.id {
          Text(model.id).font(.caption).foregroundStyle(.secondary)
        }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 82), alignment: .leading)], alignment: .leading, spacing: 5) {
          ForEach(model.features, id: \.self) { feature in
            pill(feature.title, color: feature.color)
          }
          if let context = model.contextLabel { pill(context, color: .secondary) }
        }
        if model.featureLabels.isEmpty {
          Text("Features unknown").font(.caption).foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 0)
      if model.id == selection {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
      }
    }
    .padding(.vertical, 6)
    .contentShape(Rectangle())
  }

  private func pill(_ title: String, color: Color) -> some View {
    Text(title).font(.caption2.weight(.medium)).foregroundStyle(color)
      .padding(.horizontal, 8).padding(.vertical, 4)
      .background(color.opacity(0.12), in: Capsule())
      .fixedSize(horizontal: false, vertical: true)
  }

  private func choose(_ model: ModelDescriptor) {
    selection = model.id
    onSelect(model)
    dismiss()
  }

  private func reload() async {
    guard !refreshing, let refresh else { return }
    refreshing = true
    await refresh()
    refreshing = false
  }
}

private extension ModelFeature {
  var color: Color {
    switch self {
    case .tools: .blue
    case .vision: .purple
    case .reasoning: .orange
    case .decision: .indigo
    case .voice: .teal
    }
  }
}
