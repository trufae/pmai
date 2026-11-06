import SwiftUI

struct PromptDetailView: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  @FocusState private var isNameFocused: Bool

  private let original: PromptDraft
  @State private var draft: PromptDraft
  @State private var showingLeaveConfirmation = false
  @State private var notice: ToastNotice?

  init(_ draft: PromptDraft) {
    original = draft
    _draft = State(initialValue: draft)
  }

  var body: some View {
    Form {
      Section {
        TextField("Name", text: $draft.name)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .focused($isNameFocused)
      } footer: {
        Text("Used as $name in the chat composer. Names cannot contain spaces or /.")
      }
      Section {
        TextEditor(text: $draft.text)
          .frame(minHeight: 220)
          .font(.callout)
      } header: {
        Text(draft.kind == .system ? "Instructions" : "Prompt")
      } footer: {
        Text(
          draft.kind == .system
            ? "Sent to the model at the start of each chat."
            : "Prepended to the user message before sending to the model.")
      }
    }
    .navigationTitle(navigationTitle)
    .navigationBarTitleDisplayMode(.inline)
    .navigationBarBackButtonHidden(true)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button {
          if draft == original { dismiss() } else { showingLeaveConfirmation = true }
        } label: {
          Label(draft.id == nil ? "Cancel" : "Back", systemImage: "chevron.left")
        }
      }
      ToolbarItemGroup(placement: .confirmationAction) {
        if draft.kind == .system {
          Button {
            draft.isDefault = true
          } label: {
            Image(systemName: draft.isDefault ? "star.fill" : "star")
          }
          .accessibilityLabel(draft.isDefault ? "Default Prompt" : "Make Default Prompt")
          .foregroundStyle(draft.isDefault ? Color.accentColor : .primary)
        }
        Button("Save", action: saveAndDismiss)
      }
    }
    .alert("Save changes?", isPresented: $showingLeaveConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Discard Changes", role: .destructive) { dismiss() }
      Button("Save", action: saveAndDismiss)
    } message: {
      Text("Save or discard changes before leaving this prompt.")
    }
    .toast($notice)
    .onAppear { isNameFocused = draft.id == nil }
  }

  private var navigationTitle: String {
    let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    if !name.isEmpty { return name }
    let kind = draft.kind == .system ? "Prompt" : "User Prompt"
    return draft.id == nil ? "New \(kind)" : kind
  }

  private func saveAndDismiss() {
    if let message = draft.save(to: &store.settings, original: original) {
      notice = ToastNotice(message)
      return
    }
    store.saveSettings()
    dismiss()
  }
}
