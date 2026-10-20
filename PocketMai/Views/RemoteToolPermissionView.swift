import MaiCore
import SwiftUI

/// A focused, native permission surface for tool calls from a remote pmai host.
struct RemoteToolPermissionView: View {
  let permission: RemoteAgentPermission
  let onAnswer: (String?, JSONValue?) -> Void

  @State private var editedRawInput: JSONValue?
  @State private var showingEditor = false
  @State private var showingYoloConfirmation = false

  private var rawInput: JSONValue? { editedRawInput ?? permission.rawInput }
  private var allowOnce: RemoteAgentPermission.Option? {
    permission.options.first { $0.kind == "allow_once" }
      ?? permission.options.first { $0.kind.hasPrefix("allow") }
  }
  private var rejectOnce: RemoteAgentPermission.Option? {
    permission.options.first { $0.kind == "reject_once" }
      ?? permission.options.first { $0.kind.hasPrefix("reject") }
  }
  private var yolo: RemoteAgentPermission.Option? {
    guard permission.supportsYolo else { return nil }
    return permission.options.first { $0.kind == "allow_always" }
  }
  private var otherOptions: [RemoteAgentPermission.Option] {
    permission.options.filter { option in
      option.id != allowOnce?.id && option.id != rejectOnce?.id && option.id != yolo?.id
    }
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 20) {
          header
          argumentsCard
          actions
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 28)
      }
      .background(Color(uiColor: .systemGroupedBackground))
      .navigationTitle("Tool Permission")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { onAnswer(nil, nil) }
        }
      }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
    .presentationCornerRadius(28)
    .confirmationDialog(
      "Enable YOLO mode?", isPresented: $showingYoloConfirmation, titleVisibility: .visible
    ) {
      Button("Enable YOLO & Allow", role: .destructive) { answer(yolo) }
      Button("Keep asking", role: .cancel) {}
    } message: {
      Text("The rest of this remote chat session can run tool actions without asking again. It turns off when this session ends.")
    }
    .sheet(isPresented: $showingEditor) {
      RemotePermissionJSONEditor(value: rawInput) { editedRawInput = $0 }
    }
  }

  private var header: some View {
    VStack(spacing: 12) {
      Image(systemName: permission.kind == "read" ? "eye" : "wrench.and.screwdriver")
        .font(.system(size: 30, weight: .semibold))
        .foregroundStyle(permission.kind == "read" ? .blue : .orange)
        .frame(width: 64, height: 64)
        .background(.regularMaterial, in: Circle())
      Text(permission.title)
        .font(.title2.weight(.bold))
        .multilineTextAlignment(.center)
      Label(
        permission.kind == "read" ? "Read-only action" : "This action can make changes",
        systemImage: permission.kind == "read" ? "checkmark.shield" : "exclamationmark.triangle")
        .font(.subheadline.weight(.medium))
        .foregroundStyle(permission.kind == "read" ? Color.secondary : Color.orange)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 8)
  }

  private var argumentsCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("Arguments", systemImage: "curlybraces")
          .font(.headline)
        Spacer()
        if editedRawInput != nil {
          Label("Edited", systemImage: "checkmark.circle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.green)
        }
      }

      if let rawInput {
        Text(RemotePermissionJSONEditor.formatted(rawInput))
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.primary)
          .textSelection(.enabled)
          .lineLimit(8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(12)
          .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
      } else if !permission.details.isEmpty {
        Text(permission.details)
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.secondary)
          .lineLimit(8)
          .textSelection(.enabled)
      }

      if permission.supportsEditing, permission.rawInput != nil {
        Button {
          showingEditor = true
        } label: {
          Label(editedRawInput == nil ? "Edit JSON" : "Edit JSON again", systemImage: "slider.horizontal.3")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
      }
    }
    .padding(16)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
  }

  private var actions: some View {
    VStack(spacing: 10) {
      if let allowOnce {
        Button { answer(allowOnce) } label: {
          Label("Allow once", systemImage: "checkmark")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
      }

      if yolo != nil {
        Button { showingYoloConfirmation = true } label: {
          Label("Enable YOLO mode", systemImage: "bolt.fill")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.orange)
        .controlSize(.large)
        Text("Automatically allows future tool actions in this chat session.")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }

      if let rejectOnce {
        Button(role: .destructive) { answer(rejectOnce) } label: {
          Label("Reject", systemImage: "xmark")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
      }

      ForEach(otherOptions) { option in
        Button(option.name) { answer(option) }
          .buttonStyle(.bordered)
          .frame(maxWidth: .infinity)
      }
    }
  }

  private func answer(_ option: RemoteAgentPermission.Option?) {
    onAnswer(option?.id, option?.kind.hasPrefix("allow") == true ? rawInput : nil)
  }
}

private struct RemotePermissionJSONEditor: View {
  let original: JSONValue?
  let onSave: (JSONValue) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var draft: String
  @State private var error: String?

  init(value: JSONValue?, onSave: @escaping (JSONValue) -> Void) {
    self.original = value
    self.onSave = onSave
    _draft = State(initialValue: value.map(Self.formatted) ?? "")
  }

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 12) {
        Text("These arguments are checked against the tool schema before they run.")
          .font(.footnote)
          .foregroundStyle(.secondary)
        TextEditor(text: $draft)
          .font(.system(.body, design: .monospaced))
          .autocorrectionDisabled()
          .textInputAutocapitalization(.never)
          .padding(8)
          .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        if let error {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.red)
        }
      }
      .padding()
      .navigationTitle("Edit JSON")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Use Changes") { save() }
            .fontWeight(.semibold)
        }
      }
    }
    .presentationDetents([.medium, .large])
  }

  static func formatted(_ value: JSONValue) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return (try? String(decoding: encoder.encode(value), as: UTF8.self)) ?? "{}"
  }

  private func save() {
    guard let data = draft.data(using: .utf8) else {
      error = "The JSON could not be read."
      return
    }
    do {
      let value = try JSONDecoder().decode(JSONValue.self, from: data)
      onSave(value)
      dismiss()
    } catch {
      self.error = "Enter valid JSON before using these changes."
    }
  }
}
