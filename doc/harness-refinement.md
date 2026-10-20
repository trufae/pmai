# Improving the pmai harness with execution evidence

`test/bench/refine.py` compares named harness candidates with a baseline on
fresh copies of the coding fixtures. It records repeated runs, keeps training
and held-out cases separate, exports inspectable evidence, and suggests a
candidate for review. It never installs a prompt or changes live agent settings.

This is the first part of an offline improvement cycle:

1. Inspect baseline traces to find a recurring failure or unnecessary cost.
2. Propose one small prompt, tool-exposure, protocol, or context change.
3. Execute the candidate and baseline on fresh copies of the same tasks.
4. Compare task outcomes before tokens and time, then inspect where behavior changed.
5. Keep the baseline when the evidence does not support the change.

Proposing changes and adopting lessons are manual in this version. There is no
additional model acting as an optimizer or judge: task success comes from each
fixture's existing `check.sh`.

## Run a comparison

Build pmai and preview the supplied example without calling a model:

```sh
make repl-build
python3 test/bench/refine.py \
  --spec test/bench/examples/context.json \
  --output test/results/context-study --dry-run
```

The example compares full history (`cache`), old-tool-result summaries (`tools`),
and adaptive briefs (`smart`). With three harnesses, five cases, and three
repeats, it schedules **45 complete task executions**. It demonstrates the
workflow; small fixtures may never trigger context reduction.

Run against an OpenAI-compatible endpoint using the same environment as the
existing benchmark:

```sh
UPSTREAM=http://127.0.0.1:8000/v1 UPSTREAM_KEY=local \
python3 test/bench/refine.py \
  --spec test/bench/examples/context.json \
  --output test/results/context-study \
  --pmai MaiCore/.build/debug/pmai --model YOUR_MODEL --repeat 3
```

`UPSTREAM` and `UPSTREAM_KEY` fall back to `PMAI_BASE_URL` and `PMAI_API_KEY` in
the repository's `env-ollamacloud.sh`. The model also falls back to that file,
then to `gemma4:31b`. `--pmai` falls back to `PMAI_BIN`, then the SwiftPM debug
binary. `--timeout` limits each task execution in seconds (default 900).

Use `--repeat 1` for a small wiring check. Such a report is provisional and
retains the baseline. Dry-run only reads the spec and prompts: it creates no
output directory and does not resolve a binary or contact a provider.

## Describe a candidate

Write a JSON spec, for example:

```json
{
  "baseline": {"variant": "hybrid", "context": "cache"},
  "candidates": {
    "error-guidance": {"system": "error-guidance.txt"}
  },
  "cases": ["02-fix-failing-test", "11-multi-step"],
  "holdout": ["03-add-flag", "12-config-edit"]
}
```

Prompt filenames are relative to the spec. `system` **replaces** the agent's
instructions; it does not append to the built-in prompt. Start from the existing
instructions when testing a small wording change. `system: null` selects the
built-in prompt. Candidates inherit every baseline setting they do not override.

| Setting | Values | Baseline default |
|---|---|---|
| `variant` | `inline`, `proxy`, `hybrid`, `subagent` | `inline` |
| `strategy` | `automatic`, `native`, `text`, `xml`, `json` | `automatic` |
| `context` | `cache`, `size`, `smart`, `tools` | `cache` |
| `plan` | `on`, `off` | `on` |
| `system` | prompt filename or `null` | `null` |

Unknown settings and duplicate cases are rejected. Candidate names use lowercase
letters, digits, underscores, or hyphens; `baseline` is reserved. `cases` must
be nonempty; `holdout` is optional, but required for a candidate recommendation.
All harnesses use the same model, fixture inputs, timeout, and existing per-task
tool/turn limits. The first harness rotates each round to reduce a fixed ordering
advantage; model sampling and provider cache state are not controlled.

Choose held-out tasks before tuning, and keep them out of proposal work. Once
their results influence a new proposal, use different held-out tasks for its
final validation. Change one component at a time where possible; simultaneous
changes make it hard to attribute improvements.

## Read the results

`report.md` contains totals and separate training/holdout measurements, reasons
for retaining or replacing the baseline as the review candidate, and links to
every trial. `report.json` also contains per-case solve counts and per-trial
measurements. A solved trial requires all three: a passing checker, normal exit,
and no timeout. Missing checkers stay unchecked. Missing usage stays **unknown**,
rather than becoming zero-cost execution.

A candidate qualifies for review only with at least three repeats, held-out
cases, complete checker coverage for it and the baseline, and no lower solve
count on any individual case. It must additionally have either:

- More solved trials in total; or
- At least 5% fewer total input-plus-output tokens, both overall and on holdout,
  with wall time no more than 10% higher on either group.

If several qualify, selection prefers more solved trials, then fewer tokens,
then less total wall time. An exact tie between candidates uses their names.
The baseline remains the review candidate when none qualify. This is a review
filter, not a significance test or proof that a change transfers. Inspect the
individual outcomes, cost, and traces before adopting it. The repeated-call
metric includes legitimate repeated verification calls, not just stuck loops.

Each trial lives at `trials/<harness>/r<N>/<case>/`:

| File or directory | Contents |
|---|---|
| `source/` | Starting workspace after fixture setup, excluding `.git` and `.pmai` |
| `work/` | Workspace retained after execution and the checker |
| `proxy.jsonl` | Original model API records, including usage and timing |
| `stdout.txt`, `stderr.txt` | Agent process output |
| `pmai.json`, `meta.json` | Actual configuration and checker/process results |
| `evidence/INDEX.md` | Entry point for inspection |
| `evidence/task.txt`, `harness.json` | Task and effective configuration; proxy port normalized |
| `evidence/trajectory.md` | Full generation records and request histories, including observed tool results |
| `evidence/changes.diff` | Text diffs and binary-change notices between `source/` and `work/` |
| `complete.json` | Fingerprint of completed trial inputs and outputs |

The exporter does not clip observations or execute generated artifacts. Checkers
can affect `work/`; inspect the trajectory as well as the final diff when
attributing edits. Python bytecode, `.git`, and `.pmai` are omitted from file
diffs and tree fingerprints. The evidence bundle omits checker verdicts and
checker output; those remain in the report and `meta.json`. This separation is
for inspection, not an access-control boundary. A prompt proposer should receive
training evidence, not held-out results or checker scripts.

## Resume without mixing experiments

Repeat the original command with `--resume`. Existing directories are refused
without it. The manifest fingerprints prompt contents, fixture/setup/checker
contents, effective settings, model, endpoint, timeout, repeat count, binary, and
benchmark runner code. Endpoint keys are not recorded. A changed input requires
a new output directory.

Completed trials are reused only when their fingerprints still match. Modified
completed outputs stop the resume rather than silently contributing stale data.
An interrupted trial without a completion marker is renamed with an
`.interrupted-<timestamp>` suffix and rerun from a fresh fixture. Earlier files
are preserved. Evidence and reports are rebuilt from the retained raw results.

## Where the ideas came from

This workflow was informed by [google-research/harness2 at `1cfe254`](https://github.com/google-research/harness2/tree/1cfe254e8d25b15f37048c3730134686abe60335),
especially its [propose/probe/compose orchestration](https://github.com/google-research/harness2/blob/1cfe254e8d25b15f37048c3730134686abe60335/harness2/core/recursion.py),
[evidence trees](https://github.com/google-research/harness2/blob/1cfe254e8d25b15f37048c3730134686abe60335/harness2/core/context.py),
and [reflection prompt](https://github.com/google-research/harness2/blob/1cfe254e8d25b15f37048c3730134686abe60335/harness2/core/prompts.py#L1105).
It is implemented using pmai's existing benchmark runner, without a harness2
runtime dependency.

Harness2's published selection pool excludes baseline executions. This workflow
retains the baseline unless a candidate clears the checks above. Its full
recursive method also spends `4k` task executions and `3k` improvement stages,
before selection and reflection; pmai starts with explicit offline comparisons.

Useful next steps after collecting evidence:

- Turn a recurring mechanical tool failure into a small policy shared by the
  CLI and app loops, rather than adding instructions to every model call.
- Package a longer conditional procedure as an on-demand skill or helper.
- Save a procedural lesson only with a trigger, operation, trace reference,
  and confidence. Record `helped`, `hurt`, `no observed effect`, or `confounded`
  for the underlying edit. No supported lesson is a valid outcome.

Keep procedural lessons separate from `AgentMemory`, which represents user
preferences. Recheck workspace-specific facts before applying lessons elsewhere.

The deterministic comparison tests run with:

```sh
python3 -m unittest discover -s test/bench -p 'test_*.py'
```
