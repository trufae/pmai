import Foundation
import MaiCore
import MaiTestSupport
import Testing

@testable import MaiACP

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Test("ACP provider commands resolve adapters and validate remote options")
func acpProviderCommands() throws {
  #expect(ACPClient.Configuration(command: "claude-agent-acp").promptTimeout == nil)
  let opencode = try ACPProviderCommand.configuration(["opencode"])
  #expect(opencode.kind == "acp" && opencode.defaultModel == "opencode")
  #expect(opencode.options["args"] == .array([.string("acp")]))
  #expect(
    try ACPProviderCommand.configuration(["claude"]).options["command"]
      == .string("claude-agent-acp"))
  #expect(
    try ACPProviderCommand.configuration(["codex"]).options["command"] == .string("codex-acp"))
  let custom = try ACPProviderCommand.configuration(["worker", "ssh", "host", "codex-acp"])
  #expect(custom.options["args"] == .array([.string("host"), .string("codex-acp")]))
  let remote = try ACPProviderCommand.configuration([
    "remote", "--url", "wss://example.com/acp", "--cwd", "/work", "--token-env", "ACP_TOKEN",
  ])
  #expect(remote.options["tokenEnv"] == .string("ACP_TOKEN"))
  for fields in [
    [], ["unknown"], ["remote", "--url", "https://example.com", "--cwd", "/work"],
    ["remote", "--url", "wss://example.com/acp"], ["remote", "--url"],
  ] {
    #expect(throws: (any Error).self) { try ACPProviderCommand.configuration(fields) }
  }
}

#if os(macOS) || os(Linux)
  private let providerAgentScript = #"""
    import json, os, pathlib, sys, urllib.request
    adapter = sys.argv[1]
    legacy = adapter == 'legacy'
    model = 'small'
    effort = 'default' if adapter == 'claude' else 'medium'
    turn = 0
    bridge = None
    session_method = None
    native_prompt = None
    codex_config = json.loads(os.environ.get('CODEX_CONFIG', '{}'))
    prompt_file = codex_config.get('model_instructions_file')
    if prompt_file: native_prompt = pathlib.Path(prompt_file).read_text()
    def option():
        return {'id':'model-choice', 'category':'model', 'name':'Model', 'type':'select',
                'currentValue':model, 'options':[{'value':i,'name':i.title()} for i in ['small','large']]}
    def options():
        levels = ['low','medium','high']
        if adapter == 'claude': levels = ['default'] + levels + (['max'] if model == 'large' else [])
        else: levels = ['none'] + levels + (['xhigh'] if model == 'large' else [])
        return [option(), {'id':'effort' if adapter == 'claude' else 'reasoning_effort',
                'category':'thought_level', 'name':'Effort', 'type':'select',
                'currentValue':effort, 'options':[{'value':i,'name':i.title()} for i in levels]}]
    def send(value):
        print(json.dumps(value), flush=True)
    def rpc(method, params):
        req = urllib.request.Request(bridge, json.dumps({'jsonrpc':'2.0','id':1,'method':method,'params':params}).encode(),
                                     headers={'Content-Type':'application/json'})
        with urllib.request.urlopen(req, timeout=5) as response:
            result = json.load(response)
        if 'error' in result: raise Exception(result['error']['message'])
        return result['result']
    def update(kind, **fields):
        send({'jsonrpc':'2.0','method':'session/update','params':{'sessionId':'s','update':{'sessionUpdate':kind, **fields}}})
    for line in sys.stdin:
        req = json.loads(line)
        method, params = req.get('method'), req.get('params',{})
        if method == 'initialize':
            result = {'protocolVersion':1,'agentCapabilities':{'mcpCapabilities':{'http':True}}}
            if adapter == 'claude': result['agentCapabilities']['loadSession'] = True
            if adapter == 'claude': result['agentCapabilities']['sessionCapabilities'] = {'systemPrompt': {'mode': {'override': {}}}}
        elif method in ('session/new', 'session/load'):
            session_method = method
            if 'systemPrompt' in params:
                assert params['systemPrompt']['mode'] == 'override'
                native_prompt = '\n\n'.join(b['text'] for b in params['systemPrompt']['content'])
            bridge = next((s['url'] for s in params['mcpServers'] if s['name']=='pmai'),None)
            if bridge: rpc('initialize',{})
            result = {'sessionId':'s'}
            if legacy: result['models'] = {'currentModelId':model,'availableModels':[{'modelId':i,'name':i.title()} for i in ['small','large']]}
            else: result['configOptions'] = options()
        elif method == 'session/set_model':
            model = params['modelId']
            result = {}
        elif method == 'session/set_config_option':
            if params['configId'] == 'model-choice':
                model = params['value']
                if effort not in [o['value'] for o in options()[1]['options']]:
                    effort = 'default' if adapter == 'claude' else 'medium'
            else:
                assert params['configId'] == ('effort' if adapter == 'claude' else 'reasoning_effort')
                assert params['value'] in [o['value'] for o in options()[1]['options']]
                effort = params['value']
            result = {'configOptions':options()}
        elif method == 'session/prompt':
            turn += 1
            text = params['prompt'][0]['text']
            if 'FAIL_PROMPT' in text:
                send({'jsonrpc':'2.0','id':req['id'],'error':{'code':-32603,'message':'failed after side effect'}})
                continue
            if 'HANG_PROMPT' in text:
                continue
            native = {'toolCallId':'native','title':'Starting search',
                      'rawInput':{'query':'needle'} if legacy else {},'status':'in_progress'}
            if not legacy: native['name'] = 'native_search'
            update('tool_call', **native)
            if legacy:
                update('tool_call_update', toolCallId='native', title='Search for needle')
            else:
                update('tool_call_update', toolCallId='native', rawInput={'partial':True})
                update('tool_call_update', toolCallId='native', title='Search for needle', rawInput={'query':'needle'})
            update('tool_call_update', toolCallId='native', status='completed', content=[{'type':'content','content':{'type':'text','text':'native result'}}])
            tool_result = None
            if bridge:
                tools = rpc('tools/list',{})['tools']
                if tools:
                    name = tools[0]['name']
                    tool_result = rpc('tools/call',{'name':name,'arguments':{}})
                    if 'TWICE' in text: tool_result = rpc('tools/call',{'name':name,'arguments':{}})
            update('agent_thought_chunk', content={'type':'text','text':'thinking'})
            answer = json.dumps({'model':model,'effort':effort,'turn':turn,'prompt':text,'tool':tool_result,
                                 'sessionMethod':session_method,'systemPrompt':native_prompt,
                                 'codexConfig':codex_config,'promptFile':prompt_file})
            update('agent_message_chunk', content={'type':'text','text':answer})
            result = {'stopReason':'end_turn'}
        else:
            continue
        if 'id' in req: send({'jsonrpc':'2.0','id':req['id'],'result':result})
    """#

  private func providerFixture(
    legacy: Bool = false, adapter: String = "codex", replaceContext: Bool = false,
    replacePrompt: Bool = false, sessionFile: URL? = nil
  ) throws -> ACPProvider {
    var options: [String: JSONValue] = [
      "command": .string("/usr/bin/env"),
      "args": .array(
        ["python3", "-u", "-c", providerAgentScript, legacy ? "legacy" : adapter].map(
          JSONValue.string)),
      "context": .string(replaceContext ? "replace" : "agent"),
      "prompt": .string(replacePrompt ? "replace" : "agent"),
    ]
    if let sessionFile { options["sessionFile"] = .string(sessionFile.path) }
    var environment = ProcessInfo.processInfo.environment
    environment["CODEX_CONFIG"] = "{\"developer_instructions\":\"Preserve native configuration\"}"
    return try #require(
      ACPConfiguredProviderFactory().makeProvider(
        from: .init(id: "test-acp", kind: "acp", displayName: "Fixture", options: options),
        environment: environment) as? ACPProvider)
  }

  @Test("ACP context replacement honors assistant deletion and bypasses stored sessions")
  func acpReplacedContext() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "acp-context-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let sessionFile = directory.appendingPathComponent("sessions.json")
    let key = AgentExecutionScope.directory.standardizedFileURL.path + "\u{0}default"
    try ACPStateFiles.write([key: "stale-session"], to: sessionFile)
    let provider = try providerFixture(
      adapter: "claude", replaceContext: true, sessionFile: sessionFile)
    let user = AgentMessage.user("original task")
    let reply = AgentMessage.assistant("obsolete assistant evidence")
    let tool = AgentMessage(
      role: .tool,
      content: [
        .toolResult(
          .init(
            callID: "historical", content: [.text("obsolete tool evidence")],
            structuredContent: .object(["result": .string("structured evidence")])))
      ])
    let first = try await provider.complete(
      .init(model: "large", messages: [user, reply, tool, .user("continue")]))
    #expect(first.message.text.contains("obsolete assistant evidence"))
    #expect(first.message.text.contains("obsolete tool evidence"))
    #expect(first.message.text.contains("structured evidence"))
    // The user-text prefix is unchanged; only assistant/tool evidence was removed.
    let second = try await provider.complete(
      .init(model: "large", messages: [user, .user("continue"), .user("next")]))
    let value = try JSONDecoder().decode(JSONValue.self, from: Data(second.message.text.utf8))
    #expect(value.objectValue?["turn"] == .integer(1))
    #expect(value.objectValue?["sessionMethod"] == .string("session/new"))
    let prompt = try #require(value.objectValue?["prompt"]?.stringValue)
    #expect(
      prompt.contains("original task") && prompt.contains("continue") && prompt.contains("next"))
    #expect(!prompt.contains("obsolete assistant evidence"))
    #expect(!prompt.contains("obsolete tool evidence"))
    #expect(try JSONDecoder().decode([String: String].self, from: Data(contentsOf: sessionFile)) == [key: "stale-session"])
    await provider.shutdown()
  }

  @Test(
    "ACP native prompt replacement updates Claude and local Codex without losing pmai history",
    arguments: ["claude", "codex-acp"])
  func acpReplacedPrompt(adapter: String) async throws {
    let provider = try providerFixture(adapter: adapter, replacePrompt: true)
    let user = AgentMessage.user("task")
    let first = try await provider.complete(
      .init(model: "large", messages: [.system("Original native instructions"), user]))
    let initial = try JSONDecoder().decode(JSONValue.self, from: Data(first.message.text.utf8))
    #expect(initial.objectValue?["systemPrompt"] == .string("Original native instructions"))
    #expect(
      initial.objectValue?["prompt"]?.stringValue?.contains("Original native instructions") == false
    )
    let followup = try await provider.complete(
      .init(
        model: "large",
        messages: [
          .system("Original native instructions"), user, .assistant("retained answer"),
          .user("follow up"),
        ]))
    let next = try JSONDecoder().decode(JSONValue.self, from: Data(followup.message.text.utf8))
    #expect(next.objectValue?["turn"] == .integer(2))
    let changed = try await provider.complete(
      .init(
        model: "large",
        messages: [
          .system("Updated native instructions"), user, .assistant("retained answer"),
          .user("follow up"), .user("continue"),
        ]))
    let updated = try JSONDecoder().decode(JSONValue.self, from: Data(changed.message.text.utf8))
    #expect(updated.objectValue?["turn"] == .integer(1))
    #expect(updated.objectValue?["systemPrompt"] == .string("Updated native instructions"))
    #expect(updated.objectValue?["prompt"]?.stringValue?.contains("retained answer") == true)
    if adapter == "codex-acp" {
      #expect(
        updated.objectValue?["codexConfig"]?.objectValue?["developer_instructions"]
          == .string("Preserve native configuration"))
      let oldPath = try #require(initial.objectValue?["promptFile"]?.stringValue)
      #expect(!FileManager.default.fileExists(atPath: oldPath))
      let path = try #require(updated.objectValue?["promptFile"]?.stringValue)
      #expect(try String(contentsOfFile: path, encoding: .utf8) == "Updated native instructions")
      await provider.shutdown()
      #expect(!FileManager.default.fileExists(atPath: path))
    } else {
      await provider.shutdown()
    }
  }

  @Test("ACP refuses unsupported native prompt replacement")
  func acpUnsupportedPromptReplacement() async throws {
    let provider = try providerFixture(replacePrompt: true)
    do {
      _ = try await provider.complete(
        .init(model: "large", messages: [.system("instructions"), .user("task")]))
      Issue.record("Unsupported native prompt replacement must fail")
    } catch {
      #expect(error.localizedDescription.contains("does not advertise system prompt override"))
    }
    await provider.shutdown()
  }

  private actor ProviderActivity {
    var started = 0
    var finished = 0
    var text = ""
    var reasoning = ""
    var calls: [String: ToolCall] = [:]
    func event(_ event: ProviderEvent) {
      if case .toolStarted = event { started += 1 }
      switch event {
      case .toolStarted(let call), .toolUpdated(let call): calls[call.id] = call
      default: break
      }
      if case .toolFinished = event { finished += 1 }
      if case .textDelta(let delta) = event { text += delta }
      if case .reasoningDelta(let delta) = event { reasoning += delta }
    }
  }

  @Test(
    "An ACP primary exposes its answer when also assigned as the tool model",
    arguments: [ToolCallingStrategy.automatic, .xml])
  func acpPrimaryToolAssignment(strategy: ToolCallingStrategy) async throws {
    let provider = try providerFixture()
    let runtime = AgentRuntime()
    try await runtime.register(provider)
    try await runtime.register(
      agent: AgentDefinition(id: "tool", provider: "test-acp", model: "large"))
    await runtime.configureTaskAgents(.init(tool: "tool"))
    try await runtime.register(
      tool: ClosureTool(definition: ToolDefinition(name: "probe", description: "Read README")) {
        _, _ in ToolOutput(text: "README: PocketMai is an agent runtime.")
      })
    let activity = ProviderActivity()
    let request = AgentRequest(
      provider: "test-acp", model: "large", messages: [.user("Summarize README in one sentence")],
      toolNames: ["probe"], limits: .init(maxModelTurns: 3), toolCallingStrategy: strategy,
      useToolProxy: false,
      sessionID: "readme-chat")
    let result = try await runtime.run(request) { event in
      if case .provider(_, let delta) = event { await activity.event(delta) }
    }
    let value = try JSONDecoder().decode(JSONValue.self, from: Data(result.response.text.utf8))
    #expect(result.modelTurns == 1)
    #expect(value.objectValue?["turn"] == .integer(1))
    #expect(value.objectValue?["prompt"]?.stringValue?.contains("Summarize README") == true)
    #expect(value.objectValue?["prompt"]?.stringValue?.contains("fallback protocol") == false)
    #expect(await activity.text == result.response.text)
    #expect(await activity.reasoning == "thinking")
    let native = try #require(result.transcript.flatMap(\.toolCalls).first { $0.id == "native" })
    #expect(native.name == "native_search")
    #expect(native.arguments == .object(["query": .string("needle")]))
    #expect(result.transcript.last?.text == result.response.text)

    var followup = request
    followup.messages = result.transcript + [.user("Show me that summary again")]
    let next = try await runtime.run(followup)
    let nextValue = try JSONDecoder().decode(JSONValue.self, from: Data(next.response.text.utf8))
    #expect(next.modelTurns == 1)
    #expect(nextValue.objectValue?["turn"] == .integer(2))
    #expect(
      nextValue.objectValue?["prompt"]?.stringValue?.contains("Show me that summary again") == true)
    await provider.shutdown()
  }

  @Test(
    "ACP discovers and selects modern and legacy models; preserves reasoning and session history",
    arguments: [false, true])
  func acpProviderModels(legacy: Bool) async throws {
    let provider = try providerFixture(legacy: legacy)
    let models = try await provider.availableModels()
    #expect(models.map(\.id) == ["small", "large"])
    let activity = ProviderActivity()
    let initial: [AgentMessage] = [
      .system("Be brief"), .user("first"), .assistant("old reply"), .user("second"),
    ]
    let first = try await provider.complete(
      .init(model: "large", messages: initial,
        options: .init(reasoningEffort: "high", reasoningGuidance: "Be thorough"), sessionID: "one")
    ) {
      await activity.event($0)
    }
    let value = try JSONDecoder().decode(JSONValue.self, from: Data(first.message.text.utf8))
    #expect(value.objectValue?["model"] == .string("large"))
    #expect(value.objectValue?["prompt"]?.stringValue?.contains("old reply") == true)
    #expect(value.objectValue?["prompt"]?.stringValue?.contains("Be thorough") == true)
    #expect(value.objectValue?["effort"] == .string(legacy ? "medium" : "high"))
    #expect(first.message.reasoning == "thinking")
    #expect(await activity.started == 1)
    #expect(await activity.finished == 1)
    #expect(await activity.calls["native"]?.arguments == .object(["query": .string("needle")]))
    #expect(await activity.calls["native"]?.name == (legacy ? "Search for needle" : "native_search"))
    let next = try await provider.complete(
      .init(model: "small", messages: initial + [first.message, .user("third")], sessionID: "one"))
    let nextValue = try JSONDecoder().decode(JSONValue.self, from: Data(next.message.text.utf8))
    #expect(nextValue.objectValue?["turn"] == .integer(2))
    #expect(nextValue.objectValue?["model"] == .string("small"))
    #expect(nextValue.objectValue?["prompt"]?.stringValue?.contains("old reply") == false)
    await #expect(throws: (any Error).self) {
      _ = try await provider.complete(
        .init(model: "missing", messages: [.user("no")], sessionID: "other"))
    }
    await provider.shutdown()
  }

  @Test("ACP applies model-specific Claude and Codex effort and restores auto", arguments: ["claude", "codex"])
  func acpProviderEffort(adapter: String) async throws {
    let provider = try providerFixture(adapter: adapter)
    var messages: [AgentMessage] = []
    for (model, level, expected) in [
      ("small", "high", "high"),
      ("large", "auto", adapter == "claude" ? "default" : "medium"),
      ("small", "auto", adapter == "claude" ? "default" : "medium"),
      ("large", "max", adapter == "claude" ? "max" : "xhigh"),
      ("large", "off", adapter == "claude" ? "low" : "none"),
      ("large", "auto", adapter == "claude" ? "default" : "medium"),
      ("small", "max", "high"),
      ("small", "minimal", "low"),
    ] {
      messages.append(.user("Reply with settings"))
      let response = try await provider.complete(.init(
        model: model, messages: messages,
        options: .init(reasoningEffort: level, reasoningGuidance: "Check the result")))
      let result = try JSONDecoder().decode(JSONValue.self, from: Data(response.message.text.utf8))
      #expect(result.objectValue?["model"] == .string(model))
      #expect(result.objectValue?["effort"] == .string(expected))
      #expect(result.objectValue?["prompt"]?.stringValue?.contains("Check the result") == true)
      messages.append(response.message)
    }
    await provider.shutdown()
  }

  @Test(
    "ACP MCP tools use runtime approvals, cwd, exposure and budgets",
    arguments: ["allow", "deny", "budget", "disabled"])
  func acpProviderRuntimeTools(mode: String) async throws {
    let provider = try providerFixture()
    let runtime = AgentRuntime()
    try await runtime.register(provider)
    try await runtime.register(
      tool: ClosureTool(
        definition: ToolDefinition(
          name: "probe", description: "Probe",
          annotations: ToolAnnotations(approval: mode == "deny" ? .dangerous : .automatic))
      ) { _, _ in
        #expect(mode != "deny")
        return ToolOutput(text: AgentExecutionScope.directory.path)
      })
    if mode == "disabled" { await runtime.configureToolsEnabled(false) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "acp-scope-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let result = try await AgentExecutionScope.$current.withValue(
      .init(sessionID: "tools", workingDirectory: directory)
    ) {
      try await runtime.run(
        AgentRequest(
          provider: "test-acp", model: "large",
          messages: [.user(mode == "budget" ? "TWICE" : "run probe")], toolNames: ["probe"],
          limits: .init(maxToolCalls: mode == "budget" ? 1 : 5), useToolProxy: false))
    }
    let value = try JSONDecoder().decode(JSONValue.self, from: Data(result.response.text.utf8))
    let tool = value.objectValue?["tool"]
    #expect(result.transcript.flatMap(\.toolResults).contains { $0.text == "native result" })
    switch mode {
    case "allow":
      #expect(
        tool?.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue
          == directory.path)
      #expect(result.toolCalls == 1)
    case "disabled": #expect(tool == .null && result.toolCalls == 0)
    default: #expect(tool?.objectValue?["isError"] == .bool(true))
    }
    await provider.shutdown()
  }

  @Test("ACP prompt failures bypass automatic transport retries")
  func acpPromptFailureNoRetry() async throws {
    let provider = try providerFixture()
    await #expect(throws: ProviderPolicyError.self) {
      _ = try await provider.complete(.init(model: "large", messages: [.user("FAIL_PROMPT")]))
    }
    await provider.shutdown()
  }

  @Test(
    "An explicit ACP timeout stops an unanswered turn and allows a fresh request after reconnecting",
    .timeLimit(.minutes(1)))
  func acpConfiguredPromptTimeout() async throws {
    let provider = try #require(ACPConfiguredProviderFactory().makeProvider(
      from: .init(
        id: "test-acp", kind: "acp", timeout: 5,
        options: [
          "command": .string("/usr/bin/env"),
          "args": .array(["python3", "-u", "-c", providerAgentScript, "claude"].map(JSONValue.string)),
        ]), environment: ProcessInfo.processInfo.environment) as? ACPProvider)
    do {
      _ = try await provider.complete(.init(model: "large", messages: [.user("HANG_PROMPT")]))
      Issue.record("Expected the configured turn timeout")
    } catch let error as ProviderPolicyError {
      #expect(error.code == "acp_prompt_failed")
      #expect(error.message.contains("configured provider timeout"))
      #expect(error.message.contains("null for no turn limit"))
    }
    let response = try await provider.complete(.init(model: "large", messages: [.user("Retry")]))
    #expect(response.message.text.contains("Retry"))
    await provider.shutdown()
  }
#endif

#if os(macOS) || os(Linux)
  @Test("ACP tool bridge rejects browser origins and revokes calls after the prompt")
  func acpToolBridgeLifetime() async throws {
    let bridge = ACPToolBridge()
    let descriptor = try await bridge.start()
    let address = try #require(descriptor.objectValue?["url"]?.stringValue)
    let url = try #require(URL(string: address))
    await bridge.configure(tools: [ToolDefinition(name: "probe", description: "Probe")]) { call in
      ToolResult(callID: call.id, text: "ok")
    }
    func request(origin: String? = nil) async throws -> (JSONValue?, Int) {
      var request = URLRequest(url: url)
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
      request.httpBody = try JSONEncoder().encode(
        JSONRPCMessage.request(
          id: 1, method: "tools/call",
          params: .object(["name": .string("probe"), "arguments": .object([:])])))
      let (data, response) = try await URLSession.shared.data(for: request)
      return (
        try? JSONDecoder().decode(JSONValue.self, from: data),
        (response as? HTTPURLResponse)?.statusCode ?? 0
      )
    }
    let accepted = try await request()
    #expect(accepted.0?.objectValue?["result"]?.objectValue?["isError"] == .bool(false))
    #expect(try await request(origin: "https://example.com").1 == 403)
    await bridge.configure(tools: [], execute: nil)
    let revoked = try await request()
    #expect(revoked.0?.objectValue?["error"] != nil)
    await bridge.close()
  }
#endif
