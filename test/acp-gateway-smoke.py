#!/usr/bin/env python3
"""WebSocket gateway smoke test, with a deterministic agent and loopback only.
Usage: python3 test/acp-gateway-smoke.py /path/to/pmai
Also exercises the shared URLSession ACPClient through a filtered Swift test.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import time

PMAI = str(Path(sys.argv[1]).resolve())


class WS:
    def __init__(self, port, token, origin=None, path="/acp", accepted=True):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=10)
        self.next_id = 0
        key = base64.b64encode(os.urandom(16)).decode()
        request = (f"GET {path} HTTP/1.1\r\nHost: localhost:{port}\r\nUpgrade: websocket\r\n"
                   f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n"
                   f"Authorization: Bearer {token}\r\n")
        if origin:
            request += f"Origin: {origin}\r\n"
        self.sock.sendall((request + "\r\n").encode())
        response = b""
        while b"\r\n\r\n" not in response:
            chunk = self.sock.recv(1)
            if not chunk:
                break
            response += chunk
        assert (b"101 Switching Protocols" in response) == accepted, response
        if accepted:
            expected = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest())
            assert expected in response
        else:
            self.close()

    def send(self, value, opcode=1, fin=True, masked=True):
        data = json.dumps(value).encode() if not isinstance(value, bytes) else value
        length, maskflag = len(data), 0x80 if masked else 0
        header = bytes([(0x80 if fin else 0) | opcode])
        if length < 126:
            header += bytes([maskflag | length])
        elif length < 65536:
            header += bytes([maskflag | 126]) + struct.pack("!H", length)
        else:
            header += bytes([maskflag | 127]) + struct.pack("!Q", length)
        if masked:
            mask = os.urandom(4)
            header += mask
            data = bytes(byte ^ mask[i % 4] for i, byte in enumerate(data))
        self.sock.sendall(header + data)

    def read(self, count):
        result = b""
        while len(result) < count:
            chunk = self.sock.recv(count - len(result))
            if not chunk:
                raise EOFError("WebSocket closed")
            result += chunk
        return result

    def receive(self):
        while True:
            first, second = self.read(2)
            length = second & 127
            if length == 126:
                length = struct.unpack("!H", self.read(2))[0]
            elif length == 127:
                length = struct.unpack("!Q", self.read(8))[0]
            assert not second & 128
            data = self.read(length)
            opcode = first & 15
            if opcode == 9:
                self.send(data, opcode=10)
            elif opcode == 8:
                raise EOFError("WebSocket closed")
            else:
                return opcode, data

    def rpc(self, method, params=None, fragmented=False):
        self.next_id += 1
        request = {"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params or {}}
        if fragmented:
            data = json.dumps(request).encode()
            self.send(data[:7], fin=False)
            self.send(b"probe", opcode=9)
            assert self.receive() == (10, b"probe")
            self.send(data[7:], opcode=0)
        else:
            self.send(request)
        updates = []
        while True:
            opcode, data = self.receive()
            assert opcode == 1
            message = json.loads(data)
            if message.get("method") == "session/request_permission":
                self.send({"jsonrpc": "2.0", "id": message["id"], "result": {
                    "outcome": {"outcome": "selected", "optionId": "allow_once"}}})
                updates.append(message)
            elif message.get("id") == self.next_id:
                assert "error" not in message, message
                return message["result"], updates
            else:
                updates.append(message)

    def close(self):
        self.sock.close()


FIXTURE = r'''
import json, os, sys
from pathlib import Path
root = Path(sys.argv[1])
(root / (str(os.getpid()) + ".pid")).write_text("")
def send(value):
    value["jsonrpc"] = "2.0"
    print(json.dumps(value), flush=True)
for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    params = message.get("params", {})
    if method == "initialize":
        result = {"protocolVersion": 1, "agentCapabilities": {"loadSession": True}}
    elif method == "session/new":
        result = {"sessionId": "fixture-session"}
    elif method == "session/load":
        send({"method": "session/update", "params": {"sessionId": "fixture-session", "update": {
            "sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "restored"}}}})
        result = {}
    elif method == "session/prompt":
        if params["prompt"][0]["text"] == "exit":
            sys.exit(0)
        send({"id": "permission-1", "method": "session/request_permission", "params": {
            "sessionId": "fixture-session", "toolCall": {"title": "Test tool", "kind": "execute"},
            "options": [{"optionId": "allow_once", "kind": "allow_once", "name": "Allow once"}]}})
        approval = json.loads(next(sys.stdin))
        assert approval["result"]["outcome"]["optionId"] == "allow_once"
        send({"method": "session/update", "params": {"sessionId": "fixture-session", "update": {
            "sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "reply"}}}})
        result = {"stopReason": "end_turn"}
    else:
        result = params
    if "id" in message:
        send({"id": message["id"], "result": result})
'''


def run():
    with tempfile.TemporaryDirectory(prefix="pmai-ws-e2e-") as directory:
        root = Path(directory)
        fixture = root / "agent.py"
        fixture.write_text(FIXTURE)
        token, profile = root / "token", root / "profile.txt"
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
        with (root / "gateway.log").open("w") as log:
            gateway = subprocess.Popen([PMAI, "acp-gateway", "--port", str(port), "--token-file", str(token),
                "--cwd", str(root), "--url", f"ws://localhost:{port}/acp", "--profile", str(profile),
                "--", sys.executable, "-u", str(fixture), str(root)], stdout=log, stderr=log)
            clients = []
            try:
                for _ in range(100):
                    assert gateway.poll() is None, (root / "gateway.log").read_text()
                    try:
                        with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                            break
                    except OSError:
                        time.sleep(0.1)
                credential = token.read_text().strip()
                assert token.stat().st_mode & 0o777 == 0o600
                imported = json.loads(base64.urlsafe_b64decode(profile.read_text().strip().split("/")[-1]))
                assert imported["token"] == credential and imported["cwd"] == str(root)
                if sys.platform == "darwin":
                    subprocess.run(["swift", "test/qr-terminal-smoke.swift", str(root / "gateway.log")],
                                   check=True, timeout=60)
                WS(port, "wrong", accepted=False)
                WS(port, credential, origin="https://untrusted.example", accepted=False)
                WS(port, credential, path="/other", accepted=False)
                assert not list(root.glob("*.pid")), "unauthenticated request spawned an agent"
                print("Authentication, origin/path checks, and credential export: passed", flush=True)
                client = WS(port, credential)
                clients.append(client)
                assert client.rpc("initialize", fragmented=True)[0]["protocolVersion"] == 1
                assert client.rpc("session/new")[0]["sessionId"] == "fixture-session"
                result, updates = client.rpc("session/prompt", {"sessionId": "fixture-session",
                    "prompt": [{"type": "text", "text": "hello"}]})
                assert result["stopReason"] == "end_turn"
                assert any(u.get("method") == "session/request_permission" for u in updates)
                assert any(u.get("method") == "session/update" for u in updates)
                assert client.rpc("echo", {"text": "x" * 200000})[0]["text"] == "x" * 200000
                print("Fragmentation, ping, large messages, streaming, and tool approval: passed", flush=True)
                client.close()
                time.sleep(0.3)
                reconnect = WS(port, credential)
                clients.append(reconnect)
                reconnect.rpc("initialize")
                assert reconnect.rpc("session/load", {"sessionId": "fixture-session"})[1]
                invalid = WS(port, credential)
                clients.append(invalid)
                invalid.send({"jsonrpc": "2.0", "id": 1, "method": "initialize"}, masked=False)
                try:
                    invalid.receive()
                    raise AssertionError("unmasked client frame accepted")
                except (EOFError, ConnectionResetError):
                    pass
                env = dict(os.environ, PMAI_GATEWAY_TEST_URL=f"ws://127.0.0.1:{port}/acp",
                           PMAI_GATEWAY_TEST_TOKEN=credential, PMAI_GATEWAY_TEST_CWD=str(root))
                subprocess.run(["swift", "test", "--package-path", "MaiCore", "--disable-index-store",
                    *(["--skip-build"] if os.environ.get("PMAI_TESTS_BUILT") else []),
                    "--filter", "acpWebSocketIntegration"], env=env, check=True,
                    stdout=log, stderr=log, timeout=300)
                print("Shared URLSession client: connect, prompt, approval, reconnect: passed", flush=True)
                token.write_text("revoked-" + "x" * 64)
                WS(port, credential, accepted=False)
                reconnect.sock.settimeout(45)
                try:
                    reconnect.receive()
                    raise AssertionError("revoked connection stayed open")
                except (EOFError, ConnectionResetError):
                    pass
                print("Token rotation rejects new clients and closes active clients: passed", flush=True)
            except BaseException:
                print((root / "gateway.log").read_text()[-12000:], file=sys.stderr)
                raise
            finally:
                for client in clients:
                    client.close()
                gateway.terminate()
                gateway.wait(timeout=15)
            for file in root.glob("*.pid"):
                try:
                    os.kill(int(file.stem), 0)
                except ProcessLookupError:
                    continue
                raise AssertionError(f"agent {file.stem} survived gateway shutdown")
            print("Agent children cleaned up after disconnect/shutdown: passed", flush=True)


if __name__ == "__main__":
    run()
