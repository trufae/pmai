#!/usr/bin/env python3
"""Run opencode 2 against the same fixtures and logging proxy as run.py."""
import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

from run import CASES, RESULTS, PROXY, clean_env, file_digests, free_port, wait_port


def configuration(port, model):
    return {
        "model": f"bench/{model}",
        "update": "disable",
        "share": "disabled",
        "agents": {"build": {"steps": 40}},
        "permissions": [{"action": "*", "resource": "*", "effect": "allow"}] + [
            {"action": name, "resource": "*", "effect": "deny"}
            for name in ("subagent", "question", "webfetch", "websearch", "codesearch", "skill")
        ],
        "providers": {
            "bench": {
                "name": "Benchmark endpoint",
                "package": "@opencode/ai/providers/openai-compatible",
                "settings": {"baseURL": f"http://127.0.0.1:{port}/v1"},
                "models": {model: {
                    "name": model,
                    "capabilities": {"tools": True, "input": ["text"], "output": ["text"]},
                    "limit": {"context": 131072, "output": 32768},
                }},
            },
        },
    }


def environment(root):
    env = {k: v for k, v in clean_env().items() if not k.startswith("OPENCODE_")}
    # OpenCode prefers PWD over cwd; discard the parent's directory hints.
    for name in ("PWD", "OLDPWD", "INIT_CWD"):
        env.pop(name, None)
    for kind in ("CONFIG", "DATA", "CACHE", "STATE"):
        env[f"XDG_{kind}_HOME"] = str(root / kind.lower())
    env.update({
        "OPENCODE_TEST_HOME": str(root),
        "OPENCODE_CONFIG_DIR": str(root / "config" / "opencode"),
        "OPENCODE_DISABLE_AUTOUPDATE": "1",
        "OPENCODE_DISABLE_MODELS_FETCH": "1",
        "OPENCODE_DISABLE_DEFAULT_PLUGINS": "1",
        "OPENCODE_DISABLE_EXTERNAL_SKILLS": "1",
        "OPENCODE_DISABLE_CLAUDE_CODE": "1",
        "OPENCODE_DISABLE_LSP_DOWNLOAD": "1",
    })
    return env


def run_case(name, args):
    case = CASES / name
    out = RESULTS / args.run_id / name
    out.mkdir(parents=True)  # Refuse to overwrite earlier measurements.
    work = out / "work"
    shutil.copytree(case / "fixture", work)
    subprocess.run(["git", "init", "-q", str(work)], check=True)
    if (case / "setup.sh").exists():
        subprocess.run(["/bin/sh", str(case / "setup.sh")], cwd=work, check=True)
    before = file_digests(work)
    prompt = (case / "prompt.txt").read_text().strip()
    port = free_port()
    log = out / "proxy.jsonl"
    env = environment(out / "home")
    config = Path(env["OPENCODE_CONFIG_DIR"]) / "opencode.json"
    config.parent.mkdir(parents=True)
    config.write_text(json.dumps(configuration(port, args.model), indent=2))
    version = subprocess.check_output([args.binary, "--version"], cwd=work, env=env, text=True).strip()
    proxy_env = dict(env, UPSTREAM=args.upstream, UPSTREAM_KEY="", LOG=str(log), PORT=str(port))
    with (out / "proxy.err").open("w") as proxy_errors:
        proxy = subprocess.Popen([sys.executable, str(PROXY)], env=proxy_env,
                                 stdout=subprocess.DEVNULL, stderr=proxy_errors)
        try:
            if not wait_port(port):
                raise RuntimeError("Benchmark proxy failed to start")
            command = [args.binary, "run", "--standalone", "--auto", "--format", "json",
                       "--model", f"bench/{args.model}", "--agent", "build",
                       "--title", name]
            started = time.monotonic()
            timed_out = False
            with (out / "stdout.txt").open("w") as stdout, (out / "stderr.txt").open("w") as stderr:
                process = subprocess.Popen(command, cwd=work, env=env, stdin=subprocess.PIPE,
                                           stdout=stdout, stderr=stderr, start_new_session=True)
                try:
                    # stdin preserves the exact prompt; positional arguments are shell-quoted by the CLI.
                    process.communicate(prompt.encode(), timeout=args.timeout)
                except subprocess.TimeoutExpired:
                    timed_out = True
                finally:
                    if process.poll() is None:
                        os.killpg(process.pid, signal.SIGKILL)
                    code = process.wait()
            elapsed = time.monotonic() - started
            time.sleep(2)  # Match run.py: allow the last streamed request to be logged.
        finally:
            proxy.terminate()
            proxy.wait(timeout=5)
    after = file_digests(work)
    check = subprocess.run(["/bin/sh", str(case / "check.sh")], cwd=work,
                           env=dict(env, FIXTURE=str(case / "fixture"), WORK=str(work),
                                    STDOUT=str(out / "stdout.txt")),
                           capture_output=True, text=True, timeout=120)
    meta = {
        "client": "opencode", "version": version, "variant": "build",
        "case": name, "model": args.model,
        "prompt": prompt, "instructions": "opencode built-in build agent",
        "command": command, "elapsed": round(elapsed, 1), "exit_code": code,
        "timed_out": timed_out, "check": check.returncode == 0,
        "check_output": (check.stdout + check.stderr).strip()[-2000:],
        "changed_files": sorted(k for k in after if before.get(k) != after[k]),
        "removed_files": sorted(k for k in before if k not in after),
    }
    (out / "meta.json").write_text(json.dumps(meta, indent=2))
    print(f"{name}: {'PASS' if meta['check'] else 'FAIL'}, {elapsed:.1f}s, exit={code}", flush=True)
    return meta


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cases", nargs="+")
    parser.add_argument("--binary", default=shutil.which("opencode"))
    parser.add_argument("--model", required=True)
    parser.add_argument("--upstream", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args()
    if not args.binary:
        parser.error("opencode was not found; install it or pass --binary")
    results = [run_case(name, args) for name in args.cases]
    (RESULTS / args.run_id / "run.json").write_text(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
