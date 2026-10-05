# The tool proxy: what it saves and what it costs

`useToolProxy` defaults to hybrid exposure: common tools keep their schemas,
while other enabled tools are available through `list-tools` and `call-tool`.
`proxyExposedTools: []` selects the pure proxy described in the early study
below. This note explains the mechanism,
the token arithmetic behind it, what the `test/` benchmark measured on
`gemma4:31b`, the bugs that measurement found, and when the mode pays off.
`MaiCore/README.md` documents the setting; `doc/agents.md` covers subagents,
the other way MaiCore keeps a transcript small.

## Mechanism

Without the proxy, every request carries the JSON schema of every enabled tool.
The standard coding set (`files`, `run`, `todo`) is 17 tools and about 8.9k
characters, roughly 2.2k tokens, after the catalog cut recorded in `test/PLAN.md`
(it was 23 tools and 16k characters before), and it is resent on every model
turn of every run because the schemas live outside the conversation.

With the proxy, the request carries only the two proxy schemas, which now end
with the names of the enabled tools (about 340 tokens for the standard set). The model calls `list-tools keywords=…` to learn what exists and how
to call it, then `call-tool name=… arguments={…}`. The runtime resolves the
concrete tool (`ToolProxy.resolveCall`) and runs it exactly as if it had been
called directly; approval rules, the identical-call guard and the tool budget
all apply to the resolved call.

The difference is where the description lives. Native schemas are a fixed cost
per call and never enter the transcript. A `list-tools` result is a tool
message: it enters the transcript once and is then resent on every later turn
of the run, like any other message. So the proxy trades a per-call cost for a
one-time cost that becomes context debt.

## Arithmetic

Let `S` be the schema tokens per call, `L` the tokens of the listings the model
asks for, `N` the number of model turns in a run. Native mode pays `S × N`. The
proxy pays roughly `L × (N − k)` where `k` is the turn on which the listing was
requested, plus the extra turns spent on `list-tools` itself.

With `S ≈ 2.2k` (it was 3.7k before the catalog cut), a run of 7 turns pays
about 15k tokens for schemas. The proxy wins as long as the listings it pulls
into the transcript stay well below the schema size and cost few extra turns.
It loses when `list-tools` returns most of the catalog: before the fix below, a
search for `read file list files` returned 10.9k characters (about 2.7k
tokens), nearly the whole native schema set, which then stayed in the
transcript for the rest of the run. And the smaller the native catalog gets,
the less there is for the proxy to save.

## What the benchmark measured

Thirteen coding tasks, `gemma4:31b` on Ollama cloud. The first table is the
initial study, before any fix, on the old 23-tool catalog; the second is the
same benchmark on the current build (17-tool catalog, every fix in `test/PLAN.md`
applied), two runs per mode so the run-to-run noise is visible.

| initial study (23 tools) | solved | model calls | prompt tokens | first-call prompt |
|---|---|---|---|---|
| native schemas, before fixes | 11/13 | 84 | 402k | 3,756 |
| proxy, before fixes | 4/13 | 49 | 107k | 219 |

| current build (17 tools), two runs each | solved | model calls | prompt tokens | completion tokens | median call latency | tool errors |
|---|---|---|---|---|---|---|
| native schemas | 12/13, 13/13 | 79, 76 | 215k, 206k | 5.2k, 5.6k | 0.66s, 0.91s | 1, 6 |
| pure proxy (every tool hidden) | 8/13, 5/13 | 95, 91 | 107k, 73k | 13.3k, 8.4k | 0.85s, 0.80s | 11, 40 |
| hybrid proxy (6 common tools native) | 12/13, 12/13 | 72, 74 | 140k, 143k | 5.6k, 6.3k | 0.84s, 0.74s | 5, 5 |

Wall time: a clean native sweep takes 71–90s for the 13 tasks, a hybrid sweep
90–103s, a pure-proxy sweep about 107s; two of the six runs crossed a laptop
sleep and one killed request, so their wall totals (282s, 630s) say nothing
and the per-call latency column is the fair time comparison. A model call
costs 0.7–0.9s whichever mode is on; what differs is how many calls a task
takes and how many of them are wasted on errors.

### What the pure proxy does to a model

The pure proxy's low token count is not a saving. Where the model succeeded,
it spent fewer tokens than natively (the rename: 6k against 38k; explaining
the package: 5k against 18k). Where it failed, it failed cheaply, without
doing the work:

- **It calls hidden tools by their real names.** Knowing from the `list-tools`
  description that `files_patch` exists, gemma4 emits a `files_patch` call in
  its own syntax. Only `call-tool` is declared, so the server drops the call
  and returns an empty reply; after three of those the model announces that
  "the necessary tools to edit files were not provided" and answers with what
  it would have written. Every task that had to write a file failed this way.
- **Nested JSON for file bodies.** `call-tool` puts the file content inside
  `arguments` inside the outer object: two levels of escaping, which the model
  gets wrong or gives up on (`Error: content is required.`).
- **Envelopes in every shape.** `{"name": T, "arguments": {"name": T,
  "arguments": {…}}}`, `{"arguments": {"name": T, "arguments": {…}}}` with no
  name beside it, `{"arguments": {"commands": [...]}}`. Each shape cost a
  refused call and a repeat until the resolver learned it (`381901c`,
  `e2a74f3`).
- **Twice the completion tokens** (13k against 5k): every call carries an
  envelope and the tool name twice, and the swallowed replies still count.

### Bugs found and fixed along the way

1. **The proxy tools did not say what they reach** (`749db0d`): five tasks
   ended with "I do not have access to your file system". The `list-tools`
   description is now generated from the hidden tools, each with its name and
   the start of its description (`9ffb9e3`), so the model knows what exists
   without paying for the schemas.
2. **`list-tools` returned everything with all arguments** (`749db0d`): a
   search for `read file list files` produced 10.9k characters that stayed in
   the transcript. Name matches rank first, six tools are described in full,
   the rest are named.
3. **Nested envelopes** (`381901c`, `e2a74f3`), see above.
4. **The identical-call guard did not end anything** (`564e280`): after the
   fourth identical refused call the run went on until the turn limit. The
   tools are withdrawn for the next turn and the model asked to answer.
5. **Empty replies did not end anything either** (`dd85f41`): three in a row
   now withdraw the tools too, and in a proxied run the repair feedback says
   how to reach a hidden tool through `call-tool` (`9ffb9e3`).
6. **A hidden tool called by name was refused** ("proxy mode does not expose
   tool"): it now runs (`9ffb9e3`). The proxy saves tokens; the agent's tool
   list is the permission boundary.
7. **`files_grep` stopped at 100 lines silently** (`cc2e74a`): the proxy runs
   reached for grep where the native runs used `run_shell grep -c`, counted the
   100 lines shown and answered "114 ERROR lines" for a log with 287.

### The hybrid

`useToolProxy` now keeps `files_read`, `files_grep`, `files_patch`,
`files_write`, `files_list` and `run_shell` native (about 1k tokens of schema)
and puts the rest behind `list-tools` and `call-tool`. An agent's
`proxyExposedTools` names another set; an empty set is the pure proxy. On the
benchmark the hybrid solves 12 of 13 tasks in both runs, like the native
catalog, with 72–74 model calls for 140–143k prompt tokens: a third fewer
tokens than native at the same pass rate, and none of the pure proxy's
failure modes, because the calls that matter never go through an envelope.
The remaining failure (`10-readme` once, `13-big-log` once) is the model's, not
the proxy's: the same tasks fail natively now and then.

## When to use it

- **Many tools, few needed per task.** MCP servers with dozens of tools, or an
  agent with `github`, `web`, `mastodon` and `files` enabled at once. The
  schema cost grows with the catalog; the proxy's cost grows only with what a
  task actually asks about.
- **Small, stable coding set: the hybrid, or nothing.** The 17 standard tools
  cost about 2.2k tokens per call after the catalog cut in `test/PLAN.md`; the
  hybrid brings that to about 1k plus the generated `list-tools` description,
  at the same pass rate. The pure proxy is not worth its failure modes on a
  catalog this small.
- **Never the pure proxy for a coding agent.** Every file write goes through
  two levels of JSON escaping and every hidden tool is one the model will try
  to call by name. Reserve `proxyExposedTools: []` for measurements, or for
  catalogs where nothing is called often enough to deserve a schema.

## Measuring it yourself

    python3 test/bench/run.py --variant proxy      # every tool hidden
    python3 test/bench/run.py --variant hybrid     # the default with useToolProxy
    python3 test/bench/compare.py test/results/<run-a> test/results/<run-b>
    python3 test/bench/analyze.py test/results/<run-id> --detail all

The `--detail` timeline shows each `list-tools` call and how many characters
its result added (`new_tool_out`), which is exactly the context debt discussed
above.

## Per-tool policy and automatic exposure

`toolPolicy.groups` and `toolPolicy.tools` select `direct`, `proxy`, or
`disabled`. Exact tool names override qualified groups, then short group
names, then the inherited hybrid default. Native GitHub members can therefore
be mixed individually; MCP groups use `mcp/SERVER` so a GitHub MCP cannot
shadow the native `github` group. Skills use the same policy through their
`skills_NAME` tools. Disabled tools are filtered before discovery and dispatch,
including calls that name them directly or wrap them in `call-tool`.

`toolPolicy.automatic` defaults to true. It uses a recent window of 128 concrete
executions, promotes at most four extra tools with three or more calls, and
ranks by frequency then recency. Explicit choices are excluded from learning.
Lifetime counts shown beside each tool and group are independent of that
window, and persist across launches. No model call is needed to tune exposure.
The SDK's raw requests retain native exposure unless the host passes an agent
profile; profile constructors and missing JSON fields default to hybrid.

The design follows the per-tool and per-server deferred-loading pattern in
[Anthropic's tool-search design](https://www.anthropic.com/engineering/advanced-tool-use).
The MCP [tools specification](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)
provides server tool discovery; pmai applies exposure and disable policies at
the host boundary. Validation and approval use the concrete tool in all modes.
The bounded usage heuristic is pmai's implementation choice and has regression
coverage for promotion, demotion, manual overrides, and persistence.
