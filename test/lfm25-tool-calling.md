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

- Native runs recognize rejected LFM/XML envelopes at the start of a reply and
  request a corrected native call. They do not evaluate Python, guess missing
  arguments, or interpret prose/code-fenced examples as calls.
- Empty first turns get corrective feedback. Reasoning-only output-limit
  responses retain their finish reason and usage, allowing a short retry with
  guidance rather than an identical transport retry.
- All repairs use the existing three-consecutive-repair guard and run budgets.
  Normal tool validation, permissions, and approvals still apply.
- Native instructions require known inputs, waiting for dependent results,
  and avoiding extra quoting. OpenAI-compatible requests sort object keys so
  schema order stays stable across requests and process launches.
- Text/XML/JSON modes recognize leaked LFM envelopes as repairable attempts.
  They previously accepted these as final text too.

## End-to-end results

Six tasks: read a secret word, write exact content, read then write the secret,
run a quoted shell command, edit a JSON port while preserving another property,
and greet without tools. Each run allowed six model turns and eight tool calls,
with temperature 0 and a 2,048-token response limit. Success checks use actual
files/tool output, not the model's completion claim.

| Configuration | Streaming | Buffered | Total |
| --- | ---: | ---: | ---: |
| LFM native before changes | 6/6 | 4/6 | 10/12 |
| LFM native after changes | 6/6 | 5/6 | 11/12 |
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

Deterministic validation: the MaiCore and MaiOpenAI suites passed 410 tests,
including rejected-envelope recovery, repair limits, ordinary/example text,
first-turn empty responses, output-limit accounting, and stable schema order.
