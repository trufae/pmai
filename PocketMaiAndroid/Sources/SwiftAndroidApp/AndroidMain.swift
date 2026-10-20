#if os(Android)
  // The host's Activity singleton predates actor annotations. Access below is
  // confined to the main actor by the Android main-looper entry point.
  @preconcurrency import AndroidSwiftUI
  import Foundation
  import MaiChat
  import MaiACP
  import AndroidContent
  import SwiftJava
  import PocketMaiPortableUI

  @JavaClass("org.mai.pocketmai.ForwirohIdentity")
  class AndroidForwirohIdentity: JavaObject {}
  extension JavaClass<AndroidForwirohIdentity> {
    @JavaStaticMethod
    func load(_ context: AndroidContent.Context?) throws -> String
  }

  // Retain the model across activity recreation, including a reply in flight.
  @MainActor private enum AndroidSession {
    static var chat: PortableChat?
    static var remote: PortableRemoteChat?
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
        if AndroidSession.remote == nil {
          guard let application = SwiftUIActivity.shared.getApplication() else { throw CocoaError(.fileNoSuchFile) }
          let environment = application.javaEnvironment
          let context = AndroidContent.Context(javaThis: application.javaThis, environment: environment)
          guard let files = context.getFilesDir()?.getAbsolutePath() else { throw CocoaError(.fileNoSuchFile) }
          ForwirohRemote.initializeAndroid(
            environment: UnsafeMutableRawPointer(environment),
            application: UnsafeMutableRawPointer(application.javaThis))
          if environment.interface.ExceptionCheck(environment) != 0 {
            environment.interface.ExceptionClear(environment)
            throw NSError(
              domain: "PocketMai.Forwiroh", code: 1,
              userInfo: [
                NSLocalizedDescriptionKey: "Cannot initialize Forwiroh certificate verification"
              ])
          }
          let encoded = try JavaClass<AndroidForwirohIdentity>().load(context)
          guard let identity = Data(base64Encoded: encoded), identity.count == 32 else {
            throw CocoaError(.coderInvalidValue)
          }
          let directory = URL(fileURLWithPath: files).appendingPathComponent("pocketmai/remotes")
          let preparation = Task {
            try await ForwirohRemote.shared.configure(
              directory: directory.appendingPathComponent("forwiroh"), identity: identity)
          }
          let remote = PortableRemoteChat(directory: directory, preparation: preparation)
          AndroidSession.remote = remote
          // The initial render must retain the Activity's JNI class-loader context.
          AndroidSwiftUIApp.run(PocketMaiView(store: AndroidSession.chat!, remote: remote))
        } else {
          AndroidSwiftUIApp.run(
            PocketMaiView(store: AndroidSession.chat!, remote: AndroidSession.remote!))
        }
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
