import Foundation
import MaiCore

#if canImport(Android)
  import Android
#elseif canImport(Musl)
  import Musl
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

/// Build the prompt's static candidates on its first Tab, then reuse them.
final class REPLCompletionCache: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [String]?

  func values(_ build: () -> [String]) -> [String] {
    lock.withLock {
      if let stored { return stored }
      let values = build()
      stored = values
      return values
    }
  }
}

extension MaiCLI {
  static func completionCandidates(
    workspace: AgentChatWorkspace,
    configuration: MaiConfiguration?,
    availableProviders: [ProviderDescriptor],
    toolGroups: [ToolGroupDefinition],
    skills: [AgentSkill] = [],
    themesDirectory: URL
  ) -> [String] {
    var values = [
      "/alias", "/unalias ", "/help alias",
      "/recover", "/recover clear", "/help", "/help set", "/help reset", "/reset", "/exit", "/quit", "/set tool.approval yolo", "/set tool.approval ask",
      "/help shell", "/shell", "/shell local", "/help keys", "/help model",
      "/help history", "/history", "/history list", "/history search ", "/history del ",
      "/history clear", "/history path", "/history help",
      "/help theme", "/theme", "/theme list", "/theme show", "/theme use ", "/theme save ", "/theme color",
      "/set tool.approval smart", "/set tool.approval yolo session", "/set tool.approval ask session",
      "/set debug true", "/set debug false",
      "/set debugfile ", "/set debugfile default",
      "/set ui.", "/set effort", "/set effort off", "/set effort auto", "/nothink",
      "/set ui.thinking status", "/set ui.thinking line", "/set ui.thinking three",
      "/set ui.thinking five", "/set ui.thinking full",
      "/set export.", "/set export.tools on", "/set export.tools off",
      "/set export.thinking on", "/set export.thinking off",
      "/fork", "/fork --empty", "/subagents", "/subagents main", "/subagents parent",
      "/voice", "/voice on", "/voice off", "/voice realtime", "/voice walkie-talkie",
      "/set voice", "/set voice.", "/voice voices", "/voice languages",
      "/voice record", "/voice send", "/voice discard", "/voice cancel", "/voice pause", "/voice resume", "/voice status", "/voice help",
      "/model -voice ", "/help voice",
      "/subagents next", "/subagents prev", "/btw ", "/hey", "/hey ", "/help hey", "/then ", "/unthen",
      "/help memory", "/help agents", "/help jobs", "/help ps", "/help chat", "/help edit", "/help tools",
      "/agent acp list", "/agent acp add ", "/agents acp list",
      "/help remote", "/remote", "/remote serve", "/remote stop", "/remote qr",
      "/remote serve --protocol local", "/remote serve --protocol opentunnel", "/remote serve --protocol forwiroh", "/remote serve --protocol openai",
      "/remote list", "/remote pair ", "/remote connect ", "/remote disconnect",
      "/remote ls ", "/remote get ", "/remote put ", "/remote run ",
      "/remote shell ", "/remote shell off",
      "/remote pending", "/remote accept", "/remote reject", "/remote clients", "/remote del ",
      "/help projects", "/projects", "/projects list", "/projects open ",
      "/projects rename ", "/projects tint ", "/projects del ", "/projects info ",
      "/memory", "/memory edit", "/memory learn", "/memory learn --all", "/memory add ",
      "/memory clear", "/memory on", "/memory off", "/memory scope none",
      "/memory scope project", "/memory scope all", "/edit memory", "/edit memory-prompt",
      "/help todo", "/todo", "/todo add ", "/todo done ", "/todo edit", "/todo sweep",
      "/todo del ", "/todo clear", "/todo path",
      "/help vdb", "/vdb", "/vdb index ", "/vdb query ", "/vdb status", "/vdb del ", "/vdb clear",
      "/set limits.", "/set limits.maxToolCalls ", "/set limits.maxModelTurns ",
      "/set limits.maxSubagents ", "/set limits.maxSeconds ", "/set limits.maxTotalTokens ",
      "/set limits.runTimeoutSeconds ",
      "/set limits.terminalTimeout ",
      "/set acp.", "/set acp.timeout ", "/set acp.timeout off",
      "/set acp.context", "/set acp.context agent", "/set acp.context replace",
      "/set acp.prompt", "/set acp.prompt agent", "/set acp.prompt replace",
      "/set http.", "/set http.transport", "/set http.transport auto",
      "/set http.transport curl", "/set http.transport winhttp", "/set http.transport urlsession",
      "/set retry.", "/set retry.attempts ", "/set retry.delay ", "/set ctx.", "/set ctx.compact ",
      "/set ctx.compact off",
      "/set ctx.recent ", "/set ctx.recent auto",
      "/set ctx.window ", "/set ctx.window auto",
      "/set ctx.strategy ", "/set ctx.strategy cache", "/set ctx.strategy size", "/set ctx.strategy smart",
      "/set ctx.strategy tools",
      "/set ctx.strategy adaptive",
      "/continue", "/stop",
      "/set tool.", "/set tool.calling off", "/set tool.calling automatic", "/set tool.calling native",
      "/set tool.calling text", "/set tool.calling xml", "/set tool.calling json",
      "/set tool.systemone true", "/set tool.systemone false",
      "/set awake", "/set awake on", "/set awake off",
      "/set airplane on", "/set airplane off", "/set airplane toggle",
      "/set tool.proxy on", "/set tool.proxy off", "/set tool.proxy all",
      "/set tool.proxy hybrid", "/set tool.auto on", "/set tool.auto off",
      "/set ui.editor ", "/set ui.editor none",
      "/theme color bgline rgb:024", "/theme color bgline none",
      "/theme color bgbubble rgb:123", "/theme color bgbubble none",
      "/theme color fgbubble none",
      "/theme color fgprompt yellow", "/version", "/about", "/help about", "/last", "/skills",
      "/theme color fgcolor none", "/theme color bgcolor none", "/theme color bgprompt none",
      "/theme color fgtoolresult yellow", "/set use.", "/set use.agentsmd on",
      "/set use.agentsmd off",
      "/set use.agentsmd ask",
      "/set use.plan on", "/set use.plan off",
      "/theme color bold on", "/theme color bold off",
      "/set ui.markdown on", "/set ui.markdown off",
      "/set ui.fgbold ", "/set ui.fgbold none",
      "/set ui.fgitalic ", "/set ui.fgitalic none",
      "/set ui.tableborders on", "/set ui.tableborders off",
      "/set ui.color dark", "/set ui.color light",
      "/set ui.mode classic", "/set ui.mode buffer",
      "/set ui.line single", "/set ui.line multi",
      "/set ui.scroll ",
      "/set ui.scrollbar ", "/set ui.highlight ", "/highlight", "/highlight ",
      "/set ui.broadcast on", "/set ui.broadcast off",
      "/set ui.toolgroups on", "/set ui.toolgroups off",
      "/set ui.tools all", "/set ui.tools relevant", "/set ui.tools icons", "/set ui.tools ",
      "/set ui.toolcalls truncate", "/set ui.toolcalls first", "/set ui.toolcalls ",
      "/set redact on", "/set redact off", "/set redact warn", "/edit redact",
      "/cwd", "/pwd", "/cd ", "/plugins",
      "/path", "/path list", "/path allow ", "/path deny ", "/path ask ",
      "/path del ", "/path outside ask", "/path outside deny", "/help path",
      "/path sensitive ask", "/path sensitive deny", "/path sensitive allow",
      "/path symlinks ask", "/path symlinks deny", "/path symlinks allow",
      "/path hidden ask", "/path hidden deny", "/path hidden allow",
      "/providers", "/models ", "/provider ", "/provider add ", "/provider del ", "/provider rename ",
      "/provider edit", "/providers edit", "/edit provider",
      "/provider add acp opencode", "/provider add acp claude", "/provider add acp codex",
      "/provider add local-apple --kind apple",
      "/provider add local-mlx --kind mlx", "/provider add chatgpt --kind chatgpt",
      "/provider login ", "/provider logout ", "/provider status ",
      "/help provider",
      "/agent default ", "/agent effort ",
      "/prompts",
      "/prompt",
      "/prompt list", "/prompt show ", "/prompt add ", "/prompt set ", "/prompt edit ",
      "/prompt del ", "/prompt use ", "/help prompts", "/prompts list", "/prompts show ",
      "/prompts add ", "/prompts edit ", "/prompts del ", "/edit user ", "/edit system ",
      "/agent", "/agents", "/agents list", "/agents describe ", "/agents enable ",
      "/agents disable ",
      "/agent edit", "/agents edit",
      "/ps", "/ps -a", "/ps -p", "/ps -ap", "/ps -k ",
      "/view", "/view off", "/view current", "/view main", "/view pins", "/view log", "/view todo", "/view jobs", "/view iconlog", "/view thinking", "/view voice", "/view tools",
      "/view tools ", "/view prompt ", "/view history", "/view diffs", "/view agents", "/view agent ", "/view clear", "/help view",
      "/job", "/jobs", "/jobs tree", "/jobs stop ", "/jobs continue ", "/jobs clear", "/jobs log ",
      "/jobs kill ", "/jobs focus ",
      "/jobs focus main", "/queue", "/queue push ", "/queue pop", "/queue del",
      "/help queue", "/help export", "/help import", "/export archive ", "/import ",
      "/export txt ", "/export markdown ", "/export html ", "/export json ", "/export debug ",
      "/stats", "/stats ranking", "/stats speed", "/stats time", "/stats efficiency",
      "/stats show ",
      "/stats reset", "/stats del ", "/stats path", "/help stats",
      "/export epub ", "/export docx ", "/set ui.subagents all", "/set ui.subagents tools",
      "/set ui.subagents stats", "/set ui.subagents none",
      "/agent use ",
      "/agent show ", "/agent add ", "/agent tools ", "/agent model ", "/agent prompt ",
      "/agent provider ", "/agent del ", "/edit agent", "/tools", "/tools list", "/tools full", "/tools on", "/tools off",
      "/skills", "/skills list", "/skills show ", "/skills enable ", "/skills disable ",
      "/skills enable all", "/skills disable all", "/skills prompt ", "/skills path",
      "/skills reload", "/skills add ", "/skills edit ", "/skills del ",
      "/skills import ", "/edit skill ", "/help skills",
      "/mcp list", "/mcp info",
      "/mcp edit", "/mcps edit",
      "/mcp add ", "/mcp enable ", "/mcp disable ",
      "/mcp del ",
      "/edit prompt", "/edit compact", "/edit config", "/edit mcps",
      "/edit prompt recap", "/edit smart", "/edit prompt smart",
      "/edit input", "/edit soul", "/edit chat ",
      "/chat compact ", "/chat recap", "/chat context", "/chat context reset",
      "/chat context rebuild", "/chat edit", "/export --context ",
      "/image tiny ", "/image small ", "/image medium ", "/image big ", "/image full ",
      "/image ocr ", "/attach ", "/attach source ", "/attach markdown ", "/attach copy ",
      "/attach clear", "/copy", "/help copy", "/reply", "/help reply",
      "/clear", "/chat list",
      "/chat list active", "/chat list archived", "/chat list all", "/chat new ", "/chat fork",
      "/chat use ", "/chat next", "/chat previous", "/chat info", "/chat session",
      "/chat session new", "/chat title", "/chat title ", "/chat title none", "/chat rename ",
      "/chat pin", "/chat pin ", "/chat unpin", "/chat unpin ",
      "/chat archive", "/chat unarchive ", "/chat del ",
      "/chat files", "/msg", "/msg list", "/msg log", "/msg log quiet", "/msg log verbose", "/msg log short", "/msg pin", "/msg pin ", "/msg pins", "/msg pins short", "/msg pinlist", "/msg unpin ", "/msg last", "/msg edit ", "/msg del ", "/msg undo", "/msg chop", "/msg trim ", "/msg rewind",
      "/chat rewind", "/chat rewind lastmsg", "/chat rewind lastpin", "/chat rewind firstmsg", "/chat rewind cancel",
      "/chat clear", "/project", "/project info", "/project list", "/project name ",
      "/project tint ", "/project tint none", "/project del ",
    ]
    values += ConfiguredVoice.settingNames.map { "/set voice.\($0) " }
    for mode in VoiceCaptureMode.allCases { values.append("/set voice.mode \(mode.rawValue)") }
    for key in ["input", "output"] {
      for kind in ["system", "command", "openai"] { values.append("/set voice.\(key) \(kind)") }
    }
    for id in ["null"] + (configuration?.providers.map(\.id) ?? []) {
      values.append("/set voice.provider \(id)")
    }
    for key in ConfiguredVoice.settingNames where key.hasSuffix("Command") {
      values.append("/set voice.\(key) null")
    }
    let resetKeys = Set(values.compactMap { candidate -> String? in
      let words = candidate.split(whereSeparator: \.isWhitespace)
      guard words.first == "/set", words.count > 1, !words[1].hasSuffix(".") else { return nil }
      return String(words[1])
    })
    values += resetKeys.sorted().map { "/reset \($0)" }
    values += TerminalTheme.keys.map { "/reset ui.\($0)" }
    values += REPLModelCatalog.commandPrefixes
    for tint in AgentProjectTint.presetNames {
      values.append("/project tint \(tint)")
    }
    values += TerminalTheme.keys.map { "/theme color \($0) " }
    let themeNames = TerminalTheme.names(directory: themesDirectory, color: configuration?.ui.color ?? .dark)
    values += themeNames.map { "/theme use \($0)" }
    values += themeNames.map { "/theme show \($0)" }
    for (index, chat) in chronologicalChats(workspace).enumerated() {
      values.append("/chat use \(index + 1)")
      values.append("/chat use \(chat.id.uuidString.prefix(8))")
      values.append("/chat use \(chat.displayTitle)")
      values.append("/chat info \(index + 1)")
      values.append("/chat \(chat.isPinned ? "unpin" : "pin") \(index + 1)")
      values.append(chat.isArchived ? "/chat unarchive \(index + 1)" : "/chat archive \(index + 1)")
    }
    for agent in configuration?.agents ?? [] {
      values.append("/agent use \(agent.id)")
      values.append("/agent show \(agent.id)")
      values.append("/agent edit \(agent.id)")
      values.append("/agents edit \(agent.id)")
      values.append("/edit agent \(agent.id)")
      values.append("/agent default \(agent.id)")
      values += REPLModelCatalog.taskPrefixes.map { $0 + agent.id }
      values.append("/chat new --agent \(agent.id) ")
    }
    for name in (configuration ?? .init()).systemPrompts.map(\.name) {
      values.append("/prompt \(name)")
      values.append("/edit prompt \(name)")
      values.append("/edit \(name)")
    }
    for provider in configuration?.providers ?? [] {
      values.append("/provider \(provider.id)")
      values.append("/models \(provider.id)")
      for prefix in REPLModelCatalog.commandPrefixes {
        values.append("\(prefix)\(provider.id)::")
      }
      values.append("/edit provider \(provider.id)")
      values.append("/provider edit \(provider.id)")
      values.append("/providers edit \(provider.id)")
      values.append("/provider rename \(provider.id) ")
      values.append("/provider del \(provider.id)")
    }
    for provider in availableProviders {
      values.append("/provider use \(provider.id.rawValue)")
    }
    for skill in skills {
      values.append("/skills edit \(shellQuote(skill.name))")
      values.append("/skills del \(shellQuote(skill.name))")
      values.append("/edit skill \(shellQuote(skill.name))")
      values.append("/skills show \(skill.name)")
      values.append("/skills prompt \(skill.name) ")
      if skill.isModelInvocable {
        values.append("/skills enable \(skill.name)")
        values.append("/skills disable \(skill.name)")
        for mode in ["direct", "proxy", "hide", "inherit"] { values.append("/skills \(mode) \(skill.name)") }
      }
    }
    let catalog = configuration?.promptCatalog(skills: skills) ?? PromptCatalog(skills: skills)
    for entry in catalog.entries {
      values.append("$\(entry.commandName) ")
      if entry.kind != .skill { values.append("/view prompt $\(entry.commandName)") }
      values.append("/prompts \(entry.commandName) ")
      values.append("/prompts show \(entry.commandName)")
    }
    for name in (configuration?.prompts?.user ?? [:]).keys.sorted() {
      values.append("/prompts edit \(name)")
      values.append("/prompts del \(name)")
      values.append("/edit user \(name)")
    }
    var groupNames = Set(workspace.chats.flatMap(\.primaryAgent.toolGroupNames))
    groupNames.formUnion(toolGroups.map { $0.sourceID == "mcp" ? $0.catalogID : $0.id })
    for level in ReasoningEffort.names {
      values.append("/set effort \(level)")
    }
    groupNames.formUnion(["mcp", "skills"])
    for server in configuration?.mcpServers ?? [] {
      groupNames.insert("mcp/" + server.id)
      values.append("/mcp info \(server.id)")
    }
    let toolNames = Set(workspace.chats.flatMap(\.primaryAgent.toolNames))
      .union(toolGroups.flatMap(\.toolNames))
      .union((configuration?.agents ?? []).flatMap(\.toolNames))
      .union(skills.filter(\.isModelInvocable).map(\.toolName))
    for name in toolNames {
      for action in ["show", "enable", "direct", "proxy", "hide", "disable", "inherit"] {
        values.append("/tools \(action) tool:\(name)")
      }
    }
    for group in groupNames {
      values.append("/tools show \(group)")
      values.append("/tools enable \(group)")
      values.append("/tools disable \(group)")
      for mode in ["direct", "proxy", "hide", "inherit"] { values.append("/tools \(mode) \(group)") }
      values.append("/tools set \(group) ")
    }
    return Array(Set(values))
  }
}
