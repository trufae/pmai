[Documentation](README.md) · [Project home](../README.md)

# Features

For a quick introduction and supported platforms, see the [project README](../README.md).
Detailed setup guides are listed in the [documentation index](README.md).

## Make the agent yours

- **Bring your model.** Use Apple Intelligence or MLX on supported Apple hardware,
  sign in with a ChatGPT subscription, or connect an OpenAI-compatible API such
  as OpenAI, Ollama, llama.cpp, vLLM, or OpenRouter. Native tool calling and text,
  XML, and JSON fallbacks accommodate different providers.
- **Build your own team.** Save prompts, create or import `SKILL.md` skills, and
  give agents their own models and tools. Inspect subagent transcripts and usage,
  send guidance, pause or resume work, and stop a branch. Choose separate models
  for chat, compaction, tool decisions, and approval review.
- **Set the boundaries.** Choose tools per agent and MCP server, set file and
  folder rules to allow, ask, or deny, and review or edit tool arguments before
  execution. Configure manual or model-assisted approval and limits on turns,
  tool calls, tokens, elapsed time, and subagents.
- **Isolate project work.** Use [project boxes](boxes.md) on macOS or Linux to
  run agents and tools in Docker or Podman, with an independent Git checkout
  and explicit diff/apply steps to bring changes back.
- **Connect your tools and agents.** Add Streamable HTTP MCP servers, plus local
  stdio servers and native plugins in supported CLI builds. Use ACP agents as
  providers or subagents, serve pmai to an ACP editor with `pmai --acp`, or expose
  its configured agent to an MCP client with `pmai --mcp`. The
  [tool proxy](proxy.md) controls discovery and reduces tool-schema overhead.

## Move between phone and terminal

- **An adaptable workspace — iOS.** Keep conversations beside your chat on a
  roomy display, or collapse the sidebar for more writing space. Narrow windows
  use the swipeable drawer. The layout follows window size and safe areas when
  opening or closing iPhone Duo or using Split View.
- **Take your workstation with you.** Pair PocketMai or another pmai CLI with a
  running host to continue saved chats, switch projects, and browse or transfer
  files. Use built-in Forwiroh for encrypted Iroh connections, connect over your
  LAN, or use OpenTunnel, with pairing approved on the host. See
  [remote hosts](remote-hosts.md) for setup.
- **Stay in your coding flow.** Pipe context into pmai, run shell tools for builds,
  tests, and Git, or hand the terminal over to an interactive program. Install the
  [Vim integration](vim.md) to review and apply changes to a selection.
- **Keep the whole conversation.** Organize chats by project, search past work,
  and carry persistent memory and todos forward. Share a `.pocketmai` file with
  attachments, tool messages, and nested subagent chats, then continue on another
  device using its own provider credentials.
- **Shape the context.** Edit, undo, trim, search, or compact a conversation with
  a focus. Queue `/then LINE` in iOS or the CLI to run a message or command after
  all tasks finish, one line at a time. `/then` lists pending lines; `/unthen`
  clears them. Commands such as `/model MODEL` and `/skills prompt NAME [TEXT]`
  run before the next queued message. iOS keeps each queued action in its original
  chat; `/model` selects that chat's model on its current provider.
  Ask `/btw QUESTION` alongside a running reply in iOS or the interactive
  CLI; it uses a fresh context without changing the main conversation.
  In the CLI, `/hey TEXT` interrupts the focused agent, appends the text to its
  prompt, and resubmits it as one user message. Bare `/hey` retries the same
  running prompt. When idle, `/hey TEXT` sends TEXT as a new message.
  Earlier exchanges and attachments stay in the chat.
  Use `@PID /hey TEXT` for one agent or `@* /hey TEXT` for all active agents.
  Address prefixes also dispatch other slash commands with each recipient
  focused, such as `@3 /msg last`, `@3 /continue`, and `@* /stop`.

## Put it to work

- **Files and local knowledge — iOS + CLI.** Read, search, write, and patch files
  within your configured workspace. Index documents and source with `vdb` to
  retrieve passages with file and line references; default retrieval runs locally
  without an embedding-model download. On iOS, browse, preview, and edit local
  or remote files, create folders, and upload or download documents. Unsupported
  chat attachments can be saved to the working folder, with a prompt to enable
  Files tools when needed. `files_zip` and `files_unzip` pack and extract ZIP/XDC
  archives without a shell; extraction creates a new folder and never overwrites
  existing files. Archives are limited to 50 MB, expanding to 100 MB and 10,000
  files. Packing uses stored compression and does not preserve empty folders or
  file permissions.
- **Research and everyday tools — iOS + CLI.** Search the web, including through
  your own SearXNG instance, fetch readable pages, and download files. Browse
  GitHub repositories, PR diffs, discussions, issues, releases, and CI logs.
  With a writable token, post comments, review inline with code suggestions,
  and create PRs from pushed branches. Check weather, calculate, or search
  Mastodon and enable posting when needed.
- **Documents in, documents out — iOS + CLI.** Import text, source, HTML,
  Markdown, DOCX, EPUB, JSON, and PDF; export conversations to Word, EPUB,
  Markdown, HTML, plain text, or JSON. Use local Apple Vision OCR on iOS and
  macOS, or installed Tesseract on other CLI platforms. On iOS, attach PDF pages
  as images and read scans with OCR.
- **Talk naturally — iOS.** Speak a question, listen to replies, or import a
  voice note, including Ogg Opus. Transcription stays on device by default;
  choose a local model and device voice for offline conversations. Enable
  Voiceover for short spoken summaries of finished replies. Native live
  transcription requires iOS 26+ and an installed speech model. The share sheet
  accepts pictures, audio, and documents from other apps.
- **A browser you can take over — iOS.** Let the agent read text, DOM, links, or
  OCR from a floating WebKit browser, then click, type, scroll, or run JavaScript.
  Enlarge its picture-in-picture card and take over for sign-ins or any other step.
- **Make little apps — iOS.** Create and run WebXDC mini apps with HTML, CSS, and
  JavaScript inside the chat. Keep revisions, roll back changes, and share `.xdc`
  files for PocketMai or Delta Chat. The runner blocks network access.
- **Use your device — iOS.** Read your calendar and optionally create events,
  use device location, and set countdowns or one-time and repeating alarms
  (iOS 26.1+). Follow replies and tool calls through Lock Screen and Dynamic
  Island Live Activities, receive background completion and approval
  notifications, and optionally keep long replies working when the screen locks.

See the [iOS guide](pocketmai.md) for location, voice privacy, conversation
sharing, and CarPlay setup.

Offline use depends on selecting a local model and local tools; remote providers
still need a connection. CLI Airplane Mode limits tools, not the inference
provider. File-tool rules enforce workspace boundaries; CLI shell commands run
with the pmai process's privileges and their own approval rules.
