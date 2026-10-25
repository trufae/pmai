import Combine
import Foundation
import MaiCore
import MaiDocuments
import XCTest

@testable import PocketMai

@MainActor
final class WebXDCPocketMaiTests: XCTestCase {
  func testGrantsAreLocalAndNeverTravelWithExport() throws {
    let app = try WebXDCLibrary.createApp(name: "Permission test", description: "")
    defer { try? WebXDCLibrary.deleteApp(id: app.id) }
    XCTAssertEqual(WebXDCPermissions.load(app.id), WebXDCPermissions())
    let grants = WebXDCPermissions(inference: true, transcription: true, synthesis: true)
    try grants.save(app.id)
    XCTAssertEqual(WebXDCPermissions.load(app.id), grants)
    let export = try WebXDCLibrary.exportXDC(app)
    defer { try? FileManager.default.removeItem(at: export) }
    XCTAssertFalse(
      try ZipArchiveReader.entries(at: export).contains { $0.path.contains("permissions") })
    let revised = try WebXDCLibrary.beginRevision(app, note: "test")
    XCTAssertEqual(WebXDCPermissions.load(revised.id), grants)
    // A fresh installation must not inherit the exporting device's grants.
    // Importing identical files while the app is installed reuses its grants.
    try WebXDCLibrary.deleteApp(id: app.id)
    let imported = try WebXDCLibrary.importXDC(from: export, fallbackName: "Imported").app
    defer { try? WebXDCLibrary.deleteApp(id: imported.id) }
    XCTAssertEqual(WebXDCPermissions.load(imported.id), WebXDCPermissions())
  }

  func testAllSensitiveMethodsCheckNativePermissions() async {
    let methods = ["complete", "models", "voices", "speak", "languages", "listen", "providers"]
    let replies = expectation(description: "Permission denials")
    replies.expectedFulfillmentCount = methods.count
    let host = WebXDCPocketMaiHost(appID: UUID(), settings: { .defaults }) { reply in
      XCTAssertEqual((reply["error"] as? [String: String])?["code"], "NotAllowedError")
      replies.fulfill()
    }
    for method in methods {
      host.receive(["id": method, "method": method, "options": ["inference": true]])
    }
    await fulfillment(of: [replies], timeout: 3)
  }

  func testCapabilityDiscoveryNeedsNoGrantAndRespectsMediaGates() async throws {
    let app = try WebXDCLibrary.createApp(name: "Capabilities", description: "")
    defer { try? WebXDCLibrary.deleteApp(id: app.id) }
    try WebXDCPermissions(inference: true, transcription: true, synthesis: true).save(app.id)
    let replyReceived = expectation(description: "Capabilities")
    var settings = AppSettings.defaults
    settings.toolSettings.webxdcAllowMicrophone = false
    settings.toolSettings.webxdcAllowAudioPlayback = false
    let host = WebXDCPocketMaiHost(appID: app.id, settings: { settings }) { reply in
      let result = reply["result"] as? [String: Any]
      XCTAssertEqual(result?["host"] as? String, "pocketmai")
      XCTAssertEqual(
        result?["permissions"] as? [String: Bool],
        ["inference": true, "transcription": false, "synthesis": false])
      replyReceived.fulfill()
    }
    host.receive(["id": "caps", "method": "capabilities"])
    await fulfillment(of: [replyReceived], timeout: 3)
  }

  func testCancellationSettlesOnceAndSuppressesLateCompletion() async {
    let replyReceived = expectation(description: "Cancelled")
    replyReceived.assertForOverFulfill = true
    let host = WebXDCPocketMaiHost(appID: UUID(), settings: { .defaults }) { reply in
      XCTAssertEqual((reply["error"] as? [String: String])?["code"], "AbortError")
      replyReceived.fulfill()
    }
    host.receive(["id": "cancel", "method": "capabilities"])
    host.receive(["id": "cancel", "method": "cancel"])
    await fulfillment(of: [replyReceived], timeout: 3)
    await Task.yield()
  }

  func testProviderAPISwitchBlocksGrantedAppsWithoutPrompting() async throws {
    let app = try WebXDCLibrary.createApp(name: "Disabled APIs", description: "")
    defer { try? WebXDCLibrary.deleteApp(id: app.id) }
    try WebXDCPermissions(inference: true, transcription: true, synthesis: true).save(app.id)
    var settings = AppSettings.defaults
    settings.toolSettings.webxdcAllowProviderAPIs = false
    let methods = ["complete", "models", "voices", "speak", "listen", "languages", "providers", "requestPermissions"]
    let denied = expectation(description: "All provider methods disabled")
    denied.expectedFulfillmentCount = methods.count
    let capabilities = expectation(description: "No effective grants")
    let host = WebXDCPocketMaiHost(appID: app.id, settings: { settings }) { reply in
      if reply["id"] as? String == "capabilities" {
        let result = reply["result"] as? [String: Any]
        XCTAssertEqual(result?["permissions"] as? [String: Bool],
          ["inference": false, "transcription": false, "synthesis": false])
        capabilities.fulfill()
      } else {
        let error = reply["error"] as? [String: String]
        XCTAssertEqual(error?["code"], "NotAllowedError")
        XCTAssertTrue(error?["message"]?.contains("Inference and speech APIs") == true)
        denied.fulfill()
      }
    }
    host.requestPermission = { _ in
      XCTFail("Disabled APIs must not ask for app grants")
      return true
    }
    host.receive(["id": "capabilities", "method": "capabilities"])
    for method in methods {
      host.receive(["id": method, "method": method, "options": ["capabilities": ["inference"]]])
      await Task.yield()
    }
    await fulfillment(of: [denied, capabilities], timeout: 3)
  }

  func testAppCanRequestPermissionsWithoutCallingAProvider() async throws {
    let app = try WebXDCLibrary.createApp(name: "Request access", description: "")
    defer { try? WebXDCLibrary.deleteApp(id: app.id) }
    var settings = AppSettings.defaults
    settings.toolSettings.webxdcAllowMicrophone = true
    var requested: [String] = []
    let finished = expectation(description: "Permissions granted")
    let host = WebXDCPocketMaiHost(appID: app.id, settings: { settings }) { reply in
      XCTAssertNil(reply["error"])
      let result = reply["result"] as? [String: Any]
      XCTAssertEqual(result?["permissions"] as? [String: Bool],
        ["inference": true, "transcription": true, "synthesis": true])
      finished.fulfill()
    }
    host.requestPermission = { capability in
      requested.append(capability)
      return true
    }
    host.receive(["id": "request", "method": "requestPermissions",
      "options": ["capabilities": ["inference", "transcription", "synthesis"]]])
    await fulfillment(of: [finished], timeout: 3)
    XCTAssertEqual(requested, ["inference", "transcription", "synthesis"])
    XCTAssertEqual(WebXDCPermissions.load(app.id),
      WebXDCPermissions(inference: true, transcription: true, synthesis: true))
  }

  func testProviderAPISwitchPersistsAndPreservesOlderSettings() throws {
    let legacy = try JSONDecoder().decode(NativeToolSettings.self, from: Data("{}".utf8))
    XCTAssertTrue(legacy.webxdcAllowProviderAPIs)
    var settings = legacy
    settings.webxdcAllowProviderAPIs = false
    let restored = try JSONDecoder().decode(NativeToolSettings.self, from: JSONEncoder().encode(settings))
    XCTAssertFalse(restored.webxdcAllowProviderAPIs)
  }

  func testJavaScriptCanReachNativeCapabilitiesInWKWebView() async throws {
    let html = """
      <!doctype html><script src="webxdc.js"></script><script>
      webxdc.pocketmai.capabilities().then(c => {
        console.info('native-bridge:' + c.host + ':' + c.permissions.inference);
      }).catch(e => console.error('bridge-failure:' + e.message));
      </script>
      """
    let app = try WebXDCLibrary.createApp(
      name: "Bridge integration", description: "", indexHTML: html)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
      try? WebXDCLibrary.deleteApp(id: app.id)
      try? FileManager.default.removeItem(at: directory)
    }
    let store = AppStore(persistence: PersistenceStore(localBaseURL: directory))
    let session = WebXDCRunningSession(app: app, conversationID: nil, store: store)
    defer { session.stop() }
    let replied = expectation(description: "Native bridge round trip")
    var completed = false
    let observation = session.$debugLogs.sink { logs in
      guard !completed, let message = logs.last?.message else { return }
      if message.hasPrefix("native-bridge:") {
        completed = true
        XCTAssertEqual(message, "native-bridge:pocketmai:false")
        replied.fulfill()
      } else if message.hasPrefix("bridge-failure:") {
        completed = true
        XCTFail(message)
        replied.fulfill()
      }
    }
    defer { observation.cancel() }
    await fulfillment(of: [replied], timeout: 15)
  }

  func testCompletionUsesOnlyAppMessagesAndCustomPrompt() async throws {
    let app = try WebXDCLibrary.createApp(name: "Isolated inference", description: "")
    defer { try? WebXDCLibrary.deleteApp(id: app.id) }
    try WebXDCPermissions(inference: true).save(app.id)
    var settings = AppSettings.defaults
    let endpoint = OpenAIEndpoint(
      name: "Test", baseURL: "http://127.0.0.1:1/v1", defaultModel: "test-model")
    settings.openAIEndpoints = [endpoint]
    settings.memory = "PRIVATE CHAT MEMORY"
    let finished = expectation(description: "Isolated completion")
    let host = WebXDCPocketMaiHost(
      appID: app.id, settings: { settings },
      completion: { request, update in
        XCTAssertEqual(request.conversation.messages.map(\.text), ["Hi"])
        XCTAssertFalse(request.conversation.toolsEnabled)
        XCTAssertTrue(request.conversation.enabledTools.isEmpty)
        XCTAssertEqual(request.context, "")
        XCTAssertEqual(request.settings.memory, "")
        XCTAssertEqual(request.settings.systemPrompts.first?.text, "Be brief and friendly")
        XCTAssertEqual(request.conversation.modelID, "app-model")
        XCTAssertEqual(request.conversation.endpointID, endpoint.id)
        update("Hello")
        return "Hello!"
      }
    ) { reply in
      if reply["event"] != nil { return }
      XCTAssertEqual((reply["result"] as? [String: String])?["text"], "Hello!")
      finished.fulfill()
    }
    host.receive([
      "id": "isolated", "method": "complete",
      "options": [
        "provider": endpoint.id.uuidString, "model": "app-model",
        "systemPrompt": "Be brief and friendly",
        "messages": [["role": "user", "content": "Hi"]],
      ],
    ])
    await fulfillment(of: [finished], timeout: 3)
  }

  func testListenCanFinishManuallyAndReleasesMicrophone() async throws {
    let app = try WebXDCLibrary.createApp(name: "Listen", description: "")
    defer { try? WebXDCLibrary.deleteApp(id: app.id) }
    try WebXDCPermissions(transcription: true).save(app.id)
    var settings = AppSettings.defaults
    settings.toolSettings.webxdcAllowMicrophone = true
    let engine = TestWebXDCSpeechEngine()
    let started = expectation(description: "Microphone started")
    engine.onStart = { started.fulfill() }
    let finished = expectation(description: "Transcript finished")
    let host = WebXDCPocketMaiHost(
      appID: app.id, settings: { settings }, recognitionEngine: { _, _ in engine }
    ) { reply in
      if reply["event"] != nil { return }
      XCTAssertEqual((reply["result"] as? [String: String])?["text"], "Hello from the microphone")
      finished.fulfill()
    }
    host.receive(["id": "listen", "method": "listen"])
    await fulfillment(of: [started], timeout: 3)
    host.receive(["id": "listen", "method": "finishListening"])
    await fulfillment(of: [finished], timeout: 3)
    XCTAssertTrue(engine.stopped)
  }

  func testClosingRunnerCancelsMicrophoneAndRejectsNewRequests() async throws {
    let app = try WebXDCLibrary.createApp(name: "Cancel listening", description: "")
    defer { try? WebXDCLibrary.deleteApp(id: app.id) }
    try WebXDCPermissions(transcription: true).save(app.id)
    var settings = AppSettings.defaults
    settings.toolSettings.webxdcAllowMicrophone = true
    let engine = TestWebXDCSpeechEngine()
    let started = expectation(description: "Started")
    engine.onStart = { started.fulfill() }
    let cancelled = expectation(description: "Cancelled and hidden")
    cancelled.expectedFulfillmentCount = 2
    let host = WebXDCPocketMaiHost(
      appID: app.id, settings: { settings }, recognitionEngine: { _, _ in engine }
    ) { reply in
      XCTAssertEqual((reply["error"] as? [String: String])?["code"], "AbortError")
      cancelled.fulfill()
    }
    host.receive(["id": "listen", "method": "listen"])
    await fulfillment(of: [started], timeout: 3)
    host.isActive = false
    host.receive(["id": "hidden", "method": "listen"])
    await fulfillment(of: [cancelled], timeout: 3)
    XCTAssertTrue(engine.stopped)
  }

}

@MainActor
private final class TestWebXDCSpeechEngine: LiveSpeechRecognitionEngine {
  var onTranscript: ((LiveSpeechRecognitionEvent) -> Void)?
  var onError: ((Error) -> Void)?
  var onStart: (() -> Void)?
  let languageIdentifier = "en-US"
  let recordingFilename: String? = nil
  var stopped = false
  func start() async throws { onStart?() }
  func stop() { stopped = true }
  func finalize() async throws -> LiveSpeechRecognitionEvent? {
    LiveSpeechRecognitionEvent(
      text: "Hello from the microphone", isFinal: true, languageIdentifier: languageIdentifier)
  }
}
