import Foundation
import MaiMobile
import MaiACP
import SwiftJava
#if os(Android)
import AndroidLooper
#endif

@MainActor private var engine: MobileEngine?

// These are the entire interop surface. JExtract generates every Java method,
// callback interface and JNI entry point; generated sources are never edited.
// Call once from Application.onCreate, on Android's main looper.
public func maiStart(application: JavaObject, directory: String, identity: String,
  update: @escaping (String) -> Void) {
  #if os(Android)
  guard AndroidMainActor.setupMainLooper() else {
    update("{\"ready\":false,\"error\":\"Cannot initialize Android main looper\"}")
    return
  }
  ForwirohRemote.initializeAndroid(
    environment: UnsafeMutableRawPointer(application.javaEnvironment),
    application: UnsafeMutableRawPointer(application.javaThis))
  #endif
  Task { @MainActor in
    do {
      engine = try MobileEngine(directory: URL(fileURLWithPath: directory), clientName: "PocketMai Android", update: update)
      engine?.configureRemote(identity: Data(base64Encoded: identity))
      engine?.observe()
    } catch {
      let data = try? JSONSerialization.data(withJSONObject: [
        "ready": false, "error": error.localizedDescription,
      ])
      if let data { update(String(decoding: data, as: UTF8.self)) }
    }
  }
}

public func maiExecute(command: String) {
  Task { @MainActor in engine?.execute(command) }
}

public func maiWebRequest(request: String, reply: @escaping (String) -> Void) {
  Task { @MainActor in engine?.webRequest(request, reply: reply) }
}
