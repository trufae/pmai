#!/usr/bin/env python3
"""Real Tailcat integration smoke test; uses its local test DERP and offline hello.
Usage: python3 test/tailcat-smoke.py /path/to/pmai /path/to/tailcat
No real configuration, credentials, public relay, or model endpoint is used.
"""
import base64
import importlib.util
import json
import os
from pathlib import Path
import queue
import socket
import subprocess
import sys
import tempfile
import threading
import time

PMAI, TAILCAT = map(lambda p: str(Path(p).resolve()), sys.argv[1:3])
ENV = {k: v for k, v in os.environ.items() if not k.startswith(("PMAI_", "MAI_", "OPENAI_", "TAILCAT_"))}
ENV["TS_DEBUG_TAILCAT_LOCAL_DERP"] = "true"


def command(args, cwd, **kwargs):
    result = subprocess.run(args, cwd=cwd, env=ENV, capture_output=True, text=True, timeout=45, **kwargs)
    if result.returncode:
        raise AssertionError(result.stderr)
    return result.stdout


class RPC:
    def __init__(self, args, cwd):
        self.process = subprocess.Popen(args, cwd=cwd, env=ENV, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
        self.messages = queue.Queue()
        self.updates = []
        self.next_id = 0
        def reader():
            for line in self.process.stdout:
                try:
                    self.messages.put(json.loads(line))
                except ValueError:
                    self.messages.put({"invalid": line})
            self.messages.put(None)
        threading.Thread(target=reader, daemon=True).start()

    def request(self, method, params=None, error=False):
        self.next_id += 1
        self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params or {}}) + "\n")
        self.process.stdin.flush()
        while True:
            msg = self.messages.get(timeout=20)
            assert msg is not None, "connection closed unexpectedly"
            assert "invalid" not in msg, msg
            if msg.get("id") == self.next_id:
                assert ("error" in msg) == error, msg
                return msg.get("error") if error else msg["result"]
            self.updates.append(msg)

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=5)


with tempfile.TemporaryDirectory(prefix="pmai-tailcat-e2e-") as directory:
    root = Path(directory)
    workspace, worker_home, client_home = (root / name for name in ("workspace", "worker", "client"))
    workspace.mkdir()
    state = worker_home / "tailcat"
    state.mkdir(parents=True)
    command([TAILCAT, "genkey", "--key=" + str(state / "worker.private.json"), "--region=1"], root)
    config = root / "worker.json"
    config.write_text(json.dumps({"version": 1, "defaultAgent": "main", "use": {"agentsmd": False},
        "providers": [{"id": "hello", "kind": "hello"}],
        "agents": [{"id": "main", "provider": "hello", "model": "hello", "instructions": "Be concise."}]}))
    png = root / "invite.png"
    qr_args = ["--qr", str(png)] if sys.platform == "darwin" else []
    with (root / "worker.log").open("w") as log:
        worker = subprocess.Popen([PMAI, "tailcat", "serve", "--home", str(worker_home), "--tailcat", TAILCAT,
            *qr_args, "--", "--config", str(config), "--provider", "hello", "--model", "hello"],
            cwd=workspace, env=ENV, stdout=log, stderr=log)
        connections = []
        try:
            deadline = time.monotonic() + 65
            while time.monotonic() < deadline:
                assert worker.poll() is None, (root / "worker.log").read_text()
                try:
                    registry = json.loads((state / "registry.json").read_text())
                    invite = registry["worker"]["invite"]
                    if invite and (not qr_args or png.exists()):
                        break
                except (FileNotFoundError, KeyError):
                    pass
                time.sleep(0.1)
            else:
                raise AssertionError("worker startup timed out: " + (root / "worker.log").read_text())
            text = root / "invite.txt"
            text.write_text("pmai-tailcat://pair/" + base64.urlsafe_b64encode(json.dumps(invite).encode()).decode().rstrip("="))
            client_config = root / "client.json"
            command([PMAI, "tailcat", "pair", "worker", str(png if qr_args else text), "--home", str(client_home),
                "--tailcat", TAILCAT, "--config", str(client_config)], root)
            print("QR/URI pairing and ACP agent registration: passed")
            status = json.loads(command([PMAI, "tailcat", "status", "worker", "--home", str(client_home), "--tailcat", TAILCAT], root))
            assert status["workerID"] == invite["workerID"]
            result = command([PMAI, "--config", str(client_config), "--home", str(client_home), "--agent", "worker",
                "--provider", "worker", "--model", "remote", "integration smoke"], root)
            assert "integration smoke" in result, result
            print("Remote pmai provider and worker heartbeat: passed")
            args = [PMAI, "tailcat", "connect", "worker", "--home", str(client_home), "--tailcat", TAILCAT]
            # The phone-facing gateway also works when its fixed upstream is a
            # paired Tailcat worker, with no Go code in the WebSocket client.
            spec = importlib.util.spec_from_file_location("gateway_smoke", Path(__file__).with_name("acp-gateway-smoke.py"))
            gateway_test = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(gateway_test)
            with socket.socket() as probe:
                probe.bind(("127.0.0.1", 0))
                port = probe.getsockname()[1]
            token = root / "gateway-token"
            gateway = subprocess.Popen([PMAI, "acp-gateway", "--port", str(port), "--token-file", str(token),
                "--cwd", str(workspace), "--", *args], cwd=root, env=ENV, stdout=log, stderr=log)
            ws = None
            try:
                for _ in range(100):
                    assert gateway.poll() is None
                    try:
                        with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                            break
                    except OSError:
                        time.sleep(0.1)
                ws = gateway_test.WS(port, token.read_text().strip())
                ws.rpc("initialize", {"protocolVersion": 1})
                remote_session = ws.rpc("session/new", {"cwd": str(workspace), "mcpServers": []})[0]["sessionId"]
                _, updates = ws.rpc("session/prompt", {"sessionId": remote_session,
                    "prompt": [{"type": "text", "text": "websocket through tailcat"}]})
                assert any("websocket through tailcat" in json.dumps(update) for update in updates)
                print("WebSocket gateway -> Tailcat -> pmai worker prompt: passed")
            finally:
                if ws:
                    ws.close()
                gateway.terminate()
                gateway.wait(timeout=15)
            rpc = RPC(args, root)
            connections.append(rpc)
            rpc.request("initialize", {"protocolVersion": 1})
            created = rpc.request("session/new", {"cwd": str(workspace), "mcpServers": []})
            sid = created["sessionId"]
            rpc.request("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": "keep this conversation"}]})
            rpc.close()
            connections.remove(rpc)
            resumed = RPC(args, root)
            connections.append(resumed)
            resumed.request("initialize", {"protocolVersion": 1})
            resumed.request("session/load", {"sessionId": sid, "cwd": str(workspace), "mcpServers": []})
            assert any("keep this conversation" in json.dumps(update) for update in resumed.updates)
            resumed.request("session/new", {"cwd": "/etc"}, error=True)
            print("Session recovery and workspace boundary: passed")
            stranger_key = root / "stranger.private.json"
            command([TAILCAT, "genkey", "--client", "--key=" + str(stranger_key)], root)
            stranger = RPC([TAILCAT, "--key=" + str(stranger_key), invite["address"], "80"], root)
            connections.append(stranger)
            stranger.request("initialize", {"protocolVersion": 1}, error=True)
            stranger.request("_pmai/enroll", {"name": "stranger", "token": invite["token"]}, error=True)
            print("Unknown identity and invite replay rejected: passed")
            peers = json.loads((state / "registry.json").read_text())["worker"]["peers"]
            command([PMAI, "tailcat", "revoke", peers[0]["id"], "--home", str(worker_home)], root)
            deadline = time.monotonic() + 8
            while resumed.process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.1)
            assert resumed.process.poll() is not None, "revoked connection remained open"
            print("Revocation closes an existing connection: passed")
        finally:
            for connection in connections:
                connection.close()
            worker.terminate()
            try:
                worker.wait(timeout=10)
            except subprocess.TimeoutExpired:
                worker.kill()
                worker.wait()
