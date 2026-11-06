import MaiCore
import SwiftUI

/// Shared selection UI; callers decide whether changes are drafts or saved immediately.
struct ProviderModelFields: View {
  @EnvironmentObject private var store: AppStore
  @Binding var selection: ProviderModelSelection
  var inheritedSelection: ProviderModelSelection? = nil
  var onSelectModel: (ModelDescriptor) -> Void = { _ in }

  private var catalog: ProviderModelCatalog { store.providerModelCatalog }

  var body: some View {
    Menu {
      if inheritedSelection != nil { providerButton(nil, icon: "gearshape") }
      providerButton(.apple, icon: "apple.logo")
      providerButton(.mlx, icon: "cpu")
      ForEach(catalog.endpoints.filter(\.isEnabled)) { endpoint in
        providerButton(.openAICompatible, endpointID: endpoint.id, icon: "network")
      }
    } label: {
      HStack {
        Text("Provider").foregroundStyle(.primary)
        Spacer()
        Text(catalog.title(for: selection))
          .foregroundStyle(
            catalog.unavailableReason(for: selection) == nil ? Color.accentColor : .secondary)
      }
    }
    .task { store.refreshLocalMLXModelsInBackground() }

    if selection.provider == nil, let inheritedSelection {
      LabeledContent(
        "Model",
        value: inheritedSelection.modelID.isEmpty
          ? catalog.title(for: inheritedSelection) : inheritedSelection.modelID)
    } else if catalog.unavailableReason(for: selection) == nil {
      if selection.provider == .mlx, !catalog.localModelIDs.isEmpty {
        FilteredModelPicker(
          selection: modelBinding, models: catalog.localModelIDs.map { .init(id: $0) },
          allowsCustomModelID: false,
          refresh: { store.refreshLocalMLXModelsInBackground() })
        Text(
          "Only downloaded models are shown. Manage downloads in Settings > Providers > Local MLX LLM."
        )
        .font(.caption).foregroundStyle(.secondary)
      } else if selection.provider == .openAICompatible,
        let endpoint = catalog.endpoint(for: selection)
      {
        FilteredModelPicker(
          selection: $selection.modelID, endpoint: endpoint,
          emptySelectionTitle: endpoint.defaultModel.isEmpty
            ? "Provider default" : "Provider default (\(endpoint.defaultModel))",
          initialFeatures: endpoint.kind == .systemOne ? [.decision] : [], onSelect: onSelectModel)
        if endpoint.kind == .chatGPT {
          Label("Using ChatGPT plan", systemImage: "checkmark.circle")
          Link("Manage usage", destination: URL(string: "https://chatgpt.com/settings/usage")!)
        }
      }
    }
    if let message = catalog.validationMessage(for: selection) {
      Text(message).font(.caption).foregroundStyle(.secondary)
    }
  }

  private func providerButton(_ provider: ProviderKind?, endpointID: UUID? = nil, icon: String)
    -> some View
  {
    let choice = ProviderModelSelection(provider: provider, endpointID: endpointID)
    let selected = selection.provider == provider && selection.endpointID == endpointID
    return Button {
      if let next = catalog.selecting(provider, endpointID: endpointID, from: selection) {
        selection = next
      }
    } label: {
      Label(catalog.title(for: choice), systemImage: selected ? "checkmark" : icon)
    }
    .disabled(catalog.unavailableReason(for: choice) != nil)
  }

  private var modelBinding: Binding<String> {
    Binding(get: { selection.modelID }, set: { model in
      guard catalog.localModelIDs.contains(model) else { return }
      selection.modelID = model
    })
  }
}
