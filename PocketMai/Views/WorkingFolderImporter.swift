import SwiftUI
import UniformTypeIdentifiers

private struct WorkingFolderImporter: ViewModifier {
  @Binding var isPresented: Bool
  @Binding var errorMessage: String?
  let onCompletion: () -> Void
  let onSelection: (WorkingFolderReference) -> Void

  func body(content: Content) -> some View {
    content.fileImporter(isPresented: $isPresented, allowedContentTypes: [.folder]) { result in
      onCompletion()
      do {
        onSelection(try WorkingFolderAccess.makeReference(from: result.get()))
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }
}

extension View {
  /// Resolve the folder once; the owning screen decides whether to save it or update a draft.
  func workingFolderImporter(
    isPresented: Binding<Bool>, errorMessage: Binding<String?>,
    onCompletion: @escaping () -> Void = {},
    onSelection: @escaping (WorkingFolderReference) -> Void
  ) -> some View {
    modifier(WorkingFolderImporter(
      isPresented: isPresented, errorMessage: errorMessage,
      onCompletion: onCompletion, onSelection: onSelection))
  }
}
