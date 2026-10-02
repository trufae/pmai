# pmai coding-workflow benchmark

Sample coding tasks that pmai should solve, plus a harness that records every
model call so the runs can be studied for wasted turns and tokens.

Session persistence regression checks use temporary projects and configurations:

    swift build --package-path MaiCore --product pmai
    python3 test/repl-resume-smoke.py MaiCore/.build/debug/pmai
    python3 test/repl-resume-state-smoke.py MaiCore/.build/debug/pmai
    python3 test/repl-resume-routing-smoke.py MaiCore/.build/debug/pmai

The state check covers provider/task snapshots, removed definitions, chat
switching, and saved subagent trees. The routing check starts a local mock HTTP
provider and verifies actual requests, credential rotation, one-shot history,
and recovery after terminating a process during nested work.

## Layout

- `cases/<NN-name>/` — one workflow each: `prompt.txt` (the user message),
  `fixture/` (the project files), optional `setup.sh` (runs in the working
  directory before pmai, e.g. `git init`), optional `check.sh` (exit 0 when the
  task was solved; gets `FIXTURE`, `STDOUT`, `WORK` in the environment).
- `bench/proxy.py` — logging forward proxy for OpenAI-compatible endpoints.
  Every request body and the assembled response (streamed or not) become one
  JSON line: messages, tool schemas, tool calls, usage, timings.
- `bench/run.py` — runs the cases through pmai behind the proxy.
- `bench/clients.py` — runs the same cases through opencode 2, Codex, or Claude Code.
- `bench/analyze.py` — summary table and per-call timelines of a run.
- `results/<run-id>/<case>/` — `work/` (the directory after the run),
  `proxy.jsonl`, `stdout.txt`, `stderr.txt`, `meta.json`, `pmai.json`.

## Running

The offline theme smoke test checks built-ins, custom scripts, saving, startup
overrides, and invalid input without changing your configuration:

    python3 test/repl-theme-smoke.py MaiCore/.build/debug/pmai

The color smoke test uses a local mock provider and a PTY to check tool and diff
colors, diagnostics, live updates, TAB selection, and color-disabled output:

    python3 test/repl-colors-smoke.py MaiCore/.build/debug/pmai

The recap integration smoke test uses a local mock provider and isolated chat
state to check model routing, prompt edits, and history preservation:

    python3 test/repl-recap-smoke.py MaiCore/.build/debug/pmai

The smart-context smoke test checks `ctx.context=smart`, the compact-model
assignment, prompt editing, and saved history across resumed turns:

    python3 test/repl-smart-context-smoke.py MaiCore/.build/debug/pmai

The endpoint and key come from `UPSTREAM` / `UPSTREAM_KEY`, or from
`env-ollamacloud.sh` at the repository root. pmai must be built first:

    (cd MaiCore && swift build --product pmai)
    python3 test/bench/run.py                       # native tools, inline
    python3 test/bench/run.py --strategy text       # text / xml / json protocols
    python3 test/bench/run.py --variant proxy       # list-tools / call-tool
    python3 test/bench/run.py --variant subagent    # toolDelegation: subagent
    python3 test/bench/run.py --model gpt-oss:120b 02-fix-failing-test
    python3 test/bench/analyze.py test/results/<run-id>
    python3 test/bench/analyze.py test/results/<run-id> --detail 04-rename-symbol

Each run isolates `PMAI_HOME`, the chat state and the config, and unsets the
`PMAI_*` variables so the shell's provider never leaks in. The agent uses the
default instructions from MaiCore
and the `files`, `run` and `todo` groups; `--system FILE` replaces the
instructions to compare prompts.

To compare installed opencode 2 using its built-in build agent, native tools,
isolated configuration/state, and the same logging proxy and fixture checks:

    python3 test/bench/clients.py --client opencode --model qwen38 \
      --upstream http://192.168.1.60:8000/v1 \
      --run-id opencode2-qwen38 --timeout 180 \
      02-fix-failing-test 11-multi-step
    python3 test/bench/analyze.py test/results/opencode2-qwen38

The opencode runner uses a private server, caps the build agent at 40 steps,
and disables delegation and interactive questions. It clears inherited
directory hints and sends the prompt through stdin, because the CLI prefers
`PWD` over its process working directory and quotes positional message arguments.
Existing run directories are never overwritten. Provider configuration follows
the [opencode 2 provider schema](https://opencode.ai/v2/docs/providers).

The same runner supports Codex and Claude Code against a server exposing native
Responses and Anthropic Messages endpoints:

    python3 test/bench/clients.py --client codex --model qwen38 \
      --upstream http://192.168.1.60:8000/v1 --run-id codex-qwen38 \
      02-fix-failing-test 11-multi-step
    python3 test/bench/clients.py --client claude --model qwen38 --effort xhigh \
      --upstream http://192.168.1.60:8000/v1 --run-id claude-qwen38 \
      02-fix-failing-test 11-multi-step

Codex ignores user configuration/rules, disables local skills, plugins and
delegation, and uses an ephemeral session with the workspace-write sandbox.
Its normal home location is preserved. Claude uses safe mode, isolated state,
explicit file/shell tools and disabled skills/MCP configuration. `--bare` is an
optional Claude variant with a much smaller prompt and tool set. Neither client
receives a replacement system prompt. The proxy forwards each API unchanged;
only the recorded response and offline history analysis are normalized.
Catalog and token-count requests are retained in logs but excluded from model
generation counts. Input-token totals include cache reads once, not twice.

The local Qwen server rejects Claude's default `high` effort. `--effort xhigh`
selects the server's supported default explicitly; other clients leave it unset.
Provider setup follows the [Codex custom-provider documentation](https://learn.chatgpt.com/docs/config-file/config-advanced#custom-model-providers)
and [Claude gateway configuration](https://code.claude.com/docs/en/llm-gateway-connect).
Offline accounting checks run with:

    python3 -m unittest discover -s test/bench -p test_proxy.py

## Cases

| case | workflow | tools it should need |
|---|---|---|
| 01-explain | explain a small package, list public symbols | list/read or grep |
| 02-fix-failing-test | run unit tests, fix two arithmetic bugs | run, read, patch |
| 03-add-flag | add `--json` to an argparse script and document it | read, patch ×2 |
| 04-rename-symbol | rename a function across code, tests, docs | grep, patch ×6, run |
| 05-write-tests | write a unittest file for a module, run it | read, write, run |
| 06-c-build-fix | make fails: missing includes and an unused variable | run, read, patch |
| 07-find-usage | where is a function defined and called | grep |
| 08-commit-message | describe uncommitted changes, do not commit | run (git) |
| 09-loc-stats | lines per extension as a table | run |
| 10-readme | write a README for a JS package | read ×3, write |
| 11-multi-step | three edits in one file, then verify | read, patch ×3, run |
| 12-config-edit | change one key, add one key in a JSON file | read, patch |
| 13-big-log | count and rank errors in a 4000-line log | run (grep/sort), never a full read |

The findings and the todo list live in `PLAN.md` next to this file.

## Qwen38 prompt smoke comparison, 2026-10-01

Two fixtures (`02-fix-failing-test`, `11-multi-step`) were run once each against
the user's vLLM `qwen38` endpoint, with native tools, inline execution, and cache
context. Both runs used the updated runtime. Only the system prompt changed:
the earlier one-sentence prompt versus `SystemPrompt.defaultInstructions`.

| Combined result | Earlier prompt | New default |
|---|---:|---:|
| Fixture checks passed | 2/2 | 2/2 |
| Model calls | 9 | 10 |
| Tool calls | 13 | 10 |
| Input tokens, summed across calls | 35.6k | 39.9k |
| Completion tokens | 2,005 | 1,213 |
| Elapsed time | 72.7s | 48.3s |

The shorter completions and fewer tool calls suggest better focus on these
fixtures; the extra model turn increased input tokens. This is a smoke check,
not a statistically reliable performance comparison or a test of long-context
compaction. Logs from this local run are in
`test/results/20261001-qwen38-{old,new}-prompt/` (ignored by Git).

The implementation was informed by opencode's recent-tail compaction,
malformed-call feedback, and repetition guards in `src/session/compaction.ts`,
`src/session/llm.ts`, and `src/session/processor.ts` under the local
`opencode/packages/opencode` checkout. MaiCore keeps its existing configurable
tool protocols and context modes; the changes share their runtime policy.

## Qwen38 opencode 2 and old/new pmai comparison, 2026-10-01

The same two prompts and fixture checks were run with installed opencode
**v2.0.21** and a freshly built pre-change pmai from **fe1e310**. The new-pmai
measurements above are reused, so each client has one measured run per fixture.
The old binary uses its original one-sentence instructions explicitly via
`--system`; the new binary uses `SystemPrompt.defaultInstructions`. This is an
actual old/new runtime comparison, separate from the prompt-only control above.

All used `qwen38` at `http://192.168.1.60:8000/v1`, native tool calling,
no subagents, fresh fixture copies and configuration, and a 180-second timeout.
pmai used inline execution with cache context and its files/run/todo tools;
opencode used its built-in build agent and tools. Both had a 40-model-turn cap;
pmai also had a 40-tool-call cap. No run approached these limits.
The clients retained their prompts and tool schemas. Neither request specified
temperature or a seed; opencode specified a 32,768-token completion limit,
while pmai left the limit to the server. Every recorded request succeeded.

| Task | Client | Check | Model calls | Tool calls | Input tokens (sum) | Completion tokens | Time |
|---|---|---|---:|---:|---:|---:|---:|
| Fix failing tests | opencode 2.0.21 | PASS | 6 | 7 | 28,858 | 1,381 | 40.3s |
| Fix failing tests | Old pmai, fe1e310 | PASS | 6 | 7 | 24,464 | 1,166 | 35.0s |
| Fix failing tests | New pmai | PASS | 6 | 7 | 25,233 | 588 | 25.3s |
| Three edits and verify | opencode 2.0.21 | PASS | 4 | 6 | 19,084 | 2,334 | 74.4s |
| Three edits and verify | Old pmai, fe1e310 | PASS | 4 | 3 | 15,617 | 1,653 | 61.0s |
| Three edits and verify | New pmai | PASS | 4 | 3 | 14,634 | 625 | 23.0s |

| Combined result | opencode 2.0.21 | Old pmai | New pmai |
|---|---:|---:|---:|
| Fixture checks passed | 2/2 | 2/2 | 2/2 |
| Model calls | 10 | 10 | 10 |
| Tool calls | 13 | 10 | 10 |
| Input tokens, summed across calls | 47,942 | 40,081 | 39,867 |
| Completion tokens, including reasoning | 3,715 | 2,819 | 1,213 |
| Elapsed time | 114.7s | 96.0s | 48.3s |

For completeness, the earlier **new runtime with old prompt** control passed
both tasks: failing-tests used 5 model calls, 8 tools, 20,634 input tokens,
954 completion tokens, and 33.8s; multi-step used 4 calls, 5 tools, 15,005
input tokens, 1,051 completion tokens, and 38.9s. These are the earlier
35.6k-input/72.7s figures, not the old-binary results.

Counts and tokens come from the same unmodified forwarding proxy and analyzer.
Input tokens sum all requests, including repeated context; completion tokens
include reasoning. Tool calls count model-emitted native calls, not subprocesses.
Elapsed time includes CLI startup, tool execution and model generation, excluding
the post-run checker. The failing-test check also verifies the tests were not
modified. There were no tool errors. Exact repeated calls in these runs were
verification (rerunning tests or rereading the changed file), not stuck loops.

In the failing-test request, opencode's full system message was 6,451 characters
(including environment and Code Mode catalog), versus 1,002 for new pmai and
51 for old pmai. Its serialized tool schemas were smaller: 7,485 versus 11,346
characters. Prompt length alone therefore does not explain total input tokens.
New pmai generated less output in these runs. One sample per small fixture
cannot establish a reliable speedup, general completion rate, or improvement
in long-context management; no fixture triggered compaction.

Raw requests, responses, checks and modified fixtures are under these ignored
local result directories:

- `test/results/20261001-opencode2-qwen38-isolated/`
- `test/results/20261001-qwen38-old-runtime/` (includes binary provenance/hash)
- `test/results/20261001-qwen38-new-prompt/`
- `test/results/20261001-qwen38-old-prompt/` (prompt-only control)

Two setup attempts are retained as diagnostics and excluded from the comparison:
`20261001-opencode2-qwen38` rejected the provider configuration before any model
request; `20261001-opencode2-qwen38-native` inherited the parent `PWD`, selected
the repository instead of the fixture, and was stopped. The successful runner
fixes both setup issues and its captured requests confirm exact user prompts
and fixture working directories.

## Codex and Claude Code extension, 2026-10-01

Both installed clients were tested on the same two fixtures, prompts and Qwen38
server, using native Responses (Codex) and Messages (Claude) APIs. These are
**Qwen38-driven CLI benchmarks**, not measurements of OpenAI or Anthropic models.
The earlier pmai and opencode measurements are reused unchanged.

| Client | Passed | Model calls | Tool calls | Input tokens (sum) | Completion tokens | Time |
|---|---:|---:|---:|---:|---:|---:|
| opencode 2.0.21 | 2/2 | 10 | 13 | 47,942 | 3,715 | 114.7s |
| Old pmai (fe1e310) | 2/2 | 10 | 10 | 40,081 | 2,819 | 96.0s |
| New pmai | 2/2 | 10 | 10 | 39,867 | 1,213 | 48.3s |
| Codex 0.159.3 | 2/2 | 12 | 12 | 99,006 | 6,147 | 207.6s |
| Claude Code 2.1.283 | 2/2 | 11 | 11 | 58,385 | 2,794 | 94.1s |

| Task | Client | Check | Model calls | Tool calls | Input tokens (sum) | Completion tokens | Time |
|---|---|---|---:|---:|---:|---:|---:|
| 02-fix-failing-test | Codex 0.159.3 | PASS | 7 | 8 | 56,907 | 1,570 | 51.8s |
| 11-multi-step | Codex 0.159.3 | PASS | 5 | 4 | 42,099 | 4,577 | 155.8s |
| 02-fix-failing-test | Claude Code 2.1.283 | PASS | 5 | 6 | 27,037 | 1,082 | 35.5s |
| 11-multi-step | Claude Code 2.1.283 | PASS | 6 | 5 | 31,348 | 1,712 | 58.6s |

Codex used its built-in prompt with local skills disabled. Claude used its
regular built-in prompt in safe mode with six file/shell tools, no custom
instructions, and `xhigh` effort. All runs finished within the same 180-second
limit. Claude had a 40-turn cap; Codex was bounded by wall time. No subagents
were used. Proxy totals agree exactly with each client's final usage event.
Claude marks the intentionally failing initial unit-test command as a tool
error; the final tests pass and their source remains unchanged.

Codex's multi-step run spent 129.1s in one model request, producing 3,906 output
tokens, including 3,712 reasoning tokens. This single long generation dominates
its result. These are single samples, without fixed seeds or controlled cache
warmup, and do not establish a general ranking or isolate the cause of the
latency differences. No compaction was triggered.

Additional completed variants are retained, rather than selected into the main
table based on speed:

| Task | Variant | Check | Model calls | Tool calls | Input tokens (sum) | Completion tokens | Time |
|---|---|---|---:|---:|---:|---:|---:|
| 02-fix-failing-test | Codex with local skill catalog | PASS | 6 | 5 | 50,077 | 1,261 | 42.0s |
| 11-multi-step | Codex with local skill catalog | PASS | 4 | 3 | 31,454 | 1,212 | 40.1s |
| 02-fix-failing-test | Claude Code --bare, xhigh | PASS | 5 | 6 | 12,496 | 1,109 | 32.8s |
| 11-multi-step | Claude Code --bare, xhigh | PASS | 7 | 6 | 18,216 | 1,838 | 53.3s |

The initial Codex run still included the machine's skill catalog despite
ignoring user configuration. Its combined result was 81,531 input tokens,
2,473 completion tokens and 82.1s. Explicitly disabling those skills produced
the clean run in the main table; the samples cannot attribute the timing change
to that setting. Claude's `--bare` variant used only Bash/Edit/Read and a much
shorter prompt; it totaled 30,712 input tokens, 2,947 completion tokens and 86.1s.

The initial Claude default-effort attempt returned HTTP 400 for each fixture:
`Unexpected reasoning effort high. Supported types are xhigh (default), medium,
and low.` Both attempts generated zero tokens and changed no fixture files;
they are compatibility failures, excluded from task-performance totals.
Codex also logged model-catalog decoding warnings for `/v1/models`; its actual
Responses requests all succeeded. Catalog requests are not counted as model
turns. The two tiny endpoint probes were connectivity checks, not fixture runs.

Raw logs and checks are in these ignored directories:

- `test/results/20261001-codex-qwen38-clean/` — main Codex results
- `test/results/20261001-claude-qwen38-full/` — main Claude results
- `test/results/20261001-codex-qwen38/` — local skill catalog present
- `test/results/20261001-claude-qwen38-xhigh/` — minimal `--bare` variant
- `test/results/20261001-claude-qwen38/` — rejected default effort
