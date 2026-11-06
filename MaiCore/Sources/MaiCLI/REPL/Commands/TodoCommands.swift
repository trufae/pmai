import Foundation
import MaiCore

extension MaiCLI {
  /// `/todo` in full: the same list the `todo_*` tools drive, for the person
  /// at the keyboard. Every action reads the file afresh, so the list an
  /// agent just changed is what gets shown or edited.
  static func handleTodoCommand(
    _ argument: String,
    todo: TodoState,
    terminal: TerminalWriter
  ) async {
    let fields = argument.split(maxSplits: 1, whereSeparator: \Character.isWhitespace).map(
      String.init)
    let action = fields.first?.lowercased() ?? ""
    let rest = fields.count > 1 ? fields[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
    var list = todo.current

    switch action {
    case "", "show", "list":
      await terminal.line(await terminal.renderTodoList(list))

    case "add":
      guard !rest.isEmpty else {
        await terminal.line("Usage: /todo add TEXT")
        return
      }
      await terminal.line(
        MaiTodoTools.execute(
          name: MaiTodoTools.addName, arguments: ["title": .string(rest)], list: &list))
      await storeTodo(list, in: todo, terminal: terminal)

    case "done", "check":
      guard !rest.isEmpty else {
        await terminal.line("Usage: /todo done NUMBER|TEXT")
        return
      }
      await terminal.line(
        MaiTodoTools.execute(
          name: MaiTodoTools.doneName, arguments: ["task": .string(rest)], list: &list))
      await storeTodo(list, in: todo, terminal: terminal)

    case "del":
      guard !rest.isEmpty else {
        await terminal.line("Usage: /todo del NUMBER|TEXT")
        return
      }
      guard let index = list.index(matching: rest) else {
        await terminal.line(
          list.isEmpty
            ? "The todo list is empty."
            : "No todo matched '\(rest)'.\n\(await terminal.renderTodoList(list))")
        return
      }
      guard let removed = list.remove(at: index) else { return }
      await terminal.line("Removed: \(removed.title)\n\(await terminal.renderTodoList(list))")
      await storeTodo(list, in: todo, terminal: terminal)

    case "sweep":
      let removed = list.removeCompleted()
      guard removed > 0 else {
        await terminal.line("No completed todo items.")
        return
      }
      await terminal.line("Removed \(removed) completed todo item\(removed == 1 ? "" : "s").")
      await storeTodo(list, in: todo, terminal: terminal)

    case "edit":
      guard
        let edited = await editTemporaryText(
          list.markdown, suffix: AgentTodoList.filename, terminal: terminal)
      else { return }
      await storeTodo(AgentTodoList(markdown: edited), in: todo, terminal: terminal)

    case "clear":
      await storeTodo(AgentTodoList(), in: todo, terminal: terminal)

    case "path":
      await terminal.line(todo.url?.path ?? AgentTodoList.filename)

    default:
      await terminal.line(todoHelp)
    }
  }

  private static func storeTodo(
    _ list: AgentTodoList,
    in todo: TodoState,
    terminal: TerminalWriter
  ) async {
    do {
      try todo.save(list)
      await terminal.line(
        list.isEmpty
          ? "Todo list cleared."
          : "Todo list saved to \(todo.url?.path ?? AgentTodoList.filename) (\(list.pendingCount) pending, \(list.doneCount) done)."
      )
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }
}
