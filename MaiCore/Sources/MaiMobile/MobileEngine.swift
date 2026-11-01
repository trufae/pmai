import Foundation
import MaiACP
import MaiChat
import MaiCore
import MaiOpenAI
import MaiDocuments
import Observation

/// UI-independent mobile application facade. JSON is a snapshot of app data,
/// never a view tree. All provider requests and persistence remain in MaiChat.
@MainActor public final class MobileEngine {
  let chat: PortableChat
  private let remote: RemoteState
  private let tools: MobileTools
  private let folders: ConversationFolders
  private let directory: URL
  private let update: (String) -> Void
  private let makeProvider: @Sendable (ConfiguredProvider) throws -> any ChatProvider
  private var catalogRequested = false
  private var webTasks: [String: Task<Void, Never>] = [:]

  public init(directory: URL, clientName: String = "PocketMai", update: @escaping (String) -> Void,
    makeProvider: @escaping @Sendable (ConfiguredProvider) throws -> any ChatProvider = {
      try OpenAIConfiguredProviderFactory().makeProvider(from: $0, environment: [:])
    }
  ) throws {
    self.directory = directory
    self.makeProvider = makeProvider
    folders = try ConversationFolders(directory: directory)
    let tools = try MobileTools(directory: directory)
    self.tools = tools
    chat = try PortableChat(directory: directory, makeProvider: makeProvider,
      runTurn: { request, provider, emit in try await tools.run(request, provider: provider, emit: emit) })
    remote = try RemoteState(directory: directory.appendingPathComponent("remotes"), clientName: clientName)
    self.update = update
  }

  public func configureRemote(identity: Data?) { remote.configure(identity: identity) }

  /// Kotlin checks the per-app permission before entering this API. Keys never
  /// cross into JavaScript; requests use the shared configured provider.
  public func webRequest(_ json: String, reply: @escaping (String) -> Void) {
    guard let request = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
      let id = request["id"] as? String, id.count <= 100,
      let method = request["method"] as? String else { return }
    if method == "cancel" { webTasks[id]?.cancel(); return }
    guard webTasks[id] == nil else { return }
    let emitter = WebReplyEmitter(reply)
    func emit(_ object: [String: Any]) { emitter.send(object) }
    guard webTasks.count < 8 else {
      emit(["id": id, "error": ["code": "BusyError", "message": "At most eight requests may run at once."]])
      return
    }
    webTasks[id] = Task { @MainActor in
      defer { webTasks[id] = nil }
      do {
        let options = request["options"] as? [String: Any] ?? [:]
        let providerID = options["provider"] as? String ?? chat.selectedProviderID
        guard var configuration = chat.providers.first(where: {
          $0.id == (providerID == "configured" ? chat.selectedProviderID : providerID)
        }) else { throw PortableChatError.providerUnavailable }
        if configuration.id == chat.selectedProviderID { configuration.defaultModel = chat.model }
        let provider = try makeProvider(configuration)
        let result: Any
        switch method {
        case "providers":
          result = chat.providers.map { ["id": $0.id, "name": $0.displayName ?? $0.id,
            "available": true, "capabilities": ["inference"]] as [String: Any] }
        case "models": result = try await provider.availableModels().map(\.id)
        case "complete":
          guard (options["scope"] as? String ?? "isolated") == "isolated" else {
            throw JSONRPCError.invalidParams("This Android host currently supports isolated inference")
          }
          let system = options["systemPrompt"] as? String ?? "You are a helpful assistant."
          guard let messages = options["messages"] as? [[String: String]],
            (1...200).contains(messages.count), system.utf8.count <= 64000,
            messages.reduce(0, { $0 + ($1["content"]?.utf8.count ?? 0) }) <= 256000 else {
            throw JSONRPCError.invalidParams("Supply 1–200 messages, up to 256 KB")
          }
          let input: [AgentMessage] = try messages.map {
            guard let content = $0["content"] else { throw CocoaError(.coderInvalidValue) }
            switch $0["role"] {
            case "user": return .user(content)
            case "assistant": return .assistant(content)
            default: throw CocoaError(.coderInvalidValue)
            }
          }
          let model = options["model"] as? String ?? configuration.defaultModel ?? ""
          guard !model.isEmpty else { throw PortableChatError.missingModel }
          let text = WebReplyText()
          let response = try await provider.complete(ProviderRequest(model: model,
            messages: [.system(system)] + input, toolChoice: .none)) { event in
              if case .textDelta(let delta) = event {
                let value = await text.append(delta)
                await emitter.text(id: id, value: value)
              }
          }
          result = ["text": response.message.text]
        default: throw JSONRPCError.invalidParams("Unsupported PocketMai method")
        }
        try Task.checkCancellation()
        emit(["id": id, "result": result])
      } catch {
        emit(["id": id, "error": ["code": error is CancellationError ? "AbortError" : "OperationError",
          "message": error.localizedDescription]])
      }
    }
  }

  public func observe() {
    if !catalogRequested {
      catalogRequested = true
      Task { await tools.loadCatalog() }
    }
    let snapshot = withObservationTracking {
      snapshotJSON()
    } onChange: { [weak self] in
      Task { @MainActor in self?.observe() }
    }
    update(snapshot)
  }

  public func execute(_ json: String) {
    do {
      let command = try JSONDecoder().decode([String: String].self, from: Data(json.utf8))
      func value(_ key: String) -> String { command[key] ?? "" }
      switch value("action") {
      case "toolsEnabled", "toolEnabled", "groupEnabled", "saveMcp", "mcpEnabled", "removeMcp", "saveSkill", "removeSkill":
        guard !chat.isGenerating else { throw PortableChatError.busy }
        try tools.configure(command)
      case "toolApproval": tools.answer(value("id"), choice: value("choice"))
      case "selectFolder", "saveFolder", "removeFolder", "moveChat": try folders.execute(command)
      case "pair": remote.pair(value("invitation"), name: value("name"))
      case "host": remote.selectHost(value("id"))
      case "local": remote.disconnect(); remote.selectedHostID = ""; remote.conversationID = ""
      case "folder": remote.selectFolder(value("cwd"))
      case "remoteOpen": remote.open(value("id"), cwd: value("cwd"))
      case "remoteSend":
        let parts = try importAttachments(value("attachments"))
        var text = value("text")
        for part in parts {
          guard case .file(let file) = part, let body = file.text else {
            throw JSONRPCError.invalidParams("This remote host accepts text documents. Send photos to a local vision-capable model.")
          }
          text += "\n\n<file name=\"\(file.name)\">\n\(body)\n</file>"
        }
        remote.send(text)
      case "remoteStop": remote.stop()
      case "remoteEdit": remote.changeMessage(value("id"), text: value("text"))
      case "remoteDelete": remote.changeMessage(value("id"), text: nil)
      case "remoteRetry": remote.retryMessage(value("id"))
      case "remoteRestart": remote.retryMessage(value("id"), restarting: true)
      case "disconnect": remote.disconnect()
      case "browse": remote.browse(value("path").isEmpty ? "." : value("path"))
      case "downloadXdc": try remote.prepareWorkspace(); remote.workspace.open(value("path"), archive: true)
      case "consumeDownload": try remote.workspace.consumeDownload()
      case "workspaceOpen": try remote.prepareWorkspace(); remote.workspace.show(console: value("kind") == "console")
      case "workspaceDismiss": remote.workspace.hide()
      case "workspaceClose": remote.workspace.close()
      case "filesMore": remote.workspace.more()
      case "filesUp": remote.workspace.up()
      case "filesHidden": remote.workspace.hidden(value("enabled") == "true")
      case "fileOpen": try remote.prepareWorkspace(); remote.workspace.open(value("path"))
      case "fileSave": remote.workspace.save(value("text"))
      case "fileUpload": remote.workspace.upload(value("path"), name: value("name"))
      case "fileMkdir": remote.workspace.mkdir(value("name"))
      case "consoleRun": try remote.prepareWorkspace(); remote.workspace.execute(value("command"))
      case "consoleStop": remote.workspace.stop()
      case "consoleClear": remote.workspace.clear(history: value("history") == "true")
      case "renameHost": try remote.editHost(value("id"), name: value("name"))
      case "pinHost": try remote.editHost(value("id"), name: nil, pin: true)
      case "removeHost": try remote.editHost(value("id"), name: nil, remove: true)
      case "permission": remote.answer(value("option").isEmpty ? nil : value("option"))
      case "remoteOption": remote.setOption(value("id"), value: value("value"))
      case "provider":
        guard !chat.isGenerating, !chat.isLoadingModels else { throw PortableChatError.busy }
        chat.baseURL = value("baseURL")
        chat.apiKey = value("apiKey")
        chat.model = value("model")
        try chat.saveProvider(id: value("id").isEmpty ? nil : value("id"), name: value("name"))
      case "selectProvider": try chat.selectProvider(value("id"))
      case "removeProvider": try chat.removeProvider(value("id"))
      case "models": chat.discoverModels()
      case "model": try chat.chooseModel(value("id"))
      case "prompt":
        try chat.savePrompt(id: UUID(uuidString: value("id")),
          name: value("name"), text: value("text"))
      case "selectPrompt": try chat.selectPrompt(value("id"))
      case "new": try chat.newChat(); try folders.assignNew(chat.chat.id.uuidString)
      case "open":
        guard let id = UUID(uuidString: value("id")) else { throw CocoaError(.coderInvalidValue) }
        try chat.openChat(id)
      case "send":
        guard !chat.isGenerating, !chat.isLoadingModels else { throw PortableChatError.busy }
        guard !chat.model.isEmpty else { throw PortableChatError.missingModel }
        let parts = try importAttachments(value("attachments"))
        chat.draft = value("text")
        chat.sendDraft(attachments: parts)
      case "editMessage": try chat.editMessage(value("id"), text: value("text"))
      case "deleteMessage": try chat.deleteMessage(value("id"))
      case "retryMessage": try chat.retryMessage(value("id"))
      case "restartMessage": try chat.retryMessage(value("id"), restarting: true)
      case "stop": chat.stop(); tools.cancelApprovals()
      case "dismissError": chat.errorMessage = nil; remote.error = ""; tools.error = ""
      default: throw CocoaError(.coderInvalidValue)
      }
    } catch { chat.errorMessage = error.localizedDescription }
  }

  public func snapshotJSON() -> String {
    let snapshot: [String: Any] = [
      "ready": true,
      "baseURL": chat.baseURL, "apiKey": chat.apiKey, "model": chat.model,
      "chatID": chat.chat.id.uuidString, "title": chat.chat.displayTitle,
      "isGenerating": chat.isGenerating, "isLoadingModels": chat.isLoadingModels,
      "streamedText": chat.streamedText, "streamedReasoning": chat.streamedReasoning,
      "error": chat.errorMessage ?? "", "status": chat.status,
      "selectedPromptID": chat.selectedPromptID,
      "selectedProviderID": chat.selectedProviderID,
      "providers": chat.providers.map { ["id": $0.id, "name": $0.displayName ?? $0.id,
        "baseURL": $0.baseURL?.absoluteString ?? "", "apiKey": $0.apiKey ?? "", "model": $0.defaultModel ?? ""] },
      "organization": folders.snapshot,
      "remote": remote.snapshot,
      "agent": tools.snapshot,
      "models": chat.models.map { ["id": $0.id] },
      "prompts": chat.prompts.map {
        ["id": $0.id.uuidString, "name": $0.name, "text": $0.text]
      },
      "messages": chat.messages.map { message -> [String: Any] in
        let calls = message.toolCalls.map { $0.name + "\n" + $0.arguments.compactJSONString }
        let results = message.toolResults.map(\.text)
        let text = message.content.compactMap { part -> String? in
          if case .text(let value) = part { return value }; return nil
        }.joined(separator: "\n")
        return ["id": message.id, "role": calls.isEmpty && results.isEmpty ? message.role.rawValue : "tool",
          "text": ([text] + calls + results).filter { !$0.isEmpty }.joined(separator: "\n\n"),
          "attachments": attachmentSummaries(message)]
      },
      "chats": chat.chats.map {
        ["id": $0.id.uuidString, "title": $0.displayTitle,
          "model": $0.primaryAgent.model, "updatedAt": $0.updatedAt.timeIntervalSince1970,
          "folderID": folders.folder(for: $0.id.uuidString)]
      },
    ]
    do {
      return String(decoding: try JSONSerialization.data(withJSONObject: snapshot), as: UTF8.self)
    } catch {
      // All values above are JSON primitives; still surface a serialization failure.
      return "{\"ready\":false,\"error\":\"Cannot encode application state\"}"
    }
  }

  private func importAttachments(_ json: String) throws -> [ContentPart] {
    guard !json.isEmpty else { return [] }
    let attachments = try JSONDecoder().decode([[String: String]].self, from: Data(json.utf8))
    guard attachments.count <= 12 else { throw CocoaError(.fileReadTooLarge) }
    let root = directory.appendingPathComponent("incoming").resolvingSymlinksInPath().path + "/"
    return try attachments.map { entry in
      let url = URL(fileURLWithPath: entry["path"] ?? "").resolvingSymlinksInPath()
      guard url.path.hasPrefix(root),
        (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 25_000_000 else {
        throw CocoaError(.fileReadNoPermission)
      }
      let data = try Data(contentsOf: url)
      let name = entry["name"] ?? url.lastPathComponent
      let mime = entry["mime"] ?? "application/octet-stream"
      if mime.hasPrefix("image/") { return .image(.init(source: .data(data), mimeType: mime, name: name)) }
      return try DocumentAttachmentImporter.attachment(data: data, filename: name, mimeType: mime).content
    }
  }

  private func attachmentSummaries(_ message: AgentMessage) -> [[String: String]] {
    message.content.enumerated().compactMap { index, part in
      switch part {
      case .file(let file): return ["name": file.name, "mime": file.mimeType, "path": ""]
      case .image(let image):
        let root = directory.appendingPathComponent("previews")
        let safeID = String(Data(message.id.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_").prefix(80))
        let file = root.appendingPathComponent("\(safeID)-\(index).image")
        if !FileManager.default.fileExists(atPath: file.path), case .data(let data) = image.source {
          do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); try data.write(to: file, options: .atomic) }
          catch { return ["name": image.name ?? "Photo", "mime": image.mimeType, "path": ""] }
        }
        return ["name": image.name ?? "Photo", "mime": image.mimeType, "path": file.path]
      default: return nil
      }
    }
  }
}

private actor WebReplyText {
  private var value = ""
  func append(_ text: String) -> String { value += text; return value }
}

@MainActor private final class WebReplyEmitter {
  let reply: (String) -> Void
  init(_ reply: @escaping (String) -> Void) { self.reply = reply }
  func send(_ object: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: object) {
      reply(String(decoding: data, as: UTF8.self))
    }
  }
  func text(id: String, value: String) { send(["id": id, "event": "text", "text": value]) }
}
