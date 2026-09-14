#!/usr/bin/env python3
"""Exercise paged web fetch through the release CLI and real HTTP transport."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


BODY = ("discardable source data\n" * 100_000 + "needle-🦊\n}\n}\n").encode()


class Server(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        self.protocol_version = "HTTP/1.1"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Connection", "close")
        if self.path == "/oversize":
            self.send_header("Content-Length", "16000001")
            self.end_headers()
            return
        self.server.fetches += 1
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        for offset in range(0, len(BODY), 16_384):
            chunk = BODY[offset:offset + 16_384]
            self.wfile.write(f"{len(chunk):x}\r\n".encode() + chunk + b"\r\n")
        self.wfile.write(b"0\r\n\r\n")

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        results = []
        for message in request["messages"]:
            if message["role"] == "tool":
                value = message.get("content", "")
                results.append(value if isinstance(value, str) else "\n".join(
                    part.get("text", "") for part in value))
        try:
            if not results:
                arguments = {"url": f"http://127.0.0.1:{self.server.server_port}/source", "max_bytes": 0}
            elif len(results) == 1:
                assert len(results[0]) < 1500 and "discardable source data" not in results[0], results[0]
                source = re.search(r"source_id: ([A-Za-z0-9-]+)", results[0])
                assert source, results[0]
                arguments = {"source_id": source[1], "query": "needle", "max_bytes": 100}
            elif len(results) == 2:
                assert "needle-🦊\n}\n}\n" in results[1], results[1]
                assert "�" not in results[1], results[1]
                arguments = {"url": f"http://127.0.0.1:{self.server.server_port}/oversize", "max_bytes": 0}
            else:
                assert len(results) == 3, results
                assert "16000000-byte download limit" in results[2], results[2]
                assert self.server.fetches == 1, self.server.fetches
                arguments = None
            if arguments is None:
                message = {"role": "assistant", "content": "web fetch smoke passed"}
            else:
                message = {"role": "assistant", "content": None, "tool_calls": [{
                    "id": f"fetch-{len(results)}", "type": "function",
                    "function": {"name": "web_fetch", "arguments": json.dumps(arguments)},
                }]}
            payload = {"choices": [{"message": message, "finish_reason": "tool_calls" if arguments else "stop"}]}
            status = 200
        except AssertionError as error:
            self.server.errors.append(str(error))
            payload, status = {"error": {"message": str(error)}}, 500
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def main():
    executable = str(Path(sys.argv[1]).resolve())
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(("PMAI_", "MAI_", "OPENAI_"))
                   and key.lower() not in ("http_proxy", "https_proxy", "all_proxy")}
    environment["NO_PROXY"] = "127.0.0.1,localhost"
    server = ThreadingHTTPServer(("127.0.0.1", 0), Server)
    server.fetches, server.errors = 0, []
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix="pmai-web-fetch-") as directory:
            root = Path(directory)
            config = root / "config.json"
            config.write_text(json.dumps({
                "version": 1, "defaultAgent": "smoke",
                "providers": [{"id": "smoke", "kind": "openAICompatible", "apiKey": "smoke",
                               "baseURL": f"http://127.0.0.1:{server.server_port}/v1", "timeout": 10}],
                "toolSources": [{"id": "standard", "kind": "standard-tools", "options": {"tools": ["web_fetch"]}}],
                "agents": [{"id": "smoke", "provider": "smoke", "model": "smoke", "enabled": True,
                            "toolNames": ["web_fetch"], "toolGroupNames": ["web"],
                            "retry": {"attempts": 0}}],
                "memory": {"enabled": False, "scope": "project"}, "use": {"plan": False},
            }))
            result = subprocess.run([executable, "--config", str(config), "--home", str(root / "home"),
                                     "--no-stream", "--no-markdown", "-y", "extract the needle"],
                                    cwd=root, env=environment, stdin=subprocess.DEVNULL,
                                    capture_output=True, text=True, timeout=60)
            output = result.stdout + result.stderr
            assert result.returncode == 0 and "web fetch smoke passed" in output, output
            assert not server.errors, server.errors
            assert server.fetches == 1, server.fetches
            print("PASS metadata-only fetch, chunked >2 MB source, cached UTF-8 search, download limit")
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
