# Context strategies

`/set ctx.strategy` shows the current strategy. **`adaptive` is the default** for
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

The configuration key is the agent's `context`, for example `"context": "adaptive"`.
`/reset ctx.strategy` restores `adaptive`. Context strategy is independent of the
model's reasoning effort and of the durable compaction threshold.

## Comparison

| Strategy | Good | Bad | Use it when |
| --- | --- | --- | --- |
| `smart` | Uses the prepared request's window budget, including runtime instructions, schemas and reply reserve. Keeps every user message, pins, active instructions and the newest complete exchange exact. Reuses a disposable brief; original history stays available. | Older assistant/tool evidence can still lose details in a summary. Reductions add latency and model usage. A growing user history or one huge protected result can still fill the window. | Preserving every user message verbatim is important. |
| `cache` | Preserves the retained prefix. Can discard dispensable suffix messages without rewriting that prefix. No summary-model calls unless durable compaction is enabled separately. | Does not automatically discard substantive evidence. Context can keep growing. Cache hits depend on the provider and cached input still occupies the window. | Short sessions, exact replay, or workloads where provider cache reuse is particularly valuable. |
| `size` | Replaces old file-read bodies with read-again references without a model call. Keeps current-task reads intact. | Rewrites older messages, reducing eligible cache reuse from that point. Does not bound one long task or remove large shell/search output, tool arguments or prose. Files may need rereading. | Many separate coding tasks with large reads from previous tasks. |
| `tools` | Summarizes only large, already-consumed successful tool results. Keeps user/assistant prose and call arguments intact; saved results stay whole. | Can add frequent summary calls and change the cached prefix. Small results, errors, prose and arguments still accumulate. Summaries may omit exact values or code. | Tool output dominates and preserving conversation prose is important. |
| `adaptive` (default) | Starts briefs later and waits for more evidence before rebuilding them. Retains the active task and recent exchanges exactly. | A brief may omit details from older user messages and tool results. | General coding and long mixed tool conversations, including growing user history. |

## Smart: preserve evidence until there is pressure

Smart uses the model window configured with `/set ctx.window`, a limit learned
from a provider context-limit error, or the exact model's advertised catalog
window. A configured cap can lower a catalog window; it cannot enlarge one. A provider
rejection can tighten the cap further. Model listings populate the runtime's window cache.
If the window is still unknown when a request reaches the fallback trigger,
the runtime attempts catalog discovery once per connection before reducing.
Small requests do not wait for discovery; failed or empty automatic discovery
is remembered until an explicit listing refreshes it. Replacing or removing a
connection clears its limits, and an older in-flight catalog cannot repopulate
the replacement's cache. Before deciding to reduce,
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

Adaptive starts at 90% of the available input budget, or 32,000 estimated
tokens when the window is unknown. It can include older user messages in a
brief. Both smart and adaptive wait for `min(4000, trigger / 8)` new eligible
tokens after an attempt before rebuilding a brief that remains over the soft
trigger. This also applies after a failed or non-shrinking summary: one more
small shell result must not repeatedly summarize the same history. At the
input budget or after a provider context rejection, reduction can run immediately.

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
The durable-compaction renderer excerpts long tool/file/resource text and is distinct from smart's
full-evidence renderer. Do not assume it has the same retention properties.

Provider overflow errors can tighten smart/adaptive reduction and rebuild the
brief. Recovery is bounded and does not resend an equally large rejected
request. No strategy guarantees that an oversized current request, immutable
instructions or one huge fresh tool result will fit. Prefer bounded tool output,
file ranges and paging. A non-shrinking or impossible reduction can still end
with a context error; it must not silently discard unread evidence.

## Inspecting, resetting and editing context

Pmai saves a diagnostic timeline with the chat even when `/set debug` is off.
`/export debug trace.json` includes it in `debug.diagnostics`, with a version,
coverage description, event counts, and chronological records. The records
survive restarting pmai, changing provider sessions, and reopening the chat.
Older chats have no retroactive call history; empty diagnostics cannot establish
that no compaction occurred before recording was available.

The timeline includes:

- Every runtime provider attempt, including conversation, tool-selection,
  approval, manual summary, working-context, tool-result, and durable compaction
  calls. Retries share a call ID; chunks and consolidation calls share a summary
  operation ID. Run/parent IDs identify child work.
- Request sizes, schema and reasoning sizes, generation options, output limits,
  provider/model, transport events, elapsed time, reported or estimated usage,
  stop reasons, errors, cancellations, and retries.
- Summary output, chunk splits, output-limit recovery, provider overflow
  recovery, and whether each summary operation completed or failed.
- Smart/adaptive decisions to retain or reduce context, including the reason,
  window, budget, trigger, selected message IDs, before/after estimates, fixed
  instruction/schema overhead, and applied/unchanged/failed outcomes.
- Run and tool lifecycle metadata and transcript edits, alongside the chat's
  original messages, command records, and saved child-agent transcripts.

`compactionAttempts` counts actual provider attempts for summary operations;
`compactionOperations` counts the outer operations. One operation can make
several calls because it splits input or recovers from truncation. These counts
cover recorded work, not unavailable older history or a remote agent provider's
internal calls.

Routine diagnostics record request metadata rather than copying full prompts
and tool output into every event. Summary text is retained so a disposable brief
can be inspected after the run. `/set debug true` additionally writes the verbose
request/response log (`/set debugfile` shows its path). Configuration-shaped
diagnostic values are sanitized; chat content and summary text remain evidence.
Unknown windows/budgets are null. Request sizes and context counts remain
estimates unless explicitly identified as provider-reported usage. If fixed
overhead is already near the trigger, repeated summaries cannot solve the
underlying capacity problem.

`/chat context` lists the active messages and estimates their size before runtime
instructions and tool schemas. `/export --context json context.json` exports that
working transcript; `/export json history.json` keeps originals and alternatives.
Smart/tool briefs are disposable per-run projections and are not inserted into
this saved working-context transcript. Their calls and output are available in
the debug diagnostic timeline.

`/chat context reset` excludes conversation messages while keeping configured
instructions and saved history. `/chat context rebuild` restores original evidence
and discards context replacements, including manual edits made through the whole
conversation editor. The next request applies the selected model's context policy
and window. Both commands start a fresh provider session and require an idle chat.
`/chat clear` still deletes the conversation.

`/chat edit` (also `/edit chat`) opens all retained messages in the configured
editor. Text appears in fenced Markdown, with a message ID, role and active/excluded
state above each block. Edit the text or state; removing a block excludes it.
Existing IDs, roles and order must stay intact. New user/assistant blocks with ID
`new` can be appended. Attachments, reasoning and native tool records are preserved
outside the editable text. Broken tool pairs or malformed documents reject the
entire edit. Originals remain available in ordinary exports and context rebuilds.
This editing format is separate from presentation-only Markdown exports.

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
separate context/UI plumbing; its compaction also retains original messages and
recording references, and exports preserve context annotations. Remote managed tool-loop providers own their own
context; smart/adaptive do not summarize inside those managed loops. Selecting
a CLI strategy does not establish identical mobile or remote behavior.

## Context occupancy

The shell status line and native iOS chat title show `ctx ~12.0k/32.8k (37%)`
when capacity is known. The denominator is tokens, not message count. `~` marks
an estimate. The numerator describes the prepared model context, including
instructions and tools; provider input counts take precedence over byte-based
estimates. This is separate from tokens spent over multiple calls.

Without a known limit pmai shows only context tokens. Before iOS has prepared a
call, or after history/settings edits, the saved working transcript is a partial
estimate: `ctx ~12.0k+/32.8k`, without a percentage. Partially loaded shell history
also keeps the `+` marker. Request preparation and completed calls refresh the
measurement; this is not a per-keystroke tokenizer. Last-call telemetry is
transient; reopening a chat uses the transcript estimate until another call.

`/set ctx.window 8192` sets a lower shell context cap; `auto` removes it. In iOS,
Chat Settings → Context → Token limit persists a per-chat cap; clear the field
for automatic capacity. MLX uses the smaller of its loaded model's advertised
`max_position_embeddings`, configured KV cache and user cap, and bounds generation
by the remaining space. Apple uses the SDK's context size/token counter when
available, otherwise estimates. OpenAI-compatible catalogs can publish context
metadata; a plain catalog that omits it leaves capacity unknown. No model-name
lookup table is assumed.

ACP's standard `usage_update` supplies actual remote occupancy and capacity.
These snapshots replace previous occupancy and never become billable token
usage. A remote agent owns its context policy: a host-side `ctx.window` setting
cannot reconfigure an arbitrary agent's native context. pmai hosts forward their
own occupancy over ACP too, marking estimates in `_meta.pmai.estimated`.
