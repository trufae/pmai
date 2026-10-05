#if os(Android)
  // The host's Activity singleton predates actor annotations. Access below is
  // confined to the main actor by the Android main-looper entry point.
  @preconcurrency import AndroidSwiftUI
  import Foundation
  import MaiChat
  import PocketMaiPortableUI

  // Retain the model across activity recreation, including a reply in flight.
  @MainActor private enum AndroidSession {
    static var chat: PortableChat?
  }

  /// The framework's supplied Application/Activity call this Swift entry point.
  /// They also bind Swift's main executor to Android's main looper.
  @_cdecl("AndroidSwiftUIMain")
  public func pocketMaiAndroidMain() {
    MainActor.assumeIsolated {
      do {
        if AndroidSession.chat == nil {
          guard let path = SwiftUIActivity.shared.getFilesDir()?.getAbsolutePath() else {
            throw CocoaError(.fileNoSuchFile)
          }
          AndroidSession.chat = try PortableChat(
            directory: URL(fileURLWithPath: path).appendingPathComponent("pocketmai"))
        }
        AndroidSwiftUIApp.run(PocketMaiView(store: AndroidSession.chat!))
      } catch {
        // Corrupt settings are left intact; startup never silently replaces them.
        AndroidSwiftUIApp.run(
          VStack {
            Text("PocketMai could not load its saved settings.")
            Text(error.localizedDescription)
          }.padding())
      }
    }
  }
#endif
