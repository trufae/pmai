#!/usr/bin/env python3
"""Exercise /remote serving, project discovery, CLI pairing, and durable sessions."""
import base64
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time

from smoke import clean_environment

PMAI = str(Path(sys.argv[1]).resolve())
spec = importlib.util.spec_from_file_location("gateway_smoke", Path(__file__).with_name("acp-gateway-smoke.py"))
gateway_smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gateway_smoke)
WS = gateway_smoke.WS


def wait_for(check, description, timeout=25):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(0.05)
    raise AssertionError("Timed out: " + description)


class REPL:
    def __init__(self, root, home, config, log, arguments=()):
        self.path = log
        self.log = log.open("w")
        self.process = subprocess.Popen([PMAI, "--home", str(home), "--config", str(config),
            "--no-markdown", *arguments], cwd=root, env=clean_environment(), stdin=subprocess.PIPE,
            stdout=self.log, stderr=self.log, text=True)
        self.wait("Type /help")

    def send(self, text):
        self.process.stdin.write(text + "\n")
        self.process.stdin.flush()

    def wait(self, text):
        def check():
            output = self.path.read_text()
            assert self.process.poll() is None, output
            return text in output
        try:
            wait_for(check, text)
        except AssertionError:
            raise AssertionError(self.path.read_text())

    def close(self):
        if self.process.poll() is None:
            self.send("/quit")
            try:
                self.process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
                raise AssertionError("REPL did not shut down its remote server")
        self.log.close()


def chats(directory):
    return {file.stem.lower(): json.loads(file.read_text())
            for file in (directory / ".pmai/chats").glob("*.json")}


def run():
    version = subprocess.run([PMAI, "--version"], env=clean_environment(),
                             capture_output=True, text=True, check=True).stdout.strip()
    assert version, "CLI did not report a version"
    with tempfile.TemporaryDirectory(prefix="pmai-remote-repl-") as directory:
        root = Path(directory).resolve()
        home = root / "home"
        projects = [root / name for name in ["one", "two", "three"]]
        client_dir = root / "client"
        for path in projects + [client_dir]:
            path.mkdir()
        config = root / "pmai.json"
        settings = {"defaultAgent": "main", "providers": [{"id": "hello", "kind": "hello"}],
                    "agents": [{"id": "main", "provider": "hello", "model": "hello"}],
                    "use": {"plan": False}}
        config.write_text(json.dumps(settings))
        for index, path in enumerate(projects):
            result = subprocess.run([PMAI, "--home", str(home), "--config", str(config),
                "--no-markdown", "seed-" + str(index)], cwd=path, env=clean_environment(),
                capture_output=True, text=True, timeout=25)
            assert result.returncode == 0, result.stderr
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
        server = REPL(projects[0], home, config, root / "server.log")
        client = None
        try:
            # No paths: every project in the shared index, and each old chat.
            server.send(f"/remote serve --port {port} --name server")
            server.wait("Connection profile:")
            uri = (home / "remote-server/connection.txt").read_text().strip()
            profile = json.loads(base64.urlsafe_b64decode(uri.split("/")[-1]))
            assert profile["url"].endswith(f":{port}/acp")
            assert "127.0.0.1" not in profile["url"], "automatic address should be reachable from a phone"
            token = profile["token"]
            assert profile["requiresApproval"] is True
            invitation = WS(port, token)
            try:
                invitation.rpc("initialize", {"protocolVersion": 1})
                raise AssertionError("invitation bypassed approval")
            except AssertionError as error:
                assert "accepted in the serving REPL" in str(error), error
            invitation.close()
            rejected = WS(port, token)
            rejected.send({"jsonrpc": "2.0", "id": 1, "method": "_pmai/pair",
                "params": {"clientID": "rejected-client", "name": "Rejected client"}})
            server.wait("Rejected client from")
            server.send("/remote reject")
            _, reply = rejected.receive()
            assert "The server rejected pairing" in json.loads(reply)["error"]["message"]
            rejected.close()
            assert not (home / "remote-server/clients.json").exists()
            pairing = WS(port, token)
            pairing.send({"jsonrpc": "2.0", "id": 1, "method": "_pmai/pair",
                "params": {"clientID": "test-inspector", "name": "Inspector"}})
            server.wait("Inspector from")
            assert not (home / "remote-server/clients.json").exists(), "unaccepted client got a credential"
            server.send("/remote accept")
            _, reply = pairing.receive()
            approved_token = json.loads(reply)["result"]["token"]
            assert approved_token != token
            pairing.close()
            connection = WS(port, approved_token)
            connection.rpc("initialize", {"protocolVersion": 1})
            listing = connection.rpc("session/list")[0]
            assert {str(Path(f["cwd"]).resolve()) for f in listing["_meta"]["pmai"]["folders"]} == {str(p) for p in projects}, listing
            assert len(listing["sessions"]) == 3, listing
            conversation = next(s for s in listing["sessions"] if Path(s["cwd"]).resolve() == projects[1])
            connection.rpc("session/load", {"sessionId": conversation["sessionId"], "cwd": str(projects[1])})
            connection.rpc("session/prompt", {"sessionId": conversation["sessionId"],
                "prompt": [{"type": "text", "text": "continue existing chat"}]})
            assert any("continue existing chat" in json.dumps(m) for m in chats(projects[1])[conversation["sessionId"]]["messages"])
            connection.close()
            print("Automatic LAN address, all indexed projects, and existing chat recovery: passed", flush=True)

            client_config = root / "client.json"
            client_config.write_text(json.dumps(settings))
            client_home = root / "client-home"
            client = REPL(client_dir, client_home, client_config, root / "client.log")
            client.send("/chat rename local")
            wait_for(lambda: any(c["title"] == "local" for c in chats(client_dir).values()), "local chat")
            client.send(f'/remote pair "{home / "remote-server/connection.txt"}"')
            wait_for(lambda: server.path.read_text().count("Pairing request") == 3, "CLI approval request")
            assert "Paired server." not in client.path.read_text(), "CLI paired before server approval"
            server.send("/remote accept")
            client.wait("Paired server.")
            client.send("/remote connect server")
            client.wait("Connected to server.")
            client.send("remote hello")
            client.wait("took ")
            remote = wait_for(lambda: next((c for c in chats(client_dir).values() if c["title"] == "remote hello"), None), "remote chat saved")
            source_ids = set(chats(projects[0]))
            assert len(source_ids) == 2, chats(projects[0])
            assert token not in client_config.read_text()
            assert token not in (client_home / "remotes/hosts.json").read_text()
            client.send("/remote disconnect")
            client.wait("Using your local chat.")
            client.close()
            client = REPL(client_dir, client_home, client_config, root / "resume.log", ["--resume", remote["id"]])
            client.send("resume remote")
            client.wait("took ")
            assert set(chats(projects[0])) == source_ids, "restart created another remote conversation"
            assert any("resume remote" in json.dumps(m) for c in chats(projects[0]).values() for m in c["messages"])
            client.close()
            client = None
            print("Server approval/rejection, CLI pairing, local chat preservation, and remote session recovery across restart: passed", flush=True)

            server.send("/projects forget two")
            server.wait("Forgot 'two'")
            connection = WS(port, approved_token)
            connection.rpc("initialize", {"protocolVersion": 1})
            listing = connection.rpc("session/list")[0]
            assert str(projects[1]) not in {str(Path(f["cwd"]).resolve()) for f in listing["_meta"]["pmai"]["folders"]}
            connection.close()
            server.send(f'/projects open "{projects[1]}"')
            server.wait("Opened project 'two'")
            print("Serving follows /projects index updates without restoring forgotten folders from ACP checkpoints: passed", flush=True)

            server.send("/remote stop")
            server.wait("Remote server stopped.")
            server.send(f'/remote serve --path "{projects[1]}" "{projects[2]}" --port {port} --address 127.0.0.1 --name server')
            wait_for(lambda: server.path.read_text().count("Connection profile:") == 2, "restricted server startup")
            connection = WS(port, approved_token)
            connection.rpc("initialize", {"protocolVersion": 1})
            listing = connection.rpc("session/list")[0]
            assert {str(Path(f["cwd"]).resolve()) for f in listing["_meta"]["pmai"]["folders"]} == {str(p) for p in projects[1:]}
            try:
                connection.rpc("session/new", {"cwd": str(projects[0])})
                raise AssertionError("unshared path was accepted")
            except AssertionError as error:
                assert "outside the served workspace" in str(error), error
            connection.close()
            server.send("/remote revoke test-inspector")
            server.wait("Revoked client test-inspector.")
            WS(port, approved_token, accepted=False)
            server.send("/version")
            server.wait(version)
            print("Optional multi-path restriction and a usable REPL while serving: passed", flush=True)
        finally:
            if client:
                client.close()
            server.close()
        with socket.socket() as probe:
            assert probe.connect_ex(("127.0.0.1", port)) != 0, "REPL exit left its listener running"
        print("Listener shutdown on REPL exit: passed", flush=True)


if __name__ == "__main__":
    run()
