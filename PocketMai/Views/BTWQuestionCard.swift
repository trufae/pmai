import SwiftUI

struct BTWQuestionCard: View {
  let question: BTWQuestion
  let appearance: AppearanceSettings
  let renderMarkdown: Bool
  let renderImages: Bool
  let onStop: () -> Void
  let onDismiss: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label("Side question", systemImage: "bubble.left.and.bubble.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        if question.isRunning {
          ProgressView().controlSize(.small)
          Button("Stop", action: onStop)
        }
        Button(action: onDismiss) {
          Image(systemName: "xmark")
        }
        .accessibilityLabel("Dismiss side question")
      }
      Text(question.prompt).font(.callout.weight(.medium))
      if !question.answer.isEmpty {
        if renderMarkdown {
          MarkdownContentView(text: question.answer, appearance: appearance, renderImages: renderImages)
        } else {
          Text(question.answer).textSelection(.enabled)
        }
      }
      if let error = question.error {
        Text(error).font(.callout).foregroundStyle(.secondary)
      }
    }
    .padding()
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
  }
}
