# MaiCore

MaiCore is the provider-neutral agent runtime shared by the `pmai` command-line
client and PocketMai. Concrete integrations are separate products:
`MaiOpenAI`, `MaiMCP`, and `MaiVisionOCR`. `MaiVisual` adds the SwiftTUI
terminal workspace used by the CLI's `/visual` command and is the package's only
external dependency; PocketMai does not link it. Each registers through the same plugin
API available to third-party providers. Together they support structured
message content, multimodal requests, native tool calls, approvals, MCP
Streamable HTTP servers, CLI-only stdio MCP processes, and bounded child agents.

Run the offline REPL from the repository root:

```sh
make repl
```

`make repl` loads an optional repository-local `env.sh` as a fallback when no
ad-hoc provider variable is already present in the calling shell. The ad-hoc
provider settings are `PMAI_PROVIDER`, `PMAI_MODEL`, `PMAI_BASE_URL`, and
`PMAI_API_KEY`; the older `MAI_*` and `OPENAI_*` names remain supported for
compatibility. `PMAI_API_KEY_FILE` names a file holding the key instead, read
at startup with its trailing newline dropped, so the secret never sits in the
environment where every child process could read it; it cannot be combined
with `PMAI_API_KEY`. These variables override the selected agent's provider for the
current process. `/baseurl` shows the effective URL and also identifies a
different persisted URL when one is being overridden. Export `PMAI_API_KEY=`
to explicitly send no API key and suppress configured or legacy API-key
fallbacks; merely unsetting it allows those fallbacks to be used.
Keep `env.sh` local because it can contain credentials.

Install a release build system-wide with `make repl-install`. The Linux
release archives come in two flavours: `pmai-linux-<arch>.zip` links against
glibc, libstdc++, libcurl, and libxml2, while `pmai-linux-<arch>-musl.zip` is
fully static and runs on musl distributions such as Alpine and on glibc systems
too old for the regular build. `www/install.sh` picks the static build on musl
systems automatically; set `PMAI_LIBC=musl` to force it elsewhere. Build the
static flavour locally with `make repl-musl` once the Swift Static Linux SDK
matching the toolchain is installed. Like the Android build, the static build
leaves out the `/visual` workspace because swift-tui does not build against
musl; `PMAI_NO_VISUAL=1` in the environment of `swift build` selects that
configuration. Native `--plugin` libraries cannot be loaded by the static build
either, because static musl executables cannot `dlopen`.

Run `pmai -U` or `pmai --update` to update using the website installer. It
updates the running executable's directory, or `PMAI_INSTALL_DIR` when set,
and reports "No updates available" without downloading the archive when the
installed version matches the release. `PMAI_VERSION` can select a specific
release instead of the latest. Automatic updates support macOS, Linux, and
Android and require `curl` and write access to the installation directory.

Print a complete configuration template:

```sh
make repl ARGS=--print-config
```

Load a configuration explicitly:

```sh
make repl ARGS='--config MaiCore/pmai.example.json'
```

Inside the REPL, `/models` queries the current provider's model catalog and
`/models PROVIDER` queries another registered provider without switching the
session. Use `/model NAME` to select one of the returned model IDs.
For llama.cpp or llamafile, use an OpenAI-compatible provider with a base URL
such as `http://127.0.0.1:8080/v1`; omit the API key unless the server requires
one. Model and voice discovery have a 15-second total deadline (or the
provider's shorter configured timeout), independent of the longer inference
timeout. Ctrl+C cancels `/models` and returns to the prompt. A server still
loading its model may return HTTP 503; retry after it is ready.

Use `/chat list` for a compact indexed history or `/chat log` for the complete
structured transcript, including attachments, reasoning, tool calls, tool
results, and structured MCP output. The current in-memory conversation can be
changed at any point with `/chat edit INDEX TEXT`, `/chat remove INDEX`,
`/chat undo [INDEX]`, `/chat trim INDEX`, `/chat compact [FOCUS]`, and `/chat
clear`. Positive message indexes are 1-based; negative indexes count back from
the end, so `-1` selects the last message. Compaction accepts optional guidance
describing the information the summary should prioritize. Trimming keeps
messages through the selected index and removes newer ones; linked tool-call
transactions are kept structurally valid when removing or trimming messages.

`/prompts` lists every prompt that can be sent by name — the named system
prompts and which agents use them, the user prompts, the builtin prompts, and
the skills — plus the compact, delegation, worker, and memory templates.
`$NAME [TEXT]` (short for `/prompts NAME [TEXT]`) sends prompt or skill `NAME`
with `TEXT` where its `$ARGUMENTS` stands, or after it; for a system prompt it
switches the agent to that prompt and then sends `TEXT`. User prompts are
reusable messages kept under `prompts.user`: `/prompts add NAME TEXT`,
`/prompts edit NAME` (or `/edit user NAME`), `/prompts show NAME`, and
`/prompts rm NAME` manage them, and one named like a builtin prompt — `goal`,
`newapp`, `tldr`, `followup`, shared with the iOS app — replaces it. `/prompt`
shows the active agent's system prompt and `/prompt NAME` points that agent at
another one.
`/prompt add NAME TEXT` creates a prompt from one line, `/prompt edit [NAME]`
edits or creates one in `$EDITOR`, `/prompt show NAME` prints one, and
`/prompt rm NAME` drops an unused one. Agents store the association in
`systemPrompt`; several agents may share a prompt, and editing it updates all of
them. Older inline `instructions` are migrated to a same-named prompt
automatically. `doc/prompts.md` walks through registering prompts and agents.

`/edit compact` opens the chat-compaction template. Prompts are saved under
`prompts` in the active configuration (normally `~/.config/pmai/config.json`).
The compact template must contain `{{transcript}}`. `{{focus}}` is replaced with
guidance passed to `/chat compact FOCUS`; if omitted, the focus is appended.
Clearing the compact template restores its built-in default.

Start `pmai` with `-y` (or `--yolo`) to permit all tool calls without approval
prompts for that process. `/set yolo on` saves the choice as `yolo` in the opened
project's `.pmai/settings.json`, so later runs in that project honor it until
`/set yolo off`. Both on and off override the configuration's `approvals.yolo`
default; projects without a saved choice still use that default. Changing the
project choice leaves the shared configuration unchanged. `-y` overrides the
saved choice for one run without changing it.

The REPL accepts heredoc-style multiline messages. Enter `<<WORD`, type the
message verbatim, then put `WORD` alone on its own line. The delimiter can be
any non-whitespace word; heredoc content is always sent as a message rather
than interpreted as a slash command:

```text
pmai> <<EOF
Explain this code:
if (ready) {
  run();
}
EOF
```

`/btw PROMPT` asks the active agent a one-off question in a fresh context. It
keeps the agent's system prompt, provider, model, tools, settings, and durable
memory, but receives none of the current chat transcript or queued attachments.
The answer is shown normally and then discarded, so the current chat is
unchanged.

`/copy` puts the last assistant reply on the system clipboard as plain text,
without reasoning blocks. `/copy N` copies the last `N` conversation messages
instead; several messages are labelled `User:`, `Assistant:`, and `Tool:`, while
tool calls, tool results, and attachments are summarized on their own lines.
Instructions are never copied. A trailing path writes the same text to a file
instead of the clipboard: `/copy reply.md` saves the last reply and
`/copy 4 ~/notes/chat.txt` the last four messages, replacing an existing file.
`/help copy` lists the forms. macOS uses the native pasteboard; other platforms
use the first of `wl-copy`, `xclip`, `xsel`, `pbcopy`, or `clip.exe` found in
`PATH`.

`/edit input` writes the next message in `$EDITOR` instead of at the prompt: an
empty file opens and what it holds when the editor closes is sent as an
ordinary message, so a long one is written with the editor's own keys. An empty
file sends nothing.

`/reply` answers the last assistant reply with it quoted above the answer. The
reply is wrapped at 40 columns, every line prefixed with `> `, and opened in
`$EDITOR` with a blank line under it; what the editor leaves is sent as if it
had been typed at the prompt. `/reply WIDTH` wraps the quote at another column
instead, and leaving the quote untouched sends nothing. It is the same quoting
the reply action in the iOS app uses.

`/visual` hands the terminal to a [SwiftTUI](https://swifttui.sh/) workspace
built by the `MaiVisual` module and returns to the prompt on `Ctrl+C`, `/exit`,
or the REPL button. The Chats tab keeps several conversations in a sidebar and
shows them in framed panes. Every action is reachable in three portable ways:
the button toolbar above the panes (Tab moves between controls, Return
activates, the mouse works too), the searchable command menu on `Ctrl+K` or
`F2`, and slash commands typed into a pane: `/pane new|split|down|close|next|prev`,
`/tab chats|providers|mcp|tools|agents`, `/menu`, `/sidebar`, and `/cancel`.
Alt chords (`Alt+N`, `Alt+V`, `Alt+S`, `Alt+X`, `Alt+arrows`, `Alt+B`,
`Alt+K`, `Alt+C`, `Alt+1` to `Alt+5`) are listed in the menu and work only where
the terminal sends Alt as an Escape prefix. The REPL's own slash commands run
unchanged on the focused pane's conversation: `/chat list`, `/model`, `/agent`,
`/image`, `/copy`, `/clear`, and the rest. Command output appears above the
input until Escape closes it. The Providers, MCP, Tools, and Agents tabs
register new OpenAI-compatible or plugin providers, connect Streamable HTTP MCP
servers, toggle the tools each conversation may call, register plugin tool
sources, switch agents, and save the focused conversation as a named agent.
The Stats tab draws one bar per provider:model, colored by provider, for
average output speed and for time in use, refreshed after every reply.
Registrations apply to the running session immediately and are saved atomically
to the loaded config path, or to `~/.config/pmai/config.json` when none was
loaded. Tool approvals raised
while the workspace is open appear as a sheet instead of a stdin prompt. Leaving
the workspace makes the focused conversation the REPL conversation; the other
conversations and the pane layout are kept in memory for the next `/visual`.
Visual mode needs an interactive terminal and, on macOS, version 15 or later.

`/attach PATH` queues a document for the next message. Word files, EPUB books
and PDFs are converted to Markdown (scanned PDF pages go through on-device OCR
on Apple platforms), JSON files become an indented outline, and other text files are
attached verbatim. HTML asks whether to keep its source, convert it to Markdown,
or copy it into the working directory; scripts can make that explicit with
`/attach source|markdown|copy PATH`. Images are attached at medium size, so use `/image` for other
sizes or OCR. `/attach clear` drops everything queued. The converters live in
the `MaiDocuments` module, which PocketMai links as well, so the app, the CLI,
and its visual mode share one implementation. `MaiDocuments` needs PDFKit for
PDFs, so PDF conversion is unavailable on Linux while Word, EPUB, JSON, and
text work everywhere. The same module holds the exporters (`ChatExport`, `MarkdownExport`,
`HTMLExport`, `EPUBExport`, `DOCXExport`): they write from a small `ExportDocument` that each
host builds from its own chat model, so `/export` here and the share sheet in
PocketMai produce the same files.

`/image` always takes a mode and a path. `tiny`, `small`, `medium`, and `big`
cap the longest edge at 100, 320, 640, and 1024 pixels; `full` preserves the
source image. `ocr` runs the separately injected `OCRProvider` and queues its
recognized text as a Markdown attachment:

```text
/image medium ./diagram.png
/image ocr ./receipt.jpg
```

The CLI installs `MaiVisionOCRPlugin`, whose on-device `VisionOCRProvider` is
selected with `kind: "vision"` on Apple platforms. The same plugin registers
`kind: "tesseract"`, which spawns a locally installed `tesseract` binary, so
OCR also works on Linux when the `tesseract-ocr` package is present. The CLI
picks the configured `ocrProviders` entry, then whatever the platform offers;
when nothing is usable it still starts and reports the reason the first time
`/image ocr` runs. A `tesseract` entry accepts `command` (defaults to
`tesseract`, or `TESSERACT_COMMAND`) and `languages` (for example `eng+spa`,
or `TESSERACT_LANGUAGES`) in its `options`. Other hosts can omit that module or
provide a different OCR implementation without coupling it to their chat/model
provider; PocketMai does this to preserve its layout-aware Markdown OCR.

The CLI also loads trusted native plugins from repeated `--plugin PATH` options
or from the configuration's `plugins` array. Relative config paths are resolved
from the config file's directory. `/plugins` shows built-in, statically linked,
and dynamically loaded plugins with their capabilities and origins. A plugin's
provider, tool-source, OCR, and MCP factory kinds are selected by the matching
`kind` fields in `providers`, `toolSources`, `ocrProviders`, and `mcpServers`.
See [PLUGIN_API.md](PLUGIN_API.md) for the versioned ABI and fixture command.

Custom model providers implement `ChatProvider` and register directly with
`AgentRuntime`. Configuration-backed hosts can additionally implement
`ConfiguredProviderFactory` and expose it from a `MaiPlugin` installed in the
shared `PluginRegistry`; provider kind identifiers and the `options` object are
open-ended, so adding a backend does not require a new MaiCore enum case. UI
settings remain host-owned and are translated into `ProviderRequest`,
`GenerationOptions`, and provider-specific configuration at the boundary.

Configuration is discovered in this order: `--config`, `PMAI_CONFIG`,
`./pmai.json`, and `~/.config/pmai/config.json`. Secrets should normally use
`apiKeyEnvironment`, `bearerTokenEnvironment`, or `headerEnvironment` instead
of being stored directly in JSON; a provider's `apiKeyFile` names a file
holding the key, read whenever the provider is built.

A provider's `headers` are sent with every request, for proxies that want a
tenant or routing header and for backends that need one. They are written as
an object of names to values or as `"Name: value"` strings, whichever reads
better; a saved configuration writes the object form. A value may contain
`{{session}}`, which every request replaces with the session id of the chat
it belongs to. Every chat has one: MaiCore mints it when the chat is created,
keeps it in the chat's file, and hands it to the child agents the chat
starts, so a backend that meters or routes by session sees one id per chat.
`/chat session` shows it, `/chat info` lists it, and `/chat session new`
starts a fresh session without touching the chat. OpenCode Zen's Go plan
requires exactly that in `x-opencode-session`:

```json
{
  "id": "opencode",
  "kind": "openAICompatible",
  "baseURL": "https://opencode.ai/zen/go/v1",
  "apiKeyEnvironment": "OPENCODE_API_KEY",
  "headers": ["x-opencode-session: {{session}}"]
}
```

`headerEnvironment` maps a header name to the environment variable holding
its value. `/edit provider [ID]` opens one configured provider as JSON and
rebuilds it in the running session when the editor closes, so headers can be
added without a restart; `/provider` lists the header names it sends.

Chats belong to a project, the directory pmai was started in, mirroring the
chat folders PocketMai keeps with a name, a tint, and a working folder. The
project's own file and its chats live in `.pmai/` inside that directory (one
JSON file per chat under `.pmai/chats/`, so add `.pmai/` to your gitignore),
while the list of every project ever opened lives outside them in
`~/.pmai/projects.json` next to the shared `~/.pmai/history.json`. `PMAI_HOME`
or `--home` relocate that root, `PMAI_STATE` or `--state DIR` relocate one
project's chat directory, and `--projects` prints the project list without
starting the REPL. A directory that cannot be written keeps its files under
`~/.pmai/projects/<id>/` instead. `/project` shows the open project,
`/project list` shows them all, `/project name` and `/project tint` set the
name and the prompt color, and `/project forget` drops an entry from the
list. When the default home is in use, chats found in the pre-project
`~/.config/pmai/chats.json` are imported into the first project opened
afterwards and the file is renamed `chats.json.imported`.

The persistence rules are shared with the PocketMai app through MaiCore.
`ChatFileStore` keeps one JSON file per chat in a directory, the layout
PocketMai has used since its first release, with ISO 8601 dates, `.json.corrupt`
quarantine names, and newest-wins merging; PocketMai stores its own
`Conversation` documents through it unchanged, and `AgentChatStore` is the
same store for MaiCore's `AgentChat`. Every launch opens a fresh chat that is
named after its first message, a chat that never receives a message, name, or
archive flag is disposable, and a disposable chat is never written or listed,
whichever way the process ends. Saving never deletes an existing file, so
upgrading a store cannot lose a chat. `AgentProject`, `AgentProjectIndex`, and
`AgentHome` carry the project side, with `AgentProjectTint` stored the way
PocketMai folder colors always were.
`-l` lists saved chats for the current project, and `-r INDEX|ID|TITLE` (or
`--resume`) reopens one; `-r` without a selector reopens the most recently
updated chat. A chat is saved with the agents its runs started and their
transcripts, so a reopened chat lists them under `/agents tree`, `/agents log
PID` reads one, and `/agents clear` drops them (see `doc/agents.md`). `/chat list`
shows the earlier chats grouped by day (Today, Yesterday, This week, Last week,
then dates), newest first, with their agent, size, and last-update time, and
lists archived chats last; `/chat list active` and `/chat list archived` narrow
it down. `/chat use INDEX|ID|TITLE`, `next`, and `previous` switch chats,
`/chat info` shows when a chat started and was last updated, `/chat archive`
moves a chat out of the active list (archiving the current chat starts a new
one), `/chat unarchive` brings it back, and `new`, `rename`, and `close` manage
chats, while `messages`, `log`, `edit`, `remove`, `undo`, `trim`, and `clear`
operate on the active transcript. Tab completes commands, chat selectors,
agents, and providers: one match is typed out, and several open a rotating
menu on the status line above the prompt instead of printing into the chat.
The first match is inserted immediately; each further Tab selects the next.
The highlight always matches the input and stays visible on narrow terminals.
The menu shows only suffixes after the shared prefix (`↵` means no suffix).
Any other key closes it and restores the status line.
`/agent add NAME MODEL GROUPS PROMPT [PROVIDER [BASE_URL]]`
saves a reusable agent in one line from a model, comma-separated tool groups,
and a named system prompt; `/agent tools|model|prompt|provider ID VALUE` change
one saved agent, `/agent remove ID` drops one, and `/edit agent [ID]` opens one
as JSON. `/provider`, `/model`, and `/set tool.proxy` save changes back to the
current chat's agent in the shared configuration.

Use `/baseurl URL` to change the current provider endpoint. To edit another
provider, select it first with `/provider ID`. The provider is replaced in the
live runtime and the new URL is saved immediately. `/provider baseurl URL`
remains an alias, and `/edit provider [ID]` opens the whole provider record
(base URL, key source, headers, timeout, options) as JSON with the same live
reload. In `/visual`, open the Providers tab, choose **Edit** beside a
configured provider, change **Base URL**, and choose **Update**. See
`doc/edit.md` for everything `/edit` reaches.

On a terminal the prompt never goes away: the bottom two rows are reserved for
a status line (project, agent, what is running, how much is queued) and the
input line, and everything else scrolls above them. A message typed while a
turn runs is queued and joins the conversation at the agent's next model turn —
after the tool results it is about to read — so a running agent can be steered
without stopping it. `/queue` lists what is waiting, `/queue push TEXT` adds
without sending, `/queue pop` drops the newest, and `/queue drop` drops all.
`/export markdown|html|json|debug|epub|docx [PATH]` saves the chat as a file, with
the same writers PocketMai uses (`MaiDocuments`): `debug` is the JSON envelope
plus the tools and settings the chat runs with.
`/export archive [PATH]` writes a portable `.pocketmai.json` archive containing
the configured providers, prompts, MCP servers, agents, visible skills, and the
current chat together with every nested subagent chat and transcript.
`/import PATH` merges those settings, installs skills, and adds
chats without overwriting an existing chat. The same archive is understood by
PocketMai; its existing conversation packs and older pmai JSON chat exports
also remain importable.
`@PID TEXT` sends one message to a running child agent. `@2,3,4 TEXT` or
`@2 @3 @4 TEXT` sends the same message to several agents without changing
focus; `/agents tree` lists their process IDs. Each receives one copy at its
next model turn, including paused agents after they resume. Repeated IDs are
deduplicated, and an unknown or finished child recipient rejects the list.
`/queue push @2,3,4 TEXT` uses the same addresses without starting a turn;
`@main` includes the chat. `/agents focus PID` sends everything typed to one
agent until `/agents focus main`. When a tool asks for
approval the question is printed above the prompt and answered with `y`, `a`,
`n`, `e`, or `c` at the same prompt; any other line stays an ordinary message
and the question keeps waiting. Piped input keeps the one-line-at-a-time REPL,
where a turn finishes before the next line is read. A line starting with `!`
runs in the system shell with the terminal handed over — `!ls`, `!git diff`,
`!vim notes.md` — so interactive programs work; nothing is captured or sent to
the model, and a non-zero exit status is noted.

Child agents print as they work, in blocks rather than character by character,
every line prefixed with the child's pid (`agent#3 │ …`, `agent#3 → tool …`,
`agent#3 ↲ done …`) so two children working at once stay apart. `ui.subagents`
picks how much: `all` (replies and tool calls), `tools` (tool calls only),
`stats` (one line per model turn), or `none`. Every `/agents` row says how
long its run has been going (`5 turns · 2 tools · 2.1k tok · 1m4s`), and
`/agents tree` ends with a `Total:` row summing the turns, tools, and tokens
of the whole tree. When a turn ends the REPL prints `✓ took 5s` in cyan, or
`✗ took 5s` in red when it failed or was cancelled.

`/stats` ranks every provider:model pair by a combined ranking, then by its
three measured categories: average output speed, time in use, and efficiency,
with the request and token counts beside each bar. The runtime records every
provider call it makes — REPL turns, one-shot runs, tool-loop rounds, child
agents, and the visual workspace — into `ModelUsageStore`, kept in
`~/.pmai/stats.json` (`$PMAI_HOME` relocates it) so the totals span every
project. Tokens come from the provider's usage payload, or are estimated from
text length and marked `~` when it reports none; speed is visible output
tokens over the first→last token window of the stream, time in use adds the
wait for the first token, and efficiency is total tokens divided by seconds in
use and by requests (`tokens / (seconds × requests)`, printed as `tok/s/req`).
`/stats ranking`, `/stats speed`, `/stats time`, and `/stats efficiency` print one ranking.
`Ranking` sums each model's position in the three measured categories, so the
lowest score wins.
`/stats show PROVIDER[:MODEL]` prints every fact recorded about a model or a
provider, `/stats rm PROVIDER[:MODEL]` drops one row or a whole provider,
`/stats reset` forgets everything, and `/stats path` prints the file.
PocketMai's Statistics screen is built on the same `ModelUsageLedger` and
`ModelUsageReport`, so both hosts rank, color, and describe models alike.

On piped input each prompt is preceded by a colored separator so prompts remain
easy to find in terminal scrollback. Long input scrolls horizontally and is
printed in full when submitted. `/set ui.` lists the persisted terminal styling
options; `ui.bgline` colors the status line (or the separator), `ui.fgprompt`,
`ui.bgprompt`, `ui.fgcolor`, `ui.bgcolor`, and `ui.fgtoolresult` accept named
ANSI colors, `rgb:RGB`, or `none`, while `ui.bold` and `ui.markdown` accept `on`
or `off`. `ui.toolResultLines` accepts `all` or a line count (the default is
`all`; `0` restores the compact status-only display).
`/set ui.title TEXT` adds `[TEXT]` to the prompt and sets the terminal/tab title
with an ANSI escape sequence; `/set ui.title none` clears the configured label.
`/set ui.editor COMMAND` picks the editor `/edit`, `/reply`, and the other
editor commands hand the terminal to; it is saved in the configuration and used
before `$EDITOR`, `$VISUAL`, and vim, which are what an unset (or
`/set ui.editor none`) value falls back to. The command may carry arguments,
as in `/set ui.editor code -w`, and the file path is appended to it.
Successful tool results are yellow by default, tool starts remain green, and
failed results are red. Unified diff removals and additions, including output
from `files_patch`, use dark red and dark green backgrounds. `/set limits.`
shows the per-run limits of the current
chat's agent; `/set limits.maxToolCalls N` and `/set limits.maxModelTurns N`
change them and persist the change into that agent's configuration. The
`--max-tool-calls N` and `--max-turns N` flags override both for one launch.
Reaching a limit no longer ends a task with an error. A run that spends
`limits.maxModelTurns`, `limits.maxTotalTokens` (`/set limits.maxTotalTokens
120k`), or `limits.maxSeconds` (`/set limits.maxSeconds 10m`; a long model call
is cut short at the deadline) pauses at a turn boundary: everything it did is
kept in the chat, the REPL prints `⏸ took 4m2s · model turn limit (50) reached`,
and `/continue` runs the conversation again with a fresh budget
from exactly that point. A cancelled or failed turn is kept the same way, with
any tool call it never answered marked as not executed, so Ctrl+C is no longer
the end of the work. `/stop` is the command equivalent of Ctrl+C: it interrupts
the current turn and preserves undelivered messages. A new message with a
nonempty queue asks whether to submit it first, ignore it for that turn, or
clear it. `/retry` has been removed; `/continue` is the single resume command.
With `yolo` on, a spent turn budget is treated as a
checkpoint and the task continues on its own; the token and time caps always
stop, since they exist to bound the spend. A model call that fails — a dropped
connection, a 5xx — is repeated after `retry.delay` seconds up to
`retry.attempts` times (`↻ retry 1/2 in 5s: …`) before the turn fails.
`/set ctx.compact 120k` makes the runtime summarize the older part of the
conversation, in place and before a model turn, once it is estimated to hold
that many tokens (from the provider's own count when it reports one); the
newest exchange stays verbatim, the compact prompt gets a focus on finishing
the task at hand, and `✂ context: compacted 14 messages into a summary` says
what happened. Context windows differ per model and few providers state
theirs, so the threshold is an absolute count rather than a percentage.
`/set tool.calling text|xml|json` forces message-based tool calling for
models without native tools; `automatic` prefers native calls and otherwise
uses JSON, while `native` requires native support. The selected mode is saved
on the agent.
When a run spends its tool call budget, the remaining calls of that reply are
answered with an error and the model is asked to answer without tools instead
of the run failing. Replies are rendered as styled markdown while they stream:
headings, lists, task lists, quotes, rules, fenced code, footnotes, and pipe
tables whose cells keep their bold, code, and link styling and wrap to the
terminal width. `--no-markdown` or `ui.markdown off` prints replies verbatim,
output that is not a terminal stays verbatim unless `--markdown` is given, and
`NO_COLOR` keeps the structure without colors. The visual workspace renders the
same markdown inside its panes.
Up/Down or `Ctrl+P`/`Ctrl+N` move through input history. `Ctrl+R` starts an
incremental reverse search; type to narrow it, press `Ctrl+R` again for an older
match, Return to submit it, or `Ctrl+G` to restore the original input. `Ctrl+A`
and `Ctrl+E` move to the beginning and end, `Ctrl+B` and `Ctrl+F` move one
character left and right like the arrow keys, `Ctrl+W` deletes the previous word,
and `Ctrl+C` cancels the active model or tool run without leaving the REPL.
`Ctrl+Z` suspends pmai with the terminal restored; run `fg` in the shell to
resume the same input or active run.

`/set ctx.strategy size` (config key `context`, default `cache`) turns on the cheap
half of that: before every model call the runtime replaces the body of any file
read while answering an *earlier* prompt with one line saying what it was and
that `files_read` brings it back. Everything read for the prompt in progress
stays (pruning inside a run made models re-read what they still needed). File
bodies are the largest part of a coding conversation and are rarely read again
for a later prompt, so `size` cuts the tokens of a long chat; the price is that
a server's prompt cache is invalidated from the rewritten message on. `cache`, the default, never changes a message once sent, so the
cache covers every earlier turn and each call pays only for what is new. The
REPL prints `✂ context: rewrote 1 message (12.3k → 2.1k chars)` when it prunes.

`/set effort LEVEL [TEXT]` sets how hard the model thinks, with one scale for every
provider: `off`, `minimal`, `low`, `medium`, `high`, `xhigh`, or `max` (the REPL completes them).
The level is stored as the agent's `options.reasoningEffort` and
`ReasoningEffort` (in `MaiCore`) turns it into whatever the endpoint's API
family takes — `reasoning_effort` for OpenAI (only on models that reason, with
`xhigh` where it exists) and generic endpoints, `think` for Ollama (`low`,
`medium`, `high` on gpt-oss, `true` elsewhere), `enable_thinking` and a
`thinking_budget` for Qwen, `thinking: enabled` for DeepSeek, and the
`reasoning` object for OpenRouter; a field set in `options.additional` is never
overridden, and a value that is not one of the levels (`custom`, say) is sent
as `reasoning_effort` unchanged. The runtime also adds a system prompt section
that says how much care the task deserves, followed by `TEXT` when given, so a
model without a reasoning control hears it too. `/set effort` shows the current
setting; `/set effort auto` normally restores provider defaults, but explicitly
disables thinking for DeepSeek Flash because that provider otherwise defaults to
high effort. `/set effort off` (or
`/nothink`) explicitly disables thinking where supported; models such as GPT-OSS
only allow lowering effort. These settings persist on the agent. iOS uses the
same MaiCore enum and request mapping, including `xhigh` and `max`.

`/set ui.thinking status|line|three|five|full` controls presentation independently:
`status` shows “Thinking…”, `line` keeps the newest line, `three` keeps three
scrolling rows with a grey gradient, `five` keeps five, and `full` prints all
reasoning in grey italics. Compact previews occupy transient rows above the REPL prompt and clear
at text/tool boundaries, cancellation and errors. Pipes and captured output use
a plain status instead of cursor controls; `full` retains plain reasoning there.
`NO_COLOR` disables styling. The complete reasoning stays in the transcript in
every mode. iOS offers the same display modes in Settings, keeps completed
reasoning in separate disclosure blocks, and preserves their order between
responses and tool calls. Its default is a five-line tail with an estimated token
and character count; the complete block is rendered only when expanded.

Provider mapping references: [OpenAI](https://developers.openai.com/api/docs/guides/latest-model),
[Ollama](https://docs.ollama.com/capabilities/thinking),
[DeepSeek](https://api-docs.deepseek.com/guides/thinking_mode/),
[Kimi](https://platform.kimi.ai/docs/api/models-overview),
[MiniMax](https://platform.minimax.io/docs/api-reference/text-openai-api),
[Gemma](https://huggingface.co/google/gemma-4-31B-it),
[Gemini](https://ai.google.dev/gemini-api/docs/openai).

| Backend/model | Shared effort mapping |
| --- | --- |
| DeepSeek Flash | Auto/off sends `thinking.type=disabled`; minimal/low maps to low, medium/high/xhigh to high, and max to max |
| Kimi K2.5/K2.6 API | `thinking.type` enabled/disabled |
| Kimi K2.5/K2.6 local | `chat_template_kwargs.thinking`; MLX template context |
| Kimi K3 | low/high/max; off requests low |
| Kimi K2 Thinking/K2.7 | Always thinking; no unsupported toggle sent |
| MiniMax M2.x | Always thinking; effort is prompt guidance |
| MiniMax M3 | `thinking.type` adaptive/disabled |
| Gemma 4 | `chat_template_kwargs.enable_thinking`; MLX template context |
| Older Gemma | Prompt guidance; no unsupported reasoning parameter |
| Gemini 2.5/3 OpenAI API | `reasoning_effort`; off is available only on 2.5 non-Pro |
| Ollama/OpenRouter | The host's API takes precedence over model-specific fields |

MiniMax reasoning is returned in tagged assistant content when continuing tool
calls. DeepSeek retains `reasoning_content` only for requests carrying native
tools, as its API requires; tool-free requests omit it so old thinking does not
inflate the context. Kimi retains it for continuation regardless of the display
choice. Gemma's `<|channel>thought` / `<channel|>` delimiters are
normalized alongside `<think>` by the same stream parser. Unknown providers can
still use explicit `options.additional` fields without frontend changes.

Native tools are presented as plugin-defined capability groups instead of one
checkbox per provider-visible function. `/tools` lists the groups, `/tools
enable|disable GROUP` changes the active agent, and `/tools show GROUP` says
what the group is for and prints every tool with its description, how it is
approved, and its parameters, then the group's settings — the same schema the
model receives, readable. `/tools set GROUP OPTION VALUE` persists
typed group settings and reloads the source; for example, Mastodon's instance,
API-key environment variable, and write permission are configured this way.
Visual mode renders the same descriptors as checkboxes and typed fields. Group
selections live on each `AgentDefinition`, while source credentials and options
live on `ConfiguredToolSource`, so every host uses the same configuration and
plugin API. Older native plugins without group metadata are grouped by their
tool-name prefix and described by the first sentence of each tool. MaiCore's
runtime-native families come with a description of their own that says what
they are for and how the tools work together: `agent_start`, `agent_status`,
`agent_result`, and `agent_stop` form the `agents` group, the `chats_*` tools
`chats`, the `todo_*` tools `todo`, the `context_*` tools `context`, and the
`skills_*` tools `skills` (`AgentRuntime.builtInToolGroups`); enable or
disable each group independently on each agent.

MCP tool names are namespaced as `<toolNamePrefix>::<remoteName>`, or
`<server-id>::<remoteName>` when no prefix is configured. Connecting an enabled
MCP exposes all of that server's discovered tools to every agent; the server is
the enable/disable unit. Obsolete names left in an agent after an MCP rename are
ignored instead of preventing the REPL from starting. Agents still explicitly
list non-MCP tools and child agents they are allowed to use.
`MaiStandardToolsPlugin` provides date/time, the `calc` calculator,
network, and workspace-scoped Files tools.

### ACP and MCP

pmai speaks the Agent Client Protocol both ways and serves MCP too. `pmai --acp`
exposes the selected agent to any ACP editor (Zed, JetBrains, …) over stdio;
`pmai --mcp` exposes it as a single MCP tool. Diagnostics go to stderr so the
JSON-RPC stream stays clean.

The other direction treats a remote ACP agent as an ordinary MaiCore provider:
an `AgentDefinition` whose provider is `kind: "acp"` is selectable, spawnable,
and delegable like any other agent. `/agent acp list` shows the builtin catalog
(gemini, qwen, opencode, goose natively; claude and codex through adapters) with
what is installed, and `/agent acp add NAME [COMMAND ARG ...]` registers one. See
`doc/acp.md` for the design.

### Memory

Durable notes about the person an agent works with — stable facts, standing
preferences, habits worth carrying between chats. pmai keeps one per project in
`.pmai/memory.md`; PocketMai keeps one in its settings. The text, the envelope
it is injected in, the prompt that extends it, and the tools that read other
chats all live in `AgentMemory.swift`, so both hosts behave the same.

The notes are added to the system prompt of top-level runs only, wrapped in an
envelope that says they are inferred, may be stale, and always lose to what the
person is saying now. A subagent grepping a file never sees them, and nothing is
written into the stored transcript: memory is run-scoped context.

```
/memory                      show the notes and how they are configured
/memory edit                 edit them in $EDITOR (same as /edit memory)
/memory learn [FOCUS]        fold this chat into the notes
/memory learn --all [FOCUS]  fold every chat in this project into them
/memory add|set TEXT         append one note, or replace them all
/memory clear                forget everything
/memory reload               re-read the file after editing it elsewhere
/memory on|off               whether the notes reach the model
/memory scope none|project|all   chats the chats_* tools may read
/edit memory-prompt          edit the template /memory learn uses
```

Learning is a merge, not a rewrite: the existing notes travel with the request
and the model returns the complete set, so `/memory learn` never silently
forgets. `prompts.memory` overrides the template (`{{transcript}}` is required;
`{{memory}}` and `{{focus}}` are optional).

`chats_list`, `chats_search`, `chats_read`, and `chats_read_document` let an
agent use other chats as a source of information. `memory.scope` bounds them:
`none` keeps other chats private, `project` allows this project's, and `all`
crosses working directories. Enable them for an agent with `/tools enable
chats`; each call asks for approval.

### Context tools

An agent can tidy its own conversation instead of carrying every detour to the
end. `context_list` numbers the messages with their sizes and a preview;
`context_remove` drops messages by number, range, `last N` (the most recent
ones), or `all` (a tool call and its result always go together);
`context_rewrite` replaces one message's text, for example a wrong instruction
or a long tool result reduced to what matters; and `context_compact` replaces a
stretch (`all` by default) with a summary — one the agent writes, or, when it
leaves `summary` out, one the runtime asks the model for with the compaction
prompt, guided by an optional `focus`, exactly as autocompact does. Edits are
queued while the turn runs and applied before the next model call, so the
following turn already sees the smaller context; the REPL prints
`✂ context: removed 3 messages (12.3k → 2.1k chars)`. The system prompt, the
latest user prompt, and the turn in progress cannot be touched, and a task
that should start with no history at all belongs in a child agent
(`agent_start`). The tools live in
`MaiCore` (`MaiContextTools`), are part of the default agent's set, and
`/tools enable context` adds them to another. The three editing tools ask for
`confirm` approval; `/set yolo on` or `approvals.confirm = allow` lets an agent
use them freely. The edited conversation is what gets saved, so what an agent
removes is gone from the chat.

### Todo list

A task list the agent plans with and ticks off as it works, and that the
person can read and edit. pmai keeps one per project in `.pmai/todo.md` as a
Markdown task list (`- [ ] pending`, `- [x] done`); PocketMai keeps one in its
Todo tool settings. The item, the Markdown form, and the tools live in
`AgentTodo.swift`, so both hosts behave the same.

`todo_list` shows the numbered list, `todo_add` appends pending items (one per
line adds several at once), and `todo_done` ticks off one or several by number
or title fragment, separated by commas or newlines. Both answer in one line,
not with the whole list, and their descriptions tell the model to plan only
work of five or more steps: ticking off seven steps one call at a time cost a
benchmark run more tokens than the edits themselves. The list persists across
chats, and every call reads the file afresh, so editing it by hand is fine. The tools run without asking for
approval; they are part of the default agent's tool set, and `/tools enable
todo` adds them to another. Naming `todo` (or `chats`) in an agent's
`toolGroupNames` is enough: the group is expanded into tool names at startup
like a plugin group, and a saved chat adopts its agent's configured tool set
when it is opened, so a chat started before a group was enabled sees the new
tools too.

```
/todo                      show the list, numbered
/todo add TEXT             append one pending item
/todo done NUMBER|TEXT     mark an item done
/todo remove NUMBER|TEXT   drop an item; the ones after it move up
/todo edit                 edit the list in $EDITOR
/todo clear                remove every item
/todo path                 print where the file lives
```

### Skills

A skill is a folder holding a `SKILL.md`: front matter giving a `name` and a
`description`, then the instructions to follow as the body, with any scripts
or reference files beside it. It is the layout other coding agents use
(`<skills dir>/<name>/SKILL.md`), so a skill written for one of them works
here unchanged. pmai reads the project's `.pmai/skills` and `~/.pmai/skills`
(`$PMAI_HOME/skills` when the home is relocated); a project skill shadows a
home one of the same name. The catalog, the front-matter reader, and the
tools live in `AgentSkills.swift`.

Each skill is also a `skills_<name>` tool, described by the skill's own
description, that answers with the instructions when the model calls it, so a
model that sees `skills_aicommit` can pick it up the way it picks up any
tool. The `skills` group holds them all: `/tools enable skills` (or naming
`skills` in an agent's `toolGroupNames`) offers every skill, present and
future, while `/skills enable NAME` and `/skills disable NAME` change one
skill at a time and persist in the agent's allow-list like any tool. The
tools run without approval, and every call reads the file afresh, so editing
a skill takes effect at once. A skill whose front matter says
`disable-model-invocation: true` is never offered as a tool.

`/skills prompt NAME [TEXT]` — or `$NAME [TEXT]`, which also reaches the
user and builtin prompts — sends the skill's instructions, then `TEXT`, as
the next message, whether or not the skill is enabled: a way to use one by
hand without letting the model decide. Where the body says `$ARGUMENTS` the
text goes there instead. The message carries the instructions inside a
`<skill name="…" directory="…">` envelope naming the folder, so paths in
them can be resolved.

```
/skills                    list skills; * marks the ones the agent may call
/skills show NAME          print a skill's file, tool state, and instructions
/skills enable NAME|all    offer a skill, or every skill, to the current agent
/skills disable NAME|all   stop offering it; /skills prompt still works
/skills prompt NAME [TEXT] send the instructions, then TEXT, as the next message
/skills path               print the directories scanned
/skills reload             rescan the directories (every /skills command does)
```

### Agents and subagents

An agent definition is a saved setup — provider, model, system prompt, tool set,
and limits — that people switch between with `/agent use ID`. Each one carries a
`description` saying what it is for, which a delegating model also reads when it
picks an agent for a task, and an `enabled` flag that parks a setup without
deleting it. `/agents` lists them; `/agents describe ID TEXT` and
`/agents enable|disable ID` maintain them. Visual mode edits the same fields on
its Agents tab.

A running instance of a definition is a process with a **pid**. `/agents tree`
draws them, `/agents log PID` prints one agent's own transcript,
`/agents stop PID` pauses it and everything under it at their next step, and
`/agents continue PID` lets them go on; messages queued for a paused agent are
read when it continues. `/agents kill PID` ends it and everything under it.
Any agent that is allowed
subagents can start more, so the result is a tree, bounded by
`limits.maxSubagentDepth` and `limits.maxSubagents` across the whole tree. A
child started when every slot is busy is not refused: it is registered as
`queued`, shows as such in `/agents tree`, and starts by itself, in order, when
a sibling ends; `agent_start` with `wait` false says `Queued researcher as #5`,
and a blocking start simply waits its turn. A child that hits a run limit
comes back to its parent as an error carrying whatever it said last, and the
whole tree shares the run's turn, token, and time budgets.
A chat is one process for its whole life, so a child started in the background
three turns ago is still addressable by the run that started it. Every process
has an inbox: `AgentSupervisor.post(_:to:)` queues a user message, and the run
appends it to its transcript at its next model turn — emitting
`AgentEvent.userMessage` — or goes round once more when it arrives while the
model is answering. Hosts pre-register a chat's process with
`AgentRuntime.allocateProcess(agentID:)` so messages can be queued before the
first turn, and read a child's events (tagged with the child's pid, background
or not) to show its work.

Subagents are disabled by default: enable the `agents` tool group and set the
agent's `limits.maxSubagents` above zero. `agent_start` takes a three-part brief
— `context`, `task`, and `output` — plus an optional `agent`, and waits for the
answer unless `wait` is false.
`agent_status` lists the caller's children without waiting, `agent_result`
collects a background answer, and `agent_stop` kills a subtree. A caller may
only address pids inside its own subtree. The retired `spawn_agent` and
`agent_launch` names still run but are no longer offered to models.

What an agent may call is always its definition's tool list, wherever it sits
in the tree. `toolDelegation` decides whether it may also hand work to a child.
`inline` is the default: the agent runs every call itself. `subagent` keeps the
agent's own tools and lets the enabled `agents` group send bulky work one level
down to a child whose transcript is discarded — the chat grows by one answer
instead of by a call and a result for every step, while small calls still run
in place. `/set delegation off|subagent` toggles it and persists it on the
agent. With no child definition named, MaiCore derives a `<agent>.worker` that
inherits the parent's provider, model, and tools.

`prompts.delegation` is the template a brief is rendered through (`{{task}}` is
required; `{{context}}`, `{{output}}`, `{{agent}}`, and `{{cwd}}` are optional),
and `prompts.worker` holds the derived worker's instructions. Both fall back to
MaiCore's built-in text and are editable with `/edit delegation` and
`/edit worker`. See `doc/agents.md` for the design behind all of this.

The tool family itself lives in `AgentProcessTools`, apart from the runtime,
so a host with a tool loop of its own offers the same four tools over the
same `AgentSupervisor`: `definitions(offering:delegating:)` builds the
schemas, `StartArguments` parses a call, `register` and `run` (or `launch`,
which does both in a task of its own) put a child in the table and record how
it ended, and `status`, `result`, and `stop` answer the other three calls.
`AgentSupervisor.complete` marks a host-driven process idle between turns.
PocketMai runs its children this way — each one an isolated run of its own
tool loop in a Swift task — and `AgentRuntime` uses the same code for the
children it starts, so an agent behaves the same wherever it is started.

In the `pmai` REPL, `/mcp list` shows configured servers and their live state.
Add and connect a stdio server without editing JSON using
`/mcp add COMMAND [ARG ...]`; the command basename becomes its ID. Use
`/mcp add --name ID [options] -- COMMAND [ARG ...]` when a different ID or
options are needed. `/mcp enable ID` and `/mcp disable ID` reconnect or
disconnect the complete server tool set and persist the state. Run `/mcp` for
the full option list. The legacy `/mcps` spelling remains a list alias.

`web_fetch` preserves plain text/source code and cleans only HTML. Its default
page is at most 16,000 UTF-8 bytes; `max_bytes` can request up to 256,000 or
`0` for metadata only. Downloads are capped at 16 MB while receiving data,
including chunked responses. Each successful fetch returns a `source_id`,
`totalBytes`, `offset`, `nextOffset`, and `truncated`. Continue with
`{"source_id":"…","offset":16000}` or search the whole remaining source with
`{"source_id":"…","query":"symbol to find","max_bytes":4000}`. A search returns
a page around the first literal, case-insensitive match at or after `offset`.
Offsets always address the UTF-8 text (after HTML extraction when applicable).

Sources are immutable in-memory snapshots shared by tools and child agents;
the least recently used snapshots are evicted at 16 sources or 32 MB. A missing
ID returns an explicit error; fetch its original URL again to obtain a new
snapshot. URL calls deliberately fetch fresh content, while source ID calls
never download. For large extraction tasks, fetch metadata only and pass the
ID or a file path plus a focused question to `agent_start`. Ask for concise
findings with locations so the raw source stays in the worker's transcript.
Use file indexes/searches and targeted ranges for local data. Delegation still
requires the enabled agents tool group and respects the existing child limits.

`AgentRuntime` shares half of the remaining configured autocompaction budget
across a reply's tool calls as a default page-size hint (1–32 KB). Web and file
reads honor it when `max_bytes` is omitted; explicit sizes take precedence.
This estimate does not discover a local model's context window: set
`autocompact.tokens` to suit the model. In `size` context mode, web bodies from
completed prompts can be pruned like file reads, retaining the source ID,
URL and offset needed to recover them. The active prompt's data is retained.

The `files` group can list files, find approximate names, grep bounded UTF-8
content, convert DOCX/PDF/JSON documents, write or append text, create folders,
rename entries, and delete them. Existing files are edited in place with
`files_patch` (unique literal or regex replacement) or `files_replace_range`
(1-based line ranges); both return a unified diff. For large source files,
`files_get_function` finds a function by name and reports its complete line and
UTF-8 byte bounds plus a body revision. `files_set_function` uses that revision
to atomically replace only the body, preserving concurrent edits to other
functions and rejecting stale edits to the same function. Its lightweight
locator supports common brace-, indentation-, and `end`-delimited languages,
including HolyC `.hc` files. `files_write` refuses to replace a non-empty file unless
`overwrite: true` is passed, so a model cannot clobber a file it meant to
patch. `filesRoot` confines every relative
path to one directory (including symlink checks), while `filesWriteEnabled`
removes the mutation tools when disabled. Mutations still go through normal
confirmation, and deletion is marked dangerous.

With the default Files workspace (no explicit `filesRoot`, or `filesRoot: "."`),
`/cwd` prints the process working directory and `/cd PATH` changes it; the model
has no tool for that, since every path argument already takes a relative or an
absolute path. The default workspace resolves its root on each tool call,
keeping an installed `pmai` binary aligned with the directory from which it was
launched. An explicit `filesRoot` remains fixed. Paths are relative to that
directory, and an absolute path is accepted as long as it lies inside it, so a
model can reuse a path a shell command printed; a path error names the directory
so the model can correct itself.
The `run` group is one tool, `run_sh`, which executes code on this computer
with the privileges of the `pmai` process: the command line or script is saved
to a temporary file and run with the configured shell (`runShell`; a name looked
up in `PATH` or a full path, leading arguments such as `bash -e` honoured).
Other languages go through the shell (`python3 - <<'EOF' … EOF`), so there is
one schema to pay for on every call rather than four. The text is taken from
`command` or `script` interchangeably, since models mix the two up. Every call
may pass `args`, `stdin`, `cwd`, `timeout_seconds`, and `output`. Commands run
with color disabled and ANSI sequences are stripped from returned text.
`output: "auto"` (the default) returns small output but saves any stream larger
than 24 KB to a temporary file and reports its path; use `inline` to drop the
excess, `file` to save both streams immediately, or `none` to suppress them.
The process is killed after the timeout
(`runTimeoutSeconds`, default 60), and `Ctrl+C` terminates it. The tool is
marked dangerous, so it follows the `dangerous` approval setting, and the group
is absent on iOS. Use `/tools disable run` to remove it from an agent.
Streamable HTTP support is supplied by `MaiMCPPlugin`, so the transport is not a
dependency of the core runtime.

On non-iOS hosts, `MaiMCPPlugin` also supports the standard stdio MCP
configuration fields. `kind` may be omitted when `command` is present:

```json
{
  "id": "local-tools",
  "command": "npx",
  "args": ["-y", "your-mcp-package"],
  "env": {"EXAMPLE_API_KEY": "value"},
  "cwd": ".",
  "toolNamePrefix": "local"
}
```

The command inherits the `pmai` environment, with `env` values taking
precedence. A bare command is resolved through `PATH`; `cwd` is optional. Stdio
MCP support, including its subprocess factory and public transport types, is
compiled out on iOS. The iOS app continues to support Streamable HTTP only.

The example MCP entry is disabled so the example remains safe to inspect. Set
an HTTP URL or stdio command and enable it to expose all discovered tools. Set
`useToolProxy` on an agent to keep only the common tools (`files_read`,
`files_grep`, `files_patch`, `files_write`, `files_list`, `run_sh`) as native
schemas and put the rest behind MaiCore's `list-tools` and `call-tool`, whose
description names every hidden tool. `proxyExposedTools` chooses another set of
native tools, and an empty set hides them all; `/set tool.proxy on|all|off`
does the same at the prompt. `doc/proxy.md` has the measurements behind the
default.

Agents can force MaiCore's emulated tool loop with `toolCallingStrategy` set to
`text`, `xml`, or `json`. These modes send tool instructions as messages, parse
the model's response, execute the calls, return results, and continue until the
model answers. `automatic` uses native calls when the provider supports them
and JSON emulation otherwise; `native` requires provider-native tool calling.
