import SwiftUI

struct AgentSoulEditor: View {
  let document = AgentSoul()
  @Environment(\.dismiss) private var dismiss
  @State private var draft = ""
  @State private var loaded = false
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Core personality instructions, applied on the next model request.")
        .font(.caption)
        .foregroundStyle(.secondary)
      TextEditor(text: $draft)
        .font(.system(.body, design: .monospaced))
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .accessibilityLabel("SOUL.md contents")
        .disabled(!loaded)
      if let error {
        Text(error).font(.caption).foregroundStyle(.red)
      }
    }
    .padding()
    .navigationTitle("SOUL.md")
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") {
          do {
            try document.save(draft)
            dismiss()
          } catch {
            self.error = error.localizedDescription
          }
        }
        .disabled(!loaded)
      }
    }
    .task {
      guard !loaded else { return }
      do {
        draft = try document.load()
        loaded = true
      } catch {
        self.error = error.localizedDescription
      }
    }
  }
}
