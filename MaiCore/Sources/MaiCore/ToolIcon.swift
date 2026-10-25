/// A small object-based visual vocabulary shared by tool legends and call logs.
/// Built-in tools have distinct icons; dynamic families use a stable family icon.
public enum ToolIcon {
  public static func emoji(for name: String) -> String {
    let name = AgentProcessTools.canonicalName(name)
    if let icon = builtins[name] { return icon }
    if MaiSkillTools.isSkillTool(name) { return "🎓" }
    if name.contains("::") { return "🔌" }
    return "🔧"
  }

  private static let builtins: [String: String] = [
    "current_time": "🕒", "calc": "🧮", "weather": "🌤️",
    "web_search": "🌐", "web_fetch": "📥", "run_shell": "💻", "vdb": "🗄️",
    "files_list": "📁", "files_find": "🔎", "files_grep": "🔬", "files_read": "📖",
    "files_read_index": "🗂️", "files_get_function": "🧩", "files_set_function": "🔩",
    "files_read_range": "📏", "files_replace_range": "🪡", "files_patch": "🩹",
    "files_mkdir": "🗃️", "files_write": "✏️", "files_rename": "🏷️", "files_delete": "🗑️",
    "agent_start": "🚀", "agent_status": "📡", "agent_result": "📦", "agent_stop": "🛑",
    "context_list": "📜", "context_remove": "✂️", "context_rewrite": "🖋️",
    "context_compact": "🗜️", "todo_list": "📋", "todo_add": "📌", "todo_done": "✅",
    "chats_list": "💬", "chats_search": "🪞", "chats_read": "📚",
    "chats_read_document": "📄", "pmai_run": "🎛️", "pmai_help": "💡",
    "list-tools": "🧰", "call-tool": "⚙️", "mastodon": "📣",
    "github_list_repos": "🏠", "github_search_repos": "🧭", "github_list_prs": "🎫",
    "github_pr": "🔀", "github_pr_diff": "⚖️", "github_pr_comments": "🗨️",
    "github_comment": "📮", "github_review": "📝", "github_create_pr": "🌱",
    "github_list_files": "🧾", "github_read_file": "📰", "github_commits": "🧵",
    "github_commit": "🔖", "github_issues": "🐛", "github_issue": "🔍",
    "github_releases": "🎁", "github_ci_status": "🚦", "github_ci_log": "📊",
  ]
}
