import Foundation
import MaiCore
import MaiStandardTools

extension MaiCLI {
  static func handleVectorDatabaseCommand(
    _ argument: String, configuration: MaiConfiguration?, environment: [String: String],
    access: PromptFileAccess, terminal: TerminalWriter
  ) async {
    let fields = argument.split(maxSplits: 1, whereSeparator: \Character.isWhitespace).map(String.init)
    let action = fields.first?.lowercased() ?? "status"
    let rest = fields.count > 1 ? fields[1] : ""
    var args: [String: JSONValue] = ["action": .string(action == "del" ? "remove" : action)]
    switch action {
    case "query": args["query"] = .string(rest)
    case "index", "del": args["path"] = .string(rest.isEmpty && action == "index" ? "." : rest)
    case "status", "clear":
      guard rest.isEmpty else {
        await terminal.line(vdbHelp)
        return
      }
    default:
      await terminal.line(vdbHelp)
      return
    }
    let source = configuration?.toolSources.first {
      $0.enabled && $0.kind == MaiStandardToolsPlugin.factoryKind
    }
    let context = source?.context(environment: environment)
      ?? PluginFactoryContext(id: "standard-tools", environment: environment)
    var files = MaiStandardToolFactory.fileWorkspaceConfiguration(
      context: context, additionalAllowedURLs: await access.all())
    files.pathAccessPolicy = access.policy
    files.projectHomeURL = access.home.rootURL
    let tool = MaiVectorDatabaseTool(configuration: files)
    do {
      let result = try await tool.call(
        arguments: .object(args),
        context: ToolExecutionContext(
          run: AgentEventContext(runID: UUID(), parentRunID: nil, agentID: "repl", depth: 0), modelTurn: 0))
      await terminal.line(result.text)
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }
}
