#!/usr/bin/env python3
"""Exercise the release CLI's real HTTP stack, optionally under a CPU emulator.

python3 test/linux-network-smoke.py /absolute/path/to/pmai
python3 test/linux-network-smoke.py qemu-x86_64 -cpu Nehalem /absolute/path/to/pmai
"""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from xml.sax.saxutils import escape


def tool_message(request, mode):
    steps = [
        ("files_read_range", {"path": "sample.txt", "start_line": 1e100, "end_line": 2},
         "must be integer" if mode == "native" else "lines 1-2"),
        ("context_rewrite", {"message": 1e100, "text": "replacement"}, "must be integer"),
        ("run_sh", {"script": "printf smoke-shell", "timeout_seconds": 1e100}, "smoke-shell"),
        ("run_sh", {"script": "printf smoke-shell", "timeout_seconds": "inf"},
         "must be number" if mode == "native" else "smoke-shell"),
        ("context_rewrite", {"message": 9223372036854775807, "text": "replacement"},
         "9223372036854775807"),
        # The shell exits before its child closes the output pipe.
        ("run_sh", {"script": "(sleep 0.1; printf smoke-pipe) &"}, "smoke-pipe"),
    ]
    results = [message["content"] for message in request["messages"] if message["role"] == "tool"]
    for result, (_, _, expected) in zip(results, steps):
        assert expected in result, (mode, expected, result)
    if len(results) == len(steps):
        return {"role": "assistant", "content": "tool smoke passed"}
    name, arguments, _ = steps[len(results)]
    if mode == "native":
        return {"role": "assistant", "tool_calls": [{
            "index": 0, "id": f"tool-{len(results)}", "type": "function",
            "function": {"name": name, "arguments": json.dumps(arguments)},
        }]}
    if mode == "text":
        content = "TOOL_CALL\ntool: " + name + "\n"
        content += "\n".join(f"{key}: {value}" for key, value in arguments.items()) + "\nEND_TOOL_CALL"
    elif mode == "xml":
        content = f'<tool_call name="{name}">'
        content += "".join(f'<arg name="{key}">{escape(str(value))}</arg>' for key, value in arguments.items())
        content += "</tool_call>"
    else:
        content = json.dumps({"name": name, "arguments": arguments})
    return {"role": "assistant", "content": content}


class Provider(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        case = self.path.split("/")[1]
        if case == "disconnect":
            self.connection.shutdown(socket.SHUT_RDWR)
            self.connection.close()
            return
        status = 401 if case == "unauthorized" else 200
        usage = {"prompt_tokens": 2, "completion_tokens": 3}
        if case == "range":
            usage["prompt_tokens"] = 1e100
        elif case == "overflow":
            usage["prompt_tokens"] = 9223372036854775807
        elif case == "negative":
            usage["completion_tokens"] = -1
        elif case == "fraction":
            usage["completion_tokens"] = 1.5
        if status == 401:
            payload = {"error": {"message": "smoke unauthorized"}}
        else:
            field = "delta" if request.get("stream") else "message"
            message = {"role": "assistant", "content": "smoke success"}
            if case.startswith("tool-"):
                try:
                    message = tool_message(request, case.removeprefix("tool-"))
                except AssertionError as error:
                    self.send_error(500, str(error))
                    return
            payload = {"choices": [{field: message,
                                     "finish_reason": "stop"}], "usage": usage}
        stream = request.get("stream") and status == 200
        body = json.dumps(payload)
        if stream:
            body = f"data: {body}\n\ndata: [DONE]\n\n"
        if case == "malformed":
            body = "not JSON or SSE"
        body = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/event-stream" if stream else "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    command = sys.argv[1:]
    if not command:
        raise SystemExit(__doc__)
    # Relative executable paths must survive the isolated working directory.
    command[-1] = str(Path(command[-1]).resolve())
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(("PMAI_", "MAI_", "OPENAI_"))
                   and key.lower() not in ("http_proxy", "https_proxy", "all_proxy")}
    environment["NO_PROXY"] = "127.0.0.1,localhost"
    server = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        for stream in (False, True):
            for case in ("ok", "unauthorized", "disconnect", "malformed", "range",
                         "overflow", "negative", "fraction", "tool-text", "tool-xml",
                         "tool-json", "tool-native"):
                with tempfile.TemporaryDirectory(prefix="pmai-network-") as directory:
                    root = Path(directory)
                    (root / "sample.txt").write_text("one\ntwo\n")
                    tools = ["files_read_range", "run_sh", "context_rewrite"] if case.startswith("tool-") else []
                    config = root / "config.json"
                    config.write_text(json.dumps({
                        "version": 1, "defaultAgent": "smoke",
                        "providers": [{"id": "smoke", "kind": "openAICompatible",
                                       "baseURL": f"http://127.0.0.1:{server.server_port}/{case}/v1",
                                       "apiKey": "smoke", "timeout": 5}],
                        "toolSources": [{"id": "standard", "kind": "standard-tools", "options": {"tools": tools}}],
                        "agents": [{"id": "smoke", "provider": "smoke", "model": "smoke",
                                    "toolNames": tools, "toolCallingStrategy": case.removeprefix("tool-") if tools else "automatic",
                                    "toolGroupNames": [], "enabled": True,
                                    "retry": {"attempts": 0}}],
                        "memory": {"enabled": False, "scope": "project"}, "use": {"plan": False},
                    }))
                    args = ["--config", str(config), "--home", str(root / "home"),
                            "--no-markdown", "-y"]
                    if not stream:
                        args.append("--no-stream")
                    result = subprocess.run(command + args + ["hello"], cwd=root,
                                            env=environment, stdin=subprocess.DEVNULL,
                                            capture_output=True, text=True, timeout=60)
                    output = result.stdout + result.stderr
                    expected = 0 if case == "ok" or tools else 1
                    assert result.returncode == expected, (case, stream, result.returncode, output)
                    if case == "ok":
                        assert "smoke success" in output, output
                    elif tools:
                        assert "tool smoke passed" in output, output
                    elif case in ("range", "overflow", "negative", "fraction"):
                        assert "Token usage" in output, output
                    elif case == "unauthorized":
                        assert "smoke unauthorized" in output, output
                    print(f"PASS {case} stream={stream}", flush=True)
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
