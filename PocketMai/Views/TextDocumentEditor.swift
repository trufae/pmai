import SwiftUI

struct TextDocumentEditor: View {
  let title: String
  let instructions: String
  var saveTitle = "Save"
  var defaultText: String? = nil
  let load: () throws -> String
  let save: (String) throws -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var draft = TextDocumentDraft()
  @State private var error: String?
  @State private var confirmingLeave = false

  var body: some View {
    Form {
      if let error {
        Section {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
          if !draft.isLoaded { Button("Retry", action: loadDocument) }
        }
      }
      Section {
        TextEditor(text: $draft.text)
          .font(.body.monospaced())
          .autocorrectionDisabled()
          .textInputAutocapitalization(.never)
          .accessibilityLabel(title)
          .frame(minHeight: 320)
          .disabled(!draft.isLoaded)
      } footer: {
        Text(instructions)
      }
      if let defaultText {
        Button("Reset to Default", systemImage: "arrow.counterclockwise") {
          draft.text = defaultText
        }
        .disabled(!draft.isLoaded)
      }
    }
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .navigationBarBackButtonHidden(true)
    .interactiveDismissDisabled(draft.hasChanges)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") {
          if draft.hasChanges { confirmingLeave = true } else { dismiss() }
        }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button(saveTitle, action: saveAndDismiss).disabled(!draft.isLoaded)
      }
    }
    .alert("Save changes?", isPresented: $confirmingLeave) {
      Button("Keep Editing", role: .cancel) {}
      Button("Discard Changes", role: .destructive) { dismiss() }
      Button(saveTitle, action: saveAndDismiss)
    } message: {
      Text("Save or discard your changes before leaving.")
    }
    .task { loadDocument() }
  }

  private func loadDocument() {
    guard !draft.isLoaded else { return }
    do {
      try draft.load(using: load)
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func saveAndDismiss() {
    do {
      if try draft.save(using: save) { dismiss() }
    } catch {
      self.error = error.localizedDescription
    }
  }
}
