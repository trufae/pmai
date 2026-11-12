extension MaiCLI {
  static let voiceHelp: String = """
    /voice                  Toggle voice mode
    /voice on               Enable voice using saved settings; keeps active voice
    /voice realtime         Listen; silence ends the turn (default)
    /voice walkie-talkie    Record; /voice send ends each turn
    /voice record|resume    Begin recording the next turn
    /voice send             Finish transcription and send (Ctrl+T)
    /voice discard          Discard capture/transcript and pause (Ctrl+G)
    Ctrl+Space              Start recording, or send the current recording
    /voice pause            Mute capture and stop speech
    /voice off              Stop voice and its agent
    /voice status           Show active settings, state, agent PID and last error
    /voice voices [FILTER]  List available speech voice IDs and languages
    /voice languages [FILTER] List languages with input availability and speech
    /model -voice SELECTOR  Choose the voice conversation agent/model
    /set voice.             List all voice settings (also included in /set)
    /set voice.KEY          Show a value, accepted format and when it applies
    /set voice.voice ID     Choose a voice from /voice voices
    /set voice.language TAG Choose a language from /voice languages
    /set voice.speed N      Speech rate multiplier (0.25–4; default 1)

    /set saves settings; apply changes to active voice with /voice off then /voice on.
    Explicit /voice realtime or walkie-talkie restarts voice in that mode for this
    session; /set voice.mode MODE selects the saved default. /voice by itself toggles.
    voice.language selects recognition and the default speech voice. An explicit
    voice.voice ID overrides speech language selection; default follows the language.
    A speech voice does not provide an on-device recognition model for that language.
    voice.provider selects the audio service for openai input/output; /model -voice
    selects the conversation agent/model. They are separate settings.

    MaiCore's voice settings select language, input/output plugin kinds (system,
    command, openai), silenceSeconds, speechThreshold, voice and provider/models.
    Native macOS uses on-device speech recognition and system voices. Linux uses
    arecord for PCM capture and festival for system output. Command transcription
    takes a WAV {audio} and {language}, printing text on stdout; speech programs
    receive text on stdin, or in {text}. See MaiCore/README.md for configuration.
    Voice replies and tool activity are shown as text as well as spoken.
    /view voice puts the animation, input, replies and tools in a dedicated frame.
    Text input remains available; /subagents PID opens the voice conversation.
    """

  static let statsHelp: String = """
    Statistics commands:
      /stats                 Rank every provider:model by combined ranking, tokens/s, time in use, and efficiency
      /stats METRIC          One ranking: ranking, speed, time, or efficiency
      /stats show PROVIDER[:MODEL]  Every fact recorded about one model or a whole provider
      /stats del PROVIDER[:MODEL]  Drop the statistics of one model or a whole provider
      /stats reset           Forget every statistic
      /stats path            Print the file the statistics are saved in
    The runtime records tokens (from the provider's usage, or estimated from text
    length and marked ~) and the wall-clock time of every model call, in the REPL
    and one-shot runs alike. Speed uses answer text tokens
    over the streaming window (~ means estimated from text length). Time in use
    adds the wait for the first token; efficiency is total tokens /
    (seconds in use × requests).
    """

  static let exportHelp: String = """
    Export this chat as a document, or make a portable Mai archive:

      /export archive [PATH]    Providers, prompts, MCPs, agents, visible skills,
                                and this chat (.pocketmai.json)
      /export txt [PATH]        A plain-text transcript (.txt)
      /export markdown [PATH]   A Markdown transcript (.md)
      /export json [PATH]       The chat as stored, in a JSON envelope (.json)
      /export debug [PATH]      The JSON plus the tools, settings, and every child agent's
                                transcript from this chat's runs
      /export html [PATH]       A self-contained HTML document
      /export epub [PATH]       An EPUB book, one chapter per message
      /export docx [PATH]       A Word document
      /export --context FORMAT [PATH]  Export the active context instead of original history

    PATH may be a file or a folder; without it the file is named after the
    chat title and written to the current directory.

    Documents omit tool calls, results, and thinking by default. Include them with
    /set export.tools on and /set export.thinking on. JSON keeps the complete chat.

    Archives can contain credentials already stored literally in the
    configuration. Environment-variable and key-file references stay as references.
    """

  static let importHelp: String = """
    Import a portable Mai archive into this project:

      /import PATH              Merge providers, prompts, MCPs, and agents; install
                                skills for the current user; add chats to this project

    PocketMai's Share Conversation files (.pocketmai), standalone .pocketmai.json
    archives, and archives embedded by PocketMai are accepted.
    Example: /import ~/Downloads/My Chat.pocketmai

    Existing settings are replaced only when their stable IDs or prompt
    names match; existing chats are never overwritten. Older pmai JSON chat exports
    are accepted too.
    """

  static let replyHelp: String = """
    Answer the last assistant reply with it quoted above the answer:

      /reply                 Quote the last reply and open $EDITOR on it
      /reply WIDTH           Wrap the quote at WIDTH columns instead of the screen width

    Every quoted line is wrapped and prefixed with "> ", with a blank line left
    under it for the answer. Saving and leaving the editor sends the whole text
    as an ordinary message; leaving the quote untouched sends nothing.
    """

  static let copyHelp: String = """
    Copy conversation text to the clipboard, or into a file:

      /copy                  The last assistant reply, without its reasoning
      /copy N                The last N messages, oldest first, labelled by role
      /copy PATH             The last reply, written to the file PATH
      /copy N PATH           The last N messages, written to the file PATH

    Tool calls, tool results, images, and other attachments are summarized on
    their own lines; system instructions are never copied. PATH may start with
    ~ and is resolved from the current directory; an existing file is replaced,
    and a folder is refused.
    """

  static let remoteHelp: String = """
    /remote serve          Share all indexed pmai projects over Forwiroh; prints a pairing QR
    /remote serve --protocol openai  Serve OpenAI-compatible chat and audio on localhost:11435
    /remote serve --protocol openai --tools  Include the selected agent's configured tools
    /remote serve --protocol local  Serve directly on your local network
    /remote serve --protocol opentunnel  Publish an encrypted connection using the opentunnel CLI
    /remote serve --protocol forwiroh  Share through encrypted paired devices (default)
    /remote serve --path PATH ...  Share only these directories and their descendants
    /remote serve --protocol local --loopback  Listen only on 127.0.0.1 for a local tunnel or proxy
    /remote serve --protocol local --loopback --url wss://HOST/acp  Advertise an existing tunnel or TLS proxy
    /remote stop           Stop the server and disconnect its clients
    /remote qr             Show the running server's pairing QR and connection URI again
    /remote list            List paired hosts and server status
    /remote tools HOST on|off  Allow or revoke local agents' access to a paired host
    /remote pair PROFILE [NAME] [CWD]  Save a connection URI, profile text file, or QR image
    /remote ls HOST [PATH]  List files, including hidden files
    /remote get HOST REMOTE [LOCAL]  Download a file (default: its basename here)
    /remote put HOST LOCAL [REMOTE]  Upload a file (default: its basename on the host)
    /remote run HOST COMMAND  Run a command directly on the host
    /remote shell HOST [auto|live|cmd]  Open a live shell or command/result prompt
    /remote shell off      Leave remote shell mode
    /remote pending        List clients waiting for your approval
    /remote accept [CODE]  Accept a pairing request; omit CODE when only one is waiting
    /remote reject [CODE]  Reject a pairing request
    /remote clients        List accepted clients
    /remote del ID         Revoke an accepted client's access
    /remote connect NAME   Open an ACP or OpenCode chat on a paired host
    /remote disconnect     Return to your local chat

    File and shell commands work without /remote connect and do not create chats.
    Paths on the host and commands start in the paired CWD; local paths use your
    REPL directory and support ~. Quote paths or host names containing spaces.
    Transfers replace existing files and are limited to 32 MB each; put accepts
    a remote directory ending in /. ls includes every page. Ctrl+C stops waiting.
    Everything after run HOST goes to the remote shell verbatim, including quotes,
    pipes, variables, and redirects. Shell directory changes apply to that run only.
    shell HOST uses a live PTY when the host and terminal support it. State persists;
    interactive programs work. exit or Ctrl+] closes the shell and returns to pmai.
    live requires PTY support; cmd forces command/result mode. Piped input uses cmd.
    In cmd mode the prompt becomes HOST>; cwd and environment reset for each line.
    exit or /remote shell off returns to pmai; /remote commands remain available.
    Host Files permissions apply; command/result execution requires run_shell.
    For OpenCode, use /remote pair LINK NAME /absolute/project with the link or QR
    from opencode pair --remote. /remote connect opens its native chat session;
    saved local chats resume the same host session. /shell follows the active host.
    OpenCode uploads use its experimental write API.

    OpenAI serving uses the current agent and provider settings at startup. Use
    --port PORT to change 11435, or --bind HOST to choose a listener address.
    It stays on loopback by default. LAN serving requires a bearer token from
    PMAI_HTTP_TOKEN, or creates one in ~/.pmai/remote-server/openai/token.
    /remote list shows the endpoint and token file location; /remote stop or
    leaving the REPL stops serving. Audio examples are in doc/audio-server.md.

    Other /remote serve protocols keep this REPL usable too. Forwiroh is the
    default and keeps the ACP listener on loopback. New devices need Forwiroh
    approval followed by ACP chat approval with /remote accept.
    Port 19283, the current agent, and current directory are selected automatically.
    All projects in ~/.pmai/projects.json and their saved chats are shared by default.
    Use --path PATH ... to restrict folders or --port PORT to change the port.
    With --protocol local, your LAN address is selected automatically;
    --loopback binds only to 127.0.0.1 and advertises that address by default.
    --address IP overrides the advertised address without changing the listener.
    --url ws://HOST:PORT/acp or wss://HOST/acp sets the full URL in the QR/profile.
    OpenTunnel always listens on loopback. Install opentunnel on the serving host;
    pmai manages a dedicated tunnel profile and stops it on /remote stop or exit.
    Its identity is kept for the next run. With --protocol opentunnel --url URL,
    you manage the tunnel yourself. OpenTunnel URLs must use wss://.
    --name NAME chooses the advertised host name.
    Scan the QR in PocketMai → Hosts. On another CLI, pair the URI or QR image once.
    Accept the client in the serving REPL before it can browse or run agents, then
    /remote connect NAME. Remote tools use the normal approval flow. /chat use
    reopens a saved remote chat, restoring its session on the server.
    """

  static let pathHelp: String = """
    /path                  Show current directory, Files workspace, grants, and rules
    /path allow PATH       Allow a file or directory (alias: add)
    /path deny PATH        Reject access, including inside allowed directories
    /path ask PATH         Require confirmation for every access (alias: prompt)
    /path del PATH         Remove an explicit rule/grant; parent permissions still apply
    /path outside ask|deny Prompt or reject paths outside the allowed scope (default: deny)
    /path hidden ask|deny|allow Set the default for dotfiles and dot directories (default: ask)
    /path sensitive ask|deny|allow Set the default for key, credential, and encrypted files (default: ask)
    /path symlinks ask|deny|allow Follow workspace symlinks to outside targets (default: ask)

    Paths resolve relative to the Files workspace; ~, absolute paths, and quoted
    paths with spaces work. Existing directories cover descendants. Add a trailing
    / for a new directory. Deny overrides ask and allow; ask overrides allow.
    On first startup, /etc, /root, ~/.ssh, ~/.gnupg, ~/.config, hidden paths,
    and key/credential/encrypted filenames default to ask.
    Rules and /path edits are saved in configuration; prompt grants last for this
    session. Explicit rules override the hidden-path default. These checks apply
    to Files and vdb, including child agents. /tmp (including its resolved alias)
    is allowed by default, even with saved configurations; explicit rules override it.
    At tool prompts, t saves yolo for only that tool in this project; path policies
    still apply. /set tool.approval lists these tools; setting a project mode clears them.
    At tool or path prompts, a enables yolo for tools and path asks and saves it
    for this project; s enables it for this session only. Ordinary saved tool yolo
    settings keep path prompts active. /set tool.approval yolo session also approves
    asks for this session only.
    Explicit deny rules still apply. Without a terminal, unresolved asks are rejected.
    Symlinks inside the workspace or an approved directory can reach outside
    targets: ask prompts for each operation, allow treats them as workspace paths,
    and deny rejects them. Resolved target rules and hidden/sensitive checks still
    apply. Direct outside paths keep the outside policy; following a link grants
    no session access to its target. Searches do not descend through directory links.
    Only the person at the REPL can
    change these policies.
    Explicit prompt paths use normal tool approval to add a session grant and
    print a /path hint. Setting outside deny blocks these automatic additions;
    outside ask requires confirmation. /path ask PATH prompts on every access.
    Shell commands and other tools retain their own permissions.
    """

  static let aboutMessage: String = #"""
        /\             /\
       /  \___________/  \
      /                   \
     |    \                |     _    ___
     |     >   ____        |    / \  |_ _|
     |    /                |   / _ \  | |
      \___________________/   /_/ \_\|___|

    Welcome to PocketMai! pmai \#(version)

    Chat with models, run tools, and work with coding agents from your terminal.

    Connect an API provider:
      /provider add myai https://api.example.com/v1 --api-key YOUR_API_KEY
      /models myai
      /model myai::MODEL

    Or select a coding agent over ACP (one command inside pmai):
      /agent acp add claude
      /agent acp add opencode
    Install first in your shell:
      npm install -g @agentclientprotocol/claude-agent-acp
      npm install -g opencode-ai
    Authenticate with the agent's own CLI before using ACP.

    OpenCode with a named ACP provider (keep this agent's settings):
      /provider add acp oc opencode acp
      /model oc::opencode/big-pickle

    For a local Ollama server:
      /provider add local http://127.0.0.1:11434/v1
      /models local
      /model local::MODEL

    Replace the example URL, YOUR_API_KEY, and MODEL with your settings.
    Use --api-key-file PATH to read a key from a file. Selections are saved.
    /providers lists connections; /provider del ID removes one after switching away.
    /help lists commands; /help provider covers Apple/MLX, ChatGPT, and ACP.
    /about shows this message again. https://github.com/trufae/pmai
    """#

  static let heyHelp: String = """
    /hey [TEXT] interrupts the focused agent and resubmits its prompt,
    appending TEXT on a new line. With no text, it resubmits the same prompt.
    Earlier exchanges and prompt attachments are kept. The interrupted
    attempt is replaced in chat history, leaving one amended user message.
    Text after /hey is literal, including > and |. Completed tool actions
    are not undone. With no running prompt, TEXT is sent as a new message;
    bare /hey sends nothing.
    @PID /hey [TEXT] targets one agent; @* /hey [TEXT] targets all active agents.
    """

  static let replHelp: String = """
    /about                 Logo, version, and provider setup
    /agent                 Alias for /agents
    /agents                List or edit saved agents
    /attach [MODE] PATH    Attach a file; /attach clear removes attachments
    /btw PROMPT            Ask a side question in a fresh context
    /cd PATH               Change working directory
    /chat                  List, switch, fork, archive, or delete chats
    /clear                 Clear the screen
    /continue              Resume an interrupted task
    /copy [N] [PATH]       Copy replies to the clipboard or a file
    /cwd                   Print working directory
    /edit TARGET           Edit input, prompts, skills, agents, or settings
    /exit                  Exit the REPL
    /export FORMAT [PATH]  Export this chat or a portable archive
    /fork [--empty] [TITLE] Fork into a child conversation and switch to it
    /help [COMMAND]        List commands or show detailed help
    /help keys             Keyboard shortcuts
    /help shell            Input, shell commands, redirects, and agent messages
    /hey [TEXT]            Interrupt and resend with TEXT, or send TEXT when idle
    /history [COMMAND]     List, search, or delete saved inputs
    /image MODE PATH       Attach an image or extract text with OCR
    /import PATH           Import settings, skills, and chats
    /jobs                  Manage running and saved processes
    /mcp                   Manage MCP servers
    /memory                Show, edit, learn, or scope project memory
    /model [FLAG] [MODEL]  Select chat or task models; /help model
    /models [PROVIDER] [FILTERS]  Browse models; /models --help
    /msg                   List, pin, edit, or delete messages in this chat
    /nothink               Disable reasoning
    /path                  Show or change file access policies
    /plugins               List loaded plugins
    /project               Show, rename, or tint this project
    /projects              List, manage, or switch projects
    /prompt                Manage named system prompts
    /prompts               List prompts and skills
    /provider [ID]         Show or select a provider; /help provider for setup
    /providers             List registered providers
    /ps [-a] [-p]          Show shell processes and command history; -k PID kills one
    /queue                 Manage messages waiting for an agent
    /remote                Serve, pair, or connect to remote hosts
    /reply [WIDTH]         Reply in $EDITOR with the last reply quoted
    /reset [SETTING]       Restore one default, or all defaults after confirmation
    /set [SETTING VALUE]   Show or change settings
    /skills                Manage or send skills
    /stats                 Show model usage and performance
    /stop                  Interrupt the current turn
    /subagents [PID|main]  List or switch agent conversations
    /theme                 List, apply, or customize terminal themes
    /then [LINE]           Queue a prompt or command until all tasks finish; no args lists it
    /todo                  Show or edit the project's todo list
    /tools                 List tool groups for this agent; /tools full includes tools
    /unthen                Clear all pending /then actions
    /vdb                   Index or search local documentation and code
    /version               Print the pmai version
    /view SOURCE           Read-only split in buffer mode; /help view
    /voice [MODE]          Voice agent: realtime or walkie-talkie; /voice help
    $NAME [TEXT]           Send a prompt or skill; /prompts lists names
    @PID TEXT              Send a message to an agent; @* TEXT broadcasts
    . FILE                 Read a file and send its contents as a prompt
    """

  static let shellHelp: String = """
    Input:
      /set ui.line multi  Wrap long input across rows (default, in classic and buffer modes)
      /set ui.line single Show one scrolling row; [2/3]> identifies the logical line
      Enter sends; Shift+Enter adds a newline. Alt+Enter or Ctrl+J also add newlines.
      Terminals that report Shift+Enter as plain Enter need one of those alternatives.
      Up/Down move through visible rows, then history; soft wrapping adds no newlines.
      <<WORD              Start a multiline message; WORD alone ends it
      <<!                 Compose in ui.editor, $EDITOR, $VISUAL, or vim
      <<!vim              Compose with this editor command for this invocation only
      /edit input         Same as <<!; Ctrl+X Ctrl+E edits the current prompt draft
      After editing: send / edit again / back to prompt / cancel (Enter cancels).
      Cancel restores the original draft; failed edits keep the draft. Nothing sends automatically.
      . FILE              Send a UTF-8 file's entire contents as one literal prompt
      Quote paths containing spaces; ~ expands to your home directory.
      $NAME [TEXT]        Send a named prompt or skill; /prompts lists names
      !COMMAND            Run a system shell command (interactive programs work)
      /shell [auto|live|cmd]  Shell on the active chat host (local for local chats)
      /shell local        Always open a local shell; exit returns to pmai
      /remote shell HOST [auto|live|cmd]  Live shell or command/result prompt

    Redirect slash-command output:
      /COMMAND > FILE     Overwrite a file
      /COMMAND >> FILE    Append to a file
      /COMMAND | COMMAND  Pipe stdout to a shell command
      Examples: /msg log > log.txt
                /msg last | grep banana
      Only slash commands redirect; quoted, escaped, or pasted operators stay literal.

    While a turn runs:
      Messages are queued for the next model turn. Commands run right away;
      setting changes reach the next turn.
      @2,3 TEXT or @2 @3 TEXT sends to several agents.
      @* TEXT sends to every active agent, including the running main chat.
      @@ TEXT and bare @ TEXT are aliases for @* TEXT. @ alone shows usage.
      Child output uses agent#PID blocks; /set ui.subagents controls how much.
    """

  static let modelHelp: String = """
    Change models:

    - `/model MODEL` — Chat and all tasks
    - `/model -chat MODEL` — Chat only; keep task assignments
    - `/model -compact [NAME]` — Compaction
    - `/model -tool [NAME]` — Tool decisions
    - `/model -approval [NAME]` — Smart approval
    - `/model -btw [NAME]` — Side questions

    MODEL accepts `PROVIDER::MODEL` or a model on the current provider.
    Task NAME also accepts a saved agent ID. Omit NAME (or use `-` or `default`)
    to use the current chat agent for that task. Changes are saved.
    """

  static let keysHelp: String = """
    Keyboard shortcuts:
      Shift+Enter adds a line (Alt+Enter or Ctrl+J where the terminal sends Enter for it)
      A paste keeps its lines · Enter sends the whole text
      /set ui.line multi wraps input; single shows one scrolling row with a line counter
      Ctrl+X Ctrl+E edits the current draft in your editor, then asks before sending
      Tab selects the next completion · Shift+Tab selects the previous completion
      File arguments complete paths; a directory's trailing / lets you keep browsing
      Up/Down or Ctrl+P/N move between lines, then history · Ctrl+R reverse search
      Ctrl+A/E or Home/End beginning/end of the line
      Ctrl+B/F page up/down in the focused frame, like Page Up/Down
      Ctrl+< / Ctrl+Shift+> jump to the beginning/end of the focused frame (extended keyboards)
      Ctrl+L clear the screen, keeping the input
      Ctrl+W delete word · Ctrl+C or /stop interrupt the run · Ctrl+Z suspend
      Voice: Ctrl+T transcribes/sends · Ctrl+G discards · Ctrl+Space records/sends
      Ctrl+D exits when the input is empty
      Page Up/Down and the mouse wheel scroll the transcript in buffer mode
      Tab on an empty prompt focuses /view; j/k scroll, J/K page, g/G top/bottom, Space layout, Enter fullscreen, / search, v/V resize, q closes
      Alt+1…9 selects an agent slot · Ctrl+Left/Right cycles agent conversations
      Extended keyboards also support Ctrl+1…9 and Ctrl+Tab/Ctrl+Shift+Tab
    """

  static let effortHelp: String = """
    Reasoning effort:
      /set effort                Show the current agent's reasoning effort and guidance
      /set effort LEVEL          Set it: off, minimal, low, medium, high, xhigh, or max. The provider gets the
                                 field its API takes (reasoning_effort, think, enable_thinking,
                                 thinking…) and the system prompt says how much care to take
      /set effort LEVEL TEXT     The level plus TEXT, added to the system prompt as guidance
      /set effort auto           Use pmai's automatic policy, with no guidance; DeepSeek Flash
                                 defaults to off because its provider default is high
      /set effort off            Disable thinking where supported (also /nothink)

    Examples:
      /set effort high
      /set effort max Check every edge case and verify the result before answering
      /set effort low Keep answers to one paragraph
    """

  static let themeHelp: String = """
    /theme [list]        List built-in and saved themes for ui.color
    /theme show [NAME]   Preview themes for ui.color, or just NAME, without applying them
    /theme use NAME      Apply and persist a theme's UI settings
    /theme save NAME     Save current colors and bold as a theme (overwrites NAME)
    /theme color         List all current colors and bold
    /theme color KEY     Show one setting
    /theme color KEY VALUE  Change and persist one setting (KEY=VALUE also works)

    /set ui.color dark|light selects the themes available to list, show, use, and Tab completion.
    Light themes: summer, sand, colit. All other built-ins are dark. Default: dark.
    Changing ui.color keeps current colors until /theme use NAME applies a theme.
    Buffer mode also recolors earlier prompts and themed output when colors change.

    Color settings:
      /theme color bgline COLOR       Input/status-line background
      /theme color fgcolor COLOR      Input foreground
      /theme color bgcolor COLOR      Text and buffer background
      /theme color fgprompt COLOR     Prompt foreground
      /theme color bgprompt COLOR     Background of the entire input area
      /theme color fgbubble COLOR     Submitted message text (none uses fgcolor)
      /theme color bgbubble COLOR     Submitted message bubbles (none for outlines)
      /theme color fgtoolresult COLOR Successful tool-result output
      /theme color fgtoolcall COLOR   Tool-call previews
      /theme color bgtoolcall COLOR   Tool-call background
      /theme color bgtoolresult COLOR Tool-result background
      /theme color fgerror COLOR      Errors and failed tool results
      /theme color fgwarning COLOR    Warnings, retries, and approval requests
      /theme color fgsuccess COLOR    Successful run status
      /theme color fginfo COLOR       Context notices, tool-help headings, and chat-log headers
      /theme color fgthinking COLOR   Thinking text
      /theme color fgbold COLOR       Markdown bold text (keeps bold)
      /theme color fgitalic COLOR     Markdown italic text (keeps italic)
      /theme color fgdiffadd COLOR    Added diff-line foreground
      /theme color bgdiffadd COLOR    Added diff-line background
      /theme color fgdiffdel COLOR    Removed diff-line foreground
      /theme color bgdiffdel COLOR    Removed diff-line background
      /theme color fgdiffheader COLOR Diff file and hunk headers
      /theme color fgselection COLOR  Selected TAB-completion foreground
      /theme color bgselection COLOR  Selected TAB-completion background
      /theme color bold on|off        Render input in bold
      /theme color boldtoolcall on|off Render tool calls in bold

    COLOR accepts a named ANSI color, rgb:RGB, #RRGGBB, or none.

    Built-ins: default, ansi, mono, slime (green), summer (sunny cream), ember (warm),
    pink, blood (red and white), night (blue), plum, sand, codark (Tango accents),
    colit (Visual Studio Code).
    The old light name is an alias for summer.
    PMAI_THEME=NAME selects a theme at startup, overriding configured colors and bold.
    Custom themes live in ~/.pmai/themes/NAME ($PMAI_HOME or --home relocates it)
    and take precedence over built-ins. Saved files start with /set ui.color dark|light,
    followed by /theme color KEY VALUE lines. Untagged custom themes default to dark;
    overrides of summer, sand, colit, and the light alias default to light.
    Blank lines and # comments are allowed. Older /set ui.COLOR VALUE files still load.
    Other settings stay as they are.
    """

  static let providerHelp: String = """
    /provider                         Show the current connection
    /providers                        List providers, local availability, and effective URLs
    /provider [use] ID                Save this agent's provider and default for new chats
    /provider add ID URL [--api-key KEY | --api-key-file PATH] [--model MODEL] [--kind systemone]
    /provider add ID --kind apple     Apple Intelligence; no URL or API key
    /provider add ID --kind mlx [--model org/model]  MLX on Apple silicon; no URL
    /provider add ID --kind chatgpt   Use a ChatGPT subscription; no URL or API key
    /provider add acp NAME [CMD ARG ...]  Use opencode, claude, codex, or a custom ACP agent
    /provider add acp NAME --url URL --cwd DIR [--token-env ENV]  Remote ACP WebSocket

    ACP: /models NAME discovers models; /model NAME::MODEL selects one.
    /set effort LEVEL selects a supported ACP effort; auto restores the agent's default.
    Built-in Claude and Codex adapters (already installed and authenticated):
      /provider add acp claude
      /provider add acp codex
      /provider use claude
      /models claude
      /model claude::MODEL_ID
    OpenCode example (already installed and authenticated):
      /provider add acp oc opencode acp
      /model oc::opencode/big-pickle
    For one-command setup that also saves and selects a same-named agent:
      /agent acp add claude
      /agent acp add opencode
    Install adapters: npm install -g @agentclientprotocol/claude-agent-acp @agentclientprotocol/codex-acp
    Log in with the agent's own CLI first. ACP uses that agent's credentials.
    Local agents receive enabled pmai tools through MCP over loopback HTTP.
    /tools controls pmai tools; the ACP agent manages its own native tools and permissions.
    Remote agents use host tools and MCP servers configured in provider options.mcpServers.
    Agents must support MCP HTTP to call the local pmai tool bridge.
    /provider login [ID]             Continue with ChatGPT in your browser
    /provider logout [ID]            Sign out and revoke this ChatGPT session
    /provider status [ID]            Show the ChatGPT account and usage link
    /provider rename [OLD] NEW        Rename a connection and update configured agents
    /provider del ID                  Remove a connection; move task agents to this chat's provider/model
    /provider edit [ID]               Edit its connection settings (alias: /edit provider [ID])

    Providers are added explicitly. On macOS, set up native providers with:
      /provider add apple --kind apple
      /provider add mlx --kind mlx
      /provider use apple            Uses Apple's on-device model
      /provider use mlx              Uses the default MLX model
      /model mlx::org/model          Choose an MLX-ready Hugging Face repo or local directory
      /models apple                  Check Apple Intelligence readiness
      /models mlx                    List suggested MLX models
    Apple requires macOS 26+ with Apple Intelligence enabled in System Settings.
    MLX requires Apple silicon. The first request downloads the chosen model;
    later requests reuse the Hugging Face cache. HF_TOKEN supports gated models.

    In that editor, apiKeyEnvironment is an exported variable's name;
    apiKeyFile is a path, and apiKey saves the key directly in the config file.
    defaultModel is used when no model is explicitly selected for that provider.
    URLs and credential sources belong to each provider. Ambient
    URL/key variables only fill missing settings; --base-url and --api-key explicitly
    override the selected connection for one invocation. PROVIDER::MODEL selects
    that connection and sends only MODEL, including in environment model variables.
    A rename updates the active chat; other saved chats keep their own snapshots.
    To delete this chat's provider, /provider use OTHER first. Assigned task agents
    move to this chat's provider and model, keeping their other settings. Reassign
    other saved agents with /agent provider ID OTHER or remove them with /agent del ID.
    Provider deletion also accepts /provider delete ID and /provider remove ID.
    Deletion keeps other saved chats' connection snapshots and external logins.
    """

  static let setHelp: String = """
    Settings commands:
      /set                         List current settings and their values
      /reset [SETTING]             Restore one default, or all after reset/cancel confirmation
      /set effort [LEVEL] [TEXT]   Show or set reasoning effort and optional guidance
      /set tool.approval MODE [session]  yolo, ask (default), or smart; saved for this project unless session is given
      /set debug <true|false>       Log model calls, tool activity, and run events for this project
      /set debugfile <PATH|default> Save debug logs at PATH; default uses debug.jsonl in project storage
      /set tool.                   List the tool calling settings
      /set tool.calling MODE       off disables calls; automatic/native or text/XML/JSON enables them
      /set tool.systemone BOOL     Route tools via the System One /model -tool provider (default false)
      /set awake [on|off]          Show or change the local sleep inhibitor (default off)
      /set airplane on|off|toggle  Pause internet tools; ✈ marks offline mode
      /set tool.proxy MODE         Default exposure: on/hybrid (common tools direct), all, or off
      /set tool.auto BOOL          Automatically expose frequently used tools (default on)
      /set delegation MODE         off: runs every tool itself; subagent: may also hand work to a child
      /set limits.                 List the tool, turn, and subagent limits
      /set limits.maxToolCalls N   Tool calls allowed per prompt (default: 300)
      /set limits.maxModelTurns N  Model turns allowed per run
      /set limits.maxSubagents N   Child agents allowed at once (0 disables delegation)
      /set limits.maxSubagentDepth N  Maximum depth of the agent tree
      /set limits.maxTotalTokens <off|N|Nk>  Tokens a run may spend before it pauses
      /set limits.maxSeconds <off|N|Nm|Nh>   Wall-clock time a run may take before it pauses
      /set limits.runTimeoutSeconds <default|N|Nm>  Default shell timeout (1-600 seconds)
      /set limits.terminalTimeout <0|SECONDS|3m20s|1h20m>  Remote terminal idle expiry (0 keeps until closed)
      /set acp.timeout <off|N|Nm|Nh>  Whole ACP turn timeout for the selected provider (default off)
      /set acp.context <agent|replace>  Keep agent history or send pmai's full conversation in a fresh session
      /set acp.prompt <agent|replace>   Keep agent instructions or replace its native system prompt with pmai's
      /set http.transport <auto|curl|winhttp|urlsession>  HTTP engine for the selected OpenAI-compatible provider
      /set retry.attempts N        Times a failed model call is repeated (default 2)
      /set retry.delay SECONDS     Wait before each retry (default 5)
      /set ctx.                    List context settings and their current values
      /set ctx.compact <off|N|Nk>  Prompt to prune tool output or summarize older context at ~N tokens
      /set ctx.recent <auto|N|Nk>  Recent tokens kept verbatim when summarizing (auto: up to 8k)
      /set ctx.window <auto|N|Nk>  Model context size including reply space (e.g. 32768)
      /set ctx.strategy <cache|size|smart|tools|adaptive>  Keep history, prune reads, or build a working context
      /set export.                 List document export settings
      /set export.tools BOOL       Include tool calls and results in documents (default off)
      /set export.thinking BOOL    Include thinking blocks in documents (default off)
      /set ui.                     List terminal behavior settings
      /set ui.line MODE           single (one scrolling row) or multi (default: wrap input)
      /set ui.color MODE          dark (default) or light: filter theme choices and previews
      /set ui.mode MODE           classic or buffer (default): scroll with Page Up/Down and mouse wheel
      /set ui.scroll N            Lines per mouse-wheel event in buffer mode (default 1)
      /set ui.highlight WORD      Highlight literal matches; none clears (also /highlight WORD)
      /set ui.scrollbar N         Scrollbar width: positive right, negative left, 0 hidden (default 0)
      /set ui.editor COMMAND       Editor /edit opens (`none` falls back to $EDITOR, $VISUAL, vim)
      /set ui.markdown BOOL        Render replies as styled markdown (on/off)
                                   Buffer mode also redraws earlier replies with this setting
      /set ui.fgbold COLOR         Add color to Markdown bold text (none disables color)
      /set ui.fgitalic COLOR       Add color to Markdown italic text (none disables color)
      /set ui.tableborders BOOL    Draw table frames and separators (on/off; default off)
      /set ui.toolgroups <on|off>     Collapse consecutive tools into clickable summaries (enables buffer mode)
      /set ui.tools <all|relevant|icons|N>  Full results, relevant previews, emoji rows, or first N lines (0 hides them)
      /set ui.toolcalls <truncate|first|N>  Truncate arguments (default), wrap the full first line, or show N source lines per argument
                                   Buffer mode also updates earlier tool calls and results
      /set ui.thinking MODE        Thinking display: status, line, three, five, or full
                                   Buffer history: hide blocks, show their last 1/3/5 rows, or show all
      /set ui.subagents LEVEL      What child agents print: all, tools, stats, or none
      /set ui.broadcast BOOL       Default unaddressed messages to @* / @@ / bare @ (on/off; default off)
      /set redact on|off|warn   Filter model requests using ~/.pmai/redact.txt (warn logs counts)
      /set use.agentsmd MODE       Use applicable AGENTS.md files: on, off (default), or ask
                                   (prompts once per working directory in an interactive session)
      /set use.plan BOOL           Ask an agent that can start children to open a request of
                                   several steps with a numbered plan before delegating (on/off)

    tool.approval, debug, and debugfile are saved as settings.json in the opened project's storage.
    /set tool.approval yolo session and s at approval prompts enable yolo for tools
    and path asks until exit; nothing is saved. Explicit path denials still apply.
    At approval prompts, a saves yolo for tools and path asks in the current project.
    At tool prompts, t saves yolo for only that tool; Files path policies still apply.
    /set tool.approval lists these tools; setting a project approval mode clears them.
    Debug entries append to the chosen file and may contain prompts and tool output.
    --tool-approval MODE overrides approval for one run. Projects without a saved choice use approvals.mode from the
    active configuration. Agent, UI, and document export settings use the active configuration.
    """

  static let resetHelp: String = """
    /reset SETTING restores just that setting to its stock default, without confirmation.
    Examples: /reset effort, /reset ui.scrollbar, /reset voice.speed.
    Theme colors also accept their UI key, for example /reset ui.bgcolor.
    Other settings and active voice are kept; voice settings apply after restarting voice.

    /reset restores every /set option to its stock default: voice, UI, export,
    use.*, airplane, redaction, the current agent's effort, limits, retry, context,
    delegation and tool-calling settings, and this project's approval/debug settings.
    Choose reset to apply, or cancel / Ctrl+C to keep your settings. Leaving the
    prompt with another slash command also cancels. Active voice stops on reset;
    /voice on starts it again with the stock settings.
    Providers, credentials, chats, custom prompts, other agents, and tool selections
    are preserved. Settings are saved and apply to the running agent's next call.
    """

  static let chatHelp: String = """
    Chat list commands (messages inside the current chat: /msg):
      /chat list [active|archived|all]  Pinned first, then by start date, oldest first; archived last
      /chat new [TITLE]             Start a fresh chat using the current agent
      /chat new --agent ID [TITLE]  Start a fresh chat using a configured agent
      /chat fork [TITLE]           Clone the current chat and continue in the copy
      /chat use INDEX|ID|TITLE      Switch to a chat by list index, ID prefix, or title
      /chat next|previous|prev      Cycle newer or older through chats (wraps around)
      /chat info [INDEX|ID|TITLE]   Show a chat's agent, session, size, and timestamps
      /chat session [new]           Show the session id providers see, or start a fresh one
      /chat title [TEXT|none]       Show or set this chat's temporary prompt and terminal/tab title
      /chat rename TITLE            Rename the active chat
      /chat pin [INDEX|ID|TITLE]     Pin a chat (defaults to the current chat)
      /chat unpin [INDEX|ID|TITLE]   Return a pinned chat to its date group
      /chat archive [INDEX|ID|TITLE]  Archive a chat; archiving the active one starts fresh
      /chat unarchive INDEX|ID|TITLE  Return an archived chat to the active list
      /chat del INDEX|ID|TITLE [...]  Permanently delete chats; deleting the active one switches
      /chat files                   List files accessed in this conversation
      /chat compact [FOCUS]  Summarize the chat, prioritizing what FOCUS says to preserve
      /chat context       Inspect the active context and compare its size with history
      /chat context reset  Start with instructions only; retain conversation history
      /chat context rebuild  Restore original evidence, removing context edits and summaries
      /chat edit          Edit all retained messages and context selection in the editor
      /chat recap         Print a short recap using the compact model; keep the history
      /chat rewind [lastmsg|lastpin|firstmsg|cancel]  Choose how to rewind, or apply a choice directly
      /chat clear         Clear the conversation and restore configured instructions

    Chat list indexes are 1-based. Negative indexes count back from the end;
    -1 selects the newest chat. Indexes follow creation order, oldest first,
    including archived chats, and stay the same when chats are pinned or updated.
    Pinning changes the display group only; pmai -r -1 works too.
    /chat title labels are kept only while this REPL is running, independently for
    each chat. `none` clears a label. Use /chat rename to change the saved chat name.
    /chat rewind shows status bar choices: c cancel, m lastmsg, p lastpin (only
    when messages are pinned), f firstmsg. Press one key, without Enter. lastmsg removes the
    last conversation message; lastpin keeps the newest pin and removes newer
    messages; firstmsg keeps through the first conversation message, including
    preceding instructions. Linked tool transactions stay valid. Ctrl+C or a slash command cancels.

    /chat del resolves all arguments before deleting, so indexes do not shift.
    A single exact title may contain spaces; use indexes or IDs for bulk deletion.
    /chat files keeps a sorted, unique record of Files content reads (including
    grep scans), writes, renames, deletions, and attachments across resumed turns,
    compaction, and child agents. Shell-internal file accesses are not observable.
    Older chats only include accesses recorded after this feature was added.

    pmai opens a fresh chat on every launch and names it after the first
    message; chats that never received a message are never written.
    Start with -l to list saved chats, then -r INDEX|ID|TITLE to reopen one;
    -r without a selector reopens the most recently updated chat. Chats
    belong to the project rooted at the start directory; /project shows it.
    A chat is saved with the agents its runs started and their transcripts:
    reopening it lists them under /jobs tree, /jobs log PID reads one,
    /chat info counts them, and /jobs clear drops them from the chat.
    """

  static let msgHelp: String = """
    Message commands for the current chat (the list of chats: /chat):
      /msg list                    Display a compact indexed message list
      /msg log [quiet|verbose|short]  Display the conversation (default quiet)
      /msg last                    Display the latest assistant response
      /msg pin [INDEX|MESSAGE_ID]  Pin any message; defaults to the last message
      /msg pins [short]            Show pinned messages in full, or list their first paragraphs
      /msg pinlist                 List pinned messages on one line each, with message IDs
      /msg unpin INDEX|MESSAGE_ID  Remove a message pin
      /msg edit INDEX [TEXT]       Edit in the editor, or replace text inline; preserve attachments
      /msg del INDEX               Remove a message
      /msg undo [INDEX]            Remove the last conversation message or selected message
      /msg chop                    Browse messages interactively to pin, edit, delete, or chop newer messages
      /msg trim INDEX              Keep through the selected message; remove newer messages
      /msg rewind                  Keep through the newest pinned message; remove newer messages

    Message indexes are 1-based. Negative indexes count back from the end;
    -1 selects the last message, -2 the second-to-last, and so on.
    /msg log quiet hides reasoning, tool calls, and tool outputs; verbose includes them.
    Logs show message IDs and keep their original indexes, including messages hidden in quiet mode.
    /msg log short shows the first paragraph of every message with its original
    index. 📌 marks pinned messages in logs. Pins belong to this conversation,
    persist across resumed turns and exports, and are retained during compaction.
    /msg pinlist lists each pin's ID and first paragraph; /msg unpin Tab completes pinned IDs.
    /msg edit INDEX opens the same editor as /edit chat INDEX or /edit INDEX.
    Removing a tool call or result also removes its linked tool transaction.

    /msg chop starts at the newest conversation message: n next, b previous,
    p pin/unpin, e edit in the editor, d delete, x keep through this message, q or Ctrl+C quit. Changes are saved
    immediately; slash commands leave the prompt. Chopping through an unfinished
    tool transaction also removes that transaction, as with /msg trim.
    """

  static let projectsHelp: String = """
    /projects              List every indexed working directory, recent first
    /projects open INDEX|NAME|PATH  Switch directory and load its saved conversations
    /projects info SELECTOR  Show another project's details and chat counts
    /projects rename SELECTOR NAME  Rename an indexed project
    /projects tint SELECTOR COLOR  Change a project's accent color
    /projects del SELECTOR  Remove another project from the index; keep its files

    Select by list number, name, path, or ID prefix; quote names and paths with spaces.
    Negative list numbers count from the end: -1 selects the last project, -2 the one before it.
    Disk shows space used by each project's local or central storage, like du -hs.
    A dash means the storage is missing or could not be fully read.
    Opening a new directory registers it in ~/.pmai/projects.json. /remote serve
    shares this same index by default, and Refresh in PocketMai picks up changes.
    /project shows the current project's details. /cd changes only the tools'
    working directory; /projects open also switches the chat workspace and local settings.
    """

  static let projectHelp: String = """
    Project commands (a project is the directory pmai was started in):
      /project [info]          Show the project's name, tint, directory, and chat counts
      /project list            List every project pmai has been started in, recent first
      /project name NAME       Rename the project; the directory name is the default
      /project tint COLOR      Color the prompt: a preset such as mint, or #RRGGBB; none clears it
      /project del INDEX|PATH|NAME  Drop another project from the list; its files stay

    Negative list numbers count from the end: -1 selects the last project.
    An existing .pmai directory keeps the project's chats, settings, memory,
    todo and skills locally. Otherwise they live in ~/.pmai/projects/<ID>/;
    opening a project never creates a local .pmai. --home or PMAI_HOME relocates
    central storage and the projects.json index. Create .pmai before first use
    to opt into local storage, which remains subject to git clean -xdf.
    /cd changes where tools run, not which project the chats belong to.
    """

  static let mcpCommandHelp: String = """
    MCP commands:
      /mcp list                Show configured servers and connection state (default)
      /mcp info [ID]           Show server details, tool help and call counts; all servers if omitted
      /mcp enable ID           Connect a saved server and enable it at startup
      /mcp disable ID          Disconnect a server and keep its saved configuration disabled
      /mcp del ID              Disconnect a server and delete its saved configuration
      /mcp tools ID            Show a connected server's tools and counters
      /mcp direct|proxy|hide|inherit ID[/TOOL]  Set per-agent exposure
      /mcp add COMMAND [ARG ...]
      /mcp add URL             Connect an HTTP(S) MCP endpoint
      /mcp add [--name ID] [--env KEY=VALUE] [--cwd PATH] [--timeout SECONDS]
               [--prefix PREFIX] [--approval MODE] -- COMMAND [ARG ...] | URL

    MODE is automatic, confirm, or dangerous. Quotes and backslash escapes are
    supported. Without --name, the command's basename or URL host becomes the server name.
    HTTP(S) URLs use streamable HTTP; --env and --cwd apply only to stdio commands.
    The server is connected immediately, saved in the normal mcpServers
    configuration. Its tools are available through the hybrid proxy by default;
    /tools disable mcp/ID or /tools disable PREFIX::TOOL disables them per agent.

    Examples:
      /mcp add r2mcp
      /mcp add --name weather -- npx -y weather-mcp
      /mcp add --name wordcraft -- http://127.0.0.1:9090
    """

  static let editHelp: String = """
    /edit prompt [NAME]      Edit the prompt called NAME, system or user (current agent's when omitted)
    /edit system [NAME]      Edit/create a named system prompt (current when omitted)
    /edit user NAME          Edit/create a user prompt; a builtin's name starts from its text
    /edit skill NAME         Edit/create a skill's SKILL.md (add --user for a user skill)
    /edit NAME               Edit an existing system or user prompt
    /edit agent [ID]         Edit a saved agent as JSON (alias: /agent edit [ID])
    /edit provider [ID]      Edit a configured provider as JSON (alias: /provider edit [ID])
    /edit compact            Edit the global chat-compaction prompt template
    /edit smart              Edit the per-turn smart context template (also /edit prompt smart)
    /edit prompt recap       Edit the recap template (goals, actions, pending tasks)
    /edit prompt voice       Edit instructions for the spoken conversation
    /edit prompt voiceover   Edit instructions for short spoken summaries
    /edit prompt compact     Edit the generated compact agent's system prompt
    /edit prompt tool        Edit the generated tool agent's system prompt
    /edit memory             Edit this project's durable memory notes
    /edit memory-prompt      Edit the template /memory learn uses
    /edit delegation         Edit the brief template child agents receive
    /edit worker             Edit the instructions of the derived worker agent
    /edit config             Edit the active configuration file
    /edit mcps               Edit the MCP server list as JSON (alias: /mcp edit or /mcps edit)
    /edit chat              Edit the whole conversation context; preserve originals
    /edit chat N|MESSAGE_ID  Edit a conversation message (same as /msg edit N)
    /edit N|MESSAGE_ID       Edit conversation message N or its full message ID
    /edit input              Write the next message in the editor, then review before sending
    /edit soul               Edit your core personality (lives in ~/.pmai/SOUL.md)
    /edit redact             Edit ~/.pmai/redact.txt: case-insensitive words or /regex/ rules

    The compact, smart, recap, and memory templates must contain {{transcript}}; {{focus}} and
    {{memory}} are optional. The delegation template must contain {{task}};
    {{context}}, {{output}}, {{agent}}, and {{cwd}} are optional.
    Clearing it restores the built-in default. Uses /set ui.editor when it is
    set, then $EDITOR, then $VISUAL, then vim. Agent limits and tool-calling
    strategy apply immediately, and an edited provider is rebuilt in place;
    other provider, plugin, tool, and MCP changes made through /edit config
    require a restart.

    A provider's "headers" is an object of names to values or an array of
    "Name: value" strings, sent with every request. A value may contain
    {{session}}, which becomes the session id of the chat a request belongs
    to (/chat session shows it; OpenCode Zen needs it in x-opencode-session).
    """

  static let memoryHelp: String = """
    Durable notes about you, kept in the project storage as memory.md and added to
    the system prompt of this chat — never of the subagents it starts.

      /memory                    Show the notes and how they are configured
      /memory edit               Edit them in $EDITOR (same as /edit memory)
      /memory learn [FOCUS]      Fold this chat into the notes, keeping what is known
      /memory learn --all [FOCUS]  Fold every chat in this project into them
      /memory add TEXT           Append one note
      /memory set TEXT           Replace every note
      /memory clear              Forget everything
      /memory reload             Re-read the file after editing it elsewhere
      /memory on|off             Whether the notes reach the model
      /memory scope MODE         Chats the chats_* tools may read

    MODE is none, project, or all; all crosses working directories. The tools
    are chats_list, chats_search, chats_read, and chats_read_document; enable
    them for an agent with /tools enable chats. Edit the learning prompt with
    /edit memory-prompt.
    """

  static let vdbHelp: String = """
    Index local documentation and source code for retrieval. The index is kept
    as vdb.json in the Files workspace project storage and survives restarts.

      /vdb index [PATH]       Index a file/folder (default: workspace); refresh changes
      /vdb query TEXT         Retrieve passages with source paths and line ranges
      /vdb status             Show source/chunk counts and the index path
      /vdb del PATH           Remove one indexed file/folder, preserving source files
      /vdb clear              Reset the whole index, preserving source files

    The local sparse-vector/BM25 search works offline with one or many documents.
    Reindex after editing sources. Enable the model's tool with /tools enable vdb.
    """

  static let todoHelp: String = """
    The project's todo list is stored as todo.md, a Markdown task list the
    agent plans with and ticks off through the todo_list, todo_add, and
    todo_done tools. It survives across chats, and editing the file by hand
    is fine: every command and tool call reads it afresh.

      /todo                      Show the list, numbered
      /todo add TEXT             Append one pending item
      /todo done NUMBER|TEXT     Mark an item done by number or title fragment
      /todo del NUMBER|TEXT      Drop an item by number or title fragment
      /todo sweep                Remove every completed item
      /todo edit                 Edit the list in $EDITOR
      /todo clear                Remove every item
      /todo path                 Print where the file lives

    Negative item numbers count from the end: /todo done -1 completes the last item.
    Enable the tools for an agent with /tools enable todo.
    """

  static let skillsHelp: String = """
    Skills are folders holding a SKILL.md whose front matter gives a name and
    a description and whose body is the instructions to follow: the layout
    other coding agents use, so their skills work here unchanged. pmai reads
    the skills folder in project storage and ~/.pmai/skills (or $PMAI_HOME/skills); a
    project skill shadows a home one of the same name. Each skill is also a
    skills_NAME tool the model may call to get the instructions, once it is
    enabled for the agent.

      /skills                    List skills with enabled/proxied/hidden/disabled status and calls
      /skills show NAME          Print a skill's file, tool state, and instructions
      /skills add [--user] NAME   Create a skill in the editor, including its folder and SKILL.md
      /skills add NAME "DESCRIPTION" "PROMPT"  Create without opening the editor
      /skills edit NAME          Edit SKILL.md (same as /edit skill NAME; creates new names)
      /skills import [--user] ZIP_OR_FOLDER  Import a skill with supporting files
      /skills del NAME           Delete the visible skill folder and its supporting files
      /skills enable NAME|all    Offer a skill (or every skill) to the current agent
      /skills disable NAME|all   Disable a skill (or every skill) for this agent
      /skills direct|proxy|hide|inherit NAME|all  Choose exposure or restore inheritance
      /skills prompt NAME [TEXT] Send an enabled skill's instructions, then TEXT
      /skills path               Print the directories scanned
      /skills reload             Rescan the directories (every /skills command does)

    New skills live in the project by default; --user uses your home skills.
    Editing and deleting use the visible copy; --user or --project selects a
    specific copy. Quote names and paths containing spaces. New and imported
    skills are enabled for the current agent. Imports never overwrite a skill.

    /tools enable skills is the same as /skills enable all and also picks up
    skills added later. A skill whose front matter says
    disable-model-invocation: true is never a tool. Where the body says
    $ARGUMENTS the TEXT goes there; otherwise it follows the instructions.
    """

  static let promptHelp: String = """
    Prompts. A system prompt is an agent's instructions: every agent takes
    them from one prompt in the catalog (prompts.system in the configuration),
    referenced by name in its systemPrompt field; several agents may share
    one, and editing the prompt updates all of them. A user prompt is a
    message sent by name (prompts.user), and MaiCore ships builtin ones —
    goal, newapp, tldr, followup — that a user prompt of the same name
    replaces. Skills (/skills) are sent by name the same way when their tools
    are enabled for the agent.

      /prompts                   List every prompt and skill by kind
      $NAME [TEXT]               Send prompt or skill NAME with TEXT after it: TEXT goes
                                 where $ARGUMENTS stands, or after the text. For a
                                 system prompt, switch this agent to it, then send TEXT.
                                 /prompts NAME [TEXT] is the long form.
      /prompts show NAME         Print what NAME is or sends
      /prompts add NAME TEXT     Create a user prompt from one line (set replaces it)
      /prompts edit NAME         Edit or create a user prompt in $EDITOR (/edit user NAME too)
      /prompts del NAME          Drop a user prompt (a builtin it replaced shows again)

      /prompt                    Show the current agent's system prompt
      /prompt show NAME          Print one system prompt
      /prompt add NAME TEXT      Create a system prompt from one line (set replaces it)
      /prompt edit [NAME]        Edit or create one in $EDITOR (current when omitted; /edit system NAME too)
      /prompt del NAME           Drop an unused system prompt
      /prompt use NAME           Point the current agent at a system prompt (/prompt NAME too)
      /agent prompt ID NAME      Point another saved agent at a system prompt
      /edit prompt NAME          Edit NAME, whichever kind of prompt it is

    Register an agent around a prompt in two lines:
      /prompt add reviewer You review diffs and list only real defects.
      /agent add reviewer - files,run reviewer

    Keep a message you send often as a user prompt:
      /prompts add commit Write a commit message for the staged changes: $ARGUMENTS
      $commit one line, imperative mood

    The other templates — compact, smart, recap, delegation, worker, memory — are edited
    with /edit compact, /edit smart, /edit prompt recap, /edit delegation, /edit worker,
    and /edit memory-prompt.
    """

  static let agentsHelp: String = """
    Agent definitions (/agent is an alias). A definition is a saved setup —
    provider, model, system prompt, tools, and limits — that you switch between.
    /jobs manages the processes started from these definitions.

      /agents                    List ACP, local pmai, and task definitions alphabetically
      /agents list               Same as /agents
      /agents use ID             Switch this chat to a definition
      /agents show [ID]          Show one definition in full
      /agents describe ID [TEXT] Show or set its purpose (separate from instructions)
      /agents enable|disable ID  Park a definition without deleting it
      /agents acp [list]         List external ACP agents and what is installed
      /agents acp add NAME [CMD ARG ...]  Register an ACP agent as a usable agent

    Saving and changing definitions, one line each (/agent and /agents both work):

      /agent add NAME            Copy the current agent into a new saved definition
      /agent default ID          Save the default for future chats and runs
      /agent effort ID LEVEL     Save an independent reasoning effort
      /model [PROVIDER::]MODEL  Set the chat and all task models, including side questions
      /model -chat [PROVIDER::]MODEL  Change only this agent's chat model
      /model -compact [NAME]     Assign a compaction agent or model; omit to clear
      /model -approval [NAME]    Assign a smart-approval agent or model; omit to clear
      /model -tool [NAME]        Assign a tool-decision agent or model; omit to clear
      /model -voice [NAME]       Assign the voice conversation agent or model; omit to clear
      /model -btw [NAME]         Assign a side-question agent or model; omit to clear
      /agent add NAME MODEL GROUPS PROMPT [PROVIDER [BASE_URL]]
                                 GROUPS is a,b,c (see /tools) or -; PROMPT names a system
                                 prompt (see /prompts); PROVIDER defaults to this chat's, and
                                 with BASE_URL registers a new OpenAI-compatible endpoint
      /agent tools ID GROUPS     Replace its tool groups (a,b,c), adjust them (+a,-b), or clear (-)
      /agent model ID MODEL      Change its model (- for the provider default)
      /agent prompt ID PROMPT    Point it at another named system prompt
      /agent provider ID PROVIDER  Move it to a configured provider
      /agent del ID              Drop it; subagent lists and the default agent are updated
      /agent edit [ID]           Edit a definition as JSON (alias: /edit agent [ID]; current when omitted)

    A definition's tools are its own, whatever its depth in the tree: give a
    subagent its groups the same way. Named prompts are managed with /prompt.
    /help jobs explains process control, focus, queued messages, and tree states.
    /set delegation subagent lets an agent hand tool work to a child with the
    same tools. /set limits.maxSubagents and /set limits.maxSubagentDepth bound
    the process tree.
    """

  static let toolHelp: String = """
    Tool selection commands:
      /tools on|off                  Switch all tools globally; keep individual settings
      /tools [list]                  List groups with exposure states and call counters
      /tools full                    List all groups and their tools with icons and counters
      /tools show GROUP|TOOL         Show effective states, counters, schemas, and settings
      /tools enable GROUP|TOOL       Enable using the current exposure default
      /tools direct GROUP|TOOL       Offer schemas directly
      /tools proxy GROUP|TOOL        Keep available through list-tools/call-tool
      /tools hide GROUP|TOOL         Keep callable by name; omit from schemas and list-tools
      /tools disable GROUP|TOOL      Remove from discovery and execution
      /tools inherit GROUP|TOOL      Remove an override; resume group/default behavior
      /tools set GROUP OPTION VALUE  Configure a tool group and reload its tools
      /tools unset GROUP OPTION      Restore an option's default

    Exact tool overrides win over groups and survive new tools and restarts.
    Selectors: github, github/pr, github_pr, skills/review, mcp/SERVER,
    mcp/SERVER/TOOL, or PREFIX::TOOL. Use group: or tool: to disambiguate.
    /set tool.auto off disables learned exposure. Calls persist in the home
    tool-usage.json; up to four frequently used tools join the six common ones.

    Examples:
      /tools proxy github
      /tools direct github/pr
      /tools direct github/issue
      /tools disable github/ci_log
      /tools proxy mcp
      /tools direct mcp/myserver/search
      /skills proxy all
      /skills direct review
      /tools enable github
      /tools set github githubAPIKeyEnvironment GITHUB_TOKEN
      /tools set mastodon mastodonInstance mastodon.social
      /tools set mastodon mastodonAPIKeyEnvironment MASTODON_API_KEY
      /tools set mastodon mastodonWriteEnabled on
    """

  static func printUsage() {
    print(
      """
      pmai — the Pocket Mai command-line agent

      Usage:
        pmai [options] [message]
        pmai app run --allow-exec DIRECTORY [ARGS...]

      Options:
        --acp               serve pmai as an ACP agent on stdio (for IDEs)
        --acp-root DIR      restrict ACP session directories to this workspace
        --acp-sessions DIR  directory for persistent ACP sessions (default: PMAI_HOME/acp)
        tailcat ...         pair and serve remote agents; pmai tailcat --help
        acp-gateway ...     bridge WebSocket clients to an ACP agent; pmai acp-gateway --help
        -a, --agent ID      select a configured agent
        --api-key KEY       prefer an environment variable or config reference
        --base-url URL      ad-hoc OpenAI-compatible endpoint
        --config PATH       load plugins, providers, tools, MCPs, agents, and approvals
        -E                  edit ~/.config/pmai/config.json in $EDITOR (or vim, nano, notepad) and exit
        -h, --help          show this help
        --history PATH      persist editable input history (or PMAI_HISTORY)
        --home DIR          keep the project index and shared state in DIR (or PMAI_HOME)
        --image PATH        attach an image (repeatable)
        -l, --list          list saved chats in this project and exit
        --markdown          render replies as markdown even when piped
        --max-subagents N   children an agent may run at once (default 5)
        --max-tool-calls N  tool calls allowed per agent run (default 50)
        --max-turns N       model turns allowed per agent run (default 60)
        --mcp               serve pmai as an MCP server on stdio (one prompt tool)
        --model [ID::]MODEL  override model, optionally on provider ID
        --compact-agent NAME  compaction agent or [PROVIDER::]MODEL; - inherits
        --tool-agent NAME   tool-decision agent or [PROVIDER::]MODEL; - inherits
        --effort LEVEL      override reasoning effort
        --save-defaults     save explicit model/provider/URL/agent/task choices
        --no-markdown       print replies verbatim
        --no-stream         disable response streaming
        --progress          live activity on stderr; final replies on stdout
        --plugin PATH       load a native .dylib plugin (repeatable)
        --print-config      print a complete example configuration
        --projects          list every project pmai has been started in, then exit
        --provider ID       override the selected provider
        -r, --resume [CHAT] reopen CHAT (list index, ID, or title), or the latest chat,
                            with its saved settings and the agents its runs started
        --state DIR         override this project's chat storage directory (or PMAI_STATE)
        --stdin             attach standard input as a text file (git diff | pmai --stdin "review it")
        --system TEXT       override agent instructions
        -U, --update        check for updates and install the latest release
        --vim ACTION        install, update, or uninstall the bundled Vim integration
        --vim-dir DIR       Vim runtime directory (default: ~/.vim; ~/vimfiles on Windows)
        -v, --version       print the pmai version
        --tool-approval MODE yolo, ask, or smart for this run; /set tool.approval saves the project default

      Config discovery:
        --config, PMAI_CONFIG, ./pmai.json, ~/.config/pmai/config.json

      Terminal theme:
        PMAI_THEME=default|slime|summer|ember|pink|night or a name in ~/.pmai/themes

      Ad-hoc provider defaults:
        PMAI_PROVIDER, PMAI_MODEL, PMAI_BASE_URL, and PMAI_API_KEY, or
        PMAI_API_KEY_FILE naming a file that holds the key, so the secret
        never sits in the environment
        PMAI_MODEL also accepts PROVIDER::MODEL. Configured provider URLs and
        credentials take precedence over ambient variables; explicit --base-url
        and --api-key flags override the selected connection for this run.
        Model/provider variables bootstrap installations without saved agents.
        /model and /provider use save defaults for future chats and runs;
        saved agent selections take precedence over environment defaults.

      Resuming a chat:
        Saved model/provider and agent settings take precedence over environment
        defaults. Explicit flags override only the chat being opened. The saved
        provider endpoint is used unless --base-url is given.

      Persistent REPL state:
        Chats belong to the project rooted at the current directory and are
        kept under ~/.pmai/projects/<ID>/chats unless a local .pmai directory
        already exists. ~/.pmai/projects.json lists every project and
        ~/.pmai/history.json holds input history. --home or PMAI_HOME relocates
        the central store. Existing local .pmai directories remain in use.

      Without a config file, the offline hello and OpenAI-compatible providers
      are registered as before.
      """)
  }
}
