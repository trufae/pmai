# Providers, agents, and task defaults

pmai and PocketMai use three concepts:

- A **provider** is a reusable connection: backend, base URL, credentials, headers, and timeout. Many agents can share it.
- An **agent** chooses a provider, model, system prompt, reasoning effort, and tool format. It also owns the permissions used when it runs as a conversation agent.
- A **task assignment** points compaction, tool decisions, or tool approval at a saved agent. An empty assignment uses the current conversation agent. Assignments are installation defaults, independent of which chat is open.

The default conversation agent is selected separately. Changing a task assignment does not switch the conversation's main model.

## CLI workflow

Add connections once, then refer to them by ID. OpenAI-compatible local servers do not need a key:

```text
/provider add local http://127.0.0.1:11434/v1
/provider add remote https://your-server.example/v1 --api-key-file ~/.config/pmai/key
/models local
```

Use `/edit provider ID` for credentials, headers, backend options, or connection changes. `/baseurl URL` changes the current provider's connection and saves it; other agents sharing that provider use the same connection.

Create an agent by copying the current one, then edit the fields you need:

```text
/agent add fast
/agent model fast local::qwen3:8b
/agent effort fast off
/prompt add tool-decisions Choose tools efficiently and preserve the facts needed to answer.
/agent prompt fast tool-decisions
/agent tools fast -
/model-tool fast
/model-compact fast
```

The existing `/agent add NAME MODEL GROUPS PROMPT [PROVIDER [BASE_URL]]` form still works. `/edit agent fast` exposes the complete definition, including tool format and generation options. Assigning an agent to a task borrows its inference settings; its own tool list can be empty.

For a quick alternative model, these create or update ordinary task agents, which can then be edited with `/agent effort`, `/agent prompt`, or `/edit agent`:

```text
/model-compact local::qwen3:8b
/model-tool local::qwen3:8b
```

A selector first matches a saved agent ID. Otherwise it names a model: `PROVIDER::MODEL` chooses both, and a bare model uses the current provider. The separator is deliberately `::`, so model IDs containing `/` or a single `:` keep their meaning.

```text
/model                     # show main model and all task assignments
/model-compact            # clear the compaction assignment
/model-tool               # clear the tool assignment
/model-aproval            # clear the approval assignment
/model-tool -             # also clears; "default" does the same
/model remote::large-model # set chat, compaction, tool decisions, and approval to this model
/model-chat local::qwen3:8b # change only this conversation agent's provider and model
/agent default main        # save the agent used for future chats and runs
/agent use fast            # switch this chat to fast; existing command clears its history
```

Slash commands save to the active configuration: `--config PATH`, a local `pmai.json`, or the default pmai configuration. No environment variables are needed to keep these choices.

`/model MODEL` selects the model for chat and every task, replacing any task assignments with model-specific task agents. `/model-chat MODEL` keeps the task assignments unchanged. Both accept `PROVIDER::MODEL` or a bare model on the current provider; without a model they show the current selections. Use the individual task commands to override or clear one assignment afterward.

For one invocation:

```sh
pmai --provider local --base-url http://127.0.0.1:11434/v1 --model qwen3:8b --effort low
pmai --model remote::large-model --tool-agent fast --compact-agent fast
pmai --tool-agent - --compact-agent -
```

`--tool-model` and `--compact-model` are aliases for the corresponding agent selectors. Add `--save-defaults` to persist the selected primary agent, provider/model, explicit base URL, effort, and task assignments. Otherwise command-line overrides are temporary for an existing configuration. The first launch still creates the initial configuration as before. API keys supplied with `--api-key` remain invocation overrides; use the provider's `apiKeyFile`, `apiKeyEnvironment`, or `apiKey` settings for persistent credentials.

For a new chat, model and connection precedence is explicit flags, environment overrides, saved agent/provider settings, then built-in defaults. `pmai -r` restores the chat's saved agent settings, including provider/model, reasoning, instructions, limits, and tools; only explicit flags override them, and only for the selected chat. Its endpoint comes from the saved provider unless `--base-url` is given. Credentials still resolve from the current configuration/environment. `/chat use` also restores the selected chat's settings. `--save-defaults` on resume saves the restored profile with any explicit overrides.

Task assignments use explicit task flags, then saved assignments, then the current conversation agent. A task assignment to a named agent uses that agent's own model and effort; it does not inherit the primary model's command-line overrides.

## iOS workflow

1. In **Settings → Providers**, add a local or remote connection and configure its URL and authentication. Apple and MLX are available as on-device providers.
2. In **Settings → Manage Agents**, add an agent; its editor opens without changing the default agent. Use its Edit button to select its provider connection, model, system prompt, reasoning effort, and tool format. Select it in the list to configure its tools and other advanced settings. Selecting an agent also makes it the default for new chats.
3. Under **Task agents** in Manage Agents, choose **Compaction**, **Tool decisions**, and **Tool approval** independently. Select **Current conversation agent** to clear an assignment.

Changes save automatically and survive restarting the app. Task choices do not change when you select another main agent. Removing an assigned agent clears its task assignments. Native provider/settings backups include the agent definitions and task defaults.

Remote agents can share a provider while using different models. An empty model override retains the provider's default model for compatibility with existing settings. Connection URLs and credentials belong to the shared provider; editing one affects every agent using it.

## Runtime behavior

Compaction sends the compaction template and selected transcript to the assigned agent with its prompt and reasoning settings, with tools disabled. Both manual and automatic compaction use the assignment. A failed summary leaves the existing conversation intact. With no assignment, the current model and reasoning settings are used.

`/set ctx.context=smart` also uses the compact assignment, with a separate
`prompts.smart` template (`/edit smart`). Before each conversation turn it selects
task-relevant context from the full transcript, including complete tool outputs,
and sends one working-context message alongside the original system/developer
instructions. The saved transcript keeps growing and still autocompacts normally.
Preparation calls count toward token/time budgets and usage statistics.

`/set ctx.strategy tools` uses the compact assignment to summarize only large
tool results (at least 4,000 characters), after a conversation model has seen
them in full. New results, errors, binary attachments, user messages, assistant
prose, and tool-call arguments stay intact. Each result is summarized once per
run and reused in subsequent model calls; the full output stays in the saved
transcript. A changed user request invalidates the summaries, and edited results
must be read again before summarization. Failed or oversized summaries keep the
original output. This mode replaces automatic whole-transcript compaction with
tool-result reduction; manual `/chat compact` and context tools remain available.
Summary calls count toward token/time budgets and usage statistics.

During a run, the REPL status line shows the live model context instead of the
chat history saved at the previous turn. Its message and estimated token counts
grow as tool output arrives and shrink when the model context is reduced.

Interactive autocompaction asks before replacing history, including when `tool.aproval` is `yolo`. In the pmai REPL, choose `y` to compact, `n` to continue without compaction for the current response, `m` for model-change instructions, `x` to clear the chat, or `c` to stop with the transcript kept. While the decision is pending, `/model NAME` changes all models, `/model-chat NAME` changes only the conversation model, and `/model-compact NAME` changes the summarizer; then choose `y` or `n`. `/set ctx.compact 0` disables future automatic compaction. Piped and other noninteractive runs keep the configured automatic behavior.

PocketMai shows the same decision before its MLX autocompaction. The prompt includes the chat's model settings, a compaction-agent picker, continue and stop actions, and a confirmed clear-chat action. Skipping applies to the current response; a later message may prompt again. In `/visual`, the compaction dialog also offers stopping to change models before continuing.

When tools are available, the tool agent handles successive tool decisions using its own tool format. Actual execution retains the conversation's allowed tools, approvals, delegation rules, and budgets. When the specialist stops calling tools, the primary agent receives the results and the permitted tool schemas. It can complete unfinished work with further tool calls before writing the final answer; these calls stay with the primary and share the same permissions and budgets. A primary without native tool support uses the text protocol at this handoff. The specialist's draft final text is not shown as the answer. A request without tools goes straight to the primary agent. A run with no tool assignment keeps the original single-model loop.

Task agents are inference profiles, not recursive child agents. Their own task assignments or tool grants are not followed. Calls retain the chat session ID, and usage is attributed to the provider/model that performed each call. CLI run limits count specialist and final-answer turns together, so a low turn limit can pause before final synthesis.

Compaction and tool-decision provider failures do not switch to the main model. The normal error/retry behavior applies. Invalid CLI agent references or disabled task agents fail validation; deletion clears assignments explicitly. Legacy settings without task assignments continue to use their current agent.

Routing is independent of tool-call serialization. Native, Text, XML, and JSON work with the selected chat model.

## Configuration

The shared configuration keeps references rather than copying a second provider/model schema into every task:

```json
{
  "version": 1,
  "defaultAgent": "main",
  "taskAgents": { "compact": "fast", "tool": "fast" },
  "providers": [
    { "id": "remote", "kind": "openAICompatible", "baseURL": "https://your-server.example/v1", "apiKeyFile": "~/.config/pmai/key" },
    { "id": "local", "kind": "openAICompatible", "baseURL": "http://127.0.0.1:11434/v1" }
  ],
  "agents": [
    { "id": "main", "provider": "remote", "model": "large-model", "instructions": "Help the user.", "options": { "reasoningEffort": "high" } },
    { "id": "fast", "provider": "local", "model": "qwen3:8b", "instructions": "Work concisely and preserve relevant facts.", "options": { "reasoningEffort": "disabled" }, "toolCallingStrategy": "json" }
  ]
}
```

Omit a task key or set it to `null` to inherit. Existing configuration version 1 files remain valid. PocketMai stores the same assignment structure using its agents' stable UUIDs.

## System One decision models

System One uses a separate `systemone` provider kind for Ollama's `/v1/systemone` endpoint. Ollama 0.35 or later supports local Tev and Nimble decision models. See [Ollama's Tev documentation](https://ollama.com/library/tev1).

Keep a regular chat model selected with `/model-chat`, then configure routing:

```text
/provider add decisions http://127.0.0.1:11434 --kind systemone
/models decisions
/model-tool decisions::tev1:latest
/set tool.systemone true
```

`tool.systemone` defaults to `false` and is saved with the conversation agent. `/set tool.systemone` displays it. To restore ordinary tool calling, set it to `false` and clear `/model-tool` or assign a regular chat specialist.

`/models decisions` and completion suggestions only list local GGUF models declaring the `decision` capability, including renamed models. Catalogs without capability metadata are checked through `/api/show`. A non-Ollama service with only `/v1/models` uses a conservative Tev/Nimble/Jev name filter; explicit model IDs remain usable.

System One classifies supplied choices; it does not generate arbitrary argument text. It chooses one enabled concrete tool or `none`; the primary chat model receives only that tool's schema and fills its parameters. `none` sends the primary model a turn with no tools to answer. Tool validation, approvals, execution limits, retries, and cancellation remain in place. Catalogs above 23 tools use successive choice rounds. The short decision context retains the latest user request and recent activity. Routing bypasses the proxy catalog while enabled, and adds a decision inference before each argument-generation turn; actual latency depends on both models and catalog size.

On iOS, add a connection in **Settings → Providers**, choose **API → System One (TEV / JEV)**, set its Ollama URL, and refresh models. In **Manage Agents**, configure a tool-decision agent with that connection and a filtered model selection, then assign it under **Tool decisions**. Enable **System One tool decisions** on the conversation agent. Keep the conversation agent on a chat provider for arguments and final answers. Provider backups preserve the API kind and agent backups preserve the routing toggle.

## Tool approval

Tool selection and approval are independent. `/set tool.aproval` shows the mode;
`/set tool.aproval yolo|ask|smart` saves it for the current project. The default
`yolo` runs every tool without a prompt. `ask` prompts before every call, including
read-only and proxy catalog tools, and permits editing the arguments. `smart`
reviews each concrete tool and its arguments before execution:

```text
/model-aproval decisions::tev1:latest
/set tool.aproval smart
```

This uses System One's `questions.harm` with type `noul`. A finite probability
below 0.5 allows the call; 0.5 or above blocks it. An unavailable endpoint or
unsupported model falls back to the conversation's chat model. To use a regular
model directly, run `/model-aproval local::qwen3:8b`; to use the current model,
clear the assignment with `/model-aproval -`. These choices work independently
of `tool.systemone` and `/model-tool`.

Regular reviewers receive a tools-disabled prompt requesting exactly
`{"decision":"allow|block","reason":"..."}`. The state includes the tool and its
arguments, the latest user task, working directory, valid paths, and tool-specific
sandbox information. Harmful, uncertain, out-of-scope, and sandbox-bypassing
calls are to be blocked. An invalid answer or review failure blocks execution;
a block verdict never triggers fallback. Reviews cannot change arguments or
expand the host's permissions. Model review does not provide OS isolation.
CLI review calls count towards run budgets and usage.

The shared CLI configuration stores `approvals.mode` and
`taskAgents.approval`. `--tool-aproval MODE` overrides the mode for one run. Old
`yolo` booleans migrate on load (`true` → `yolo`, `false` → `ask`); they are no
longer written or exposed as settings or command-line flags.

On iOS, choose **Tool approval → smart** in the conversation agent's tool
settings. Create an approval agent using either a regular provider or a System
One connection, then select it under **Manage Agents → Task agents → Tool
approval**. Each agent keeps its approval mode, and backups retain both the mode
and reviewer assignment. The `ask` mode displays the editable approval dialog
for every call. Existing settings with approval prompts enabled migrate to `ask`.
