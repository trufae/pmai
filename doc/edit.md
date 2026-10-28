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

Most targets are written to a temporary file with a suffix that tells the
editor what it is holding (`agent-main.json`, `compact-prompt.md`, and so on),
so syntax highlighting and JSON checking work without configuration.

## Targets

| Command | What opens | When it applies |
| --- | --- | --- |
| `/edit prompt [NAME]` | The prompt called NAME as Markdown, whether a system prompt or a user prompt; a new name is refused, since the two are different things. Current agent's system prompt when omitted. | Immediately. |
| `/edit system [NAME]` | A named system prompt; creates it when NAME is new. Current agent's prompt when omitted. | Immediately, in every agent that uses the prompt. |
| `/edit user NAME` | A user prompt — a message sent with `$NAME`; creates it when NAME is new, starting from the builtin prompt of that name if there is one. | Immediately. |
| `/edit skill NAME` | A skill's `SKILL.md`; creates its folder when NAME is new. Add `--user` to use your home skills. Same as `/skills edit NAME`. | Immediately; supporting files stay in place and new skills are enabled for the current agent. |
| `/edit NAME` | The same, for an existing system or user prompt name. | Immediately. |
| `/edit agent [ID]` | One saved agent as JSON: provider, model, tools, limits, prompt name, delegation, retry, autocompact. Current agent when omitted. | Immediately; the current chat picks up its own agent's changes. |
| `/edit provider [ID]` | One configured provider as JSON: base URL, default model, key source, headers, timeout, options. Current provider when omitted. | Immediately; the provider is rebuilt in the running session. |
| `/edit compact` | The template `/chat compact` and autocompact render. | Immediately. |
| `/edit smart` or `/edit prompt smart` | The per-turn working-context template for `ctx.strategy=smart`, using the compact model. | Immediately. |
| `/edit prompt recap` | The embedded recap template: short goals, actions/results, and pending tasks with emoji labels. Must keep `{{transcript}}`; clearing it restores the default. | Immediately. |
| `/edit prompt compact` | The generated compact agent's system prompt (formerly `task-compact`). | Immediately. |
| `/edit prompt tool` | The generated tool agent's system prompt (formerly `task-tool`). | Immediately. |
| `/edit memory` | This project's durable notes (`.pmai/memory.md`). Same as `/memory edit`. | Immediately. |
| `/edit redact` | Your redaction rules (`~/.pmai/redact.txt`). | Reloaded immediately when redaction is enabled. |
| `/edit soul` | Your global core personality (`~/.pmai/SOUL.md`); creates the file and its directory if needed. | On the next model request. |
| `/edit memory-prompt` | The template `/memory learn` sends to the model. | Immediately. |
| `/edit delegation` | The brief a child agent receives when started. | Immediately. |
| `/edit worker` | The instructions of the derived worker agent. | Immediately. |
| `/edit config` | The whole configuration file. | Agent limits and tool-calling strategy immediately; providers, plugins, tools, and MCP servers after a restart. |
| `/edit mcps` | The configured MCP server list as JSON. | After a restart. |
| `/edit input` | An empty file for the next message, so a long one is written with the editor's keys instead of at the prompt. | Sent as an ordinary message when the editor closes; an empty file sends nothing. |
| `/edit N` | Message N of this chat as Markdown. | Immediately; attachments are kept. |
| `/edit MESSAGE_ID` | The same, by the message's full id. | Immediately. |

On iOS, **Settings → Agent → SOUL.md** edits `.pmai/SOUL.md` in PocketMai's
Files workspace. Saving updates the core personality instructions on the next
app-run model request; clearing the file removes them. Remote agent hosts use
their own configuration.

The `id` field of an agent or provider record must stay what it was: `/edit`
changes one record, `/agent add` and `/edit config` create new ones.

### Prompts

`/edit system` is the long form of `/prompt add NAME TEXT`. The prompt is
saved under `prompts.system` in the configuration and every agent whose
`systemPrompt` names it starts using the new text at its next turn. Emptying
the file does not delete the prompt; `/prompt del NAME` does that, and only
when no agent uses it. `/edit user` is the long form of
`/prompts add NAME TEXT`: the text is saved under `prompts.user` and
`$NAME [TEXT]` sends it; `/prompts del NAME` drops it. See `doc/prompts.md`
for how prompts and agents fit.

### Skills

`/skills add NAME` and `/edit skill NAME` open a Markdown draft with YAML name
and description fields followed by the skill's instructions. Fill in the
description and prompt, keeping the name unchanged. Saving an unchanged draft
creates nothing. Existing skills retain their supporting files and extra YAML
fields. `/skills add NAME "DESCRIPTION" "PROMPT"` creates one without an editor,
`/skills import ZIP_OR_FOLDER` imports one, and `/skills del NAME` deletes it.
Skills are created under the project's `.pmai/skills`; `--user` uses the home
skills folder. Editing and deletion use the visible copy unless `--user` or
`--project` selects a specific copy. Quote names and paths containing spaces.

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
  "_credentialHelp": [
    "baseURL: the remote API endpoint, such as https://api.openai.com/v1.",
    "defaultModel: the model ID to use when no model is explicitly selected."
  ],
  "id": "opencode",
  "kind": "openai",
  "baseURL": "https://opencode.ai/zen/go/v1",
  "defaultModel": "some-model-id",
  "apiKey": null,
  "apiKeyEnvironment": "OPENCODE_API_KEY",
  "apiKeyFile": null,
  "headers": {
    "x-opencode-session": "{{session}}"
  },
  "headerEnvironment": {},
  "options": {}
}
```

The editor always shows `baseURL`, `defaultModel`, `apiKey`,
`apiKeyEnvironment`, and `apiKeyFile`, even when they are unset (`null`).
It also shows a `_credentialHelp` note, which is
discarded when you save. To use an environment variable, set
`apiKeyEnvironment` to its **name** (for example, `OPENAI_API_KEY`) and export
the variable before starting pmai. Set `apiKeyFile` to a file path containing
the key, or set `apiKey` to the key itself if you want it saved in the config
file. A configured environment variable takes precedence over the file, which
takes precedence over `apiKey`.

`defaultModel` is the model used when you select that provider without naming
a model, or when an agent's model is empty. An explicit model still takes
precedence. Set it to `null` to leave it unset.

For example, run `export OPENCODE_API_KEY='your-key'` in the shell before
starting pmai, then set `"apiKeyEnvironment": "OPENCODE_API_KEY"` in the provider.

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
provider sends. Change `baseURL` in this editor to update the connection.
Unknown top-level fields, invalid JSON, and invalid field values produce an
error and reopen the same draft for correction. `headers`, `headerEnvironment`,
and `options` remain maps with provider-specific names.

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
comes back as the message body and any attachments stay. `/edit chat N` and
`/msg edit N` open the same editor. `/msg edit INDEX TEXT` replaces the text
in one line. `/msg list` shows the indexes. Inside `/msg chop`, `e` opens
the selected message in the same editor and saves changes immediately.
`/msg del`, `/msg undo`, `/msg trim`, and `/msg rewind` cover deleting rather
than editing.

### Writing a message

`/edit input` is the odd one out: it changes nothing pmai owns. An empty file
opens, and what it holds when the editor closes is sent to the chat as if it
had been typed at the prompt, so a long message is written with the editor's
keys. Leaving the file empty sends nothing. It works at the chat prompt.

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

### Redaction rules

`/edit redact` opens `~/.pmai/redact.txt` directly in your configured editor,
creating it with private permissions if needed. With `--home` or `PMAI_HOME`,
it lives in that pmai home instead. Saving valid rules reloads an enabled filter
immediately. Invalid regexes report their line number and leave the previously
loaded rules active; startup with an enabled but unreadable or invalid file
fails instead of sending unfiltered requests.

Use `/set redact on`, `/set redact off`, or `/set redact warn`. The setting is
saved in the configuration; `off` is the default. `warn` filters exactly like
`on` and writes a warning with the match count for each affected model request,
including repeated context. Warnings contain neither matched values nor rules.
`/set redact` shows the current mode.

Each nonblank line is a case-insensitive substring, or a regular expression if
it begins with `/`. Lines beginning with `#` are comments. Regexes use ICU syntax;
the final `/` is optional, and inline flags can override case sensitivity.
For example:

```text
# Replace with your own username
private_username
# Card-like sequences: tune this to the formats you need
/\b(?:\d[ -]?){13,19}\b/
```

An optional `=label` after a keyword or a closing regex delimiter names its
placeholder, for example `private_username=USER`. Replacements are unique,
opaque tokens, not a shared `<REDACT>` marker: separate values and original
capitalization can be restored accurately. Overlapping matches are hidden
together. Existing path-valued `redact` settings must be changed to `"on"` or
`"warn"`, with their rules moved into `redact.txt`.

Filtering happens at every model-request boundary, including tools' text and
structured results, child agents, compaction, and model-based approval reviews.
The tool engine restores arguments before validation, path checks, and approval;
the assistant's tool-call record stays redacted during execution. Tool results
are filtered again before the next model call. Each chat has its own in-memory
token table, shared with its children; another chat cannot restore its tokens.
Local history and ordinary tool output remain readable.

This filters text sent to models, not access by tools. Approved tools (including
network and MCP tools) receive original arguments and retain their existing
permissions. Binary attachments and encrypted provider state are not inspected;
use extracted text when those contents need redaction. Labels should describe
the category, not repeat the private value. The ordinary debug log and saved
local chats may contain originals; `warn` does not enable debug logging.
