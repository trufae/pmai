# Editing things from the REPL

`/edit` opens something pmai owns in your editor, waits for the editor to
exit, and applies what you saved. It is the one door for anything too long or
too structured to type after a slash command: prompts, agent and provider
records, templates, the configuration file, the MCP list, a message in the
current chat. `/help edit` prints the short form of this page.

## Which editor

The editor is `/set ui.editor` when it is set, then `$EDITOR`, then `$VISUAL`,
then `vim`. `ui.editor` is saved in the configuration, so it survives restarts
and does not depend on the environment the terminal happens to have; it may
carry arguments (`/set ui.editor code -w`), the file path is appended to it,
and `/set ui.editor none` goes back to the environment. The terminal is handed
to it whole (the persistent prompt and status rows are suspended) and taken
back when it exits. An editor that exits with a non-zero status, or a file
saved as anything but UTF-8, cancels the edit and nothing changes. Saving the
file unchanged is also a no-op.

Every target is written to a temporary file with a suffix that tells the
editor what it is holding (`agent-main.json`, `compact-prompt.md`, and so on),
so syntax highlighting and JSON checking work without configuration.

## Targets

| Command | What opens | When it applies |
| --- | --- | --- |
| `/edit prompt [NAME]` | The prompt called NAME as Markdown, whether a system prompt or a user prompt; a new name is refused, since the two are different things. Current agent's system prompt when omitted. | Immediately. |
| `/edit system [NAME]` | A named system prompt; creates it when NAME is new. Current agent's prompt when omitted. | Immediately, in every agent that uses the prompt. |
| `/edit user NAME` | A user prompt — a message sent with `$NAME`; creates it when NAME is new, starting from the builtin prompt of that name if there is one. | Immediately. |
| `/edit NAME` | The same, for an existing system or user prompt name. | Immediately. |
| `/edit agent [ID]` | One saved agent as JSON: provider, model, tools, limits, prompt name, delegation, retry, autocompact. Current agent when omitted. | Immediately; the current chat picks up its own agent's changes. |
| `/edit provider [ID]` | One configured provider as JSON: base URL, key source, headers, timeout, options. Current provider when omitted. | Immediately; the provider is rebuilt in the running session. |
| `/edit compact` | The template `/chat compact` and autocompact render. | Immediately. |
| `/edit smart` or `/edit prompt smart` | The per-turn working-context template for `ctx.context=smart`, using the compact model. | Immediately. |
| `/edit prompt recap` | The embedded recap template: short goals, actions/results, and pending tasks with emoji labels. Must keep `{{transcript}}`; clearing it restores the default. | Immediately. |
| `/edit prompt compact` | The generated compact agent's system prompt (formerly `task-compact`). | Immediately. |
| `/edit prompt tool` | The generated tool agent's system prompt (formerly `task-tool`). | Immediately. |
| `/edit memory` | This project's durable notes (`.pmai/memory.md`). Same as `/memory edit`. | Immediately. |
| `/edit memory-prompt` | The template `/memory learn` sends to the model. | Immediately. |
| `/edit delegation` | The brief a child agent receives when started. | Immediately. |
| `/edit worker` | The instructions of the derived worker agent. | Immediately. |
| `/edit config` | The whole configuration file. | Agent limits and tool-calling strategy immediately; providers, plugins, tools, and MCP servers after a restart. |
| `/edit mcps` | The configured MCP server list as JSON. | After a restart. |
| `/edit input` | An empty file for the next message, so a long one is written with the editor's keys instead of at the prompt. | Sent as an ordinary message when the editor closes; an empty file sends nothing. |
| `/edit N` | Message N of this chat as Markdown. | Immediately; attachments are kept. |
| `/edit MESSAGE_ID` | The same, by the message's full id. | Immediately. |

The `id` field of an agent or provider record must stay what it was: `/edit`
changes one record, `/agent add` and `/edit config` create new ones.

### Prompts

`/edit system` is the long form of `/prompt add NAME TEXT`. The prompt is
saved under `prompts.system` in the configuration and every agent whose
`systemPrompt` names it starts using the new text at its next turn. Emptying
the file does not delete the prompt; `/prompt rm NAME` does that, and only
when no agent uses it. `/edit user` is the long form of
`/prompts add NAME TEXT`: the text is saved under `prompts.user` and
`$NAME [TEXT]` sends it; `/prompts rm NAME` drops it. See `doc/prompts.md`
for how prompts and agents fit.

### Agents

`/edit agent` shows the same JSON `/agent show ID` summarizes. Change the
`systemPrompt` name and `instructions` follows it; change `model`,
`provider`, `toolNames`, `toolGroupNames`, `subagentNames`, `limits`,
`toolDelegation`, `retry`, or `autocompact` and the current chat applies them
if it runs that agent. `/agent tools|model|prompt|provider ID VALUE` covers
the one-field cases without an editor.

### Providers

`/edit provider` opens a record like this one:

```json
{
  "id": "opencode",
  "kind": "openAICompatible",
  "baseURL": "https://opencode.ai/zen/go/v1",
  "apiKeyEnvironment": "OPENCODE_API_KEY",
  "headers": {
    "x-opencode-session": "{{session}}"
  },
  "headerEnvironment": {},
  "options": {}
}
```

`headers` are sent with every request. Write them as an object of names to
values, as shown, or as `"Name: value"` strings in an array; the file is saved
back in the object form. A value may contain `{{session}}`, which every
request replaces with the session id of the chat it belongs to: one id per
chat, minted when the chat is created, kept in its file, and shared with the
child agents it starts. `/chat session` shows it and `/chat session new`
starts a fresh one. OpenCode Zen's Go plan requires it in
`x-opencode-session`. `headerEnvironment` maps a header name to the
environment variable holding its value, for keys that should stay out of the
file, and `apiKeyEnvironment` or `apiKeyFile` do the same for the bearer key.

When the editor closes, the provider is built again from the record and
replaces the old one in the running session, so a header or URL change is
live at the next message. `/provider` lists the header names the current
provider sends, and `/baseurl URL` changes just the URL.

### Templates

The compact and memory templates must contain `{{transcript}}`; `{{focus}}`
and `{{memory}}` are optional. The delegation template must contain
`{{task}}`; `{{context}}`, `{{output}}`, `{{agent}}`, and `{{cwd}}` are
optional. A template saved without its required placeholder is rejected and
the previous one stays. Clearing a template restores the built-in default.
`doc/agents.md` explains where the delegation and worker templates are used.

### Configuration and MCP servers

`/edit config` opens the active configuration file (`--config`, `PMAI_CONFIG`,
`./pmai.json`, or `~/.config/pmai/config.json`, whichever is in use). It is
reloaded when the editor closes; a file that no longer parses is reported and
left for you to fix, and nothing is applied from it. `/edit mcps` opens only
the `mcpServers` array. Provider, plugin, tool, and MCP changes made this way
need a restart, since those are built when pmai starts; `/edit provider` is
the exception, because it rebuilds the one provider it edited.

### Messages

`/edit N` opens message N of the current chat; indexes are 1-based and count
from the end when negative, so `/edit -1` is the last message. The text
comes back as the message body and any attachments stay. `/chat edit INDEX
TEXT` does the same in one line, `/chat messages` shows the indexes, and
`/chat remove`, `/chat undo`, and `/chat trim` cover deleting rather than
editing.

### Writing a message

`/edit input` is the odd one out: it changes nothing pmai owns. An empty file
opens, and what it holds when the editor closes is sent to the chat as if it
had been typed at the prompt, so a long message is written with the editor's
keys. Leaving the file empty sends nothing. It works at the chat prompt; in
visual mode, type the message into the pane.

## Related one-line commands

`/reply [WIDTH]` opens the editor on the last assistant reply, quoted: every
line wrapped to fit the screen and prefixed with `> `, with a blank line under
it to write the answer in. Leaving the editor sends the whole file as an
ordinary message, so the model reads the answer next to the text it answers,
the way the reply action in the iOS app does. `WIDTH` wraps the quote at an
explicit column instead. Leaving the quote untouched sends nothing.

`/memory edit`, `/todo edit`, and `/prompt edit [NAME]` open the same editor
on the project's memory notes, its todo list, and a named prompt. `/set
SETTING VALUE` changes a single agent setting without an editor; `/help set`
lists them.
