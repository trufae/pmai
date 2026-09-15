#!/usr/bin/env python3
"""Run pmai over the sample coding workflows in test/cases and record everything.

Usage:
  python3 test/bench/run.py [--variant inline|proxy|subagent] [--model NAME]
                           [--run-id ID] [--timeout SEC] [--system FILE]
                           [--plan on|off] [--repeat N] [case ...]

Each case lives in test/cases/<case>/ with:
  prompt.txt   the user message
  fixture/     the project files copied into a fresh working directory
  setup.sh     optional, run inside the working directory before pmai
  check.sh     optional, run afterwards; exit 0 means the task was solved
               (env: FIXTURE, STDOUT, WORK)

Results land in test/results/<run-id>/<case>/:
  work/        the working directory after the run
  proxy.jsonl  one JSON line per model call (request, response, usage, timing)
  stdout.txt, stderr.txt, meta.json

The upstream endpoint and key are read from UPSTREAM / UPSTREAM_KEY, falling
back to env-ollamacloud.sh at the repository root.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CASES = ROOT / "test" / "cases"
RESULTS = ROOT / "test" / "results"
PROXY = Path(__file__).resolve().parent / "proxy.py"

DEFAULT_INSTRUCTIONS = "You are a helpful assistant. Use tools when needed."


def read_env_file():
    values = {}
    path = ROOT / "env-ollamacloud.sh"
    if path.exists():
        for line in path.read_text().splitlines():
            match = re.match(r"\s*export\s+([A-Z_]+)=(.*)", line)
            if match:
                values[match.group(1)] = match.group(2).strip().strip('"').strip("'")
    return values


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def wait_port(port, timeout=10):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.5):
                return True
        except OSError:
            time.sleep(0.1)
    return False


def make_config(port, model, variant, instructions, strategy="automatic", context="cache", plan=True):
    groups = ["files", "run", "todo"]
    agent = {
        "id": "coder",
        "displayName": "Coder",
        "instructions": instructions,
        "provider": "bench",
        "model": model,
        "toolGroupNames": groups,
        "toolCallingStrategy": strategy,
        "context": context,
        "useToolProxy": variant in ("proxy", "hybrid"),
        "toolDelegation": "subagent" if variant == "subagent" else "inline",
        "limits": {
            "maxModelTurns": 40,
            "maxToolCalls": 40,
            "maxSubagents": 4 if variant == "subagent" else 0,
            "maxSubagentDepth": 2,
        },
        "enabled": True,
    }
    if variant == "subagent":
        agent["toolGroupNames"] = groups + ["agents"]
    if variant == "proxy":
        agent["proxyExposedTools"] = []  # the pure proxy; "hybrid" keeps the default exposed set
    return {
        "version": 1,
        "defaultAgent": "coder",
        "providers": [
            {
                "id": "bench",
                "kind": "openAICompatible",
                "displayName": "bench proxy",
                "baseURL": f"http://127.0.0.1:{port}/v1",
                "apiKey": "proxy",
            }
        ],
        "toolSources": [
            {
                "id": "standard-tools",
                "kind": "standard-tools",
                "options": {
                    "filesRoot": ".",
                    "filesWriteEnabled": True,
                    "runShell": "/bin/sh",
                    "runPython": "python3",
                    "runTimeoutSeconds": 120,
                },
            }
        ],
        "agents": [agent],
        "ui": {"markdown": False, "toolResultLines": -1},
        "use": {"plan": plan},
        "approvals": {"confirm": "allow", "dangerous": "allow", "yolo": True},
        "memory": {"enabled": False, "scope": "project"},
    }


def file_digests(root):
    digests = {}
    for path in Path(root).rglob("*"):
        if path.is_file() and ".pmai" not in path.parts and ".git" not in path.parts:
            rel = str(path.relative_to(root))
            digests[rel] = hashlib.md5(path.read_bytes()).hexdigest()
    return digests


def clean_env():
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("PMAI_", "MAI_", "OPENAI_"))}
    return env


def run_case(name, args, upstream, key):
    case_dir = CASES / name
    prompt = (case_dir / "prompt.txt").read_text().strip()
    out_dir = RESULTS / args.run_id / name
    if out_dir.exists():
        shutil.rmtree(out_dir)
    work = out_dir / "work"
    shutil.copytree(case_dir / "fixture", work)
    (out_dir / "home").mkdir()
    (out_dir / "state").mkdir()
    setup = case_dir / "setup.sh"
    if setup.exists():
        subprocess.run(["/bin/sh", str(setup)], cwd=work, check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    before = file_digests(work)

    instructions = DEFAULT_INSTRUCTIONS
    if args.system:
        instructions = Path(args.system).read_text().strip()
    port = free_port()
    log = out_dir / "proxy.jsonl"
    config = make_config(port, args.model, args.variant, instructions, args.strategy, args.context,
                         args.plan == "on")
    config_path = out_dir / "pmai.json"
    config_path.write_text(json.dumps(config, indent=2))

    proxy_env = dict(os.environ, UPSTREAM=upstream, UPSTREAM_KEY=key, LOG=str(log), PORT=str(port))
    proxy = subprocess.Popen([sys.executable, str(PROXY)], env=proxy_env,
                             stdout=subprocess.DEVNULL, stderr=open(out_dir / "proxy.err", "w"))
    if not wait_port(port):
        proxy.kill()
        raise SystemExit("proxy did not start")

    env = clean_env()
    env["PMAI_HOME"] = str(out_dir / "home")
    cmd = [str(args.pmai), "--config", str(config_path), "--state", str(out_dir / "state"),
           "--agent", "coder", "--yolo", "--no-markdown", prompt]
    started = time.time()
    timed_out = False
    with open(out_dir / "stdout.txt", "wb") as out, open(out_dir / "stderr.txt", "wb") as err:
        try:
            proc = subprocess.run(cmd, cwd=work, env=env, stdout=out, stderr=err,
                                  stdin=subprocess.DEVNULL, timeout=args.timeout)
            code = proc.returncode
        except subprocess.TimeoutExpired:
            timed_out = True
            code = -1
    elapsed = time.time() - started
    time.sleep(2)  # let the proxy finish logging the last streamed call
    proxy.terminate()
    try:
        proxy.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proxy.kill()

    after = file_digests(work)
    changed = sorted(k for k in after if before.get(k) != after[k])
    removed = sorted(k for k in before if k not in after)

    check = case_dir / "check.sh"
    check_result = None
    check_output = ""
    if check.exists():
        cenv = dict(os.environ, FIXTURE=str(case_dir / "fixture"),
                    STDOUT=str(out_dir / "stdout.txt"), WORK=str(work))
        res = subprocess.run(["/bin/sh", str(check)], cwd=work, env=cenv,
                             capture_output=True, text=True, timeout=120)
        check_result = res.returncode == 0
        check_output = (res.stdout + res.stderr).strip()[-2000:]

    meta = {
        "case": name,
        "variant": args.variant,
        "strategy": args.strategy,
        "context": args.context,
        "plan": args.plan,
        "model": args.model,
        "prompt": prompt,
        "instructions": instructions,
        "elapsed": round(elapsed, 1),
        "exit_code": code,
        "timed_out": timed_out,
        "changed_files": changed,
        "removed_files": removed,
        "check": check_result,
        "check_output": check_output,
    }
    (out_dir / "meta.json").write_text(json.dumps(meta, indent=2))
    calls = sum(1 for _ in open(log)) if log.exists() else 0
    status = "PASS" if check_result else ("FAIL" if check_result is False else "n/a")
    print(f"{name:24s} {status:4s} calls={calls:3d} {elapsed:6.1f}s changed={len(changed)} exit={code}"
          + (" TIMEOUT" if timed_out else ""), flush=True)
    return meta


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("cases", nargs="*")
    parser.add_argument("--variant", default="inline", choices=["inline", "proxy", "hybrid", "subagent"])
    parser.add_argument("--model")
    parser.add_argument("--run-id")
    parser.add_argument("--timeout", type=int, default=900)
    parser.add_argument("--system", help="file with agent instructions replacing the default")
    parser.add_argument("--context", default="cache", choices=["cache", "size"],
                        help="context mode of the agent: cache keeps every message, size prunes read files")
    parser.add_argument("--plan", default="on", choices=["on", "off"],
                        help="use.plan: ask an agent with children to plan a multi-step request first")
    parser.add_argument("--repeat", type=int, default=1,
                        help="run every case N times, under run ids <run-id>-r1 … <run-id>-rN")
    parser.add_argument("--strategy", default="automatic",
                        choices=["automatic", "native", "text", "xml", "json"],
                        help="toolCallingStrategy of the agent")
    args = parser.parse_args()
    if os.environ.get("PMAI_BIN"):
        args.pmai = Path(os.environ["PMAI_BIN"]).resolve()
    else:
        bin_path = subprocess.check_output(
            ["swift", "build", "--package-path", str(ROOT / "MaiCore"), "--show-bin-path"],
            text=True).strip()
        args.pmai = Path(bin_path) / "pmai"

    envfile = read_env_file()
    upstream = os.environ.get("UPSTREAM") or envfile.get("PMAI_BASE_URL", "https://ollama.com/v1")
    key = os.environ.get("UPSTREAM_KEY") or envfile.get("PMAI_API_KEY", "")
    args.model = args.model or envfile.get("PMAI_MODEL", "gemma4:31b")
    args.run_id = args.run_id or time.strftime("%Y%m%d-%H%M%S") + f"-{args.variant}-{args.strategy}-plan{args.plan}-{args.model.replace(':', '_').replace('/', '_')}"
    if not args.pmai.exists():
        raise SystemExit(f"pmai binary not found at {args.pmai}; build with swift build --package-path MaiCore --product pmai")

    names = args.cases or sorted(p.name for p in CASES.iterdir() if (p / "prompt.txt").exists())
    base_id = args.run_id
    for round_index in range(1, args.repeat + 1):
        args.run_id = base_id if args.repeat == 1 else f"{base_id}-r{round_index}"
        print(f"run {args.run_id}: model={args.model} variant={args.variant} strategy={args.strategy} "
              f"plan={args.plan} cases={len(names)}", flush=True)
        metas = [run_case(name, args, upstream, key) for name in names]
        (RESULTS / args.run_id / "run.json").write_text(json.dumps(metas, indent=2))
        print(f"results in {RESULTS / args.run_id}")


if __name__ == "__main__":
    main()
