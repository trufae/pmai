#!/usr/bin/env python3
"""Logging forward proxy for Chat Completions, Responses, and Messages APIs.

Sits between pmai and the real endpoint. Every request body and the assembled
normalized response (streamed or not) are appended as one JSON line to LOG, so a run can be
studied offline: exact messages, tool schemas, tool calls, usage, timings.

Environment:
  UPSTREAM      base URL of the real endpoint, e.g. https://ollama.com/v1
  UPSTREAM_KEY  bearer token added to every upstream request
  LOG           path of the JSONL log
  PORT          listen port (default 8765)
"""
import http.client
import json
import os
import ssl
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

UPSTREAM = os.environ.get("UPSTREAM", "https://ollama.com/v1").rstrip("/")
UPSTREAM_KEY = os.environ.get("UPSTREAM_KEY", "")
LOG = os.environ.get("LOG", "proxy.jsonl")
PORT = int(os.environ.get("PORT", "8765"))

_lock = threading.Lock()
_seq = 0


def _log(record):
    global _seq
    with _lock:
        _seq += 1
        record["seq"] = _seq
        with open(LOG, "a") as fh:
            fh.write(json.dumps(record) + "\n")


def _upstream_conn():
    parts = urlsplit(UPSTREAM)
    if parts.scheme == "https":
        return http.client.HTTPSConnection(parts.hostname, parts.port or 443, timeout=600,
                                           context=ssl.create_default_context())
    return http.client.HTTPConnection(parts.hostname, parts.port or 80, timeout=600)


def _upstream_path(local_path):
    base = urlsplit(UPSTREAM).path.rstrip("/")
    # pmai sends /v1/chat/completions when baseURL ends in /v1; keep everything after /v1.
    rest = local_path
    if rest.startswith("/v1"):
        rest = rest[3:]
    return base + rest


class Assembler:
    """Folds streamed chat.completion.chunk objects into one message."""

    def __init__(self):
        self.content = []
        self.reasoning = []
        self.tool_calls = {}
        self.finish_reason = None
        self.usage = None
        self.chunks = 0
        self.first_at = None

    def feed(self, obj):
        self.chunks += 1
        if self.first_at is None:
            self.first_at = time.time()
        if obj.get("usage"):
            self.usage = obj["usage"]
        for choice in obj.get("choices", []) or []:
            delta = choice.get("delta") or choice.get("message") or {}
            if delta.get("content"):
                self.content.append(delta["content"])
            for key in ("reasoning", "reasoning_content"):
                if delta.get(key):
                    self.reasoning.append(delta[key])
            for tc in delta.get("tool_calls") or []:
                idx = tc.get("index", 0)
                slot = self.tool_calls.setdefault(idx, {"id": None, "name": "", "arguments": ""})
                if tc.get("id"):
                    slot["id"] = tc["id"]
                fn = tc.get("function") or {}
                if fn.get("name"):
                    slot["name"] += fn["name"]
                if fn.get("arguments"):
                    slot["arguments"] += fn["arguments"]
            if choice.get("finish_reason"):
                self.finish_reason = choice["finish_reason"]

    def message(self):
        return {
            "content": "".join(self.content),
            "reasoning": "".join(self.reasoning),
            "tool_calls": [self.tool_calls[k] for k in sorted(self.tool_calls)],
            "finish_reason": self.finish_reason,
            "usage": self.usage,
            "chunks": self.chunks,
        }


def token_usage(usage):
    """Normalize usage for reports while retaining the original API fields."""
    return dict(usage,
                prompt_tokens=sum(usage.get(k, 0) for k in
                                  ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens")),
                completion_tokens=usage.get("output_tokens", 0))


class ResponsesAssembler(Assembler):
    def __init__(self):
        super().__init__()
        self.items = {}

    def feed(self, obj):
        self.chunks += 1
        self.first_at = self.first_at or time.time()
        if obj.get("type") == "response.output_item.done":
            self.items[obj["output_index"]] = obj["item"]
        response = obj if obj.get("object") == "response" else obj.get("response", {})
        if response.get("status") in ("completed", "incomplete", "failed"):
            self.items = dict(enumerate(response.get("output", [])))
            self.finish_reason = response["status"]
            if response.get("usage"):
                self.usage = token_usage(response["usage"])

    def message(self):
        result = super().message()
        for item in self.items.values():
            kind = item.get("type")
            if kind in ("function_call", "custom_tool_call"):
                result["tool_calls"].append({"id": item.get("call_id"), "name": item["name"],
                                             "arguments": item.get("arguments", item.get("input", ""))})
            elif kind == "message":
                result["content"] += "".join(p.get("text", "") for p in item.get("content", []))
            elif kind == "reasoning":
                result["reasoning"] += "".join(p.get("text", "") for p in
                                               item.get("summary", []) + (item.get("content") or []))
        return result


class MessagesAssembler(Assembler):
    def __init__(self):
        super().__init__()
        self.blocks = {}
        self.native_usage = {}

    def feed(self, obj):
        self.chunks += 1
        self.first_at = self.first_at or time.time()
        kind = obj.get("type")
        if kind in ("message", "message_start"):
            message = obj.get("message", obj)
            self.blocks = dict(enumerate(message.get("content", [])))
            self.native_usage.update(message.get("usage", {}))
            self.finish_reason = message.get("stop_reason")
        elif kind == "content_block_start":
            self.blocks[obj["index"]] = dict(obj["content_block"])
        elif kind == "content_block_delta":
            block = self.blocks[obj["index"]]
            delta = obj["delta"]
            for key in ("text", "thinking", "partial_json"):
                if key in delta:
                    block[key] = block.get(key, "") + delta[key]
        elif kind == "message_delta":
            self.native_usage.update(obj.get("usage", {}))
            self.finish_reason = obj.get("delta", {}).get("stop_reason")
        if self.native_usage:
            self.usage = token_usage(self.native_usage)

    def message(self):
        result = super().message()
        for block in self.blocks.values():
            result["content"] += block.get("text", "")
            result["reasoning"] += block.get("thinking", "")
            if block["type"] == "tool_use":
                result["tool_calls"].append({"id": block["id"], "name": block["name"],
                    "arguments": block.get("partial_json", json.dumps(block.get("input", {})))})
        return result


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # quiet
        pass

    def handle(self):
        try:
            super().handle()
        except (ConnectionResetError, BrokenPipeError):
            pass  # pmai closes idle keep-alive sockets; nothing to log

    def do_GET(self):
        self._forward(None)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        self._forward(body)

    def _forward(self, body):
        started = time.time()
        try:
            req_json = json.loads(body) if body else None
        except Exception:
            req_json = None
        conn = _upstream_conn()
        headers = {"Content-Type": "application/json", "Accept": self.headers.get("Accept", "*/*")}
        for key in ("anthropic-version", "anthropic-beta"):
            if self.headers.get(key):
                headers[key] = self.headers[key]
        if UPSTREAM_KEY:
            headers["Authorization"] = f"Bearer {UPSTREAM_KEY}"
        try:
            conn.request(self.command, _upstream_path(self.path), body=body, headers=headers)
            resp = conn.getresponse()
        except Exception as exc:
            self.send_response(502)
            self.send_header("Content-Type", "application/json")
            msg = json.dumps({"error": {"message": f"proxy: {exc}"}}).encode()
            self.send_header("Content-Length", str(len(msg)))
            self.end_headers()
            self.wfile.write(msg)
            _log({"t": started, "path": self.path, "request": req_json, "error": str(exc)})
            return

        ctype = resp.getheader("Content-Type", "")
        streaming = "text/event-stream" in ctype
        self.send_response(resp.status)
        for key, value in resp.getheaders():
            if key.lower() in ("content-length", "transfer-encoding", "connection"):
                continue
            self.send_header(key, value)
        route = urlsplit(self.path).path
        assembler = (ResponsesAssembler if route.endswith("/responses") else
                     MessagesAssembler if route.endswith("/messages") else Assembler)
        asm = assembler()
        raw_error = None
        if streaming:
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            buffer = b""
            while True:
                data = resp.read1(65536) if hasattr(resp, "read1") else resp.read(65536)
                if not data:
                    break
                try:
                    self.wfile.write(b"%x\r\n" % len(data) + data + b"\r\n")
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    pass
                buffer += data
                while b"\n" in buffer:
                    line, buffer = buffer.split(b"\n", 1)
                    line = line.strip()
                    if not line.startswith(b"data:"):
                        continue
                    payload = line[5:].strip()
                    if payload == b"[DONE]":
                        continue
                    try:
                        asm.feed(json.loads(payload))
                    except Exception:
                        pass
            try:
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
        else:
            data = resp.read()
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            try:
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                pass
            try:
                obj = json.loads(data)
                if resp.status >= 400:
                    raw_error = obj
                else:
                    asm.feed(obj)
            except Exception:
                raw_error = data[:2000].decode("utf-8", "replace")
        ended = time.time()
        record = {
            "t": started,
            "elapsed": round(ended - started, 3),
            "first_token": round(asm.first_at - started, 3) if asm.first_at else None,
            "path": self.path,
            "status": resp.status,
            "stream": streaming,
            "request": req_json,
            "response": asm.message(),
        }
        if raw_error is not None:
            record["error"] = raw_error
        _log(record)


def main():
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    server.daemon_threads = True
    print(f"proxy listening on 127.0.0.1:{PORT} -> {UPSTREAM} log={LOG}", file=sys.stderr, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
