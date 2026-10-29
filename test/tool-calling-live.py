#!/usr/bin/env python3
"""Opt-in live tool-call checks, with isolated files/config and artifact assertions.

Example: python3 test/tool-calling-live.py --base-url http://localhost:8000/v1 --model lfm25
PMAI_API_KEY is passed through the provider's environment setting, never written to disk.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

from smoke import clean_environment

ROOT = Path(__file__).resolve().parent.parent
CASES = [
    ("read", "Read notes.txt and tell me the secret word in it."),
    ("write", "Write hello.txt containing exactly hello world."),
    ("multi", "Read notes.txt, then write its secret word to secret.txt."),
    ("shell", 'Use run_shell to execute printf "shell-probe-ok" and report the output.'),
    ("json", "Read settings.json and change the port from 8000 to 9000, preserving the other settings."),
    ("none", "Say hello. Do not use tools."),
]


def check(name, root, output, events):
    calls = {e["value"]["id"]: e["value"]["name"] for e in events if e["kind"] == "tool.started"}
    outputs = [(calls.get(e["value"]["callID"]),
                "".join(p.get("text", {}).get("_0", "")
                        + p.get("file", {}).get("_0", {}).get("text", "")
                        for p in e["value"].get("content", [])))
               for e in events if e["kind"] == "tool.finished" and not e["value"].get("isError")]
    if name == "read":
        return any(tool == "files_read" and "tangerine" in text for tool, text in outputs) and "tangerine" in output.lower()
    if name == "shell":
        return ("run_shell", "shell-probe-ok") in outputs and "shell-probe-ok" in output
    if name == "none":
        return not calls and "hello" in output.lower()
    if name == "json":
        return json.loads((root / "settings.json").read_text()) == {"port": 9000, "host": "localhost"}
    filename, expected = ("hello.txt", "hello world") if name == "write" else ("secret.txt", "tangerine")
    return (root / filename).read_text() == expected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=ROOT / "MaiCore/.build/debug/pmai")
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--strategy", choices=["native", "text", "xml", "json"], default="native")
    parser.add_argument("--proxy", action="store_true", help="Use the hybrid tool proxy")
    parser.add_argument("--stream", choices=["both", "on", "off"], default="both")
    parser.add_argument("--temperature", type=float, default=0)
    parser.add_argument("--repeat", type=int, default=1)
    parser.add_argument("--output", type=Path, help="New directory for config, transcripts, and results")
    args = parser.parse_args()
    if args.repeat < 1:
        parser.error("--repeat must be positive")
    destination = args.output.resolve() if args.output else Path(tempfile.mkdtemp(prefix="pmai-tools-live-"))
    if args.output:
        destination.mkdir(parents=True, exist_ok=False)
    env = clean_environment()
    if "PMAI_API_KEY" in os.environ:
        env["PMAI_LIVE_KEY"] = os.environ["PMAI_API_KEY"]
    results = []
    streams = [True, False] if args.stream == "both" else [args.stream == "on"]
    for repeat in range(args.repeat):
        for stream in streams:
            for name, prompt in CASES:
                root = destination / f"{repeat + 1}-{stream}-{name}"
                root.mkdir()
                (root / "notes.txt").write_text("The secret word is tangerine.\n")
                (root / "settings.json").write_text('{"port":8000,"host":"localhost"}\n')
                (root / ".pmai").mkdir()
                (root / ".pmai/settings.json").write_text(json.dumps({"debug": True}))
                config = {
                    "defaultAgent": "probe",
                    "providers": [{"id": "probe", "kind": "openai", "baseURL": args.base_url,
                                   "apiKeyEnvironment": "PMAI_LIVE_KEY"}],
                    "agents": [{"id": "probe", "provider": "probe", "model": args.model,
                                "instructions": "You are a helpful, concise assistant. Use the available tools to complete the task.",
                                "toolGroupNames": ["files", "run"], "toolCallingStrategy": args.strategy,
                                "useToolProxy": args.proxy, "toolDelegation": "inline", "stream": stream,
                                "options": {"temperature": args.temperature, "maxOutputTokens": 2048},
                                "limits": {"maxModelTurns": 6, "maxToolCalls": 8, "maxSubagents": 0},
                                "retry": {"attempts": 0}}],
                    "toolSources": [{"id": "standard", "kind": "standard-tools",
                                     "options": {"filesRoot": str(root), "filesWriteEnabled": True,
                                                 "runShell": "/bin/sh"}}],
                    "memory": {"enabled": False}, "use": {"plan": False, "agentsmd": False},
                    "ui": {"markdown": False, "tools": -1},
                }
                config_path = root / "config.json"
                config_path.write_text(json.dumps(config, indent=2))
                started = time.monotonic()
                error = None
                try:
                    run = subprocess.run([str(args.binary.resolve()), "--config", str(config_path),
                                          "--home", str(root / "home"), "--tool-approval", "yolo",
                                          "--no-markdown", prompt], cwd=root, env=env,
                                         capture_output=True, text=True, timeout=180)
                    output = run.stdout + "\n" + run.stderr
                    (root / "cli.txt").write_text(output)
                    log = root / ".pmai/debug.jsonl"
                    events = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
                    passed = run.returncode == 0 and check(name, root, run.stdout, events)
                    if run.returncode:
                        error = run.stderr[-1000:]
                except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
                    passed, error = False, str(exc)
                result = {"case": name, "stream": stream, "repeat": repeat + 1,
                          "passed": passed, "seconds": round(time.monotonic() - started, 2), "error": error}
                results.append(result)
                (destination / "results.json").write_text(json.dumps(results, indent=2))
                print(f'{"PASS" if passed else "FAIL"} stream={stream} {name} ({result["seconds"]}s)', flush=True)
    print(f'{sum(r["passed"] for r in results)}/{len(results)} passed; artifacts: {destination}')
    return 0 if all(r["passed"] for r in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
