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
subagents, delegation, and memory with no special case anywhere. MaiCore discovers the agent's models, selects them, and streams reasoning,
replies, and native tool activity. Local ACP agents can also call enabled pmai
tools over a session-scoped MCP bridge.

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

For phone and CLI clients, run `/remote serve` inside the REPL. It chooses the
network address, shows a QR, and shares all indexed projects. New clients wait
until you accept them with `/remote accept`; `--path PATH ...` optionally limits
the shared directories. `/projects` lists and switches the same project index.
See [Remote ACP agents](tailcat.md) for pairing and host management.

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

## ACP providers in the normal prompt

```
/provider add acp opencode
/provider add acp claude
/provider add acp codex
/provider use codex
/models codex
/model codex::MODEL_ID
/tools
```

Use the model IDs returned by `/models`. Agents with no model catalog expose
one default entry named after the provider. Model selection supports both
`configOptions` and the older `models` / `session/set_model` API.

Claude and Codex use adapters; install them and authenticate with their own CLI:

```
npm install -g @agentclientprotocol/claude-agent-acp @agentclientprotocol/codex-acp
```

A custom command or SSH connection works too:

```
/provider add acp worker /path/to/agent --acp
/provider add acp workstation ssh user@host codex-acp
/provider add acp remote --url wss://host/acp --cwd /work/project --token-env ACP_TOKEN
```

`/provider add` saves only the provider; your current agent keeps its instructions,
tools, and settings. `/agent acp add` additionally creates and selects an agent.
Both use the same MaiCore provider implementation. For SSH, set
`options.remoteCwd` to the remote workspace's absolute path with `/edit provider
workstation` when it differs from your local path.

Local agents receive pmai tools through a loopback HTTP MCP endpoint. Tools still
use maiCore's validation, approvals, working directory, offline rules, and run
budgets. `/tools` changes their exposure as usual. The ACP adapter must advertise
HTTP MCP support. The endpoint accepts calls only during an active prompt, and
cancels outstanding tool calls when that prompt finishes or is cancelled.

ACP-native tools execute inside the external agent. Their progress appears in
chat; pmai never executes those notifications again. Their permissions and
limits belong to the agent. `/tools off` disables pmai tools, not native agent
tools. ACP has no standard endpoint to enumerate or disable arbitrary native
tools. Remote agents use their own host tools; configure additional MCP servers
in the provider's `options.mcpServers`. For SSH, that list is evaluated on the
remote host and pmai tool forwarding is disabled. For custom remote wrappers,
set `options.forwardTools` to `false` to avoid offering a local loopback endpoint.

A failed prompt is not retried automatically because the agent may already have
performed side effects. Authentication failures are reported with adapter stderr.

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

### File browsing from PocketMai

Open **Files…** from a chat's title menu, or long-press a local folder or remote
project and choose **Browse Files…**. Both locations use the same browser. It
starts in the chat's working folder or the selected remote project; **Choose
Local Folder…** opens the system folder picker for another on-device location.
Navigate folders, filter names, show hidden files, and copy file or folder paths.
**New Folder** creates a directory; **Upload Files** imports one or more files
from Files. Existing names require explicit replacement. Long-press a file to
preview it or choose **Download…**, then pick a destination in Files.

Quick Look previews supported formats. Other files show UTF-8 text or hexadecimal
bytes. Files larger than 16 MiB preview their first 64 KiB; binary fallback displays
up to 4 KiB. Download always transfers the complete file. Local browsing works
offline; remote browsing needs an approved, connected host and Airplane Mode off.
Browsing uses its own connection and does not create or run a chat.

ACP's standard [filesystem methods](https://github.com/agentclientprotocol/agent-client-protocol/blob/main/docs/protocol/v1/file-system.mdx)
let the agent access files on the **client**. For a phone accessing the **worker**,
pmai uses the protocol's [custom method and capability mechanism](https://agentclientprotocol.com/protocol/v1/extensibility).
The server advertises `agentCapabilities._meta.pmai.workspaceFiles: 1` and
handles `_pmai/workspace/files` with `{cwd, request}`:

| Operation | Request fields | Response |
| --- | --- | --- |
| `list` | `path`, `offset`, `limit`, `showHidden` | `listing`: root, path, writeEnabled, entries, nextOffset |
| `read` | `path`, `offset`, `limit`, optional `version` | `chunk`: base64 data, size, version |
| `mkdir` | `path` | Empty result |
| `uploadBegin` | destination `path`, `overwrite` | `transferID` |
| `uploadChunk` | `transferID`, sequential `offset`, base64 `data` | acknowledged `bytes` |
| `uploadFinish` | `transferID`, final `offset` | committed `bytes` |
| `uploadCancel` | `transferID` | Empty result |

`WorkspaceFileRequest` and `WorkspaceFileResponse` in `MaiStandardTools` define
the complete Codable payload. Reads and upload chunks are limited to 512 KiB;
listings return at most 500 entries per page. Download versions detect changes
between chunks. Uploads use private staging files, publish only after completion,
and clean up on cancellation or disconnection.

The local and worker services reuse the CLI Files tools' path resolver, including
symlink checks. The worker validates `cwd` against its served paths, keeps file
operations inside that project, and honors saved Files access rules and
`filesWriteEnabled`. Denied paths are omitted from listings. `ask` paths remain
inaccessible to direct browsing until the host explicitly allows them; browsing
has no agent session for a tool approval. Read-only listings disable New Folder
and Upload in the phone interface. Hosts that lack the extension report that
an updated pmai is required.

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
- **Host workspace data stays behind a repository.** `ACPWorkspaceRepository`
  supplies folders and durable chats without coupling `AgentRuntime` to CLI or
  iOS persistence. The CLI exposes its `AgentHome` projects and saved chats through
  this adapter. `session/list` discovers them; `session/load` restores history.
  Persistent ACP session checkpoints retain interruption state and exclusive
  leases; browsing a host does not create a session. See [Remote ACP agents](tailcat.md).
