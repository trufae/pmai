# ACP and MCP

For a standalone WebSocket gateway, the iOS remote frontend, and optional
Tailcat routing, see [Remote ACP agents](tailcat.md).

pmai speaks the [Agent Client Protocol](https://agentclientprotocol.com) — JSON-RPC
over stdio between an editor and a coding agent — in both directions, and serves
[MCP](https://modelcontextprotocol.io) as well. All three ride one transport in
`MaiCore/Sources/MaiACP`; only the method vocabulary and the peer's handlers
differ.

## The one idea

**A remote ACP agent is a `ChatProvider`.** That is the whole design. An ACP
connection answers `complete` the way an LLM backend does, so an
`AgentDefinition` pointing at it flows through `AgentRuntime`, `/agent`,
subagents, delegation, and memory with no special case anywhere. The external
agent's own tools, model, and reasoning stay behind the boundary; MaiCore only
sees a reply.

The mirror image is just as thin: **the ACP server is an adapter over
`AgentRuntime.run`**. `session/prompt` becomes one run, provider deltas become
`session/update` notifications, and a tool that needs approval becomes a
`session/request_permission` the editor answers.

```
                 MaiACP
  ┌────────────────────────────────────┐
  │ StdioJSONRPCTransport  (stdio/pipes)│
  │ JSONRPCPeer            (correlation)│
  ├───────────────┬────────────────────┤
  │ ACPProvider   │ ACPServer          │  ACP, both directions
  │  (agent →     │  (pmai → editor)   │
  │   provider)   │                    │
  │ ACPClient     │ MCPAgentServer     │  MCP: pmai as one tool
  └───────────────┴────────────────────┘
```

## pmai as a server

```
pmai --acp     # serve pmai as an ACP agent on stdio (for Zed, JetBrains, …)
pmai --mcp     # serve pmai as an MCP server: one tool that runs the agent
```

Both read stdin and write the protocol to stdout; diagnostics go to stderr, so
nothing pollutes the JSON-RPC stream. The served agent is the one the config
selects (`defaultAgent`, or `--agent ID`), with its full tool set, subagents,
and limits. In ACP mode a tool that needs approval is forwarded to the editor as
`session/request_permission`; the terminal approval handler delegates to the
client, so the same runtime serves the REPL and an IDE unchanged.

Point an editor at `pmai --acp`. Point another agent or an MCP client at
`pmai --mcp`; it sees a single tool named after the agent that takes a `prompt`.

## pmai as a client — ACP agents as agents

An ACP provider stores its command line in a provider record; no new schema:

```json
{ "id": "gemini", "kind": "acp", "displayName": "Gemini",
  "options": { "command": "gemini", "args": ["--acp"], "permission": "auto" } }
```

Any `AgentDefinition` whose `provider` is that id is now an ordinary agent:
select it with `/agent use gemini`, spawn it as a subagent, or let a delegating
agent pick it. The REPL builds these for you:

```
/agent acp list                     # the builtin catalog, marked ✅ installed / ❌ not
/agent acp add gemini               # register a known agent (command from the catalog)
/agent acp add myagent mycmd --acp  # register a custom one by command
```

`/agent acp add` writes the provider and a same-named agent, registers both
live, and selects the agent for the current chat.

### Catalog

The builtin roster follows the official ACP registry: `gemini`, `qwen`,
`opencode`, and `goose` speak ACP natively. Claude Code and Codex do not, so
they run through adapters:

```
npm install -g @agentclientprotocol/claude-agent-acp   # claude
npm install -g @agentclientprotocol/codex-acp          # codex
```

An entry with the same id in the configuration overrides the builtin. Every
agent must be authenticated with its own CLI once before it can be driven.

### Permission and files

`options.permission` decides how pmai answers an agent's
`session/request_permission`: `allow`, `reject`, or `auto` (approve read-only
kinds — read, search, fetch, think — and reject the rest; the default). pmai
answers `fs/read_text_file` from the working directory so an agent can read the
files it reasons about; writes are declined.

## Design notes

- **One session per working directory.** `ACPProvider` pools an `ACPClient` per
  cwd, so a subagent running in a different directory never lands its prompt in
  the parent's session. Each client keeps its child process and ACP session
  across turns, so the agent keeps its context.
- **The runtime hands over the whole transcript each turn, but the ACP agent
  keeps its own.** So the provider sends only the latest user turn; everything
  before it already lives in the agent's session.
- **No model schema crosses the boundary.** An ACP agent carries its own tools,
  so MaiCore never offers it a tool definition — tool calling stays remote.
- **Sessions are not persisted.** Like agent processes, an ACP session is live
  state tied to a child process; a resumed session would answer a stale prompt.
