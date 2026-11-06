import SwiftUI

/// Keep the error in its owning screen so dismissing a picker cannot discard it.
private struct ErrorAlertModifier: ViewModifier {
  let title: LocalizedStringKey
  @Binding var message: String?
  var isEnabled: Bool

  func body(content: Content) -> some View {
    content.alert(
      title,
      isPresented: Binding(
        get: { isEnabled && message != nil },
        set: { if !$0 { message = nil } }),
      presenting: message
    ) { _ in
      Button("OK", role: .cancel) { message = nil }
    } message: { Text($0) }
  }
}

extension View {
  func errorAlert(
    _ title: LocalizedStringKey, message: Binding<String?>, isEnabled: Bool = true
  ) -> some View {
    modifier(ErrorAlertModifier(title: title, message: message, isEnabled: isEnabled))
  }
}
