# Testing

Tests must earn their maintenance cost. Before adding or repairing a test,
identify the user-visible failure it prevents. Prefer deleting a low-value
flaky assertion over adding synchronization machinery just to preserve it.

## What to test

- Cover meaningful behavior: correct results, saved data, permissions, protocol
  compatibility, cancellation, crashes, and hangs.
- Prefer a small regression case in an existing suite. Do not add tests for
  every edit, private helper, cosmetic change, or straightforward refactor.
- Assert observable results, not internal call order, redraw counts, exact
  terminal byte sequences, or a completely silent idle terminal. Terminal tests
  may check visible text, layout bounds, editing, and terminal restoration.
- Keep CPU usage, animation cadence, output volume, and speed thresholds out of
  correctness tests and required CI. Use opt-in benchmarks under `test/bench/`
  when a performance investigation is actually requested.
- Test timing arithmetic with fixed timestamps or a controlled clock. Do not
  compare measured throughput against ranges derived from real sleeps.
- Use the smallest fixture that demonstrates the failure. Large histories and
  many-agent workloads belong in explicit stress tests unless size is essential
  to a specific correctness regression.

## Async and integration checks

- Wait for a relevant result, request, or explicit event with a generous bounded
  timeout. A timeout prevents a hung test; it is not a performance target.
- Do not use a short sleep, a quiet interval, or absence of output as proof that
  an operation completed. Do not assert subsecond scheduling margins.
- Keep real timeout/cancellation coverage when it proves work actually stops;
  use ample separation between the timeout and the simulated workload.
- Use temporary directories and local deterministic providers. Live models,
  credentials, external services, hardware, and load tests require explicit
  opt-in and must not become default CI dependencies.
- For a flaky test, first assess its value. Keep and repair valuable coverage
  with an observable completion condition; remove incidental assertions. Do not
  hide failures with retries, longer settling sleeps, or blanket error ignores.

## How to run tests

- Run the smallest affected suite once. Reuse builds with `--skip-build` when
  the binary is current; do not clean builds or repeat passing suites by default.
- Use `python3 test/run-tests.py core`, `chat`, or `documents` for those focused
  Swift graphs. For a CLI script, build once with `make repl-build`, then run
  `python3 test/<name>-smoke.py MaiCore/.build/debug/pmai`.
- `make test-cli` defaults to the small `platform` suite. Select `unit`, `smoke`,
  `terminal`, or `full` explicitly when the scope warrants it. Do not run the
  full matrix for a narrow edit or a documentation-only change.
- `python3 test/run-tests.py stress` is explicitly opt-in and excluded from
  `terminal` and `full`. External suites and performance benchmarks are also
  opt-in. Keep PTY/load suites serial by default (`--jobs 1`).
- Required CI should cover correctness and platform compatibility. Add a CI
  test only when its regression value justifies its runtime and maintenance;
  do not automatically copy every local check into every platform job.
