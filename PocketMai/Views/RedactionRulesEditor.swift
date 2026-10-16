import MaiCore
import SwiftUI

struct RedactionRulesEditor: View {
  @Binding var rules: String
  @Environment(\.dismiss) private var dismiss
  @State private var draft: String
  @State private var error: String?

  init(rules: Binding<String>) {
    _rules = rules
    _draft = State(initialValue: rules.wrappedValue)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("One keyword per line, case-insensitive. Use /pattern/ for regex; # starts a comment.")
        .font(.caption)
        .foregroundStyle(.secondary)
      TextEditor(text: $draft)
        .font(.system(.body, design: .monospaced))
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .accessibilityLabel("Redaction entries")
      if let error {
        Text(error).font(.caption).foregroundStyle(.red)
      }
    }
    .padding()
    .navigationTitle("Redacted")
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") {
          do {
            _ = try ContentRedactor.parse(draft)
            rules = draft
            dismiss()
          } catch {
            self.error = error.localizedDescription
          }
        }
      }
    }
  }
}
