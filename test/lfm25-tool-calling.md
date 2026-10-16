# LFM2.5 tool-calling investigation

Tested on 2026-10-16 against `vllmthor::lfm25`. The endpoint's `/v1/models`
identified `LiquidAI/LFM2.5-8B-A1B`. All prompts used synthetic data; file and
shell operations ran in isolated temporary workspaces.

## Findings

The server does support native calls. Ten small prompts, each streamed and
buffered, produced eight native-call replies, one greeting, and one
reasoning-only output-limit response per mode. Calls included current time,
weather in two cities, arithmetic, file reads/writes, and a filename containing
an apostrophe. This is not a missing native-tool capability.

LFM emits Python-style calls enclosed by `<|tool_call_start|>` and
`<|tool_call_end|>`. With malformed quoting, vLLM can return the rejected block
as ordinary content with `finish_reason: stop`. One real response was:

```text
<|tool_call_start|>[files_patch(expected_matches=1, replace='"port":8000", '"port":9000', path='settings.json')]<|tool_call_end|>
```

pmai's native loop previously accepted that as a final answer, so the requested
edit never happened. Streamed calls also sometimes contained invalid JSON
arguments, but those already had a repair path. The difference explains why
turning streaming off could make the same task silently stop.

Other observed failures were model decisions: a read and a dependent write in
one reply with `{{notes_content}}` as the write content; extended reasoning that
spent the entire 1,024-token probe limit; and patches with invented punctuation
despite having the exact file contents. Valid JSON arguments can still describe
an incorrect edit. Changing transport handling cannot guarantee correct edits.

For comparison with the implementation, see Liquid's [chat template](https://huggingface.co/LiquidAI/LFM2.5-8B-A1B/blob/main/chat_template.jinja)
and vLLM's [LFM2 parser](https://github.com/vllm-project/vllm/blob/main/vllm/tool_parsers/lfm2_tool_parser.py).
The latter returns original content on buffered parsing failure. The configured
endpoint's `/tokenize` output also showed the LFM template and its tool list.

## Changes

- Native runs recover complete LFM envelopes at the start of a reply, or request
  corrected native calls for malformed LFM/XML envelopes. The literal parser
  does not evaluate Python, guess missing arguments, or interpret prose or
  code-fenced examples as calls. A malformed batch executes nothing.
- Empty first turns get corrective feedback. Reasoning-only output-limit
  responses retain their finish reason and usage, allowing a short retry with
  guidance rather than an identical transport retry.
- All repairs use the existing three-consecutive-repair guard and run budgets.
  Normal tool validation, permissions, and approvals still apply.
- Native instructions require known inputs, waiting for dependent results,
  and avoiding extra quoting. OpenAI-compatible requests sort object keys so
  schema order stays stable across requests and process launches.
- Text/XML/JSON modes also accept complete LFM envelopes. The initial repair-only
  approach wasted turns when LFM kept emitting its trained protocol.

## PocketMai export follow-up

The exported conversation “Websearch for the author of rizin” exposed two bugs
the initial CLI checks missed. Its agent used **Text mode with the tool proxy
enabled**, not native mode. Its first response was a complete call:

```text
<|tool_call_start|>[web_search(query='author of rizen')]<|tool_call_end|>
```

The text parser rejected this format and asked LFM to rewrite it using a
`list-tools(keywords: ...)` example. After rewriting, PocketMai rejected
`web_search` as unavailable even though the conversation enabled it. The app's
loop checked prompt-visible definitions (only the proxy) rather than callable
definitions. The registry and CLI already allowed enabled tools to be called
directly behind the proxy. The network error at the end of the export occurred
after these two failures; it was not the cause of the initial rejection.

The shared literal parser now handles that first call directly, preserving its
query exactly (including the model's `rizen` typo). PocketMai uses the catalog's
callable definitions for normalization, approval and execution, while still
using only visible definitions in model prompts. Native recovery supplies call
IDs and proper assistant/tool history. Disabled tools remain unavailable and
hidden tools still go through approval.

Live proxy probes also exposed a discovery loop: LFM passed the user's web
query as `list-tools` keywords, got no matches, and repeated the lookup. An
unmatched discovery request now returns up to six available schemas and explains
how to execute the selected tool. Proxy descriptions distinguish discovery from
the task's query. Native proxy names use `list_tools` and `call_tool`, preserving
the canonical names in stored chats. Hyphenated names are incompatible with the
Python call AST expected by vLLM's [LFM2 parser](https://github.com/vllm-project/vllm/blob/main/vllm/tool_parsers/lfm2_tool_parser.py).

Regression coverage replays the exact first response through PocketMai's full
loop with a stub OpenAI endpoint and a stub SearXNG service: Text, Native, XML,
and JSON, each with streaming enabled and disabled. All eight combinations
execute one search and return its result to the model in two turns, without
repair. Separate cases cover the rewritten Text call, approval cancellation,
rejection of a disabled tool, and native proxy alias resolution. All 23 selected
iOS tests passed, as did 357 core tests and 60 OpenAI provider tests. Parser cases cover nested proxy
arguments, escaped strings, Unicode, batches, malformed input, expressions,
duplicate keys, reasoning exclusion, and bounded nesting.

Live follow-up used the original user prompt against `vllmthor::lfm25` through
the CLI, with only `web_search` enabled and controlled SearXNG results. Each
configuration ran once buffered and once streamed (temperature 0, 2,048 output
tokens, six model turns). The metric below means a search actually executed and
its fixture result reached a subsequent model request; it does **not** score
the final answer's factual accuracy.

| Configuration | Search executed and returned |
| --- | ---: |
| Text + proxy, parser/host fixes only | 0/2 |
| Text + proxy, including discovery improvements | 2/2 |
| Native + proxy, before/after discovery and alias changes | 0/2 each |
| Native without proxy, final changes | 2/2 |

Native without proxy is the recommended LFM configuration for this case. The
native proxy runs still skipped tools and answered from memory or claimed no
web access. Text proxy runs now search, but often change `rizin` to `rizen` and
keep searching instead of answering. Direct native runs also made multiple
searches before answering. These small probes show remaining model decision
failures, not a guarantee of reliable task completion. The eight-mode simulator
replay separately verifies that the app executes the valid call in the export.

## End-to-end results

Six tasks: read a secret word, write exact content, read then write the secret,
run a quoted shell command, edit a JSON port while preserving another property,
and greet without tools. Each run allowed six model turns and eight tool calls,
with temperature 0 and a 2,048-token response limit. Success checks use actual
files/tool output, not the model's completion claim.

| Configuration | Streaming | Buffered | Total |
| --- | ---: | ---: | ---: |
| LFM native before changes | 6/6 | 4/6 | 10/12 |
| LFM native after initial repair changes | 6/6 | 5/6 | 11/12 |
| LFM JSON fallback, exploratory run | 3/6 | 3/6 | 6/12 |
| Local `gpt-oss:20b` native control, after changes | 6/6 | 6/6 | 12/12 |

These are single small runs, not a statistical estimate. The remaining native
failure was the JSON edit: the model repeatedly used the wrong search string,
then generated a syntactically valid call that wrote malformed JSON. Temperature
0.2 fixed that case but failed the shell case instead (5/6 buffered). Sampling
defaults were therefore left unchanged. JSON fallback frequently ignored its
instructions and emitted LFM's Python-style envelope, costing repair turns.
Native streaming was the most reliable LFM configuration in these checks.
No Qwen model was listed by the configured reachable servers, so the comparison
used the installed `gpt-oss:20b` through local Ollama. It passed all twelve tasks
with the same runner. Latency is not directly comparable across these servers.

## Reproduce

```sh
swift build --package-path MaiCore --product pmai
python3 test/tool-calling-live.py --base-url http://192.168.1.60:8000/v1 --model lfm25
```

Use `--strategy json`, `--proxy`, `--stream off`, `--temperature 0.2`, or
`--repeat N` for comparisons. `--output` names a new artifact directory;
otherwise it is created under the system temporary directory. The runner saves
configuration, CLI output, debug requests/responses/tool results, and
`results.json`. `PMAI_API_KEY` supplies an optional credential via the environment.
Live runs are opt-in and are not part of the deterministic test runner.

On this machine macOS blocked direct LAN access for the rebuilt executable;
the LFM runs used a loopback proxy forwarding unchanged JSON through curl.
The initial failed direct connection checks are excluded from the table.

Initial deterministic validation: the MaiCore and MaiOpenAI suites passed 410 tests,
including rejected-envelope recovery, repair limits, ordinary/example text,
first-turn empty responses, output-limit accounting, and stable schema order.
