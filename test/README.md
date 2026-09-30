# pmai coding-workflow benchmark

Sample coding tasks that pmai should solve, plus a harness that records every
model call so the runs can be studied for wasted turns and tokens.

## Layout

- `cases/<NN-name>/` — one workflow each: `prompt.txt` (the user message),
  `fixture/` (the project files), optional `setup.sh` (runs in the working
  directory before pmai, e.g. `git init`), optional `check.sh` (exit 0 when the
  task was solved; gets `FIXTURE`, `STDOUT`, `WORK` in the environment).
- `bench/proxy.py` — logging forward proxy for OpenAI-compatible endpoints.
  Every request body and the assembled response (streamed or not) become one
  JSON line: messages, tool schemas, tool calls, usage, timings.
- `bench/run.py` — runs the cases through pmai behind the proxy.
- `bench/analyze.py` — summary table and per-call timelines of a run.
- `results/<run-id>/<case>/` — `work/` (the directory after the run),
  `proxy.jsonl`, `stdout.txt`, `stderr.txt`, `meta.json`, `pmai.json`.

## Running

The recap integration smoke test uses a local mock provider and isolated chat
state to check model routing, prompt edits, and history preservation:

    python3 test/repl-recap-smoke.py MaiCore/.build/debug/pmai

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
default instructions ("You are a helpful assistant. Use tools when needed.")
and the `files`, `run` and `todo` groups; `--system FILE` replaces the
instructions to compare prompts.

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
