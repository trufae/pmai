[Documentation](README.md) · [Project home](../README.md)

# Install and configure pmai

## Install

Install the **pmai CLI** on macOS, Linux, or Android:

```sh
curl -fsSL https://raw.githubusercontent.com/trufae/pmai/main/www/install.sh | sh
```

No root needed. The installer selects the release for your platform, verifies its
SHA-256 checksum, and chooses a writable install directory. Update with `pmai -U`.
Linux releases include glibc and fully static musl builds; the installer detects
musl automatically. See the [installer](../www/install.sh) for custom install paths
and version selection.

On **Windows** (PowerShell 5.1 or 7):

```powershell
irm https://raw.githubusercontent.com/trufae/pmai/main/www/install.ps1 | iex
```

The [Windows installer](../www/install.ps1) selects x64 or ARM64, verifies the
SHA-256 checksum, and installs the executable and runtime DLLs in
`%LOCALAPPDATA%\Programs\pmai` without administrator privileges. It adds that
directory to your user PATH and the current PowerShell session. Update with
`pmai -U`. Set `PMAI_INSTALL_DIR` for a custom directory or
`PMAI_VERSION` for a specific release tag.

## Choose a provider and run prompts

Run `pmai`, add your provider, and choose a model. For a local Ollama server
already running with a downloaded model:

```text
/provider add local http://127.0.0.1:11434/v1
/models local
/model local::MODEL_FROM_THE_LIST
```

The selection is saved for future runs. You can also use
[ChatGPT sign-in](#use-your-chatgpt-subscription), a remote API, or native
[Apple Intelligence and MLX providers](../MaiCore/README.md).

To use an installed, authenticated coding agent over ACP, enter either
`/agent acp add claude` or `/agent acp add opencode` inside pmai. Each command
saves and selects the agent. See [ACP setup and shell one-liners](acp.md#acp-providers-in-the-normal-prompt).
The [Claude guide](claude.md) covers installation, model selection, reasoning
effort, and disabling commit attribution.
Use `/providers` to list connections and `/provider del ID` to remove an unused
one; `/about` shows setup options and `/help provider` explains provider commands.

```sh
pmai "explain this project"
pmai --progress "review this project" > review.md
git diff | pmai --stdin "review this change"
pmai --vim install
```

Use `--progress` for live model-turn, tool, and message feedback on stderr while
stdout contains only the final reply. It also works in the REPL and with redirected output.

In Vim, select lines and press `m` to choose a prompt, review the reply, and apply
it. Use `pmai --vim update` to refresh the integration or `pmai --vim uninstall`
to remove it. In the REPL, try `/projects` and `/help`.

## Project storage

Project data uses an existing `.pmai` directory when present. Otherwise chats,
settings, memory, todos, skills, and the vector index live under
`~/.pmai/projects/<project-id>/`, outside the checkout so `git clean -xdf` cannot
remove them. `--home DIR` or `PMAI_HOME` relocates the central store; for example,
`PMAI_HOME=~/.config/pmai` uses `~/.config/pmai/projects/`. Create `.pmai` before
first opening a project to choose local storage. Existing local data stays in
place and is still vulnerable to repository cleanup; it is not migrated automatically.

## Tool display

Consecutive tool calls in iOS start collapsed into one tappable row with the call
count and elapsed wall time. Expand the row to access the usual individual calls.
Old chats without recorded timings show “time unavailable”.

In the CLI, `/set ui.toolgroups on` enables the same clickable summaries and
switches to buffer mode. `/set ui.toolgroups off` restores individual rows;
`/set ui.tools` still controls their result previews. The status bar shows the
current prompt's elapsed time at the right, including time spent awaiting approval.

Use `/set ui.toolcalls first` to read the complete first line of tool arguments,
wrapped to the terminal width, or `/set ui.toolcalls 5` to show the first five
source lines of each argument (including heredoc scripts). Hidden lines are
counted after the preview. `/set ui.toolcalls truncate` restores the default
single-row previews clipped to the available terminal columns. Resizing the
terminal updates existing previews in buffer mode. This setting is saved;
`ui.tools` controls result visibility separately, and `ui.tools icons` keeps calls
as icons.

`/tools` lists groups in an aligned table with shared mode and call-count columns;
`/tools full` adds each group's individual tools. Terminal Markdown tables are
frameless by default to save space. Use `/set ui.tableborders on` to draw frames
and separators, or `off` to remove them. This applies to command output and
replies, including existing tables in buffer mode.

## Use your ChatGPT subscription

In iOS Settings → Providers, add a provider, choose **ChatGPT subscription** in
the API picker, then tap **Continue with ChatGPT**. Select an available model
after signing in. Add separate providers for different accounts or workspaces.

In the pmai CLI REPL:

```text
/provider add chatgpt --kind chatgpt
/provider login chatgpt
/models chatgpt
/model chatgpt::MODEL_FROM_THE_LIST
```

The provider kind is `chatgpt`. API-key connections use `openai`; existing JSON
using `openAICompatible` still loads and is saved with the new name.
Eligible requests use your ChatGPT plan through
the Responses API; no API key or Codex CLI is needed. Plan limits and account
eligibility apply. [Manage usage](https://chatgpt.com/settings/usage).
Use `/provider status chatgpt` to inspect the account and `/provider logout chatgpt`
to sign out. Credentials stay in the iOS device's Keychain or owner-only files
under `$PMAI_HOME/chatgpt` (`~/.pmai/chatgpt` by default); provider exports do not
include them. Sign in independently on each device. This provider supports text,
images, files, and pmai tools; audio and hosted Responses tools are unavailable.
