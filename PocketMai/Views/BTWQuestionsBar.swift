import SwiftUI

struct BTWQuestionsBar: View {
  let questions: [BTWQuestion]
  let appearance: AppearanceSettings
  let renderMarkdown: Bool
  let renderImages: Bool
  let onStop: (UUID) -> Void
  let onDismiss: (UUID) -> Void
  @State private var isExpanded = false

  var body: some View {
    VStack(spacing: 0) {
      ChatTitleBar(
        title: "Side questions · \(questions.count)", subtitle: questions.last?.prompt,
        systemImage: "bubble.left.and.bubble.right",
        onTap: { isExpanded.toggle() }
      ) {
        if questions.contains(where: \.isRunning) { ProgressView().controlSize(.small) }
        Button { isExpanded.toggle() } label: {
          Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            .frame(width: 30, height: 30)
        }
        .accessibilityLabel(isExpanded ? "Collapse side questions" : "Expand side questions")
      }
      if isExpanded {
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            ForEach(questions.reversed()) { question in
              answer(question)
              Divider()
            }
          }
          .padding(12)
        }
        .frame(maxHeight: 240)
      }
    }
  }

  private func answer(_ question: BTWQuestion) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top) {
        Text(question.prompt).font(.callout.weight(.medium)).textSelection(.enabled)
        Spacer()
        if question.isRunning {
          ProgressView().controlSize(.small)
          Button("Stop") { onStop(question.id) }
        }
        Button { onDismiss(question.id) } label: {
          Image(systemName: "xmark").frame(width: 30, height: 30)
        }
        .accessibilityLabel("Dismiss side question")
      }
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
  }
}
