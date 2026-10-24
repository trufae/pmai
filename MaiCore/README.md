# MaiCore

`pmai --vim install|update|uninstall` manages the bundled
[Vim integration](../doc/vim.md) without needing a checkout. Select lines and
press `m` to choose a prompt, review pmai's reply, and apply it to the buffer.

Task-specific models are configured through saved agents in both pmai and iOS. See [providers, agents, and task defaults](../doc/task-agents.md) for `/model -compact`, `/model -tool`, `/model -btw`, persistent CLI overrides, and the iOS workflow.


MaiCore is the provider-neutral agent runtime shared by the `pmai` command-line
client and PocketMai. Concrete integrations are separate products:
`MaiOpenAI`, `MaiLocalProviders`, `MaiMCP`, and `MaiVisionOCR`.
`MaiLocalProviders` owns the Apple Foundation Models and MLX engines used by
both hosts, including availability checks, streaming, and model loading.
Each registers through the same plugin API available to third-party providers. Together they support structured
message content, multimodal requests, native tool calls, approvals, MCP
Streamable HTTP servers, CLI-only stdio MCP processes, and bounded child agents.

Agents without configured instructions use `SystemPrompt.defaultInstructions`:
a short prompt focused on completing the task, targeted tool use, and verification.
Explicit prompts (including an empty one) take precedence. Native tools are used
automatically when the provider supports them. `/set tool.calling` selects native,
text, XML, or JSON calling, and `/set tool.proxy` controls discovery through a proxy.
Malformed calls receive corrective feedback; three consecutive empty or malformed
turns withdraw tools and ask for a final answer explaining any unfinished work.

Run the REPL from the repository root:

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
with `PMAI_API_KEY`. Model/provider variables bootstrap the first saved agent;
`PMAI_MODEL`, `MAI_MODEL`, and `OPENAI_MODEL` also accept `PROVIDER::MODEL`.
A configured provider's URL and credential sources take precedence over ambient
URL/key variables. Those variables supply missing settings or the initial ad-hoc
connection. Explicit `--base-url` and `--api-key` flags override the selected
connection for one invocation. `/baseurl` shows the effective URL
and identifies a different persisted URL when an explicit flag overrides it.
Export `PMAI_API_KEY=` to suppress legacy key fallbacks for an ad-hoc connection;
use `--api-key ''` to suppress a configured provider's credentials for this run.
Keep `env.sh` local because it can contain credentials.

You can configure pmai entirely from the REPL without environment variables:

A fresh installation starts with no providers and shows the PocketMai ASCII
logo with setup commands. `/about` shows this welcome message again at any time.
Add a remote provider with its API URL and key, then select a model:

```text
/provider add myai https://api.example.com/v1 --api-key YOUR_API_KEY
/models myai
/model myai::MODEL
```

Replace the example URL and key with your provider's settings and choose `MODEL`
from `/models`. For a local OpenAI-compatible server that needs no API key:

```text
/provider add local http://127.0.0.1:11434/v1
/provider use local
/model qwen3:8b
```

These choices survive restarts and become the defaults for new chats and runs,
even if the shell still exports older model/provider values. For a remote
connection, use `--api-key KEY` or `--api-key-file /path/to/key` with
`/provider add`, or set its credentials with `/edit provider ID`.
Settings save to the active `--config`
file, `./pmai.json`, or `~/.config/pmai/config.json` by default.

On macOS, add `apple` and `mlx` explicitly. `/providers` shows the availability
of configured providers. These run natively and need no server URL or OpenAI key:

```text
/provider add apple --kind apple
/provider add mlx --kind mlx
/providers
/model apple::on-device
/model mlx::LiquidAI/LFM2.5-1.2B-Instruct-MLX-4bit
```

Choose either `/model` command to save it as the default. `/provider use apple`
or `/provider use mlx` selects that provider's default model. To create a named
configuration with its own default model, use:

```text
/provider add private-apple --kind apple
/provider add small-mlx --kind mlx --model mlx-community/LFM2-350M-MLX
/provider use small-mlx
```

Apple requires macOS 26 or later with Apple Intelligence enabled in
**System Settings → Apple Intelligence & Siri** and its model download complete.
MLX requires an Apple silicon Mac. Its first inference downloads the selected
MLX-ready Hugging Face repository; later requests reuse the cache. `HF_HOME` and
`HF_HUB_CACHE` choose the cache location, and `HF_TOKEN` supplies authentication
for gated models. You can also select an absolute local model directory with
`/model mlx::/path/to/model`. `/models mlx` lists the presets without downloading
weights. Remote URL and API-key overrides do not apply to these native providers;
MLX authentication can instead be set on its own provider with `/edit provider ID`.

`make repl-build` and `make repl-install` compile and package the MLX Metal shaders
as `mlx.metallib` beside `pmai`, so inference works from any directory. When building
with plain SwiftPM, also run `python3 sys/build-mlx-metal.py --bin-dir PATH`, using
the path from `swift build --package-path MaiCore --show-bin-path`. Xcode handles
the iOS Metal resources. `PMAI_NO_MLX=1` builds the CLI without MLX dependencies;
Apple and remote providers remain available.

The Make targets and CI pass `--disable-prefetching` so SwiftPM fetches only
packages in the active dependency graph. The shared `Package.resolved` also
contains Apple-only MLX pins; without that flag SwiftPM may clone those unused
repositories on Linux before resolving the graph. Include the flag when invoking
`swift build`, `swift test`, or `swift package resolve` directly.

For Linux/Android cross-builds from a Mac, also set `PMAI_NO_MLX=1` and
`PMAI_FORWIROH_PLATFORM=native`. The latter selects Forwiroh's Linux/Android
artifact bundle without downloading its Apple XCFramework. Native Apple builds
fetch only the Apple artifact. `make repl-musl` and the Android build script set
the cross-build environment automatically.

Install a release build system-wide with `make repl-install`. The Linux
release archives come in two flavours: `pmai-linux-<arch>.zip` links against
glibc, libstdc++, libcurl, and libxml2, while `pmai-linux-<arch>-musl.zip` is
fully static and runs on musl distributions such as Alpine and on glibc systems
too old for the regular build. `www/install.sh` picks the static build on musl
systems automatically; set `PMAI_LIBC=musl` to force it elsewhere. Build the
static flavour locally with `make repl-musl` once the Swift Static Linux SDK
matching the toolchain is installed. Native `--plugin` libraries cannot be
loaded by the static build because static musl executables cannot `dlopen`.

Run `pmai -U` or `pmai --update` to download and verify a release directly in
Swift, showing the old and new versions without download progress noise. It
updates the running executable's directory, or `PMAI_INSTALL_DIR` when set,
and reports the installed version and "No updates available" without downloading
the archive when it matches the release. `PMAI_VERSION` can select a specific
release instead of the latest. `PMAI_RELEASES_URL` overrides the release server
(normally `https://github.com/trufae/pmai/releases`); `PMAI_RELEASE_BASE` overrides
the selected release's asset directory. Automatic updates support macOS, Linux,
and Android, require write access to the installation directory, and need no
external download, checksum, or unzip tools.

Print a complete configuration template:

```sh
make repl ARGS=--print-config
```

Load a configuration explicitly:

```sh
make repl ARGS='--config MaiCore/pmai.example.json'
```

Run `pmai -E` to edit `$HOME/.config/pmai/config.json` and exit. It uses `$EDITOR`
(which may include arguments), or the first available `vim`, `nano`, or `notepad`
in `PATH`; Windows also checks its system directory for Notepad. If the config
does not exist, pmai creates it from the example configuration. This always
edits the user config, regardless of `--config`, `PMAI_CONFIG`, or `./pmai.json`,
and works even when the existing JSON is invalid.

Inside the REPL, `/models` queries the current provider's model catalog and
`/models PROVIDER` queries another registered provider without switching the
session. Use `/model NAME` to select a model for chat and all tasks, including
side questions, or `/model -chat NAME` to change only the chat model. Both accept
`PROVIDER::MODEL` and support Tab completion. Task selectors are flags under
`/model`: `-compact`, `-tool`, `-aproval`, and `-btw`; each also completes saved
agent IDs. `/model` shows the current assignments as a Markdown table and lists
the available flags; `/help model` explains selection and reset behavior.
For llama.cpp or llamafile, use an OpenAI-compatible provider with a base URL
such as `http://127.0.0.1:8080/v1`; omit the API key unless the server requires
one. Model and voice discovery have a 15-second total deadline (or the
provider's shorter configured timeout), independent of the longer inference
timeout. Ctrl+C cancels `/models` and returns to the prompt. A server still
loading its model may return HTTP 503; retry after it is ready.

For a ChatGPT subscription, add a provider with `/provider add chatgpt --kind chatgpt`,
then `/provider login chatgpt` opens browser sign-in. `/models chatgpt` lists the
account's available models; `/model chatgpt::MODEL` selects one for pmai's own
agent and tools. No API key, custom endpoint, or Codex installation is needed.
`/provider status chatgpt` shows the account and usage link; `/provider logout chatgpt`
revokes the session and clears its local tokens. Add another `chatgpt` provider
for another account or workspace. Credentials are separate from configuration,
under the selected home directory's `chatgpt/`, with owner-only permissions.
The provider uses subscription-authorized Responses streaming, including when
the REPL display has streaming disabled. Plan limits apply; manage them at
https://chatgpt.com/settings/usage. It supports text, images, files, and local
function tools, but does not provide audio or hosted Responses tools.
Browser sign-in is currently available on POSIX hosts; Windows keeps using
the other configured providers.

API-key endpoints use the provider kind `openai`. Legacy `openAICompatible`
records are accepted and written back as `openai` when saved.

Use `/chat messages` for a compact indexed history or `/chat log` for the
conversation text and attachments. Logs are quiet by default: reasoning, tool
calls, and tool outputs are hidden. `/chat log verbose` includes all of these,
including structured MCP output; `/chat log quiet` explicitly selects the default.
Message indexes retain their original positions even when messages are hidden.
Message headers are bold in the theme's `fginfo` color, and text uses Markdown
rendering when enabled. The current in-memory conversation can be changed at
any point with `/chat edit INDEX [TEXT]` (opens the editor when TEXT is omitted,
the same as `/edit chat INDEX` or `/edit INDEX`), `/chat del INDEX`,
`/chat undo [INDEX]`, `/chat trim INDEX`, `/chat rewind`, `/chat compact
[FOCUS]`, and `/chat clear`. Positive message indexes are 1-based; negative
indexes count back from the end, so `-1` selects the last message. Compaction
accepts optional guidance describing the information the summary should
prioritize. Trimming keeps
messages through the selected index and removes newer ones; linked tool-call
transactions are kept structurally valid when removing or trimming messages.
`/chat rewind` does the same through the newest pinned message, so a pin acts as
a rewind point; it reports an error when the chat has no pins.

`/chat last` prints the latest assistant response. Slash commands support
stdout redirection: `>` overwrites a file, `>>` appends, and `|` sends the output
to a shell command. Redirected output is plain text; diagnostics stay on the
terminal. Quote filenames containing spaces. For example:

```text
/chat log > log.txt
/chat last >> "saved replies.txt"
/chat last | grep banana
/chat log | grep banana > matches.txt
```

These operators only apply to slash commands entered at the REPL prompt.
Ordinary messages and heredocs remain literal. Quoted or backslash-escaped
operators, and operators received through bracketed paste, are also literal;
you can paste a command and then type its redirection suffix.

`/chat chop` opens a modal prompt at the newest conversation message and shows
its index, role, and full Markdown text. Enter `n` for the next message, `b` for
the previous message, `p` to pin or unpin it, `e` to edit it in the configured
editor, `d` to delete it, or `x` to chop everything after it. Editing keeps the current selection and
preserves attachments. After deletion it selects the next surviving message,
or the previous one at the end. Changes are saved immediately and use the same linked-tool rules as
`/chat del` and `/chat trim`. Enter `q` or press Ctrl+C to leave; slash commands
also leave the prompt. Modal answers are kept out of input history and never
sent to the model.

`/chat recap` prints a short Markdown recap with emoji labels for goals,
completed actions and results, and pending work. It uses the compact model
selected by `/model -compact` (or the current model when unset), and leaves
history and pending attachments unchanged. It also includes context from
earlier compaction summaries. `/edit prompt recap` edits its embedded default
template; keep `{{transcript}}`, or clear the file to restore the default.

`/prompts` lists every prompt that can be sent by name — the named system
prompts and which agents use them, the user prompts, the builtin prompts, and
the skills — plus the compact, recap, delegation, worker, and memory templates.
`$NAME [TEXT]` (short for `/prompts NAME [TEXT]`) sends prompt or skill `NAME`
with `TEXT` where its `$ARGUMENTS` stands, or after it; for a system prompt it
switches the agent to that prompt and then sends `TEXT`. User prompts are
reusable messages kept under `prompts.user`: `/prompts add NAME TEXT`,
`/prompts edit NAME` (or `/edit user NAME`), `/prompts show NAME`, and
`/prompts del NAME` manage them, and one named like a builtin prompt — `goal`,
`newapp`, `tldr`, `followup`, shared with the iOS app — replaces it. `/prompt`
shows the active agent's system prompt and `/prompt NAME` points that agent at
another one.
`/prompt add NAME TEXT` creates a prompt from one line, `/prompt edit [NAME]`
edits or creates one in `$EDITOR`, `/prompt show NAME` prints one, and
`/prompt del NAME` drops an unused one. Agents store the association in
`systemPrompt`; several agents may share a prompt, and editing it updates all of
them. Older inline `instructions` are migrated to a same-named prompt
automatically. `doc/prompts.md` walks through registering prompts and agents.

`/edit compact` opens the chat-compaction template. Prompts are saved under
`prompts` in the active configuration (normally `~/.config/pmai/config.json`).
The compact template must contain `{{transcript}}`. `{{focus}}` is replaced with
guidance passed to `/chat compact FOCUS`; if omitted, the focus is appended.
Clearing the compact template restores its built-in default.
The generated task agents' system prompts are edited with `/edit prompt compact`
and `/edit prompt tool`. Older `task-compact` and `task-tool` prompt names migrate
automatically, preserving custom text and agent IDs; a suffix avoids name conflicts.

`/set tool.aproval yolo|ask|smart` controls every tool execution. `yolo` is the
default and runs tools without prompting. `ask` prompts to approve, edit the
arguments, reject, or cancel. `smart` asks a model to allow or block each call.
The spelling `aproval` is intentional in the setting and command names.

On a terminal, pending approvals, argument edits, context decisions, and queue
choices take over the input with a labelled prompt and a highlighted status bar.
The prompt updates as soon as a question arrives, even while you are typing.
Your unfinished chat message and cursor are restored when the decision is done.
Tab completes the available answers; approval and context prompts still accept
slash commands. Invalid answers keep the question open, and modal answers stay
out of input history. File-access approvals offer only yes, no, and cancel;
`/path allow PATH` grants ongoing access.

Use `/model -aproval PROVIDER::MODEL` (or a saved agent ID) to select the reviewer;
`/model -aproval -` restores the conversation model. A System One provider uses
its `harm` probability; a regular model returns a strict JSON allow/block
verdict. The review includes the tool, arguments/command, user task, working
directory, valid paths, and sandbox context. Reviewers receive no executable
tools. Missing/unsupported System One endpoints or models fall back to the
conversation's chat model; malformed decisions or other failures block the
call. See [task agents](../doc/task-agents.md) for setup and details.

The mode is saved in the project's `.pmai/settings.json`; `--tool-aproval MODE`
overrides it for one invocation. The shared default is `approvals.mode` in the
configuration. The old `yolo` setting and `-y`/`--yolo` flags have been removed.
Existing saved booleans migrate to `yolo` or `ask`, and subsequent saves write
only the new mode.

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

`/btw PROMPT` asks a one-off question in a fresh context. By default it uses the
active agent's model and settings. `/model -btw [PROVIDER::]MODEL` selects and saves
a separate model for side questions; a saved agent ID also works. `/model -btw`
with no argument, `-`, or `default` restores the current chat model. `/model`
shows the assignment. Side questions retain the active agent's system prompt,
tools, limits, and durable memory, with the assigned agent's inference settings
and additional instructions, but receive none of the current chat transcript
or queued attachments. `/model MODEL` updates this assignment along with all
other models; `/model -chat MODEL` preserves it.
In the interactive REPL it starts immediately, alongside any running turn.
Its answer appears in a labelled block as soon as the side question finishes;
it is not added to the current chat. Multiple side questions can run at once.
Ctrl+C cancels the most recently started run still in progress, then returns
control to the remaining run. `/jobs kill PID` stops a specific run. Piped
input remains sequential.

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

`/attach PATH` queues a document for the next message. Word files, EPUB books
and PDFs are converted to Markdown (scanned PDF pages go through on-device OCR
on Apple platforms), JSON files become an indented outline, and other text files are
attached verbatim. HTML asks whether to keep its source, convert it to Markdown,
or copy it into the working directory; scripts can make that explicit with
`/attach source|markdown|copy PATH`. Images are attached at medium size, so use `/image` for other
sizes or OCR. `/attach clear` drops everything queued. The converters live in
the `MaiDocuments` module, which PocketMai links as well, so the app and CLI
share one implementation. `MaiDocuments` needs PDFKit for
PDFs, so PDF conversion is unavailable on Linux while Word, EPUB, JSON, and
text work everywhere. The same module holds the exporters (`ChatExport`, `TextExport`, `MarkdownExport`,
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
  "kind": "openai",
  "baseURL": "https://opencode.ai/zen/go/v1",
  "apiKeyEnvironment": "OPENCODE_API_KEY",
  "headers": ["x-opencode-session: {{session}}"]
}
```

`headerEnvironment` maps a header name to the environment variable holding
its value. `/edit provider [ID]` opens one configured provider as JSON and
rebuilds it in the running session when the editor closes, so headers can be
added without a restart; `/provider` lists the header names it sends. The editor
includes current field and credential guidance, which is omitted from saved
configuration. Invalid edits show a repair suggestion and wait for Enter before
reopening with the draft intact. Ctrl+C or Ctrl+D at that prompt cancels the
edit; closing an unchanged invalid draft also cancels it. Piped sessions report
the error and return without reopening. Ctrl+Z in an editor suspends the whole
pmai job; use the shell's `fg` to continue editing.

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
name and the prompt color, and `/project del` drops an entry from the
list. When the default home is in use, chats found in the pre-project
`~/.config/pmai/chats.json` are imported into the first project opened
afterwards and the file is renamed `chats.json.imported`.

`/history` lists saved REPL inputs with numbers; `/history [list] N` shows
only the latest N. Use `/history search TEXT` to find inputs, `/history del N`
to delete one, `/history clear` to clear both saved inputs and live Up/Down
and Ctrl+R recall, and `/history path` to locate the file. This history is
shared across projects and separate from chat transcripts. It keeps up to
500 entries, including slash commands, but excludes consecutive duplicates,
modal replies, `/remote pair`, and `/history` commands. `--history PATH` or
`PMAI_HISTORY` selects another file. `/help history` lists the commands.

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
updated chat. Resuming or switching to a saved chat restores its provider,
model, reasoning options, instructions, run limits, and tool settings.
Saved agent model/provider settings apply to new chats; environment defaults
bootstrap installations without saved agents. Explicit flags such
as `--model`, `--effort`, and `--max-turns` override only the chat being opened.
Chats snapshot their provider definitions (including effective launch-time
base URLs, headers and options), task-model assignments, and named subagent
definitions. Resuming restores these even when shared defaults have changed
or those definitions have been removed. `--base-url`, `--compact-agent`, and
`--tool-agent` override the saved setup for that chat and survive its next
resume; shared defaults change only when requested. API keys and authentication
headers still resolve from the current configuration/environment. Older chats
without a setup snapshot fall back to the current configuration and acquire a
snapshot when saved; endpoints never recorded by an older version cannot be
recovered. Switching between different setups waits until active agents finish.
A chat is saved with the agents its runs started and their
transcripts, so a reopened chat lists them under `/jobs tree`, `/jobs log
PID` reads one, and `/jobs clear` drops them (see `doc/agents.md`). This also
works for one-shot resumes. Finished agents retain their transcripts; agents
left running or paused by a previous process appear as cancelled history and
are never silently relaunched. The CLI retains the complete saved tree until
it is cleared. Interactive turns checkpoint before inference and save child
progress as it changes. `/chat list`
shows the earlier chats grouped by day (Today, Yesterday, This week, Last week,
then dates), newest first, with their agent, size, and last-update time, and
lists archived chats last; `/chat list active` and `/chat list archived` narrow
it down. `/chat use INDEX|ID|TITLE` switches by list entry; `/chat previous`
goes to an older chat and `/chat next` to a newer one, wrapping at either end.
Switching chats shows when the conversation started and how many messages it contains.
`/chat fork [TITLE]` copies the current conversation and switches to the copy,
preserving messages, attachments, agent settings, and saved subagent history.
The fork is an active chat with fresh chat and provider session IDs; its default
title is the original title followed by `(fork)`. Later messages and edits stay
in the selected copy, and `/chat use` returns to the original.
`/chat info` shows when a chat started and was last updated, `/chat archive`
moves a chat out of the active list (archiving the current chat starts a new
one), `/chat unarchive` brings it back, and `new`, `rename`, and `close` manage
chats, while `messages`, `log`, `edit`, `del`, `undo`, `trim`, and `clear`
operate on the active transcript. `/clear` clears the terminal screen while
keeping the conversation; `/chat clear` clears the conversation and restores
configured instructions. Tab completes commands, chat selectors,
agents, and providers: one match is typed out, and several open a rotating
menu on the status line above the prompt instead of printing into the chat.
The first match is inserted immediately; each further Tab selects the next.
The highlight always matches the input and stays visible on narrow terminals.
The menu shows only suffixes after the shared prefix (`↵` means no suffix).
Any other key closes it and restores the status line.
`/agent add NAME MODEL GROUPS PROMPT [PROVIDER [BASE_URL]]`
saves a reusable agent in one line from a model, comma-separated tool groups,
and a named system prompt; `/agent tools|model|prompt|provider ID VALUE` change
one saved agent, `/agent del ID` drops one, and `/edit agent [ID]` opens one
as JSON. `/provider`, `/model`, and `/set tool.proxy` save changes back to the
current chat's agent in the shared configuration. Selecting a provider or model
also makes that agent the default for new chats and runs.

Use `/edit provider [ID]` to change a provider's `baseURL`, `defaultModel`,
credentials, headers, timeout, or options. The provider is replaced in the live
runtime and the change is saved when the editor closes. `/baseurl [ID]` shows the
effective URL without changing it. `/provider rename OLD NEW` renames a
connection and updates all configured agents, including task agents; omit OLD
to rename the current provider. The active chat follows the rename, while other
saved chats retain their independent snapshots. See
`doc/edit.md` for everything `/edit` reaches.

`/help` lists commands and the `$NAME [TEXT]` prompt/skill syntax. Use
`/help shell` for input, shell commands, redirects, and agent messages, or
`/help keys` for keyboard shortcuts.

On a terminal the prompt never goes away: the bottom two rows are reserved for
a status line and the input line, and everything else scrolls above them.
The status shows the current directory once, the agent, estimated context as
tokens/messages (`2.8k/7`), and `provider::model`, followed by activity and queue
details when needed. A message typed while a turn runs is queued and joins the
conversation at the agent's next model turn —
after the tool results it is about to read — so a running agent can be steered
without stopping it. `/queue` lists what is waiting, `/queue push TEXT` adds
without sending, `/queue pop` drops the newest, and `/queue del` drops all.
`/export txt|markdown|html|json|debug|epub|docx [PATH]` saves the chat as a file using
the same writers PocketMai uses (`MaiDocuments`). Tool calls, tool results, and
thinking are omitted from readable documents by default.
`/export txt foo.txt` writes a UTF-8 plain-text transcript with speaker labels,
readable text, and link URLs. PocketMai offers the same format as Plain Text (.txt).
`/set export.tools on` and `/set export.thinking on` opt into each independently;
`/set export.` lists the saved preferences. JSON and debug exports keep the full chat.
`debug` adds the tools and settings the chat runs with to the JSON envelope.
`/export archive [PATH]` writes a portable `.pocketmai.json` archive containing
the configured providers, prompts, MCP servers, agents, visible skills, and the
current chat together with every nested subagent chat and transcript.
`/import PATH` merges those settings, installs skills, and adds
chats without overwriting an existing chat. The same archive is understood by
PocketMai; its existing conversation packs and older pmai JSON chat exports
also remain importable.
PocketMai's chat-title **Share Conversation...** action sends a `.pocketmai`
file via AirDrop or Mail. Use `/import ~/Downloads/My Chat.pocketmai` to continue
that conversation in the CLI; no conversion or debug export is needed. The older
`.pocketmai.json` extension remains supported.
`@PID TEXT` sends one message to a running child agent. `@2,3,4 TEXT` or
`@2 @3 @4 TEXT` sends the same message to several agents without changing
focus; `/jobs tree` lists their process IDs. Each receives one copy at its
next model turn, including paused agents after they resume. Repeated IDs are
deduplicated, and an unknown or finished child recipient rejects the list.
`/queue push @2,3,4 TEXT` uses the same addresses without starting a turn;
`@main` includes the chat. `@* TEXT` or `/queue push @* TEXT` reaches every
active process in this CLI session, including the running main chat, paused
agents, and children waiting for a slot. Idle chats and finished agents are
skipped; if no agents are active, the CLI reports it without sending anything.
`/set ui.broadcast on` makes unaddressed messages and `/queue push TEXT`
broadcast by default; explicit `@` addresses override it. The prompt shows
`pmai@*>` while enabled. The setting survives restarts; `/set ui.broadcast off`
(the default) restores delivery to the focused agent. When no agents are
active, `@main TEXT` still starts a chat turn.
`/jobs focus PID` chooses one agent until `/jobs focus main`. When a tool asks for
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
`stats` (one line per model turn), or `none`. Every `/jobs` row says how
long its run has been going (`5 turns · 2 tools · 2.1k tok · 1m4s`), and
`/jobs tree` ends with a `Total:` row summing the turns, tools, and tokens
of the whole tree. When a turn ends the REPL prints
`✓ took 5s and 1.2k tok · avg 42.1 tok/s` in cyan, or `✗ took 5s` in red
when it failed or was cancelled. Average speed divides received answer tokens
by generation time across that turn's model calls, excluding tool execution
and child runs. Stream timing excludes the initial wait and trailing usage
events; buffered or non-streaming replies use the full request time.
A `~` marks estimated token rates, and speed is omitted when no answer tokens
or generation duration are available.

`/stats` ranks every provider:model pair by a combined ranking, then by its
three measured categories: average output speed, time in use, and efficiency,
with the request and token counts beside each bar. The runtime records every
provider call it makes — REPL turns, one-shot runs, tool-loop rounds, child
agents — into `ModelUsageStore`, kept in
`~/.pmai/stats.json` (`$PMAI_HOME` relocates it) so the totals span every
project. Tokens come from the provider's usage payload, or are estimated from
text length and marked `~` when it reports none; speed is all output tokens
(including reasoning and tool calls) over the first→last token window of the
stream, time in use adds the wait for the first token, and efficiency is total tokens divided by seconds in
use and by requests (`tokens / (seconds × requests)`, printed as `tok/s/req`).
`/stats ranking`, `/stats speed`, `/stats time`, and `/stats efficiency` print one ranking.
`Ranking` sums each model's position in the three measured categories, so the
lowest score wins.
`/stats show PROVIDER[:MODEL]` prints every fact recorded about a model or a
provider, `/stats del PROVIDER[:MODEL]` drops one row or a whole provider,
`/stats reset` forgets everything, and `/stats path` prints the file.
PocketMai's Statistics screen is built on the same `ModelUsageLedger` and
`ModelUsageReport`, so both hosts rank, color, and describe models alike.

On piped input each prompt is preceded by a colored separator so prompts remain
easy to find in terminal scrollback. Long input scrolls horizontally and is
printed in full when submitted. `/set debug true` enables a project-specific
append-only `.pmai/debug.jsonl` log; `/set debug false` stops it. `/set
debugfile PATH` chooses another file, and `/set debugfile default` restores the
project log path. Relative paths resolve from the current working directory
when the setting is saved. `/set debug` and `/set debugfile` show the current
state and path. Each JSON line has a timestamp and records full
model requests and responses (including retries and compaction), model errors,
tool calls and results, and run events. The setting survives restarts in
`.pmai/settings.json`. The log is readable only by the current user and can
contain prompts, tool output, and other private data.

`/theme` (or `/theme list`) lists terminal themes. Seven are built in:
`default` preserves the original styling, `slime` is green, `light` suits
white-background terminals, `ember` uses warm colors, and `pink`, `orange`, and
`sky` provide pink, orange, and blue palettes. `/theme use slime`
applies and saves all the theme's colors and bold setting together.
Set `PMAI_THEME=light` in your environment to apply a theme at startup over
the configured styling; startup selection alone does not write the configuration.

`/theme color` lists every theme setting, and `/theme color fgerror` shows one.
Use `/theme color fgerror bright-red` or `/theme color fgerror=bright-red` to change
and save it. `/theme color bold on` enables bold input. These colors and bold
are managed entirely by `/theme`; `/set` contains behavior settings.

After tweaking colors with `/theme color`, `/theme save mine` writes the current
colors and bold setting to `~/.pmai/themes/mine`, replacing that file if it
exists. `PMAI_HOME` or `--home` relocates the themes directory. Files are plain
scripts with one `/theme color` per line; for example:

```text
# ~/.pmai/themes/mine
/theme color bgline rgb:eee
/theme color fgcolor rgb:222
/theme color fgprompt rgb:046
/theme color bold off
```

Use `/theme use mine` or `PMAI_THEME=mine` to load it. User files take
precedence over built-ins of the same name. Themes accept all the color settings
listed below and `bold`; omitted settings keep their current values. Blank
lines and `#` comment lines are ignored, and invalid scripts leave the UI unchanged.
Old configuration files and saved themes using `/set ui.COLOR VALUE` remain valid.

| Settings | REPL output |
| --- | --- |
| `bgline` | Input/status-line background |
| `fgcolor`, `bgcolor` | Input text |
| `fgprompt`, `bgprompt` | Prompt |
| `fgtoolcall`, `fgtoolresult` | Tool calls and successful results |
| `fgerror` | Errors and failed tool results |
| `fgwarning` | Warnings, retries, interruptions, and approval requests |
| `fgsuccess` | Successful run status |
| `fginfo` | Context notices, tool-help headings, and chat-log headers |
| `fgthinking` | Thinking previews and full reasoning text |
| `fgdiffadd`, `bgdiffadd` | Added lines in tool-output diffs |
| `fgdiffdel`, `bgdiffdel` | Removed lines in tool-output diffs |
| `fgdiffheader` | Diff file and hunk headers |
| `fgselection`, `bgselection` | Selected TAB completion |

Colors apply immediately to main and child agent output. For example,
`/theme color fgerror bright-red` changes error text, and `/theme color bgdiffadd none`
removes the background from added diff lines. `/theme save mine` saves these
choices along with the prompt and input colors. TAB selection falls back to
reverse video when both selection colors are `none` or colors are disabled.
Colored output respects `NO_COLOR`, `TERM=dumb`, and redirected output.

All theme colors accept named ANSI colors, `rgb:RGB`, `#RRGGBB`, or `none`.
`/set ui.` lists persisted terminal behavior settings. `ui.markdown` and
`ui.broadcast` accept `on` or `off`. `ui.toolResultLines` accepts `all`, `relevant`, or a line count (the default is
`all`; `0` prints each completed tool call on one line, with a green `✔` for
success or a red `✘` for failure, using the theme's tool-call and error colors). Use
`/set ui.toolResultLines relevant` to show complete file-edit results and errors,
while keeping routine results such as reads and searches to three leading lines.
This applies to both main and child agents. The setting persists as
`"toolResultLines": "relevant"` in the configuration's `ui` object; existing numeric
values still work, including `-1` for `all`. Tools opt into complete output in this
mode through `ToolAnnotations.resultImportance = .important`; unmarked tools use
the normal preview. This only changes terminal display, not what the model receives.
`/set ui.title TEXT` adds `[TEXT]` to the prompt and sets the terminal/tab title
with an ANSI escape sequence; `/set ui.title none` clears the configured label.
`/set ui.mode buffer` enables a full-screen output buffer. Page Up/Page Down
(Re Pág/Av Pág) and the mouse wheel scroll the session transcript while the
status bar and editable prompt stay fixed at the bottom. The wheel scrolls one
line per event by default; `/set ui.scroll=3` changes this to three lines.
`ui.scroll` accepts a positive integer, applies immediately, and persists in the
configuration. Output is retained in memory, including tool output and submitted
commands, and reflows when the
terminal resizes. Incoming output keeps your place while you scroll; Page Down
to the end resumes following it. Submitting input or pressing Ctrl+L also returns
to the latest output. Shell commands such as `!uname` retain stdout and stderr
in the buffer after returning to the prompt; interactive commands still receive
the terminal. The setting persists; `/set ui.mode classic` restores the
default terminal scrollback behavior. Buffer mode restores the shell's screen
and mouse handling on exit and during terminal handoffs. Hold Shift to select
text using your terminal's normal mouse selection. Saved conversations remain
available separately through `/chat log` and the project's `.pmai/chats` files.

`/chat log short` lists the first paragraph of every message with its original
number; 📌 marks pinned messages. `/chat pin NUMBER` pins any message, including
instructions and tool messages; negative numbers count from the end. A full
message ID also works. `/chat pins` (or `/chat pin`) shows pinned messages in full;
`/chat pins short` lists their first paragraphs with the original message numbers.
Inside `/chat chop`, `p` toggles the selected message's pin, and
`/chat unpin NUMBER` removes a pin. Pins are saved with the conversation, survive compaction
and portable exports, and appear in PocketMai's pinned-message bar below the
chat title. In PocketMai, use a message's **Pin Message** menu action; tap the bar
to jump to it or use the bar's menu to choose another pin or unpin it. Global
bookmarked messages remain a separate library across conversations.

`/set ui.editor COMMAND` picks the editor `/edit`, `/reply`, and the other
editor commands hand the terminal to; it is saved in the configuration and used
before `$EDITOR`, `$VISUAL`, and vim, which are what an unset (or
`/set ui.editor none`) value falls back to. The command may carry arguments,
as in `/set ui.editor code -w`, and the file path is appended to it.
In the default theme, successful tool results are yellow, tool starts are green, and
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
With `tool.aproval = yolo`, a spent turn budget is treated as a
checkpoint and the task continues on its own; the token and time caps always
stop, since they exist to bound the spend. A model call that fails — a dropped
connection, a 5xx — is repeated after `retry.delay` seconds up to
`retry.attempts` times (`↻ retry 1/2 in 5s: …`) before the turn fails.
Context-limit errors bypass these transport retries. The runtime learns a
reported window for that provider/model and offers context reduction before
another chat request. If no smaller transcript can be produced, it stops
without resending the same oversized request.
An OpenAI `cyber_policy` error stops immediately, including when it arrives during
streaming. Its message, code, and available HTTP status/request ID are retained.
Completed tool work and the conversation remain available after the rejection;
no automatic retry is sent. `/export debug PATH` saves the chat for local review.
`/set ctx.compact 64k` enables a context action prompt before a model turn
once the conversation reaches about that many tokens (using the provider's
count when available). Choose **prune old tool output**, **summarize older
context**, **keep context for this response**, or **stop**. The `yolo` approval mode does
not bypass this choice. The prompt also permits changing the model or clearing
the chat. Noninteractive CLI runs continue to summarize automatically.
Pruning shows its expected savings, needs no model call, and keeps the first
800 and last 200 characters of large successful tool outputs, including search
and shell results. The middle is discarded. Errors, call arguments, conversation
text, and the newest exchange stay intact. The prune option is offered only
when it can save space. If pruning still leaves the context over the threshold,
the prompt offers summarization or keeping the remaining context.
Summarization replaces older exchanges with a model-written summary focused on
finishing the current task. The latest user request stays verbatim, together
with recent complete tool exchanges. By default this tail has a budget of
one quarter of the effective compaction threshold, capped at 8,000 tokens. Set the agent's
`autocompact.preserveRecentTokens` (or `/set ctx.recent 4k`) to override it;
`/set ctx.recent auto` restores the default. Zero keeps only the newest
exchange and the user request. Tool calls and results stay together, even when
the newest exchange exceeds this budget. Provider usage is supplemented with
an estimate for tool output and queued messages added since that call.
`✂ context: compacted 14 messages into a summary` reports that replacement.
`/set ctx.compact off` (`autocompact.tokens: 0` in the agent configuration)
disables the context action prompt entirely. `/set ctx.compact` shows the
current setting.

For a small model, set `/set ctx.window 32768` to declare its total context
window. This persists as `options.contextWindowTokens` on the agent and is
inherited by derived workers. The runtime reserves reply space and a safety
margin, lowers the compaction threshold and recent tail to fit, accounts for
tool schemas and instructions before sending a request, and gives tools
smaller output budgets. `/set ctx.window auto` clears the explicit setting;
limits learned from provider errors remain available for the current process.
Named agents, including a separate `/model -compact` agent, can declare their
own window in their `options` configuration.

Manual `/chat compact`, `/chat recap`, automatic compaction, and smart/tool
summaries split oversized input into bounded pieces and consolidate the
partial summaries. This also handles a single message larger than the model
window. Each piece retains its summary template and focus; an unknown summary
model starts with a conservative 32,768-token window and adapts to context
rejections. All successful calls count toward usage and token/time budgets.
History is replaced only after the complete summary succeeds; empty,
truncated, or failed summaries leave it intact. The newest user request and
protected instructions still stay verbatim, so those alone must fit the chat
model's window.
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
`NO_COLOR` keeps the structure without colors.
Up/Down or `Ctrl+P`/`Ctrl+N` move through input history. `Ctrl+R` starts an
incremental reverse search; type to narrow it, press `Ctrl+R` again for an older
match, Return to submit it, or `Ctrl+G` to restore the original input. `Ctrl+A`
and `Ctrl+E` move to the beginning and end, `Ctrl+B` and `Ctrl+F` move one
character left and right like the arrow keys, `Ctrl+W` deletes the previous word,
and `Ctrl+C` cancels the active model or tool run without leaving the REPL.
`Ctrl+L` clears the screen and redraws the prompt, keeping the current input,
cursor position and history search. It does not clear the conversation.
`Ctrl+Z` suspends pmai with the terminal restored; run `fg` in the shell to
resume the same input or active run.

`/set ctx.strategy=smart` (config key `context: "smart"`) keeps small working
conversations intact. Once the working context reaches about 16k estimated
tokens, it uses `/model -compact` to summarize older exchanges, keeping about
8k recent tokens and the newest complete tool exchange verbatim. Newly read
code and tool results reach the acting model directly instead of through a
lossy brief. The brief is reused until enough new evidence accumulates; queued
corrections, changed evidence, and transcript edits invalidate stale briefs.
Earlier evidence includes tool arguments, complete text and structured results,
files, and child-agent findings.
System/developer instructions, active skill bodies, and loaded proxy tool catalogs
are excluded from the brief-generation input. The conversation model receives
the brief alongside recent exchanges, the exact current user task, and skill-loading receipts.
Skills invoked for the current user turn, including `$NAME` and `/skills prompt`,
and proxy catalogs loaded by `list-tools` reach the model verbatim in separate
instruction sections. Their steps, arguments, resource directories, output formats,
and tool schemas survive a lossy brief. These instruction sections are supplied
in every context mode. System/developer instructions keep their original roles
and text; runtime instructions and tool protocols are injected after reduction.
Cache mode leaves conversational evidence whole; its inference view still
separates injected instructions and replaces skill/catalog bodies with receipts.
Binary attachments remain available unchanged. Automatic/manual compaction,
context-edit tools, and explicit output pruning protect active instruction
exchanges, including sibling tool results. Manual `/chat compact` retains all
system/developer instructions and stores summaries as conversation evidence;
older chats with system-role summaries remain readable as evidence.
Messages queued while a task is running steer that same task: its exact starting
request, corrections, loaded skills, and catalogs remain active. Continuing a
limit-interrupted process retains that task boundary; a new user turn starts
with a fresh active instruction scope.
The brief is disposable: saved history continues growing with the actual replies
and tool results, and `ctx.compact` still reduces that history when needed.
Exact instruction delivery does not guarantee that a particular model follows
the skill's workflow or output format.
Smart mode uses its own `prompts.smart` template, editable with `/edit smart`
or `/edit prompt smart`; it must contain `{{transcript}}`.
Only needed reductions add compact-model calls; their usage counts toward
statistics and token/time limits. If no compact model is assigned, the current
model is used. A failed or empty brief keeps the evidence available and lets the
run continue; that same reduction is not retried at every tool step.
`ctx.strategy` accepts `cache`, `size`, `smart`, and `tools`.

`/set ctx.strategy size` (config key `context`, default `cache`) turns on the cheap
half of that: before every model call the runtime replaces the body of any file
read while answering an *earlier* prompt with one line saying what it was and
how to read it again. This includes full files, `files_read_range`, and
`files_get_function` results. Everything read for the prompt in progress
stays (pruning inside a run made models re-read what they still needed). File
bodies can be a large part of a coding conversation and are often no longer
needed for a later prompt, so `size` can cut tokens; the price is that
a server's prompt cache is invalidated from the rewritten message on. `cache`, the default, never changes a message once sent, so the
cache covers every earlier turn and each call pays only for what is new. The
REPL prints `✂ context: pruned 1 old read result (12.3k → 2.1k chars)` when it
prunes. Those sizes are totals for the conversation; pruning only removes old
read bodies. Large search results, shell output, generated code in tool
arguments, and assistant prose remain, so the reduction can be small.
This automatic read pruning is independent of `ctx.compact` and does not ask
for a decision. It never enables summarization implicitly. Use the context
action prompt above for broader tool-output pruning or summary replacement.

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
`status` shows “Thinking…”. In the REPL, `line`, `three`, and `five` show a continuous
character carousel filling one, three, or five rows: newlines become spaces, and
the oldest characters slide out as new text arrives. Rows update in place without
clearing and repainting the prompt. Small terminals reduce the preview height;
resizing reflows the retained text. `full` prints all reasoning in grey italics.
Compact previews occupy transient rows above the REPL prompt and clear
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

Tools have three states: **direct** (their schema is listed), **proxy**
(available through discovery), and **disabled** (unavailable). `/tools` lists
plugin-defined groups with state totals and call counters; `/tools
show GROUP|TOOL` says
what the group is for and prints every tool with its description, how it is
approved, and its parameters, then the group's settings — the same schema the
model receives, readable. `/tools set GROUP OPTION VALUE` persists
typed group settings and reloads the source; for example, Mastodon's instance,
API-key environment variable, and write permission are configured this way.
Group selections live on each `AgentDefinition`, while source credentials and options
live on `ConfiguredToolSource`, so every host uses the same configuration and
plugin API. Older native plugins without group metadata are grouped by their
tool-name prefix and described by the first sentence of each tool. MaiCore's
runtime-native families come with a description of their own that says what
they are for and how the tools work together: `agent_start`, `agent_status`,
`agent_result`, and `agent_stop` form the `agents` group, the `chats_*` tools
`chats`, the `todo_*` tools `todo`, the `context_*` tools `context`, and the
`skills_*` tools `skills` (`AgentRuntime.builtInToolGroups`); enable or
disable each group independently on each agent.

GitHub keeps the same read-only tools with optional authentication. Export
`GITHUB_TOKEN` before starting pmai, or save a token with
`/tools set github githubAPIKey YOUR_TOKEN`; `/tools set github githubAPIKeyEnvironment GH_TOKEN`
selects another environment variable. The selected environment variable takes
precedence over the saved key. Enable the group with `/tools enable github`.
On iOS, set **GitHub personal access token** in Settings → Tools → Native → GitHub.
With no token, public access works as before. The token is a setting, never a
model tool argument. Private release links still require GitHub login in the browser.
[Authentication](https://docs.github.com/en/rest/authentication/authenticating-to-the-rest-api)
uses the same endpoints with a bearer token. For a fine-grained token, select
repositories and grant read permissions for Contents (files, commits, releases),
Pull requests, Issues, Checks (CI results), and Actions (job logs), as needed.
[Personal-token limits](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api)
are normally 5,000 requests/hour, compared with 60/hour for anonymous access.

MCP tool names are namespaced as `<toolNamePrefix>::<remoteName>`, or
`<server-id>::<remoteName>` when no prefix is configured. Connecting an enabled
MCP exposes all of that server's discovered tools to every agent; the server is
the enable/disable unit. Obsolete names left in an agent after an MCP rename are
ignored instead of preventing the REPL from starting. Agents still explicitly
list non-MCP tools and child agents they are allowed to use.
`MaiStandardToolsPlugin` provides date/time, the `calc` calculator,
network, and workspace-scoped Files tools.

### Remote pmai hosts

In the REPL, `/remote serve --protocol local` shares the host's indexed projects
and saved chats over its LAN WebSocket gateway. `local` is the default, so
`/remote serve` keeps the same behavior. Add `--path PATH ...` to restrict the
shared directories, `--port PORT` to change the listener port, or `--loopback`
to listen only on `127.0.0.1`.

For encrypted access across firewalls, install the
[OpenTunnel CLI](https://github.com/anomalyco/opentunnel) on the serving machine,
then run:

```text
/remote serve --protocol opentunnel
```

pmai starts its gateway on loopback, publishes it using a dedicated OpenTunnel
profile, and prints a pairing QR and `pmai-acp://` connection URI containing the
public `wss://` address. pmai saves its dedicated profile name in
`~/.pmai/remote-server/opentunnel-profile.json`; OpenTunnel keeps the identity
and certificates in its own storage so the URL can be reused. Initial
certificate provisioning can take a few minutes. `/remote stop`, REPL exit, and
Airplane Mode stop both the gateway and the managed publisher. The tunnel
identity remains available for the next run. No OpenTunnel library is linked
into pmai or PocketMai; only the publishing host needs the external CLI.

On another CLI, use `/remote pair URI_OR_PROFILE_FILE [NAME]`, accept the request
in the serving REPL with `/remote accept`, then use `/remote connect NAME`.
In PocketMai on iOS, open Hosts → Add Remote Host and scan the QR or paste its
connection URI, save it, and select the host. Accept its pairing request in the
serving REPL. Both clients use individual credentials after approval.

To use a tunnel or TLS proxy you manage separately:

```text
/remote serve --protocol opentunnel --url wss://YOUR-TUNNEL/acp
```

This also binds to loopback but leaves the external publisher's lifecycle to
you. For other proxies, use `--protocol local --loopback --url wss://HOST/acp`.
`--url` selects the address exported in the QR/profile; `--address IP` selects
only the advertised host and cannot be combined with `--url`. Plain `ws://`
connections should be used on trusted private networks. OpenTunnel encrypts
the public connection; pmai still requires operator-approved pairing.

### OpenAI HTTP server

In the pmai REPL, run `/remote serve --protocol openai` to expose configured
agents and providers at `http://127.0.0.1:11435/v1`. Add `--tools` to enable agent
tools. `/remote status` shows the endpoint and `/remote stop` stops it. The server
also exposes OpenAI-compatible transcription, speech and voice discovery routes.
See [audio server usage](../doc/audio-server.md) for model selectors, Groq and
native speech, streaming formats, authentication and examples.

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
`/tools enable context` adds them to another. The three editing tools follow
`tool.aproval`, like other tools. The edited conversation is what gets saved, so what an agent
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
/todo del NUMBER|TEXT      drop an item; the ones after it move up
/todo edit                 edit the list in $EDITOR
/todo clear                remove every item
/todo path                 print where the file lives
```

### Local documentation and source retrieval

`vdb` indexes files in the Files workspace and returns relevant passages for
RAG with their source path, 1-based line range, and ranking score. Both pmai and
PocketMai use MaiCore's Swift engine and the same `MaiStandardTools` tool.

```
/vdb index docs
/vdb index Sources
/vdb query how are refresh tokens renewed?
/vdb status
/tools enable vdb
/vdb del docs/old-guide.md
/vdb clear
```

The model calls `vdb` with `{"action":"index","path":"docs"}`, then
`{"query":"refresh token","limit":5}`. An optional query `path` restricts
retrieval to a file or folder; `max_bytes` bounds the total passage text. In
PocketMai, enable **Local documentation** and workspace access in its tool
settings. It uses the chat's selected working folder, or FilesData by default,
including security-scoped folders from Files and iCloud Drive. It is available
in Airplane Mode. Selecting Files tools separately is optional.

Snapshots persist in `.pmai/vdb.json`. Reindexing a file replaces its passages;
reindexing a folder refreshes changed files and removes sources no longer in
that folder. Failed imports are reported and their previous snapshots retained.
Remove and clear only change the index. A read-only Files workspace permits
queries and status but disallows index changes. Traversal skips hidden and
generated directories and honors Git/Mercurial ignores where those programs are
available. Index one folder at a time when it exceeds 2,000 files. The complete
index is bounded to 20,000 passages and 64 MB.

Source files, extensionless text, Markdown, and supported document attachments
(DOCX, PDF, EPUB, JSON) use the shared document importer. Passages contain up to
2,400 characters with a small line overlap; long lines are split too. For
converted documents, line ranges address the converted text. UTF-8 result
budgets preserve complete characters and mark truncated passages explicitly.

The default retrieval is local **sparse TF-IDF cosine plus BM25**, with an
inverted index of actual terms. There is no hashing into a small fixed vector,
no KD-tree, and no model download. Queries never change corpus statistics;
source updates rebuild weights together, so insertion order cannot leave old
vectors with incompatible weights. Smoothed frequencies keep common terms
useful even in a single-document collection. Tokenization preserves code
identifiers and also splits camel case, acronyms, and underscores. Unrelated
queries return no passages. This is lexical retrieval: synonyms without shared
terms require a trained embedding model.

Hosts that have such a model can inject a `MaiVectorEmbeddingProvider` into
`MaiVectorDatabaseTool` to add exact dense cosine retrieval. Embeddings are
batched and persisted with the provider's identifier. Every passage and query
must use the same model and dimension; errors never silently fall back to
another vector space. Clear the index before changing providers. The built-in
CLI and iOS configuration use the local sparse mode by default.

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
tool. The runtime tells the model to load a named or matching skill before doing
its task, then perform the steps and honor its final-answer format. The `skills`
group holds them all: `/tools enable skills` (or naming
`skills` in an agent's `toolGroupNames`) offers every skill, present and
future, while `/skills enable NAME` and `/skills disable NAME` change one
skill at a time. Disabling a member preserves group membership, so new skills
still inherit the group's policy. `/skills direct|proxy|inherit NAME|all` sets
its exposure; exact skill settings override the group, like any tool. The
tools run without approval, and every call reads the file afresh, so editing
a skill takes effect at once. A skill whose front matter says
`disable-model-invocation: true` is never offered as a tool.

`/skills prompt NAME [TEXT]` — or `$NAME [TEXT]`, which also reaches the
user and builtin prompts — sends the skill's instructions, then `TEXT`, as
the next message when the skill's tool is enabled for the agent.
Where the body says `$ARGUMENTS` the
text goes there instead. The message carries the instructions inside a
`<skill name="…" directory="…">` envelope identifying its resource folder.
Project paths such as `AGENTS.md`, source files, and output files remain
relative to the workspace.

```
/skills                    list skills with colored enabled/disabled status
/skills show NAME          print a skill's file, tool state, and instructions
/skills add NAME           create a skill in your editor, including its folder and SKILL.md
/skills add NAME "DESCRIPTION" "PROMPT"  create a skill directly
/skills edit NAME          edit SKILL.md (same as /edit skill NAME; creates new names)
/skills import ZIP_OR_FOLDER  import a skill and its supporting files
/skills del NAME           delete the skill folder and its supporting files
/skills enable NAME|all    offer a skill, or every skill, to the current agent
/skills disable NAME|all   disable a skill (or every skill) for this agent
/skills prompt NAME [TEXT] send an enabled skill's instructions, then TEXT
/skills path               print the directories scanned
/skills reload             rescan the directories (every /skills command does)
```

New skills are created in the project and enabled for the current agent.
Add `--user` before the name or path to use your home skills folder instead.
Editing and deleting target the visible copy; `--user` or `--project` selects
a specific copy. Quote names, descriptions, prompts, and paths containing spaces.
Imports accept a folder or a ZIP containing one skill, either at the archive root
or inside a containing folder. Existing skills are never overwritten by import.
Edits preserve supporting files, and the runtime picks up changes immediately.

In PocketMai, open Settings → Tools → Skills to create a skill with a name,
description, and prompt, or import a ZIP/folder from Files. Tap a skill to edit,
use its switch to enable it for the selected agent, and use its actions menu to
delete it. Created and imported skills are enabled automatically.

### Agents and subagents

An agent definition is a saved setup — provider, model, system prompt, tool set,
and limits — that people switch between with `/agent use ID`. Each one carries a
`description` saying what it is for, which a delegating model also reads when it
picks an agent for a task, and an `enabled` flag that parks a setup without
deleting it. `/agents` lists them; `/agents describe ID TEXT` and
`/agents enable|disable ID` maintain them.

A running instance of a definition is a process with a **pid**. `/jobs` (or
`/jobs tree`) draws them, `/jobs log PID` prints one agent's own transcript,
`/jobs stop PID` pauses it and everything under it at their next step, and
`/jobs continue PID` lets them go on; messages queued for a paused agent are
read when it continues. `/jobs kill PID` cancels it and everything under it.
`/job` aliases `/jobs`, and `/agent` aliases `/agents`. Bare `/agent` and
`/agents` list definitions only. The former `/agents tree|log|stop|continue|kill|focus|clear`
commands still work as compatibility aliases; `/help jobs` describes process control.
Pausing waits at runtime boundaries; killing requests cancellation rather than
sending an operating-system signal.
Any agent that is allowed
subagents can start more, so the result is a tree, bounded by
`limits.maxSubagentDepth` and `limits.maxSubagents` across the whole tree. A
child started when every slot is busy is not refused: it is registered as
`queued`, shows as such in `/jobs tree`, and starts by itself, in order, when
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
answer unless `wait` is false. An optional `title` explains why the child is
running in `/jobs` and `agent_status`; it defaults to a summary of `task` and
is saved with the job. The title stays visible alongside the current activity.
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
`/mcp info [ID]` shows connection settings, protocol and resource details, and
the same tool help, exposure modes, and call counts as `/tools show mcp/ID`.
Omit ID to inspect every server. Disabled servers include saved settings and
recorded tool call counts. Environment and header values and bearer tokens
are not printed.
Add and connect a stdio server without editing JSON using
`/mcp add COMMAND [ARG ...]`; the command basename becomes its ID. Use
`/mcp add --name ID [options] -- COMMAND [ARG ...]` when a different ID or
options are needed. `/mcp enable ID` and `/mcp disable ID` reconnect or
disconnect the complete server tool set and persist the state. `/mcp del ID`
disconnects the server and deletes its saved configuration and per-agent tool
references. Run `/help mcp` for the full option list. The legacy `/mcps` spelling
remains a list alias.

MCP requests default to 180 seconds for both stdio and Streamable HTTP. Set
`timeout` on an entry in `mcpServers`, or pass `--timeout SECONDS` when adding
it, to override that server's deadline. For slow Mail automation, for example,
set `"timeout": 300` on the `apple-mail-mcp` entry. Explicit timeouts remain
unchanged when the default changes. PocketMai's Tool Call Timeout also defaults
to 180 seconds and offers Continue, Skip, or Interrupt when it expires.

Stdio requests send `notifications/cancelled` on timeout or client cancellation,
except during initialization. Servers may ignore cancellation. If a request
times out or its connection fails after sending progress messages or logs,
the tool result retains that text, marked incomplete and with `isError: true`,
for the next model turn. Partial output is bounded to 64 KiB per request;
unfinished JSON frames are not treated as results. Stdio stderr is retained
as diagnostics. A shortened terminal preview does not shorten the tool result
sent to the model; `/set ui.toolResultLines all` shows the full result.

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
content, convert documents to readable text, write or append text, create folders,
rename entries, and delete them. Existing files are edited in place with
`files_patch` (unique literal or regex replacement), which returns a unified diff.
Prefer literal replacements for small edits, copying enough surrounding text
from a fresh read to match exactly once. `files_replace_range` is excluded from
the default catalog; custom hosts can opt in with
`MaiFileWorkspaceTool.makeTools(..., includeLineRangeEdits: true)`.
For complete function bodies in large source files,
`files_get_function` finds a function by name and reports its complete line and
UTF-8 byte bounds plus a body revision. `files_set_function` uses that revision
to atomically replace only the body, preserving concurrent edits to other
functions and rejecting stale edits to the same function. Its lightweight
locator supports common brace-, indentation-, and `end`-delimited languages,
including HolyC `.hc` files. `files_write` refuses to replace an existing file unless
`mode: 'overwrite'` is passed, so a model cannot clobber a file it meant to
patch. `filesRoot` confines every relative
path to one directory (including symlink checks), while `filesWriteEnabled`
removes the mutation tools when disabled. Mutations still go through normal
confirmation, and deletion is marked dangerous.

`files_mkdir` creates a directory and any missing parents using only `path`,
for example `{"path":"notes/reports"}`. It succeeds if the directory already
exists and refuses to replace a file. The legacy
`files_write` call with `create_directory: true` remains supported. Creating an
empty file uses `files_write` with `content: ""`.
`files_delete` removes files of any type or empty folders; pass `recursive: true`
to remove a folder and its contents. Deleting a symbolic link removes the link,
including a broken link, while preserving its target. These basic operations
are available in both iOS and the CLI without enabling advanced file tools.

`files_read` accepts an optional `format` in both the iOS app and the CLI REPL:

- `auto` (default) converts PDF, DOCX and EPUB to Markdown and extracts image
  text with OCR. HTML, JSON and source files retain their original text.
- `markdown` detects supported documents by content and filename and also
  converts HTML to Markdown. Other text, including JSON, stays unchanged.
- `text` reads the original UTF-8 source without conversion; binary input is
  rejected.

For example, `{"path":"report.pdf","format":"markdown"}` returns readable
Markdown in the tool result, and `{"path":"page.html","format":"text"}`
returns HTML source. Conversion is in memory and never rewrites the file.
`offset`, `nextOffset`, `totalBytes` and `max_bytes` refer to the returned UTF-8
text after conversion. Continue with the same path and format. Image OCR uses
Apple Vision on iOS/macOS and a locally installed Tesseract on other supported
platforms; PDF conversion requires PDFKit on iOS/macOS. Images yield recognized
text, not a description of their visual contents.

With the default Files workspace (no explicit `filesRoot`, or `filesRoot: "."`),
`/cwd` prints the process working directory and `/cd PATH` changes it; the model
has no tool for that, since every path argument already takes a relative or an
absolute path. The default workspace resolves its root on each tool call,
keeping an installed `pmai` binary aligned with the directory from which it was
launched. An explicit `filesRoot` remains fixed. Paths are relative to that
directory, and an absolute path is accepted as long as it lies inside it, so a
model can reuse a path a shell command printed; a path error names the directory
so the model can correct itself.

`/path` lists the current directory, effective Files workspace, external paths
granted from prompts, and access rules. On first startup, the CLI saves `ask`
rules for `/etc`, `~/.ssh`, and `~/.config`, plus an `ask` default for hidden
paths (dotfiles and dot directories, including newly created ones). Existing
configurations without `fileAccess` settings receive these defaults once.
The workspace is otherwise allowed by default.
Use `/path allow PATH` (or `add`) for an additional file or directory,
`/path deny PATH` to block a path even inside the workspace, and
`/path ask PATH` to require confirmation each time it is accessed.
`/path del PATH` removes an explicit rule or grant; inherited workspace and
parent permissions still apply. Denials override prompts and grants, and prompts
override grants. Directories include descendants; file grants cover just that
file. Relative paths resolve from the Files workspace, and quoted paths support
spaces. A trailing `/` marks a directory that does not yet exist.
`/path hidden ask|deny|allow` changes the hidden-path default; explicit path
rules override it, so `/path allow .env` can permit one hidden file. An explicit
parent grant also covers its hidden descendants. Searches still skip hidden
entries. Moving or deleting a directory checks its protected hidden descendants.

`/path outside ask|deny` controls paths outside the allowed scope (default: deny).
Path prompts require a person even in `yolo` mode; unattended calls are rejected.
Paths explicitly named in prompts retain normal tool approval: `yolo` adds them
automatically, while `ask` and `smart` ask the person. Each addition prints a
`/path` hint so the grant can be reviewed, denied, or changed to ask. Setting
`outside deny` blocks these automatic additions; `outside ask` requires a person.
Rules, the hidden-path default, and the outside policy are saved under
`fileAccess` in the active configuration and survive restarts. Automatic prompt
grants remain session-only. The policy applies to Files and `vdb` tools including
child agents, and checks resolved symlink targets. Searches omit denied subtrees, and
directory moves or deletions cannot bypass a protected descendant. Models can
inspect `/path` through `pmai_run`, but cannot change its policies or the Files
workspace. These are tool-level checks: `run_shell` and other tools retain their
own permissions. `/help path` lists the commands.

`/ps` lists the current chat's live main-agent shell commands with their OS
PID, agent name, `/jobs` ID, elapsed time, start time, working directory, and
command. Add `-a` to include all subagents, `-p` to show past commands with
duration and exit status, or `-ap` for past commands from every agent.
`/ps -k PID` kills a live command and its process group. It only accepts
processes owned by this chat; a saved PID is never used to signal a process.
Command records persist with the conversation and in exports, independently
of transcript compaction and `/jobs clear`. Restored unfinished commands are
marked interrupted with unknown duration. `/help ps` describes the flags.
Chats saved before command records existed recover their command history and
durations from the available run-tool calls and results; missing PIDs and
start times are shown as unknown.

The `run` group is one tool, `run_shell`, which executes code on this computer
with the privileges of the `pmai` process: the command line or script is saved
to a temporary file and run with the configured shell (`runShell`; a name looked
up in `PATH` or a full path, leading arguments such as `bash -e` honoured).
Other languages go through the shell (`python3 - <<'EOF' … EOF`), so there is
one schema to pay for on every call rather than four. The text is taken from
`command` or `script` interchangeably, since models mix the two up. Every call
may pass `args`, `stdin`, `cwd`, `timeout_seconds`, and `output`. Commands run
with color disabled and ANSI sequences are stripped from returned text.
For programs the person will operate, such as `vim`, `nano`, `less`, or a
language REPL, pass `interactive: true`, for example
`{"command":"vim notes.md","interactive":true}`. The CLI pauses its input
reader and hands over the terminal until the program exits, preserving any
unfinished prompt. The model receives the exit status; terminal input and
output stay out of the conversation. Interactive runs preserve the terminal
environment and have no default timeout; an explicit `timeout_seconds` still
applies. Omit `stdin` and `output` in this mode. It requires a foreground CLI
terminal and is unavailable in piped/server sessions.
`output: "auto"` (the default) returns small output but saves any stream larger
than 24 KB to a temporary file and reports its path; use `inline` to drop the
excess, `file` to save both streams immediately, or `none` to suppress them.
Captured runs are killed after the timeout
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
an HTTP URL or stdio command and enable it to connect its discovered tools.
The hybrid proxy is the default for agent profiles, including old profiles
that omitted `useToolProxy`; an explicit `false` remains respected. Common
file/shell tools (`files_read`, `files_grep`, `files_patch`, `files_write`,
`files_list`, `run_shell`) are direct and other enabled tools use `list-tools`
and `call-tool`. Raw `AgentRequest` SDK callers retain their native default;
hosts pass the profile's policy. `proxyExposedTools` remains supported as an
explicit fixed native set (an empty set means pure proxy).

Set **each tool or group** with `/tools direct|proxy|hide|disable|inherit TARGET`.
Individual overrides win over groups; group changes preserve those overrides.
`inherit` removes an override and returns to the allowlist/group/default.
`enable` adds a tool or group using the current default exposure. Tool policies
change availability and presentation; approvals still use the concrete tool.
Connected MCP servers default to available, but the same per-agent policy can
disable a server or a single tool. Qualified server groups use `mcp/SERVER`;
individual tools use their exact `PREFIX::NAME` or `mcp/SERVER/NAME`.

`hide` keeps a tool available by name while omitting its schema and name from
model discovery, including `list-tools` searches. Calls by known name, directly
or through `call-tool`, still use the same validation and approvals. Choose
**Hidden** in the GUI tool list, or save `"hidden"` in a tool/group policy.
Hidden tools remain visible in settings so you can change their mode.

```text
/tools proxy github
/tools direct github/pr
/tools direct github/issue
/tools disable github/ci_log
/tools hide github/issue
/tools proxy mcp
/tools direct mcp/myserver/search
/tools disable myserver::delete
/skills proxy all
/skills direct review
```

Automatic exposure is enabled by default (`/set tool.auto on|off`, or
`toolPolicy.automatic`). It promotes up to four inherited proxy tools after
at least three calls in the most recent 128 executed calls. Ranking uses
frequency, then recency. As workflows change, infrequently used tools return
to the proxy. The six common tools remain direct. Explicit tool/group modes
and `proxyExposedTools` always win; automatic exposure never enables a disabled
tool or reveals a hidden tool. `/set tool.proxy on|hybrid|all|off` changes the
inherited default without clearing per-tool policies.

Counters accumulate under the concrete name, including MCP and skill tools,
regardless of whether the call was direct or proxied. Invalid, disabled,
denied, and discovery calls do not count. Lifetime counts and the recent name
window persist in `$PMAI_HOME/tool-usage.json` (normally `~/.pmai`), shared
across projects; group counts sum their current members. Arguments and results
are not stored there. Both `/tools show` and the visual Tools tab show counts.

The per-agent configuration for two direct GitHub tools is:

```json
{
  "useToolProxy": true,
  "toolPolicy": {
    "automatic": true,
    "groups": {"github": "proxy", "mcp": "proxy", "skills": "proxy"},
    "tools": {"github_pr": "direct", "github_issue": "direct", "github_ci_log": "disabled"}
  }
}
```

`doc/proxy.md` has the measurements behind the hybrid default.

Agents can force MaiCore's emulated tool loop with `toolCallingStrategy` set to
`text`, `xml`, or `json`. These modes send tool instructions as messages, parse
the model's response, execute the calls, return results, and continue until the
model answers. The default, `automatic`, uses native calls when the provider
advertises support and JSON emulation otherwise; it does not select XML.
`native` requires provider-native tool calling.
