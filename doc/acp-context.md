# Context, tools, skills, and prompts through ACP

When pmai runs Claude Code or Codex through ACP, the external agent owns its
conversation, native tools, and compaction. pmai supplies the interface,
instructions, and optional tools. Choose whether pmai or the external agent
supplies context and the base prompt with:

```text
/set acp.context replace
/set acp.prompt replace
```

Both default to `agent`, preserving the external agent's session and base
prompt. The choices are independent and saved for the selected ACP provider.
Use `/set acp.` to inspect them. `on`/`true` are aliases for `replace`;
`off`/`false` select `agent`. `/reset acp.context` and `/reset acp.prompt`
restore each default; a full `/reset` restores both for the selected provider.

See [ACP and MCP](acp.md) for installation and provider setup, and
[Claude Code through ACP](claude.md) for Claude authentication and settings.
Native options depend on the installed adapter and agent versions.

## What works today

| Capability | Behavior through pmai + ACP |
| --- | --- |
| Pin a message | Saves a pmai pin; replacement context includes retained pins and marks them in the handoff. |
| Edit or delete a message | With `acp.context replace`, the next turn starts from pmai's edited context in a new session. |
| Compact or prune context | With `acp.context replace`, pmai's prepared context becomes the next session's input. |
| Add MCP tools | Forward pmai tools over MCP, or supply servers directly to the adapter. |
| Add skills | Use pmai's skill tools or install skills in the external agent's native directories. |
| Edit pmai instructions | Sent as user text in `acp.prompt agent`, or as native instructions in `replace`. |
| Replace the agent's base prompt | Supported for agents advertising ACP override, including current Claude adapters, and locally launched `codex-acp`. |

## Pins, deletion, and the two histories

These commands operate on the pmai transcript:

```text
/msg list
/msg pin 5
/msg unpin 5
/msg del 5
/msg edit 5 Replacement text
/msg chop
/msg rewind
```

Indexes are 1-based; negative indexes count from the end. Pin and unpin also
accept message IDs. `/msg chop` opens an interactive browser for pinning,
editing, deleting, and trimming. `/msg rewind` trims after the newest pinned
message. Removing a message can also remove linked tool messages to preserve
valid tool transactions. See [message editing](edit.md#messages).

### Keep the agent's conversation

```text
/set acp.context agent
```

The external agent keeps its history, including native tool results.
`ACPProvider` pools clients by working directory and pmai session ID. After a
successful turn, subsequent prompts normally send only newly appended user
text, together with pmai's current instructions.

In this mode, pmai detects changes by comparing user-message text. Editing or
removing an earlier user message can cause reconnection, but editing only an
assistant reply or tool result does not. Pins do not guarantee retention across
the agent's native compaction. A provider using `sessionFile` can also reload
its existing session on reconnection. Local deletion is not proof that the
agent has forgotten the material.

### Replace context from pmai each turn

```text
/set acp.context replace
```

Every provider turn starts a fresh ACP session and receives the entire
conversation prepared by pmai. This bypasses stored session restoration,
including `sessionFile`, and leaves those saved checkpoints unchanged.
Deleted or edited assistant replies and tool results
therefore affect the next request, even when user-message text is unchanged.

The handoff includes role labels, retained pin markers, full text, historical
tool names and arguments, tool results, structured results, and text
attachments. Historical calls are evidence and are not executed again. This
is a textual handoff, not an import of native assistant/tool records. Binary
images, audio, and binary-only files are represented by labels; their binary
contents are not replayed by this ACP provider.

pmai's `/chat compact` and `/set ctx.strategy ...` determine the prepared
conversation. The resulting context is sent to the new agent session. A pin
is a pmai retention choice and a marker in that context; it is not a command
that disables the external agent's own compaction.

Replacement resends context and starts an adapter process/session each turn,
which adds startup work and can increase token use. Native tools still run
inside the agent's turn, and native session state not recorded in pmai's
prepared transcript is not restored. Neither context replacement nor deletion
undoes filesystem changes or other tool side effects.

Implementation: [ACPProvider.swift](../MaiCore/Sources/MaiACP/ACPProvider.swift).

## Share MCP tools through pmai

Register a server in pmai:

```text
/mcp add --name mytools -- /absolute/path/to/server --stdio
/mcp info mytools
/tools
```

The server connects immediately and is saved in pmai's `mcpServers`
configuration. Its tools use pmai's normal exposure rules; `/mcp direct`,
`/mcp proxy`, and `/mcp hide` select exposure for the current agent.

For a local ACP provider, enabled tools are offered through a session-scoped
loopback HTTP MCP bridge. The adapter must advertise HTTP MCP support. Calls
through that bridge use pmai's validation, approvals, workspace rules, and run
budgets. The bridge accepts calls only while a prompt is active.

`/tools off` disables forwarded pmai tools. Claude/Codex's native tools execute
inside the external agent and have their own permissions and limits; this
command does not disable them.

## Give MCP servers directly to the adapter

Open `/edit provider claude` or `/edit provider codex` and merge an
`mcpServers` array into its existing `options`, preserving the command and
other settings. For example, this is an options fragment:

```json
{
  "mcpServers": [
    {
      "name": "mytools",
      "command": "/absolute/path/to/server",
      "args": ["--stdio"],
      "env": []
    }
  ]
}
```

These entries use the ACP server format, rather than pmai's top-level MCP
configuration format. pmai passes them to `session/new` and `session/load`;
the adapter connects to them directly. Calls do not pass through pmai's tool
bridge, so use the external agent's controls for them. See
[ACP session setup](https://agentclientprotocol.com/protocol/v1/session-setup).

For SSH providers, server commands and paths refer to the remote host. pmai
disables local tool forwarding for SSH by default. A custom remote wrapper
should set `options.forwardTools` to `false` when it cannot reach the local
loopback endpoint. WebSocket providers also use host-side tools rather than
the local bridge.

Saving `/edit provider` rebuilds that provider. Begin a fresh chat after
changing session-level MCP or native agent configuration so the adapter starts
with the intended setup.

## Skills managed by pmai

```text
/skills import /path/to/skill-folder
/skills enable NAME
/skills prompt NAME task arguments
```

pmai reads `.pmai/skills` in the project and `~/.pmai/skills` (or
`$PMAI_HOME/skills`). A project skill shadows a home skill with the same name.
Each folder contains `SKILL.md` and optional supporting files. Imports enable
the skill for the current agent; `/skills enable` also enables an existing
skill that was disabled.

Enabled skills become `skills_NAME` tools and can be exposed through the local
ACP MCP bridge. `/skills prompt` explicitly sends an enabled skill's
instructions and arguments as a prompt. A skill supplies instructions; it does
not grant access to disabled tools. Supporting files must be accessible to the
tools and host executing the work. Importing a skill locally does not copy it
to an SSH host.

## Skills managed by Claude or Codex

Native skills are a separate catalog from pmai's:

| Agent | Project location | Personal location |
| --- | --- | --- |
| Claude Code | `.claude/skills/NAME/SKILL.md` | `~/.claude/skills/NAME/SKILL.md` |
| Codex | `.agents/skills/NAME/SKILL.md` | `~/.agents/skills/NAME/SKILL.md` |

Install these on the machine running the external agent, relative to its
workspace or home directory. Native skill discovery and invocation follow that
agent's rules. pmai's `/skills` commands manage its own catalog and do not
install or enable native skills. See
[Claude skills](https://code.claude.com/docs/en/skills) and
[Codex skills](https://developers.openai.com/codex/skills/).

## Custom instructions and the base system prompt

Edit pmai's current agent instructions, then choose native replacement:

```text
/prompt edit
/set acp.prompt replace
```

Named prompts, prompt assignment, and shared prompts work as described in
[Prompts and agent definitions](prompts.md). The replacement includes pmai's
prepared system/developer instructions, including applicable workspace,
memory, skill, and tool guidance supplied by the runtime.

With the default `/set acp.prompt agent`, pmai prepends those instructions as
user text under `[pmai instructions]` on each request. This preserves the
external agent's built-in base prompt and does not give pmai's text native
system-message priority.

With `/set acp.prompt replace`, instructions are installed before the first
prompt and are not repeated as `[pmai instructions]` in user text:

- **Claude and other agents advertising override:** pmai sends ACP
  `systemPrompt` with `mode: "override"` and text content. Current Claude
  adapters advertise this capability. Older or unsupported adapters report an
  error with guidance to update or choose `agent`; pmai does not silently
  fall back to appending. See the
  [Claude adapter implementation](https://github.com/agentclientprotocol/claude-agent-acp/blob/main/src/client-system-prompt.ts).
- **Locally launched Codex:** the current Codex adapter's ACP `systemPrompt`
  accepts append mode only. pmai instead writes a private temporary instruction
  file and merges its path into `CODEX_CONFIG.model_instructions_file` before
  launching `codex-acp`. Other `CODEX_CONFIG` entries are preserved. The file
  remains available for the client lifetime and is removed when the client
  closes. See [Codex adapter prompt support](https://github.com/agentclientprotocol/codex-acp/blob/main/src/ClientSystemPrompt.ts),
  [adapter runtime options](https://github.com/agentclientprotocol/codex-acp#runtime-options),
  and the [OpenAI configuration reference](https://developers.openai.com/codex/config-reference/).

Local Codex detection uses the `codex-acp` executable name in the provider's
command or arguments, including an absolute path. An opaque wrapper with a
different name must expose native ACP override support or use its own native
configuration. SSH/WebSocket Codex cannot read pmai's local temporary file;
full prompt replacement is rejected for these connections. Remote Claude can
use replacement when its adapter advertises override support.

Prompt replacement starts with a new session instead of restoring a saved
session whose base prompt may already be fixed. It leaves `sessionFile`
checkpoints unchanged, so an overridden prompt cannot become the restored
default when replacement is disabled. Subsequent turns reuse that
session when `acp.context agent` is selected. If the prepared native
instructions change, pmai starts another fresh session and seeds it with the
prepared conversation so the new prompt takes effect immediately. With
`acp.context replace`, every turn already starts fresh.

Native workspace instructions (`CLAUDE.md`, `AGENTS.md`), permissions, tools,
MCP configuration, and additional developer instructions still follow the
agent's own rules. Replacing the base prompt does not disable those features.

## Limits within an agent turn

Context replacement controls what pmai hands to each new session. Claude/Codex
still owns the model requests and native tool loop within that turn. Selective
pruning of native tool results during the turn requires controls inside the
agent's harness or an adapter extension. pmai's pins and context settings do
not intercept every underlying model request.
