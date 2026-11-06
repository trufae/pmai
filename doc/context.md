# Context strategies

`/set ctx.strategy` shows the current strategy. **`smart` is the default** for
new agents, requests and REPL sessions, and for agent configurations that omit
`context`. An explicitly saved strategy still takes precedence.

```text
/set ctx.strategy
/set ctx.strategy smart
/set ctx.strategy cache
/set ctx.strategy size
/set ctx.strategy tools
/set ctx.strategy adaptive
/reset ctx.strategy
```

The configuration key is the agent's `context`, for example `"context": "smart"`.
`/reset ctx.strategy` restores `smart`. Context strategy is independent of the
model's reasoning effort and of the durable compaction threshold.

## Comparison

| Strategy | Good | Bad | Use it when |
| --- | --- | --- | --- |
| `smart` (default) | Uses the prepared request's window budget, including runtime instructions, schemas and reply reserve. Keeps every user message, pins, active instructions and the newest complete exchange exact. Reuses a disposable brief; original history stays available. | Older assistant/tool evidence can still lose details in a summary. Reductions add latency and model usage. A growing user history or one huge protected result can still fill the window. | General coding and long mixed tool conversations. |
| `cache` | Preserves the retained prefix. Can discard dispensable suffix messages without rewriting that prefix. No summary-model calls unless durable compaction is enabled separately. | Does not automatically discard substantive evidence. Context can keep growing. Cache hits depend on the provider and cached input still occupies the window. | Short sessions, exact replay, or workloads where provider cache reuse is particularly valuable. |
| `size` | Replaces old file-read bodies with read-again references without a model call. Keeps current-task reads intact. | Rewrites older messages, reducing eligible cache reuse from that point. Does not bound one long task or remove large shell/search output, tool arguments or prose. Files may need rereading. | Many separate coding tasks with large reads from previous tasks. |
| `tools` | Summarizes only large, already-consumed successful tool results. Keeps user/assistant prose and call arguments intact; saved results stay whole. | Can add frequent summary calls and change the cached prefix. Small results, errors, prose and arguments still accumulate. Summaries may omit exact values or code. | Tool output dominates and preserving conversation prose is important. |
| `adaptive` | Uses the same window-aware brief machinery as `smart`, but can also summarize earlier user messages. Retains the active task and recent exchanges exactly. | More aggressive: older user wording can be lost as well as tool evidence. Has the same summary cost and overflow limits. | Explicitly opting into stronger reduction when old user messages dominate. |

## Smart: preserve evidence until there is pressure

Smart uses the model window configured with `/set ctx.window`, or a smaller
window learned from a provider context-limit error. Before deciding to reduce,
the runtime assembles the request with its runtime instructions and tool
schemas. It reserves reply space and a safety margin:

- Reply reserve: `maxOutputTokens`, or `min(4096, window / 4)` when unset.
- Safety margin: `min(1024, window / 16)`.
- Trigger: 75% of the remaining input budget.
- Recent evidence: a quarter of the trigger, capped at 8,000 estimated tokens.

For example, a 32,768-token window with a 4,096-token reply reserve has a
27,648-token input budget. Reduction starts at about 20,736 estimated tokens,
with about 5,184 recent tokens retained. A 131,072-token window uses a much
later trigger, about 94,464 tokens, instead of summarizing at a fixed 16k.
Without a known window the fallback trigger is 16,000 estimated tokens and
the recent budget is 4,000 tokens. All counts remain estimates.

Older eligible assistant/tool exchanges become a reusable brief. Every user
message remains verbatim, preserving earlier constraints even if the brief
omits them. Pinned messages, active skill/catalog instructions, binary evidence
and the newest complete tool exchange are also retained. A new result reaches
the acting model before it becomes eligible for summarization.

The summarizer sees full selected text and structured results, not an arbitrary
4k excerpt. It receives the exact user requests for relevance. Summary output
space scales with the trigger, from 2k to 8k tokens by default, subject to the
compact model's window and explicit output settings. Empty, truncated or
non-shrinking summaries do not replace the evidence.

Briefs are reused within a run until enough new evidence accumulates. Queued
corrections and changed source messages invalidate stale briefs. A failed
reduction is not retried at every unchanged tool step. Rebuilding reads the
original selected evidence, avoiding repeated summary-of-summary drift.
Original history remains stored; pin evidence that must stay exact in the
model view. Summarization cannot guarantee perfect retention of older facts.

Smart and adaptive use `/model -compact` and `prompts.smart` (`/edit smart`).
Without a compact assignment they use the current model. Preparation calls
count toward token/time limits and usage statistics. Their automatic brief
reduction works even when durable compaction is disabled.

## Cache: prefix preservation allows suffix removal

Cache reuse depends on the common prefix, not on keeping the previous request
as an indivisible whole. Dropping a suffix leaves the retained prefix unchanged
and eligible for reuse. Appending new messages can reuse that retained prefix.
Changing a message in the middle preserves eligibility only before that point.
Actual cache hits also depend on the endpoint, stable instructions/tool schemas,
cache lifetime and provider-specific minimum prefix sizes.

Cache mode automatically drops only empty trailing assistant messages: unpinned
messages containing no content or only whitespace text, with no opaque provider
state. It stops at the first substantive or protected message. It never drops
an empty-looking tool call/result, reasoning, attachment or user message.
Empty messages in the middle are left alone so the retained prefix stays exact.
Explicit history trimming can discard a larger suffix when that evidence is no
longer needed; tool transaction boundaries must remain complete.

A suffix is not safe to discard merely because it is recent or expensive.
Fresh results may be the evidence needed for the next action. The runtime has
no reliable automatic policy for discarding arbitrary substantive suffixes.
Consequently, cache mode alone cannot guarantee a bounded context window.

## Size and tools

Size mode prunes file bodies read for earlier user tasks before model calls.
References identify the file and how to read it again. It leaves current-task
reads intact to avoid repeated reads while the model is still working.

Tools mode summarizes successful consumed results of at least 4,000 characters.
Errors, active skill bodies, loaded proxy catalogs and fresh unread results
are excluded. Binary attachments remain available. A changed user task
invalidates result summaries; edited results must be consumed again. Failed,
invalid or oversized summaries retain the original result. Routine automatic
whole-transcript compaction is skipped in this mode; explicit compaction and
context-edit tools remain available.

## Durable compaction and limits

`ctx.strategy` controls the model's working view; `ctx.compact` controls a
separate durable context-action prompt. It defaults to off. For example:

```text
/set ctx.window 32768
/set ctx.strategy smart
/set ctx.compact 20k
```

The context action can prune output, summarize history, keep it or stop. Durable
compaction saves exclusions and replacement versions alongside the original
messages. The model receives the reduced context; conversation history and JSON
archives retain the originals. Summary records identify the messages they replace.
Readable exports include the originals and mark context changes (tool traffic
still follows `export.tools`). Explicit chat clearing and message deletion remain
deletions. Older chats already compacted without originals cannot recover them.
Its renderer
currently excerpts long tool/file/resource text and is distinct from smart's
full-evidence renderer. Do not assume it has the same retention properties.

Provider overflow errors can tighten smart/adaptive reduction and rebuild the
brief. Recovery is bounded and does not resend an equally large rejected
request. No strategy guarantees that an oversized current request, immutable
instructions or one huge fresh tool result will fit. Prefer bounded tool output,
file ranges and paging. A non-shrinking or impossible reduction can still end
with a context error; it must not silently discard unread evidence.

## Context, spending and reasoning

These are different quantities:

- **Context:** estimated prepared model input plus subsequently appended
  messages, including tool arguments/results, instructions and schemas.
- **Spent:** cumulative input plus output from completed model calls, including
  summary and approval calls. Cached input is part of input, not extra tokens.
- **Think:** the provider-reported reasoning-token subset of output. It must
  not be added to output again. Visible reasoning summaries are not the full
  hidden reasoning token count.

During active CLI runs, the status line shows spent tokens and reported thinking
tokens alongside the context estimate. Provider counts take precedence over
fallback estimates; estimated spending is marked with `~`. Counts generally
arrive at call completion, not continuously during generation. Missing hidden
reasoning usage is unknown, not zero. Failed/cancelled calls may have incomplete
usage. Tool-batch transcript growth is published at the batch boundary.

These strategies belong to the MaiCore agent runtime and CLI. Native iOS has
separate context/UI plumbing. Remote managed tool-loop providers own their own
context; smart/adaptive do not summarize inside those managed loops. Selecting
a CLI strategy does not establish identical mobile or remote behavior.
