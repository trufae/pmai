import AppKit
import MaiCore
import MaiDocuments
import Observation
import SwiftUI
import UniformTypeIdentifiers
import WebKit

@MainActor @Observable
final class MacWebXDCApps {
  static let shared = MacWebXDCApps()
  let store = WebXDCStore(rootURL: AgentHome.resolve().rootURL.appendingPathComponent("WebXDCApps"))
  private(set) var apps: [WebXDCAppInfo] = []
  private var updates: [UUID: [MacWebXDCUpdate]] = [:]
  private var listeners: [UUID: [UUID: (MacWebXDCUpdate) -> Void]] = [:]

  func reload() { apps = store.listApps() }
  func importApp(_ url: URL) throws -> WebXDCAppInfo {
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    let app = try store.importXDC(from: url, fallbackName: url.deletingPathExtension().lastPathComponent).app
    reload()
    return app
  }
  fileprivate func history(_ app: UUID) -> [MacWebXDCUpdate] {
    if let history = updates[app] { return history }
    let url = store.appURL(app).appendingPathComponent("updates.json")
    let history = (try? JSONDecoder().decode([MacWebXDCUpdate].self, from: Data(contentsOf: url))) ?? []
    updates[app] = history
    return history
  }
  fileprivate func post(_ body: [String: Any], app: UUID) throws {
    let payload = body["payload"] as? String ?? "null"
    guard payload.utf8.count <= store.maxFileBytes,
      let data = payload.data(using: .utf8),
      (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) != nil else {
      throw WebXDCError.message("The app sent an invalid or oversized update.")
    }
    var history = history(app)
    let update = MacWebXDCUpdate(serial: (history.last?.serial ?? 0) + 1, payloadJSON: payload,
      info: body["info"] as? String, document: body["document"] as? String, summary: body["summary"] as? String)
    history.append(update)
    // Match the iOS update log's retained history.
    history = Array(history.suffix(500))
    try JSONEncoder().encode(history).write(to: store.appURL(app).appendingPathComponent("updates.json"), options: .atomic)
    updates[app] = history
    for listener in listeners[app, default: [:]].values { listener(update) }
  }
  fileprivate func observe(_ app: UUID, token: UUID, receive: @escaping (MacWebXDCUpdate) -> Void) {
    listeners[app, default: [:]][token] = receive
  }
  fileprivate func removeObserver(_ app: UUID, token: UUID) { listeners[app]?[token] = nil }
}

private struct MacWebXDCUpdate: Codable {
  let serial: Int
  let payloadJSON: String
  let info: String?
  let document: String?
  let summary: String?
}

/// Retains the browser while hidden, and tears down its native bridge on chat close.
@MainActor @Observable
final class MacWebXDCSession: NSObject, Identifiable, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
  let id = UUID()
  let app: WebXDCAppInfo
  private(set) var webView: WKWebView!
  var error: String?
  private weak var conversation: MacConversation?
  var chatInteraction = true
  private var pendingChat: [(text: String, expectsUpdate: Bool)] = []
  private var stopped = false
  private var loading: Task<Void, Never>?
  private(set) var native: MacWebXDCNative?

  init(app: WebXDCAppInfo, conversation: MacConversation) {
    self.app = app
    self.conversation = conversation
    super.init()
    let bridge = WebXDCBridge.script(selfAddr: "you@pmai", selfName: "You") + WebXDCPocketMaiBridge.script
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: app.id)
    configuration.setURLSchemeHandler(MacWebXDCSchemeHandler(
      root: MacWebXDCApps.shared.store.currentRevisionURL(app), bridge: bridge), forURLScheme: "xdc")
    configuration.userContentController.addUserScript(.init(source: bridge,
      injectionTime: .atDocumentStart, forMainFrameOnly: true))
    configuration.userContentController.add(MacWebXDCMessageHandler(self), name: "webxdc")
    configuration.userContentController.add(MacWebXDCMessageHandler(self), name: "pocketmai")
    webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = self
    webView.uiDelegate = self
    webView.isInspectable = true
    native = MacWebXDCNative(conversation: conversation) { [weak self] reply in
      self?.evaluate("window.__pocketmaiReply", value: reply)
    }
    MacWebXDCApps.shared.observe(app.id, token: id) { [weak self] update in self?.deliver([update]) }
    loading = Task { [weak self] in
      do {
        let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}}]"#
        let list = try await WKContentRuleListStore.default().compileContentRuleList(
          forIdentifier: "pmai-webxdc-offline", encodedContentRuleList: rules)
        guard let self, !stopped, !Task.isCancelled else { return }
        guard let list else { throw WebXDCError.message("Could not prepare the app's offline browser.") }
        webView.configuration.userContentController.add(list)
        webView.load(URLRequest(url: URL(string: "xdc://app/index.html")!))
      } catch { self?.error = error.localizedDescription }
    }
  }

  func stop() {
    stopped = true
    loading?.cancel()
    loading = nil
    native?.stop()
    pendingChat = []
    MacWebXDCApps.shared.removeObserver(app.id, token: id)
    webView.stopLoading()
    webView.configuration.userContentController.removeAllScriptMessageHandlers()
    webView.loadHTMLString("", baseURL: nil)
  }
  func suspendAudio() { native?.stop() }

  func flushChat() {
    guard !stopped, !pendingChat.isEmpty, let conversation,
      conversation.connected, !conversation.busy else { return }
    let item = pendingChat[0]
    if conversation.sendApp(item.text, completion: { [weak self] result in
      guard let self, !self.stopped else { return }
      do {
        let answer = try result.get()
        if item.expectsUpdate {
          var payload = MessageContentFilter.render(answer).visibleText.trimmingCharacters(in: .whitespacesAndNewlines)
          if payload.hasPrefix("```"), let newline = payload.firstIndex(of: "\n"), payload.hasSuffix("```") {
            payload = String(payload[payload.index(after: newline)...].dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
          }
          try MacWebXDCApps.shared.post(["payload": payload], app: self.app.id)
        }
      } catch { self.error = error.localizedDescription }
    }) { pendingChat.removeFirst() }
  }

  private func enqueue(_ text: String, expectsUpdate: Bool) {
    guard pendingChat.count < 100 else { error = "The app's chat queue is full."; return }
    pendingChat.append((text, expectsUpdate))
    flushChat()
  }

  private func deliver(_ updates: [MacWebXDCUpdate]) {
    guard let data = try? JSONEncoder().encode(updates),
      let value = try? JSONSerialization.jsonObject(with: data) else { return }
    evaluate("window.__webxdcDeliver", value: value)
  }
  private func evaluate(_ function: String, value: Any) {
    guard !stopped, webView.url?.scheme == "xdc", webView.url?.host == "app",
      let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed),
      let json = String(data: data, encoding: .utf8) else { return }
    webView.evaluateJavaScript("\(function) && \(function)(\(json));", completionHandler: nil)
  }
  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    guard !stopped, message.frameInfo.isMainFrame,
      message.frameInfo.request.url?.scheme == "xdc", message.frameInfo.request.url?.host == "app",
      webView.url?.scheme == "xdc", webView.url?.host == "app",
      let body = message.body as? [String: Any] else { return }
    if message.name == "pocketmai" { native?.receive(body); return }
    switch body["type"] as? String {
    case "ready":
      let serial = (body["serial"] as? NSNumber)?.intValue ?? 0
      deliver(MacWebXDCApps.shared.history(app.id).filter { $0.serial > serial })
    case "sendUpdate":
      do {
        try MacWebXDCApps.shared.post(body, app: app.id)
        if chatInteraction {
          let store = MacWebXDCApps.shared.store
          var source = ""
          for file in store.listFiles(app) where ["html", "js", "json"].contains((file as NSString).pathExtension) {
            guard let data = try? store.readFile(app, path: file), let text = String(data: data, encoding: .utf8) else { continue }
            source += "\nFile: \(file)\n" + String(text.prefix(max(0, 64_000 - source.count)))
            if source.count >= 64_000 { break }
          }
          enqueue("Webxdc app '\(app.name)' sent an update: \(body["payload"] as? String ?? "null").\n"
            + "Respond only with the JSON payload this app expects from the assistant. It will be delivered to the app's webxdc update listener. App source for context:\n" + source,
            expectsUpdate: true)
        }
      }
      catch { self.error = error.localizedDescription }
    case "sendToChat":
      let text = (body["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return }
      guard text.utf8.count <= 1_000_000, pendingChat.count < 100 else {
        error = "The app's chat queue is full or the message is too large."
        return
      }
      enqueue(text, expectsUpdate: false)
    default: break
    }
  }
  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
    let url = navigationAction.request.url
    let allowed = url?.scheme == "xdc" && url?.host == "app"
    if allowed, navigationAction.targetFrame?.isMainFrame == true { native?.stop() }
    decisionHandler(allowed ? .allow : .cancel)
  }
  func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
    initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
    decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
    // Speech goes through the explicit native permission flow, not web media capture.
    decisionHandler(.deny)
  }
  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    self.error = error.localizedDescription
  }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    self.error = error.localizedDescription
  }
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    native?.stop()
    error = "The app's web process stopped. Stop and reopen the app to continue."
  }
}

/// WKUserContentController retains its handlers; keep the session reference weak.
@MainActor private final class MacWebXDCMessageHandler: NSObject, WKScriptMessageHandler {
  weak var session: MacWebXDCSession?
  init(_ session: MacWebXDCSession) { self.session = session }
  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    session?.userContentController(controller, didReceive: message)
  }
}

@MainActor private final class MacWebXDCSchemeHandler: NSObject, WKURLSchemeHandler {
  let root: URL
  let bridge: String
  init(root: URL, bridge: String) { self.root = root.resolvingSymlinksInPath(); self.bridge = bridge }
  func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
    do {
      guard let url = task.request.url, url.host == "app" else { throw URLError(.badURL) }
      var path = url.path
      while path.hasPrefix("/") { path.removeFirst() }
      if path.isEmpty { path = "index.html" }
      let relative = try MacWebXDCApps.shared.store.validatedRelativePath(path)
      let file = root.appendingPathComponent(relative).resolvingSymlinksInPath()
      guard file.path.hasPrefix(root.path + "/") else { throw URLError(.noPermissionsToReadFile) }
      let data = relative == "webxdc.js" ? Data(bridge.utf8) : try Data(contentsOf: file)
      let mime = relative.hasSuffix(".js") ? "text/javascript"
        : UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
      task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: "utf-8"))
      task.didReceive(data)
      task.didFinish()
    } catch { task.didFailWithError(error) }
  }
  func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

struct MacWebXDCLauncher: View {
  let conversation: MacConversation
  @Environment(\.dismiss) private var dismiss
  @State private var error: String?
  private var library: MacWebXDCApps { .shared }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("Webxdc Apps").font(.title2.bold())
        Spacer()
        Button("Import .xdc…", action: importApp)
        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      if library.apps.isEmpty {
        ContentUnavailableView("No apps yet", systemImage: "app.dashed",
          description: Text("Import a .xdc app from PocketMai or another webxdc host, then start it in this chat."))
      } else {
        List(library.apps) { app in
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Text(app.name).font(.headline)
              if !app.appDescription.isEmpty { Text(app.appDescription).foregroundStyle(.secondary) }
            }
            Spacer()
            Button("Start") { conversation.startWebXDC(app); dismiss() }
          }.padding(.vertical, 6)
        }
      }
      if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
    }.padding(20).frame(width: 580, height: 420).onAppear { library.reload() }
  }
  private func importApp() {
    let panel = NSOpenPanel()
    panel.title = "Import Webxdc App"
    panel.allowedContentTypes = [UTType(filenameExtension: "xdc") ?? .data]
    panel.allowsMultipleSelection = false
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      do {
        let app = try library.importApp(url)
        conversation.startWebXDC(app)
        dismiss()
      } catch { self.error = error.localizedDescription }
    }
  }
}

struct MacWebXDCRunner: View {
  let session: MacWebXDCSession
  let conversation: MacConversation
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Label(session.app.name, systemImage: "app").font(.headline)
        Spacer()
        Toggle("Chat interaction", isOn: Binding(get: { session.chatInteraction }, set: { session.chatInteraction = $0 }))
          .toggleStyle(.checkbox).help("Forward app updates to the assistant and return its JSON replies to the app")
        Button("Hide") { session.suspendAudio(); conversation.showWebXDC = false }
        Button("Stop App") { conversation.stopWebXDC() }
      }.padding(10).background(.bar)
      if let error = session.error {
        HStack {
          Text(error).textSelection(.enabled)
          Spacer()
          Button("Dismiss") { session.error = nil }
        }.font(.caption).padding(8).background(.orange.opacity(0.12))
      }
      MacWebXDCBrowser(webView: session.webView)
    }.frame(minHeight: 220, idealHeight: 360, maxHeight: 460)
      .alert("Allow \(session.app.name) to use \(session.native?.permission ?? "native features")?", isPresented: Binding(
        get: { session.native?.permission != nil },
        set: { if !$0 { session.native?.answerPermission(false) } }
      )) {
        Button("Allow") { session.native?.answerPermission(true) }
        Button("Don't Allow", role: .cancel) { session.native?.answerPermission(false) }
      } message: {
        Text("Allow for this running app. Inference sends messages to this chat's agent; transcription uses your microphone; synthesis reads text aloud with your configured voice.")
      }
  }
}

private struct MacWebXDCBrowser: NSViewRepresentable {
  let webView: WKWebView
  func makeNSView(context: Context) -> WKWebView { webView }
  func updateNSView(_ nsView: WKWebView, context: Context) {}
}
