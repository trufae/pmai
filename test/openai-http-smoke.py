#!/usr/bin/env python3
"""Exercise the real CLI HTTP host against an offline audio provider fixture."""
import http.client
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Provider(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def send(self, body, kind="application/json", status=200):
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        key = "models" if self.path.endswith("models") else "voices"
        self.send(json.dumps({"data": [{"id": "whisper-test" if key == "models" else "fixture-voice"}]}).encode())

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        if self.headers.get("Authorization") != "Bearer fixture-key":
            self.send(b'{"error":{"message":"wrong credentials"}}', status=401)
        elif self.path == "/v1/audio/speech":
            payload = json.loads(body)
            if payload["input"] == "fail":
                self.send(b'{"error":{"message":"fixture rate limit"}}', status=429)
                return
            assert payload["model"] == "voice-test"
            self.send(b"RIFF\x00\xff\x80WAVEfixture", "audio/wav")
        elif self.path == "/v1/audio/transcriptions":
            assert b'"model"' in body and b"whisper-test" in body
            assert b"\x00\xff\x80binary" in body
            self.send(b'{"text":"transcribed by fixture"}')
        else:
            self.send(b"{}", status=404)


def main():
    binary = Path(sys.argv[1] if len(sys.argv) > 1 else "MaiCore/.build/debug/pmai").resolve()
    backend = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    threading.Thread(target=backend.serve_forever, daemon=True).start()
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    with tempfile.TemporaryDirectory(prefix="pmai-http-") as directory:
        root = Path(directory)
        config = {"providers": [
            {"id": "hello", "kind": "hello"},
            {"id": "local", "kind": "openai", "baseURL": f"http://127.0.0.1:{backend.server_port}/v1", "apiKey": "fixture-key"},
        ], "defaultAgent": "main", "agents": [{"id": "main", "provider": "hello", "model": "hello", "instructions": ""}]}
        (root / "config.json").write_text(json.dumps(config))
        env = dict(os.environ, PMAI_HTTP_TOKEN="fixture-client-token")
        with (root / "server.log").open("w+") as log:
            process = subprocess.Popen([str(binary), "--config", str(root / "config.json"), "--home", str(root / "home"),
                "--state", str(root / "state"), "--history", str(root / "history"), "--no-markdown"],
                cwd=root, env=env, stdin=subprocess.PIPE, stdout=log, stderr=log)
            process.stdin.write(f"/remote serve --protocol openai --port {port}\n".encode())
            process.stdin.flush()
            def request(path, body=None, kind="application/json", authorized=True):
                connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
                headers = {"Content-Type": kind}
                if authorized:
                    headers["Authorization"] = "Bearer fixture-client-token"
                connection.request("POST" if body is not None else "GET", path, body=body, headers=headers)
                response = connection.getresponse()
                result = (response.status, response.read(), response.getheader("Content-Type"))
                connection.close()
                return result
            try:
                for _ in range(100):
                    try:
                        if request("/health")[0] == 200:
                            break
                    except OSError:
                        time.sleep(0.05)
                    if process.poll() is not None:
                        log.seek(0)
                        raise RuntimeError(log.read())
                else:
                    raise RuntimeError("HTTP server did not start")
                assert request("/health", authorized=False)[0] == 401
                status, data, _ = request("/v1/models")
                assert status == 200 and "local::whisper-test" in [m["id"] for m in json.loads(data)["data"]]
                chat = {"messages": [{"role": "user", "content": "hello"}]}
                status, data, _ = request("/v1/chat/completions", json.dumps(chat))
                assert status == 200 and json.loads(data)["choices"][0]["message"]["content"]
                chat["stream"] = True
                status, data, kind = request("/v1/chat/completions", json.dumps(chat))
                assert status == 200 and kind == "text/event-stream" and b"data: [DONE]" in data
                speech = {"model": "local::voice-test", "input": "hello", "voice": "fixture-voice", "response_format": "wav"}
                status, data, kind = request("/v1/audio/speech", json.dumps(speech))
                assert status == 200 and kind == "audio/wav" and data == b"RIFF\x00\xff\x80WAVEfixture"
                speech["input"] = "fail"
                assert request("/v1/audio/speech", json.dumps(speech))[0] == 429
                status, data, _ = request("/v1/voices?model=local::voice-test")
                assert status == 200 and json.loads(data)["data"][0]["id"] == "fixture-voice"
                form = (b'--fixture\r\nContent-Disposition: form-data; name="model"\r\n\r\nlocal::whisper-test\r\n'
                    b'--fixture\r\nContent-Disposition: form-data; name="file"; filename="test.wav"\r\nContent-Type: audio/wav\r\n\r\n'
                    b'\x00\xff\x80binary\r\n--fixture--\r\n')
                status, data, _ = request("/v1/audio/transcriptions", form, "multipart/form-data; boundary=fixture")
                assert status == 200 and json.loads(data)["text"] == "transcribed by fixture"
                assert request("/v1/audio/transcriptions", b"invalid")[0] == 400
                process.stdin.write(b"/remote status\n/remote stop\n/remote status\n/exit\n")
                process.stdin.flush()
                process.wait(timeout=10)
                log.seek(0)
                output = log.read()
                assert "via OpenAI" in output and "Remote server stopped" in output, output
                assert process.returncode == 0, output
                print("OpenAI HTTP smoke passed: authentication, models, chat, SSE, binary speech, transcription, voices and provider errors.")
            finally:
                if process.poll() is None:
                    process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
    backend.shutdown()


if __name__ == "__main__":
    main()
