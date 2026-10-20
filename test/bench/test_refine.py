"""Offline regressions for harness comparisons, evidence, and resuming."""
import json
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import refine
import run as benchmark


class RefinementTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.cases = self.root / "cases"
        for name in ("train", "held-out"):
            fixture = self.cases / name / "fixture"
            fixture.mkdir(parents=True)
            (fixture / "file.txt").write_text("original\n")
            (fixture.parent / "prompt.txt").write_text("Fix the file.")
            (fixture.parent / "check.sh").write_text("exit 0\n")
        self.binary = self.root / "pmai"
        self.binary.write_bytes(b"test binary")
        self.spec = self.root / "spec.json"
        self.spec.write_text(json.dumps(dict(baseline={}, candidates={"candidate": {}},
                                           cases=["train"], holdout=["held-out"])))
        self.patch = patch.object(refine, "CASES", self.cases)
        self.patch.start()
        self.addCleanup(self.patch.stop)
        self.args = SimpleNamespace(model="mock", repeat=3, timeout=10, resume=False, pmai=self.binary)

    def trial(self, case, args, upstream, key):
        path = args.results / args.run_id / case
        path.mkdir(parents=True)
        (path / "source").mkdir()
        (path / "work").mkdir()
        (path / "source/file.txt").write_text("original\n")
        (path / "work/file.txt").write_text("fixed\n")
        (path / "stdout.txt").write_text("Done\n")
        (path / "stderr.txt").write_text("")
        (path / "meta.json").write_text(json.dumps(dict(
            case=case, prompt="Fix the file.", check=True, check_output="SECRET CHECKER VERDICT",
            exit_code=0, timed_out=False, elapsed=1)))
        (path / "pmai.json").write_text(json.dumps(dict(providers=[{"baseURL": "http://localhost:123/v1"}])))
        (path / "proxy.jsonl").write_text(json.dumps(dict(path="/v1/chat/completions", request={
            "messages": [{"role": "tool", "tool_call_id": "a", "content": "OBSERVATION " * 6000}]},
            response={"content": "done", "usage": {"prompt_tokens": 100, "completion_tokens": 20}}
        )) + "\n")

    def experiment(self):
        variants, groups = refine.load_spec(self.spec)
        with patch.object(refine, "run_case", side_effect=self.trial) as run:
            result = refine.run_experiment(self.root / "output", variants, groups,
                                           self.args, "http://localhost:100/v1", "secret")
        return result, run

    def test_schedule_resume_and_evidence(self):
        result, run = self.experiment()
        self.assertEqual(run.call_count, 12)
        order = [(call.args[1].results.name, call.args[1].run_id, call.args[0])
                 for call in run.call_args_list]
        self.assertEqual(order[:2], [("baseline", "r1", "train"), ("candidate", "r1", "train")])
        self.assertEqual(order[4:6], [("candidate", "r2", "train"), ("baseline", "r2", "train")])
        self.assertEqual(result["review_candidate"], "baseline")
        evidence = self.root / "output/trials/baseline/r1/train/evidence"
        trajectory = (evidence / "trajectory.md").read_text()
        self.assertEqual(trajectory.count("OBSERVATION"), 6000)
        self.assertNotIn("SECRET CHECKER VERDICT", "".join(p.read_text() for p in evidence.iterdir()))
        self.assertIn("-original\n+fixed\n", (evidence / "changes.diff").read_text())
        self.assertNotIn(":123", (evidence / "harness.json").read_text())
        self.assertNotIn("secret", (self.root / "output/experiment.json").read_text())
        self.args.resume = True
        resumed, run = self.experiment()
        run.assert_not_called()
        self.assertEqual(resumed, result)

    def test_refuses_overwrite_and_changed_inputs_or_completed_outputs(self):
        self.experiment()
        with self.assertRaisesRegex(ValueError, "already exists"):
            self.experiment()
        self.args.resume = True
        self.binary.write_bytes(b"different binary")
        with self.assertRaisesRegex(ValueError, "inputs changed"):
            self.experiment()
        self.binary.write_bytes(b"test binary")
        output = self.root / "output/trials/baseline/r1/train/stdout.txt"
        output.write_text("changed")
        with self.assertRaisesRegex(ValueError, "completed trial changed"):
            self.experiment()

    def test_incomplete_trial_is_preserved_before_retry(self):
        partial = self.root / "output/trials/baseline/r1/train"
        # Establish the experiment manifest, then simulate interruption before the first run.
        with patch.object(refine, "run_case", side_effect=KeyboardInterrupt):
            with self.assertRaises(KeyboardInterrupt):
                variants, groups = refine.load_spec(self.spec)
                refine.run_experiment(self.root / "output", variants, groups, self.args,
                                      "http://localhost:100/v1", "secret")
        partial.mkdir(parents=True)
        (partial / "partial.txt").write_text("keep this evidence")
        self.args.resume = True
        self.experiment()
        archived = list(partial.parent.glob("train.interrupted-*/partial.txt"))
        self.assertEqual(len(archived), 1)
        self.assertEqual(archived[0].read_text(), "keep this evidence")

    def test_inheritance_prompt_snapshots_and_case_validation(self):
        (self.root / "prompt.txt").write_text("Custom prompt")
        data = dict(baseline={"system": "prompt.txt", "context": "tools"},
                    candidates={"inherited": {}, "default-prompt": {"system": None}},
                    cases=["train"], holdout=["held-out"])
        self.spec.write_text(json.dumps(data))
        variants, _ = refine.load_spec(self.spec)
        self.assertEqual(variants["inherited"]["system"], "Custom prompt")
        self.assertEqual(variants["inherited"]["context"], "tools")
        self.assertIsNone(variants["default-prompt"]["system"])
        for key, value in (("holdout", ["train"]), ("cases", ["../train"]),
                           ("candidates", {"baseline": {}}), ("baseline", {"contex": "tools"})):
            with self.subTest(key=key):
                self.spec.write_text(json.dumps(dict(data, **{key: value})))
                with self.assertRaises(ValueError):
                    refine.load_spec(self.spec)

    def comparison(self, candidate_tokens=80, candidate_elapsed=1):
        variants = {"baseline": {}, "candidate": {}}
        groups = {"train": "train", "held-out": "holdout"}
        rows = [dict(variant=name, case=case, split=split, round=round_index, solved=True,
                     checked=True, tokens=100 if name == "baseline" else candidate_tokens,
                     elapsed=1 if name == "baseline" else candidate_elapsed,
                     calls=1, tool_errors=0, repeats=0)
                for name in variants for case, split in groups.items() for round_index in (1, 2, 3)]
        return variants, groups, rows

    def test_recommendation_requires_repeat_holdout_and_complete_usage(self):
        variants, groups, rows = self.comparison()
        self.assertEqual(refine.report(variants, groups, rows, 3)["review_candidate"], "candidate")
        self.assertEqual(refine.report(variants, groups, rows, 1)["review_candidate"], "baseline")
        self.assertEqual(refine.report(variants, {"train": "train"}, rows, 3)["review_candidate"], "baseline")
        for field, value in (("tokens", None), ("checked", False), ("elapsed", 50)):
            changed = [dict(row, **{field: value}) if row["variant"] == "candidate" else row for row in rows]
            self.assertEqual(refine.report(variants, groups, changed, 3)["review_candidate"], "baseline")

    def test_per_case_regression_cannot_hide_behind_total_success(self):
        variants, groups, rows = self.comparison()
        for row in rows:
            if row["variant"] == "baseline" and row["case"] == "train":
                row["solved"] = False
            if row["variant"] == "candidate" and row["case"] == "held-out" and row["round"] == 1:
                row["solved"] = False
        result = refine.report(variants, groups, rows, 3)
        self.assertEqual(result["review_candidate"], "baseline")
        self.assertIn("held-out", result["reasons"]["candidate"])

    def test_failure_with_passing_checker_is_not_solved_and_missing_usage_is_unknown(self):
        self.experiment()
        trial = self.root / "output/trials/baseline/r1/train"
        meta = json.loads((trial / "meta.json").read_text())
        meta["timed_out"] = True
        (trial / "meta.json").write_text(json.dumps(meta))
        call = json.loads((trial / "proxy.jsonl").read_text())
        call["response"]["usage"] = None
        (trial / "proxy.jsonl").write_text(json.dumps(call) + "\n")
        row = refine.measurements(trial)
        self.assertFalse(row["solved"])
        self.assertIsNone(row["tokens"])

    def test_diff_handles_deleted_binary_files_and_unterminated_lines(self):
        self.experiment()
        trial = self.root / "output/trials/baseline/r1/train"
        (trial / "source/deleted.txt").write_text("gone\n")
        (trial / "work/binary.bin").write_bytes(b"\0\xff")
        (trial / "work/file.txt").write_text("fixed")
        refine.export_evidence(trial)
        diff = (trial / "evidence/changes.diff").read_text()
        self.assertIn("+++ /dev/null", diff)
        self.assertIn("Binary files differ: /dev/null -> b/binary.bin", diff)
        self.assertIn("+fixed\n\\ No newline at end of file\n", diff)
        self.assertEqual(refine.fence("`````"), "``````\n`````\n``````\n")

    def provider(self, tools=False):
        class Provider(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def respond(self, value):
                body = json.dumps(value).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                self.respond({"data": [{"id": "mock"}]})

            def do_POST(self):
                request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                self.server.requests.append(request)
                message = {"role": "assistant", "content": "Done"}
                if tools and not any(m.get("role") == "tool" for m in request.get("messages", [])):
                    message["tool_calls"] = [{"id": "write", "type": "function", "function": {
                        "name": "run_shell", "arguments": json.dumps({"script": "printf 'fixed\\n' > file.txt"})}}]
                self.respond({"choices": [{"message": message,
                                           "finish_reason": "tool_calls" if "tool_calls" in message else "stop"}],
                              "usage": {"prompt_tokens": 10, "completion_tokens": 2}})

        server = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
        server.requests = []
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return server

    def test_real_runner_proxy_setup_snapshot_and_overwrite_protection(self):
        server = self.provider()
        (self.cases / "train/setup.sh").write_text("printf 'after setup\\n' > file.txt\n")
        (self.cases / "train/check.sh").write_text("test \"$(cat file.txt)\" = fixed\n")
        executable = self.root / "fake-pmai.py"
        executable.write_text('''#!/usr/bin/env python3
import json, sys, urllib.request
from pathlib import Path
config = json.loads(Path(sys.argv[sys.argv.index('--config') + 1]).read_text())
request = urllib.request.Request(config['providers'][0]['baseURL'] + '/chat/completions',
    data=json.dumps({'model': 'mock', 'messages': [{'role': 'user', 'content': 'fix'}]}).encode(),
    headers={'Content-Type': 'application/json'})
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
with opener.open(request) as response:
    print(json.load(response)['choices'][0]['message']['content'])
Path('file.txt').write_text('fixed\\n')
''')
        executable.chmod(0o755)
        args = SimpleNamespace(results=self.root / "runner", run_id="trial", model="mock", timeout=10,
                               pmai=executable, **refine.DEFAULTS)
        with patch.object(benchmark, "CASES", self.cases):
            meta = benchmark.run_case("train", args, f"http://127.0.0.1:{server.server_port}/v1", "secret")
            self.assertTrue(meta["check"])
            self.assertEqual(meta["exit_code"], 0)
            with self.assertRaises(FileExistsError):
                benchmark.run_case("train", args, "unused", "unused")
        trial = args.results / "trial/train"
        self.assertEqual((trial / "source/file.txt").read_text(), "after setup\n")
        self.assertEqual((trial / "work/file.txt").read_text(), "fixed\n")
        self.assertEqual(len(server.requests), 1)
        self.assertEqual(refine.measurements(trial)["tokens"], 12)

    @unittest.skipUnless((refine.ROOT / "MaiCore/.build/debug/pmai").is_file(),
                         "build pmai for the real CLI integration check")
    def test_real_pmai_campaign_and_resume(self):
        server = self.provider(tools=True)
        self.args.pmai = refine.ROOT / "MaiCore/.build/debug/pmai"
        self.args.repeat = 1
        for case in ("train", "held-out"):
            (self.cases / case / "check.sh").write_text("test \"$(cat file.txt)\" = fixed\n")
        variants, groups = refine.load_spec(self.spec)
        variants["candidate"]["context"] = "tools"
        upstream = f"http://127.0.0.1:{server.server_port}/v1"
        with patch.object(benchmark, "CASES", self.cases):
            result = refine.run_experiment(self.root / "output", variants, groups,
                                           self.args, upstream, "local")
            self.assertEqual([row["solved"] for row in result["trials"]], [True] * 4)
            self.assertEqual(result["review_candidate"], "baseline")
            count = len(server.requests)
            self.args.resume = True
            resumed = refine.run_experiment(self.root / "output", variants, groups,
                                            self.args, upstream, "local")
            self.assertEqual(resumed, result)
            self.assertEqual(len(server.requests), count)
        evidence = self.root / "output/trials/candidate/r1/train/evidence/trajectory.md"
        self.assertIn("run_shell", evidence.read_text())
        self.assertIn("tool_call_id", evidence.read_text())


if __name__ == "__main__":
    unittest.main()
