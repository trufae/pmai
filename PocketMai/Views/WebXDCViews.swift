import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

// MARK: - Running session

struct WebXDCDebugLog: Identifiable, Sendable, Equatable {
  let id = UUID()
  let date: Date
  let level: String
  let message: String
  let source: String?
  let line: Int?
  let column: Int?
}

/// A running webxdc app. Owns the WKWebView so the app keeps its state while
/// the runner sheet is closed; it stays attached to the chat it was started
/// from until explicitly stopped.
@MainActor
final class WebXDCRunningSession: NSObject, ObservableObject, Identifiable {
  static let appScheme = "xdc"

  let app: WebXDCAppInfo
  let conversationID: UUID?
  @Published private(set) var debugLogs: [WebXDCDebugLog] = []
  private(set) var webView: WKWebView!
  private weak var store: AppStore?
  private var outbox: [(prompt: String, display: String, expectsUpdate: Bool)] = []
  private var flushTask: Task<Void, Never>?
  private var awaitingAssistantUpdate = false

  nonisolated var id: UUID { app.id }

  init(app: WebXDCAppInfo, conversationID: UUID?, store: AppStore) {
    self.app = app
    self.conversationID = conversationID
    self.store = store
    super.init()

    let configuration = WKWebViewConfiguration()
    let webxdcSettings = store.settings.toolSettings
    configuration.setURLSchemeHandler(
      WebXDCSchemeHandler(
        rootURL: WebXDCLibrary.currentRevisionURL(app),
        bridgeScript: WebXDCBridge.script(
          selfAddr: "you@pocketmai", selfName: "You", settings: webxdcSettings)),
      forURLScheme: Self.appScheme)
    configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: app.id)
    configuration.userContentController.addUserScript(
      WKUserScript(
        source: WebXDCDebugBridge.script,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false))
    configuration.userContentController.addUserScript(
      WKUserScript(
        source: WebXDCRuntimePolicy.script(settings: webxdcSettings),
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false))
    configuration.userContentController.add(self, name: "webxdc")
    configuration.userContentController.add(self, name: "webxdcDebug")
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = self
    webView.isOpaque = false
    self.webView = webView

    store.webxdcHub.addListener(appID: app.id, token: ObjectIdentifier(self)) {
      [weak self] update in
      if update.sender == "assistant" {
        self?.awaitingAssistantUpdate = false
      }
      self?.deliver([update])
    }

    let load = {
      if let url = URL(string: "\(Self.appScheme)://app/index.html") {
        webView.load(URLRequest(url: url))
      }
    }
    if store.settings.toolSettings.webxdcAllowInternet {
      load()
    } else {
      // Attach the network-blocking rules before the first load so no remote
      // subresource can slip through while they compile.
      Self.blockNetworkRuleList { ruleList in
        if let ruleList {
          webView.configuration.userContentController.add(ruleList)
        }
        load()
      }
    }
  }

  func stop() {
    flushTask?.cancel()
    flushTask = nil
    outbox.removeAll()
    store?.webxdcHub.removeListener(appID: app.id, token: ObjectIdentifier(self))
    webView.stopLoading()
    webView.configuration.userContentController.removeScriptMessageHandler(forName: "webxdc")
    webView.configuration.userContentController.removeScriptMessageHandler(forName: "webxdcDebug")
  }

  /// Content rules blocking http/https/websocket loads. The filter must stay
  /// scheme-scoped: a match-everything rule also blocks the app's own xdc://
  /// resources and renders the app blank.
  private static func blockNetworkRuleList(_ completion: @escaping (WKContentRuleList?) -> Void) {
    let rules = """
      [{"trigger":{"url-filter":"^https?://.*"},"action":{"type":"block"}},
       {"trigger":{"url-filter":"^wss?://.*"},"action":{"type":"block"}}]
      """
    WKContentRuleListStore.default().compileContentRuleList(
      forIdentifier: "webxdc-block-network", encodedContentRuleList: rules
    ) { ruleList, _ in
      completion(ruleList)
    }
  }

  private func handleSendUpdate(_ body: [String: Any]) {
    guard let store else { return }
    let payloadJSON = (body["payload"] as? String) ?? "null"
    let info = nonEmpty(body["info"] as? String)
    let document = nonEmpty(body["document"] as? String)
    let summary = nonEmpty(body["summary"] as? String)
    let update = store.webxdcHub.post(
      appID: app.id,
      payloadJSON: payloadJSON,
      info: info,
      document: document,
      summary: summary,
      sender: "app")
    guard store.settings.toolSettings.webxdcChatInteractionEnabled else { return }
    var prompt =
      "[webxdc app '\(app.name)' sent update serial \(update.serial)] payload: \(payloadJSON)"
    if let info { prompt += "\ninfo: \(info)" }
    prompt +=
      "\nReply by calling the webxdc_send_update tool (app='\(app.name)') with the JSON payload the app expects. Never print that JSON as plain text in the chat."
    let display = info ?? "[\(app.name)] \(payloadJSON)"
    enqueueChat(prompt: prompt, display: display, expectsUpdate: true)
  }

  /// Chat sends are queued: a send that lands while the assistant is still
  /// responding would otherwise be silently dropped by AppStore.send, which
  /// loses game moves.
  private func enqueueChat(prompt: String, display: String, expectsUpdate: Bool) {
    outbox.append((prompt, display, expectsUpdate))
    guard flushTask == nil else { return }
    flushTask = Task { [weak self] in
      await self?.flushOutbox()
      self?.flushTask = nil
    }
  }

  private func flushOutbox() async {
    while !outbox.isEmpty, !Task.isCancelled {
      guard let store else { return }
      if let conversationID {
        var ticks = 0
        while store.currentConversation?.id != conversationID
          || store.isResponding(in: conversationID)
        {
          if Task.isCancelled { return }
          guard ticks < 1200 else {
            outbox.removeAll()
            return
          }
          try? await Task.sleep(nanoseconds: 250_000_000)
          ticks += 1
        }
      }
      let item = outbox.removeFirst()
      awaitingAssistantUpdate = item.expectsUpdate
      let sent = await store.send(prompt: item.prompt, displayText: item.display)
      if sent, item.expectsUpdate, awaitingAssistantUpdate {
        recoverAssistantPayloadFromChat()
      }
      awaitingAssistantUpdate = false
    }
  }

  /// Small models sometimes print the JSON payload as chat text instead of
  /// calling webxdc_send_update. When a turn triggered by an app update ends
  /// without an assistant update, salvage the first JSON object from the
  /// assistant's reply and deliver it to the app.
  private func recoverAssistantPayloadFromChat() {
    guard let store, let conversationID,
      store.currentConversation?.id == conversationID,
      let message = store.currentConversation?.messages.last(where: { $0.role == .assistant })
    else { return }
    let cleaned = Self.strippedBlocks(message.text, tags: ["think", "tool_run"])
    guard let json = Self.firstJSONObjectString(in: cleaned) else { return }
    store.webxdcHub.post(
      appID: app.id,
      payloadJSON: json,
      info: nil,
      document: nil,
      summary: nil,
      sender: "assistant")
  }

  private static func strippedBlocks(_ text: String, tags: [String]) -> String {
    var result = text
    for tag in tags {
      while let open = result.range(of: "<\(tag)>"),
        let close = result.range(
          of: "</\(tag)>", range: open.upperBound..<result.endIndex)
      {
        result.removeSubrange(open.lowerBound..<close.upperBound)
      }
    }
    return result
  }

  private static func firstJSONObjectString(in text: String) -> String? {
    guard let start = text.firstIndex(of: "{") else { return nil }
    var depth = 0
    var inString = false
    var escaped = false
    var index = start
    while index < text.endIndex {
      let character = text[index]
      if inString {
        if escaped {
          escaped = false
        } else if character == "\\" {
          escaped = true
        } else if character == "\"" {
          inString = false
        }
      } else {
        switch character {
        case "\"":
          inString = true
        case "{":
          depth += 1
        case "}":
          depth -= 1
          if depth == 0 {
            let candidate = String(text[start...index])
            guard let data = candidate.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil
            else { return nil }
            return candidate
          }
        default:
          break
        }
      }
      index = text.index(after: index)
    }
    return nil
  }

  private func deliver(_ updates: [WebXDCUpdate]) {
    guard !updates.isEmpty, let webView else { return }
    let items: [[String: Any]] = updates.map { update in
      var item: [String: Any] = [
        "serial": update.serial,
        "payloadJSON": update.payloadJSON,
      ]
      if let info = update.info { item["info"] = info }
      if let document = update.document { item["document"] = document }
      if let summary = update.summary { item["summary"] = summary }
      return item
    }
    guard let data = try? JSONSerialization.data(withJSONObject: items),
      var json = String(data: data, encoding: .utf8)
    else { return }
    json = json
      .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
      .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    webView.evaluateJavaScript("window.__webxdcDeliver(\(json));", completionHandler: nil)
  }

  private func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }
    return value
  }

  private func appendDebugLog(
    level: String,
    message: String,
    source: String? = nil,
    line: Int? = nil,
    column: Int? = nil
  ) {
    let entry = WebXDCDebugLog(
      date: Date(),
      level: level,
      message: message,
      source: source,
      line: line,
      column: column)
    debugLogs.append(entry)
    if debugLogs.count > 500 {
      debugLogs.removeFirst(debugLogs.count - 500)
    }
  }

  private func handleDebugMessage(_ body: [String: Any]) {
    let level = (body["level"] as? String) ?? "log"
    let message = (body["message"] as? String) ?? ""
    let source = body["source"] as? String
    let line = (body["line"] as? NSNumber)?.intValue
    let column = (body["column"] as? NSNumber)?.intValue
    appendDebugLog(level: level, message: message, source: source, line: line, column: column)
  }
}

extension WebXDCRunningSession: WKScriptMessageHandler {
  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    guard let body = message.body as? [String: Any] else { return }
    if message.name == "webxdcDebug" {
      handleDebugMessage(body)
      return
    }
    guard message.name == "webxdc", let type = body["type"] as? String else { return }
    switch type {
    case "ready":
      let since = (body["serial"] as? NSNumber)?.intValue ?? 0
      let updates = (store?.webxdcHub.updates(appID: app.id) ?? [])
        .filter { $0.serial > since }
      deliver(updates)
    case "sendUpdate":
      handleSendUpdate(body)
    case "sendToChat":
      let text = (body["text"] as? String ?? "").trimmingCharacters(
        in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return }
      enqueueChat(prompt: text, display: text, expectsUpdate: false)
    default:
      break
    }
  }
}

extension WebXDCRunningSession: WKNavigationDelegate {
  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
  ) {
    guard let url = navigationAction.request.url else {
      decisionHandler(.cancel)
      return
    }
    let scheme = url.scheme?.lowercased() ?? ""
    if scheme == Self.appScheme || scheme == "about" || scheme == "blob" || scheme == "data" {
      decisionHandler(.allow)
      return
    }
    if (scheme == "http" || scheme == "https"),
      store?.settings.toolSettings.webxdcAllowInternet == true
    {
      decisionHandler(.allow)
      return
    }
    decisionHandler(.cancel)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    appendDebugLog(level: "info", message: "Loaded \(webView.url?.absoluteString ?? "page")")
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    appendDebugLog(level: "error", message: error.localizedDescription)
  }

  func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    appendDebugLog(level: "error", message: error.localizedDescription)
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    appendDebugLog(level: "error", message: "Web content process terminated.")
  }
}

// MARK: - Runner sheet

struct WebXDCRunnerSheet: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss

  @ObservedObject var session: WebXDCRunningSession
  @State private var showingDebugLogs = false

  var body: some View {
    NavigationStack {
      WebXDCWebViewContainer(webView: session.webView)
        .ignoresSafeArea(edges: .bottom)
        .navigationTitle(session.app.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .topBarLeading) {
            HStack(spacing: 8) {
              Button {
                showingDebugLogs = true
              } label: {
                Label("Debug Logs", systemImage: "list.bullet.rectangle")
              }
              .labelStyle(.iconOnly)
              .accessibilityLabel("Debug logs")
              if isThinking {
                ProgressView()
                Text("Thinking...")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .accessibilityLabel("The assistant is responding")
              }
            }
          }
          ToolbarItem(placement: .confirmationAction) {
            Button("Close") { dismiss() }
          }
        }
    }
    .ignoresSafeArea(edges: .bottom)
    .interactiveDismissDisabled()
    .sheet(isPresented: $showingDebugLogs) {
      WebXDCDebugLogView(session: session)
    }
  }

  private var isThinking: Bool {
    guard let conversationID = session.conversationID else { return false }
    return store.isResponding(in: conversationID)
  }
}

private struct WebXDCDebugLogView: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var session: WebXDCRunningSession

  var body: some View {
    NavigationStack {
      List {
        if session.debugLogs.isEmpty {
          Text("No logs yet.")
            .foregroundStyle(.secondary)
        } else {
          ForEach(session.debugLogs.reversed()) { log in
            VStack(alignment: .leading, spacing: 4) {
              HStack {
                Text(log.level.uppercased())
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(color(for: log.level))
                Spacer()
                Text(formatted(log.date))
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
              Text(log.message)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
              if let location = locationText(log) {
                Text(location)
                  .font(.caption2)
                  .foregroundStyle(.secondary)
                  .textSelection(.enabled)
              }
            }
            .padding(.vertical, 4)
          }
        }
      }
      .navigationTitle("Debug Logs")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
  }

  private func color(for level: String) -> Color {
    switch level.lowercased() {
    case "error": return .red
    case "warn", "warning": return .orange
    case "info": return .secondary
    default: return .primary
    }
  }

  private func formatted(_ date: Date) -> String {
    date.formatted(date: .omitted, time: .standard)
  }

  private func locationText(_ log: WebXDCDebugLog) -> String? {
    let source = log.source?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let hasPosition = log.line != nil || log.column != nil
    if source.isEmpty && !hasPosition { return nil }
    var text = source.isEmpty ? "unknown source" : source
    if let line = log.line {
      text += ":\(line)"
      if let column = log.column {
        text += ":\(column)"
      }
    }
    return text
  }
}

private struct WebXDCWebViewContainer: UIViewRepresentable {
  let webView: WKWebView

  func makeUIView(context: Context) -> WKWebView { webView }

  func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// Serves app files for the xdc:// scheme and injects the standard webxdc.js
/// implementation, shadowing any webxdc.js stub bundled with the app.
private final class WebXDCSchemeHandler: NSObject, WKURLSchemeHandler {
  private let rootURL: URL
  private let bridgeScript: String

  init(rootURL: URL, bridgeScript: String) {
    self.rootURL = rootURL
    self.bridgeScript = bridgeScript
  }

  func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
    guard let url = urlSchemeTask.request.url else {
      urlSchemeTask.didFailWithError(URLError(.badURL))
      return
    }
    var path = url.path
    while path.hasPrefix("/") { path.removeFirst() }
    if path.isEmpty { path = "index.html" }

    if path == "webxdc.js" {
      respond(urlSchemeTask, url: url, data: Data(bridgeScript.utf8), mime: "text/javascript")
      return
    }

    let components = path.split(separator: "/").map(String.init)
    guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
      urlSchemeTask.didFailWithError(URLError(.badURL))
      return
    }
    let fileURL = components.reduce(rootURL) { $0.appendingPathComponent($1) }
    guard let data = try? Data(contentsOf: fileURL) else {
      urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
      return
    }
    respond(urlSchemeTask, url: url, data: data, mime: Self.mimeType(for: path))
  }

  func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

  private func respond(_ task: WKURLSchemeTask, url: URL, data: Data, mime: String) {
    let response = URLResponse(
      url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: "utf-8")
    task.didReceive(response)
    task.didReceive(data)
    task.didFinish()
  }

  private static func mimeType(for path: String) -> String {
    let ext = (path as NSString).pathExtension.lowercased()
    if let type = UTType(filenameExtension: ext), let mime = type.preferredMIMEType {
      return mime
    }
    switch ext {
    case "html", "htm": return "text/html"
    case "js", "mjs": return "text/javascript"
    case "css": return "text/css"
    case "json": return "application/json"
    case "wasm": return "application/wasm"
    default: return "application/octet-stream"
    }
  }
}

enum WebXDCDebugBridge {
  static let script = """
    (function () {
      if (window.__pocketMaiDebugBridgeInstalled) { return; }
      window.__pocketMaiDebugBridgeInstalled = true;
      function text(value) {
        try {
          if (value instanceof Error) {
            return value.stack || value.message || String(value);
          }
          if (typeof value === "string") { return value; }
          return JSON.stringify(value);
        } catch (e) {
          try { return String(value); } catch (_) { return "<unprintable>"; }
        }
      }
      function post(level, args, source, line, column) {
        var message = Array.prototype.slice.call(args || []).map(text).join(" ");
        try {
          window.webkit.messageHandlers.webxdcDebug.postMessage({
            level: level,
            message: message,
            source: source || null,
            line: line || null,
            column: column || null
          });
        } catch (e) {}
      }
      ["debug", "log", "info", "warn", "error"].forEach(function (level) {
        var original = console[level];
        console[level] = function () {
          post(level, arguments, null, null, null);
          if (original) { return original.apply(console, arguments); }
        };
      });
      window.addEventListener("error", function (event) {
        post("error", [event.message || event.error || "Script error"], event.filename, event.lineno, event.colno);
      });
      window.addEventListener("unhandledrejection", function (event) {
        post("error", ["Unhandled promise rejection", event.reason], null, null, null);
      });
    })();
    """
}

enum WebXDCBridge {
  static func script(selfAddr: String, selfName: String, settings: NativeToolSettings) -> String {
    """
    (function () {
      if (window.webxdc) { return; }
      var listener = null;
      var pending = [];
      var maxSerial = 0;
      function toUpdate(item) {
        var payload = null;
        try { payload = JSON.parse(item.payloadJSON); } catch (e) {}
        var update = { payload: payload, serial: item.serial, max_serial: maxSerial };
        if (item.info) { update.info = item.info; }
        if (item.document) { update.document = item.document; }
        if (item.summary) { update.summary = item.summary; }
        return update;
      }
      window.__webxdcDeliver = function (items) {
        items.forEach(function (item) {
          if (item.serial > maxSerial) { maxSerial = item.serial; }
        });
        items.forEach(function (item) {
          var update = toUpdate(item);
          if (listener) { listener(update); } else { pending.push(update); }
        });
      };
      function post(message) {
        try { window.webkit.messageHandlers.webxdc.postMessage(message); } catch (e) {}
      }
      window.webxdc = {
        selfAddr: \(jsString(selfAddr)),
        selfName: \(jsString(selfName)),
        sendUpdate: function (update, descr) {
          update = update || {};
          var payload = update.payload === undefined ? null : update.payload;
          var payloadJSON = "null";
          try { payloadJSON = JSON.stringify(payload); } catch (e) {}
          if (payloadJSON === undefined) { payloadJSON = "null"; }
          post({
            type: "sendUpdate",
            payload: payloadJSON,
            info: update.info ? String(update.info) : null,
            document: update.document ? String(update.document) : null,
            summary: update.summary ? String(update.summary) : null
          });
        },
        setUpdateListener: function (callback, serial) {
          listener = callback;
          // Discard anything buffered before the listener existed: the ready
          // handshake makes the host resend every update newer than `serial`,
          // so replaying the buffer here would deliver duplicates.
          pending = [];
          post({ type: "ready", serial: serial || 0 });
          return Promise.resolve();
        },
        sendToChat: function (message) {
          message = message || {};
          var text = message.text ? String(message.text) : "";
          if (message.file && message.file.plainText) {
            text = text ? text + "\\n" + message.file.plainText : message.file.plainText;
          }
          post({ type: "sendToChat", text: text });
          return Promise.resolve();
        },
        importFiles: function (filter) {
          if (!\(settings.webxdcAllowFileImport ? "true" : "false")) {
            return Promise.resolve([]);
          }
          return Promise.resolve([]);
        },
        joinRealtimeChannel: function () {
          if (!\(settings.webxdcAllowRealtimeChannels ? "true" : "false")) {
            throw new Error("realtime channels are disabled in PocketMai");
          }
          throw new Error("realtime channels are not supported in PocketMai");
        }
      };
    })();
    """
  }

  private static func jsString(_ value: String) -> String {
    let data = (try? JSONSerialization.data(
      withJSONObject: value, options: [.fragmentsAllowed]))
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
  }
}

enum WebXDCRuntimePolicy {
  static func script(settings: NativeToolSettings) -> String {
    """
    (function () {
      var policy = {
        gps: \(settings.webxdcAllowGPSLocation ? "true" : "false"),
        motion: \(settings.webxdcAllowMotionSensors ? "true" : "false"),
        wasm: \(settings.webxdcAllowWASM ? "true" : "false"),
        webgl: \(settings.webxdcAllowWebGL ? "true" : "false"),
        canvas2d: \(settings.webxdcAllowCanvas2D ? "true" : "false"),
        audio: \(settings.webxdcAllowAudioPlayback ? "true" : "false"),
        camera: \(settings.webxdcAllowCamera ? "true" : "false"),
        microphone: \(settings.webxdcAllowMicrophone ? "true" : "false"),
        clipboard: \(settings.webxdcAllowClipboard ? "true" : "false"),
        storage: \(settings.webxdcAllowLocalStorage ? "true" : "false"),
        serviceWorkers: \(settings.webxdcAllowServiceWorkers ? "true" : "false"),
        notifications: \(settings.webxdcAllowNotifications ? "true" : "false")
      };
      function denied(name) {
        return new DOMException(name + " is disabled in PocketMai WebXDC settings", "NotAllowedError");
      }
      function hide(object, name) {
        try { Object.defineProperty(object, name, { configurable: true, get: function () { return undefined; } }); } catch (e) {}
      }
      if (!policy.gps && navigator) {
        hide(Navigator.prototype, "geolocation");
        hide(navigator, "geolocation");
      }
      if (!policy.motion) {
        hide(window, "DeviceMotionEvent");
        hide(window, "DeviceOrientationEvent");
        var addEventListener = EventTarget.prototype.addEventListener;
        EventTarget.prototype.addEventListener = function (type, listener, options) {
          if (type === "devicemotion" || type === "deviceorientation" || type === "deviceorientationabsolute") {
            return;
          }
          return addEventListener.call(this, type, listener, options);
        };
      }
      if (!policy.wasm) {
        hide(window, "WebAssembly");
      }
      if ((!policy.webgl || !policy.canvas2d) && window.HTMLCanvasElement) {
        var getContext = HTMLCanvasElement.prototype.getContext;
        HTMLCanvasElement.prototype.getContext = function (type) {
          var kind = String(type || "").toLowerCase();
          if (!policy.webgl && (kind === "webgl" || kind === "experimental-webgl" || kind === "webgl2")) {
            return null;
          }
          if (!policy.canvas2d && kind === "2d") {
            return null;
          }
          return getContext.apply(this, arguments);
        };
      }
      if (!policy.audio) {
        hide(window, "AudioContext");
        hide(window, "webkitAudioContext");
        if (window.HTMLMediaElement) {
          HTMLMediaElement.prototype.play = function () { return Promise.reject(denied("audio playback")); };
        }
      }
      if ((!policy.camera || !policy.microphone) && navigator && navigator.mediaDevices) {
        var mediaDevices = navigator.mediaDevices;
        var getUserMedia = mediaDevices.getUserMedia ? mediaDevices.getUserMedia.bind(mediaDevices) : null;
        mediaDevices.getUserMedia = function (constraints) {
          constraints = constraints || {};
          if ((constraints.video && !policy.camera) || (constraints.audio && !policy.microphone)) {
            return Promise.reject(denied("media capture"));
          }
          return getUserMedia ? getUserMedia(constraints) : Promise.reject(denied("media capture"));
        };
        if (!policy.camera && !policy.microphone) {
          mediaDevices.enumerateDevices = function () { return Promise.resolve([]); };
        }
      }
      if (!policy.clipboard && navigator) {
        hide(Navigator.prototype, "clipboard");
        hide(navigator, "clipboard");
      }
      if (!policy.storage) {
        hide(window, "localStorage");
        hide(window, "sessionStorage");
        hide(window, "indexedDB");
        if (navigator) {
          hide(Navigator.prototype, "storage");
          hide(navigator, "storage");
        }
      }
      if (!policy.serviceWorkers && navigator) {
        hide(Navigator.prototype, "serviceWorker");
        hide(navigator, "serviceWorker");
      }
      if (!policy.notifications) {
        hide(window, "Notification");
      }
    })();
    """
  }
}

// MARK: - Apps panel

struct WebXDCAppsPanel: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  @State private var apps: [WebXDCAppInfo] = []
  @State private var showingImporter = false
  @State private var pendingDelete: WebXDCAppInfo?
  @State private var errorMessage: String?

  var body: some View {
    NavigationStack {
      List {
        if apps.isEmpty {
          Text(
            "No apps yet. Enable the WebXDC Apps tool in a chat and ask the assistant to create one, or import a .xdc file."
          )
          .foregroundStyle(.secondary)
        }
        ForEach(apps) { app in
          NavigationLink(value: app.id) {
            appRow(app)
          }
          .contextMenu {
            Button(role: .destructive) {
              pendingDelete = app
            } label: {
              Label("Delete App", systemImage: "trash")
            }
          }
        }
      }
      .navigationTitle("Apps")
      .navigationBarTitleDisplayMode(.inline)
      .navigationDestination(for: UUID.self) { id in
        WebXDCAppDetailView(appID: id) { reload() }
      }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button {
            showingImporter = true
          } label: {
            Label("Import", systemImage: "square.and.arrow.down")
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
      .fileImporter(
        isPresented: $showingImporter,
        allowedContentTypes: importTypes
      ) { result in
        if case .success(let url) = result {
          importApp(from: url)
        }
      }
      .alert(
        "Delete app?", isPresented: deleteConfirmationBinding, presenting: pendingDelete
      ) { app in
        Button("Cancel", role: .cancel) { pendingDelete = nil }
        Button("Delete", role: .destructive) {
          try? WebXDCLibrary.deleteApp(id: app.id)
          pendingDelete = nil
          reload()
        }
      } message: { app in
        Text("'\(app.name)' and all of its revisions will be removed. This cannot be undone.")
      }
      .alert(
        "Import failed", isPresented: errorBinding
      ) {
        Button("OK") { errorMessage = nil }
      } message: {
        Text(errorMessage ?? "")
      }
      .onAppear { reload() }
    }
  }

  private var importTypes: [UTType] {
    var types: [UTType] = [.zip]
    if let xdc = UTType(filenameExtension: "xdc") {
      types.insert(xdc, at: 0)
    }
    return types
  }

  private var deleteConfirmationBinding: Binding<Bool> {
    Binding(
      get: { pendingDelete != nil },
      set: { if !$0 { pendingDelete = nil } })
  }

  private var errorBinding: Binding<Bool> {
    Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } })
  }

  private func appRow(_ app: WebXDCAppInfo) -> some View {
    HStack(spacing: 12) {
      WebXDCAppIcon(app: app)
      VStack(alignment: .leading, spacing: 2) {
        Text(app.name)
          .font(.body.weight(.medium))
        Text(
          app.appDescription.isEmpty
            ? "\(app.revisions.count) revision\(app.revisions.count == 1 ? "" : "s")"
            : app.appDescription
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
      }
    }
  }

  private func reload() {
    apps = WebXDCLibrary.listApps()
  }

  private func importApp(from url: URL) {
    let accessing = url.startAccessingSecurityScopedResource()
    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
    do {
      let fallback = url.deletingPathExtension().lastPathComponent
      _ = try WebXDCLibrary.importXDC(from: url, fallbackName: fallback)
      reload()
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

struct WebXDCAppIcon: View {
  let app: WebXDCAppInfo
  var size: CGFloat = 40

  var body: some View {
    Group {
      if let data = WebXDCLibrary.iconData(app), let image = UIImage(data: data) {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
      } else {
        Image(systemName: "square.grid.2x2")
          .foregroundStyle(.secondary)
      }
    }
    .frame(width: size, height: size)
    .background(Color.secondary.opacity(0.12))
    .clipShape(RoundedRectangle(cornerRadius: size / 5, style: .continuous))
  }
}

private struct WebXDCEditingFile: Identifiable {
  let path: String
  let text: String

  var id: String { path }
}

struct WebXDCAppDetailView: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss

  let appID: UUID
  let onChange: () -> Void

  @State private var app: WebXDCAppInfo?
  @State private var files: [String] = []
  @State private var draftName = ""
  @State private var draftDescription = ""
  @State private var editingFile: WebXDCEditingFile?
  @State private var newFilePath = ""
  @State private var shareURL: URL?
  @State private var runningSession: WebXDCRunningSession?
  @State private var showingIconImporter = false
  @State private var showingDeleteConfirmation = false
  @State private var showingDeleteOtherRevisionsConfirmation = false
  @State private var errorMessage: String?

  init(appID: UUID, onChange: @escaping () -> Void = {}) {
    self.appID = appID
    self.onChange = onChange
  }

  var body: some View {
    Form {
      if let app {
        appSection(app)
        revisionSection(app)
        filesSection(app)
        actionsSection(app)
      } else {
        Text("This app is gone.")
          .foregroundStyle(.secondary)
      }
    }
    .navigationTitle(app?.name ?? "App")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear { reload() }
    .sheet(item: $editingFile) { file in
      MessageTextSelectionSheet(
        title: file.path,
        text: file.text,
        initialFontSize: 13,
        initialLineSpacing: 2,
        fontFamily: .monospaced,
        isEditable: true,
        onSave: { newText in
          saveFile(path: file.path, text: newText)
        })
    }
    .fullScreenCover(item: $runningSession) { session in
      WebXDCRunnerSheet(session: session)
        .environmentObject(store)
    }
    .sheet(isPresented: shareBinding) {
      if let shareURL {
        ActivityShareSheet(activityItems: [shareURL])
      }
    }
    .fileImporter(
      isPresented: $showingIconImporter,
      allowedContentTypes: [.png, .jpeg, .image]
    ) { result in
      if case .success(let url) = result {
        importIcon(from: url)
      }
    }
    .alert("Delete app?", isPresented: $showingDeleteConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Delete", role: .destructive) { deleteApp() }
    } message: {
      Text("All revisions will be removed. This cannot be undone.")
    }
    .alert("Delete other revisions?", isPresented: $showingDeleteOtherRevisionsConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Delete Others", role: .destructive) {
        if let app {
          deleteOtherRevisions(app)
        }
      }
    } message: {
      Text("Only the selected revision will remain, and it will become revision 1.")
    }
    .alert("Something went wrong", isPresented: errorBinding) {
      Button("OK") { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "")
    }
  }

  private var shareBinding: Binding<Bool> {
    Binding(
      get: { shareURL != nil },
      set: { if !$0 { shareURL = nil } })
  }

  private var errorBinding: Binding<Bool> {
    Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } })
  }

  @ViewBuilder
  private func appSection(_ app: WebXDCAppInfo) -> some View {
    Section("App") {
      HStack(alignment: .top, spacing: 12) {
        Button {
          showingIconImporter = true
        } label: {
          WebXDCAppIcon(app: app, size: 56)
        }
        .buttonStyle(.borderless)
        VStack(alignment: .leading, spacing: 6) {
          TextField("Name", text: $draftName)
            .font(.body.weight(.medium))
            .onSubmit { saveMetadata() }
          TextField("Description", text: $draftDescription, axis: .vertical)
            .font(.caption)
            .onSubmit { saveMetadata() }
        }
        Spacer(minLength: 8)
        runAppButton(app)
      }
      if draftName != app.name || draftDescription != app.appDescription {
        Button("Save Details") { saveMetadata() }
      }
      Text("Tap the icon to set a new one (PNG or JPEG, square, 128-512 px).")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private func revisionSection(_ app: WebXDCAppInfo) -> some View {
    Section("Revision") {
      Picker("Revision", selection: revisionBinding(app)) {
        ForEach(app.revisions.sorted { $0.number > $1.number }) { revision in
          Text("\(revision.number) — \(formatted(revision.date)) (\(revision.note))")
            .tag(revision.number)
        }
      }
      if app.revisions.count > 1 {
        Button(role: .destructive) {
          deleteCurrentRevision(app)
        } label: {
          Label("Delete Revision \(app.currentRevision)", systemImage: "clock.arrow.circlepath")
        }
        Button(role: .destructive) {
          showingDeleteOtherRevisionsConfirmation = true
        } label: {
          Label("Delete Other Revisions", systemImage: "trash")
        }
      }
    }
  }

  @ViewBuilder
  private func filesSection(_ app: WebXDCAppInfo) -> some View {
    Section("Files") {
      ForEach(files, id: \.self) { path in
        Button {
          openFile(path)
        } label: {
          HStack {
            Image(systemName: iconName(for: path))
              .foregroundStyle(.secondary)
              .frame(width: 20)
            Text(path)
              .foregroundStyle(.primary)
            Spacer()
            Text(fileSizeText(app, path: path))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .swipeActions {
          Button(role: .destructive) {
            deleteFile(path)
          } label: {
            Label("Delete", systemImage: "trash")
          }
        }
      }
      HStack {
        TextField("New file, e.g. style.css", text: $newFilePath)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .onSubmit { addFile() }
        Button {
          addFile()
        } label: {
          Image(systemName: "plus.circle.fill")
        }
        .buttonStyle(.borderless)
      }
      Text("Editing a file snapshots the app into a new revision first.")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private func actionsSection(_ app: WebXDCAppInfo) -> some View {
    Section {
      Button {
        exportApp(app)
      } label: {
        Label("Export .xdc", systemImage: "square.and.arrow.up")
      }
      Button(role: .destructive) {
        showingDeleteConfirmation = true
      } label: {
        Label("Delete App", systemImage: "trash")
      }
    } footer: {
      Text("Exported .xdc files can be shared and used in Delta Chat or another PocketMai.")
    }
  }

  private func runAppButton(_ app: WebXDCAppInfo) -> some View {
    Button {
      runningSession = store.startWebXDCSession(app: app)
    } label: {
      Text("RUN")
        .font(.caption.weight(.bold))
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
        .background(Color.blue, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Run app")
  }

  private func revisionBinding(_ app: WebXDCAppInfo) -> Binding<Int> {
    Binding(
      get: { app.currentRevision },
      set: { revision in
        do {
          _ = try WebXDCLibrary.selectRevision(app, revision: revision)
          reload()
        } catch {
          errorMessage = error.localizedDescription
        }
      })
  }

  private func reload() {
    app = WebXDCLibrary.app(id: appID)
    if let app {
      files = WebXDCLibrary.listFiles(app)
      draftName = app.name
      draftDescription = app.appDescription
    } else {
      files = []
    }
    onChange()
  }

  private func saveMetadata() {
    guard var app else { return }
    let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    app.name = name
    app.appDescription = draftDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    do {
      try WebXDCLibrary.save(app)
      reload()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func openFile(_ path: String) {
    guard let app else { return }
    do {
      let data = try WebXDCLibrary.readFile(app, path: path)
      if data.prefix(4096).contains(0) {
        errorMessage = "'\(path)' is a binary file and cannot be edited as text."
        return
      }
      guard let text = String(data: data, encoding: .utf8) else {
        errorMessage = "'\(path)' is not valid UTF-8 text."
        return
      }
      editingFile = WebXDCEditingFile(path: path, text: text)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func saveFile(path: String, text: String) {
    guard let app else { return }
    do {
      _ = try WebXDCLibrary.writeFile(app, path: path, data: Data(text.utf8))
      reload()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func addFile() {
    guard let app else { return }
    let path = newFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else { return }
    do {
      _ = try WebXDCLibrary.writeFile(app, path: path, data: Data())
      newFilePath = ""
      reload()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func deleteFile(_ path: String) {
    guard let app else { return }
    do {
      _ = try WebXDCLibrary.deleteFile(app, path: path)
      reload()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func deleteCurrentRevision(_ app: WebXDCAppInfo) {
    do {
      _ = try WebXDCLibrary.deleteRevision(app, revision: app.currentRevision)
      reload()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func deleteOtherRevisions(_ app: WebXDCAppInfo) {
    do {
      _ = try WebXDCLibrary.deleteOtherRevisions(app, keeping: app.currentRevision)
      reload()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func exportApp(_ app: WebXDCAppInfo) {
    do {
      shareURL = try WebXDCLibrary.exportXDC(app)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func importIcon(from url: URL) {
    guard let app else { return }
    let accessing = url.startAccessingSecurityScopedResource()
    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
    guard let data = try? Data(contentsOf: url), let image = UIImage(data: data),
      let png = image.pngData()
    else {
      errorMessage = "Could not read the image."
      return
    }
    do {
      try WebXDCLibrary.writeFileInPlace(app, path: "icon.png", data: png)
      let jpgURL = WebXDCLibrary.currentRevisionURL(app).appendingPathComponent("icon.jpg")
      try? FileManager.default.removeItem(at: jpgURL)
      reload()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func deleteApp() {
    do {
      try WebXDCLibrary.deleteApp(id: appID)
      onChange()
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func iconName(for path: String) -> String {
    switch (path as NSString).pathExtension.lowercased() {
    case "html", "htm": return "chevron.left.forwardslash.chevron.right"
    case "css": return "paintbrush"
    case "js", "mjs": return "curlybraces"
    case "png", "jpg", "jpeg", "gif", "webp", "svg": return "photo"
    case "toml", "json": return "doc.badge.gearshape"
    default: return "doc"
    }
  }

  private func fileSizeText(_ app: WebXDCAppInfo, path: String) -> String {
    let url = WebXDCLibrary.currentRevisionURL(app).appendingPathComponent(path)
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
    guard let size else { return "" }
    return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
  }

  private func formatted(_ date: Date) -> String {
    date.formatted(date: .abbreviated, time: .shortened)
  }
}

// MARK: - Chat launcher

struct WebXDCAppLauncherSheet: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss

  let onLaunch: (WebXDCAppInfo) -> Void

  @State private var apps: [WebXDCAppInfo] = []

  var body: some View {
    NavigationStack {
      List {
        if apps.isEmpty {
          Text(
            "No apps available. Enable the WebXDC Apps tool and ask the assistant to create one, or import a .xdc from Apps in the folders menu."
          )
          .foregroundStyle(.secondary)
        }
        ForEach(apps) { app in
          Button {
            dismiss()
            onLaunch(app)
          } label: {
            HStack(spacing: 12) {
              WebXDCAppIcon(app: app)
              VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                  .foregroundStyle(.primary)
                if !app.appDescription.isEmpty {
                  Text(app.appDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                }
              }
            }
          }
        }
      }
      .navigationTitle("Start App")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
      .onAppear { apps = WebXDCLibrary.listApps() }
    }
  }
}
