import SwiftUI

struct ToastNotice: Identifiable, Equatable {
  enum Style {
    case error, success

    var systemImage: String {
      switch self {
      case .error: "exclamationmark.triangle.fill"
      case .success: "checkmark.circle.fill"
      }
    }
  }

  let id = UUID()
  let message: String
  let style: Style

  init(_ message: String, style: Style = .error) {
    self.message = message
    self.style = style
  }
}

private struct ToastModifier: ViewModifier {
  @Binding var notice: ToastNotice?

  func body(content: Content) -> some View {
    content
      .overlay(alignment: .top) {
        if let notice {
          Button {
            self.notice = nil
          } label: {
            Label(notice.message, systemImage: notice.style.systemImage)
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(.white)
              .multilineTextAlignment(.leading)
              .fixedSize(horizontal: false, vertical: true)
              .padding(.horizontal, 14)
              .padding(.vertical, 10)
              .frame(maxWidth: 480)
              .background(
                notice.style == .success ? Color.green : .red,
                in: RoundedRectangle(cornerRadius: 16)
              )
              .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
          }
          .buttonStyle(.plain)
          .accessibilityHint("Dismiss notification")
          .padding(.top, 12)
          .padding(.horizontal, 16)
          .transition(.move(edge: .top).combined(with: .opacity))
          .zIndex(1)
        }
      }
      .animation(.snappy, value: notice)
      .task(id: notice?.id) {
        guard let presented = notice else { return }
        do {
          try await Task.sleep(for: .seconds(presented.style == .success ? 3 : 6))
        } catch {
          return
        }
        guard notice?.id == presented.id else { return }
        notice = nil
      }
  }
}

extension View {
  func toast(_ notice: Binding<ToastNotice?>) -> some View {
    modifier(ToastModifier(notice: notice))
  }
}
