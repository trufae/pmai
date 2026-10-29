# Claude Code through ACP

pmai can run Claude Code through the
[Claude ACP adapter](https://github.com/agentclientprotocol/claude-agent-acp).
Claude runs its own tool loop; pmai provides the chat interface, model selection,
streaming replies, and tool progress. See [ACP and MCP](acp.md) for the general
protocol setup and [Remote ACP agents](tailcat.md) for connecting from PocketMai.

## Install and authenticate

Install Claude Code using the [official quickstart](https://code.claude.com/docs/en/quickstart).
For example, on macOS with Homebrew:

```sh
brew install --cask claude-code
```

Install the ACP adapter with npm (requires Node.js and npm), then start Claude
Code once to complete its sign-in prompts:

```sh
npm install -g @agentclientprotocol/claude-agent-acp
claude
```

Exit Claude Code after signing in. Both `claude` and `claude-agent-acp` must be
available on the `PATH` used to launch pmai. Authentication belongs to Claude;
there is no need to add an API key to pmai for this connection.

## Select Claude in pmai

Start pmai in the project you want Claude to work on:

```sh
cd /path/to/project
pmai
```

Inside pmai, run:

```text
/agent acp add claude
/agent default claude
/models claude
```

The first command saves an ACP provider and a same-named agent, then selects it
for the current chat. The second makes that agent the default for future chats
and runs. `/models claude` asks the adapter for its available models.

For an already configured agent, `/agent use claude` selects it again; this
command clears the current chat's history. To register only the provider and
keep the current agent's instructions and tools, use `/provider add acp claude`
instead, then select a model as below.

## Change the model and reasoning effort

List the models and copy an exact model ID from the output:

```text
/models claude
/model claude::MODEL_ID
/model
```

Replace `MODEL_ID` with the returned ID. Model availability depends on the
adapter and your Claude account; avoid copying a model name from an old guide.
The `claude::` prefix selects the pmai provider; only the model ID is sent to
Claude. `/model` without arguments shows the current selections.

`/model claude::MODEL_ID` changes the chat and every task model, replacing any
existing task assignments. To change only the conversation model and preserve
your task assignments, use:

```text
/model -chat claude::MODEL_ID
```

Both forms save the selected agent as the default for future chats and runs.
See [Providers, agents, and task defaults](task-agents.md) for task-specific
model selection.

Set reasoning effort through pmai:

```text
/set effort high
```

Use `/set effort max` for the highest level the adapter advertises, or
`/set effort auto` to restore the session's original/default effort. pmai maps
requested levels to supported values. Temperature and token limits have no
standard ACP control and remain managed by Claude.

## Disable commit and PR attribution

Claude Code adds a `Co-Authored-By` commit trailer by default. Disable it in
Claude's settings, including when using the ACP adapter. Merge this object into
the settings file, preserving its other keys:

```json
{
  "attribution": {
    "commit": "",
    "pr": ""
  }
}
```

Choose the scope:

| File | Scope |
| --- | --- |
| `~/.claude/settings.json` | Your default across projects. |
| `.claude/settings.json` | This project, shared with the repository. |
| `.claude/settings.local.json` | Your local settings for this project. |

The [adapter loads user, project, and local settings](https://github.com/agentclientprotocol/claude-agent-acp/blob/main/src/acp-agent.ts).
These are Claude settings files, separate from `pmai.json`. For SSH or other
remote ACP connections, edit them on the machine running Claude.

An empty `commit` removes commit attribution; an empty `pr` removes PR
attribution. The older `includeCoAuthoredBy` key is deprecated. If you also use
Claude's cloud or Remote Control sessions, add `"sessionUrl": false` inside
`attribution` to suppress their session links. See the
[Claude attribution settings](https://code.claude.com/docs/en/settings-reference#attribution).

Restart pmai and start a fresh Claude ACP chat after changing the settings.
The change applies to future commits and PRs; it does not rewrite existing
commit messages.

## Tools and troubleshooting

Claude's native tools execute in the adapter. `/tools` controls the pmai tools
forwarded to Claude over MCP; `/tools off` does not disable Claude's native tools.
Tool requests that need approval appear through pmai's permission interface.
See [ACP permissions and files](acp.md#permission-and-files) for provider policies.

- **Adapter not found:** check `command -v claude-agent-acp` in the shell used to
  launch pmai. Use `/agent acp list` to inspect installed adapters. A custom path
  can be registered with `/provider add acp claude /absolute/path/to/claude-agent-acp`.
- **Authentication failed:** run `claude` directly and sign in again before
  retrying in pmai. The adapter's stderr is included in authentication errors.
- **Model unavailable:** run `/models claude` again and select a returned ID.
- **Attribution still appears:** check the settings in the actual project and
  user account running Claude, including project overrides and instructions in
  `CLAUDE.md`; then use a fresh ACP chat.
- **Adapter update needed:** run
  `npm install -g @agentclientprotocol/claude-agent-acp` again, then restart pmai.
