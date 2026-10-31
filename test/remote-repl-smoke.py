#!/usr/bin/env python3
"""Exercise /remote serving, project discovery, CLI pairing, and durable sessions."""
import base64
import importlib.util
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlsplit

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
    def __init__(self, root, home, config, log, arguments=(), environment=None):
        self.path = log
        self.log = log.open("w")
        self.process = subprocess.Popen([PMAI, "--home", str(home), "--config", str(config),
            "--no-markdown", *arguments], cwd=root, env=environment or clean_environment(), stdin=subprocess.PIPE,
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
            server.send(f"/remote serve --protocol local --port {port} --name server")
            server.wait("Connection profile:")
            uri = (home / "remote-server/connection.txt").read_text().strip()
            profile = json.loads(base64.urlsafe_b64decode(uri.split("/")[-1]))
            assert profile["url"].endswith(f":{port}/acp")
            assert "127.0.0.1" not in profile["url"], "automatic address should be reachable from a phone"
            lan_address = urlsplit(profile["url"]).hostname
            with socket.create_connection((lan_address, port), timeout=2):
                pass
            token = profile["token"]
            assert profile["requiresApproval"] is True
            assert profile["connectionProtocol"] == "local"
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
            client.send("/set airplane on")
            client.wait("airplane = on")
            client.send(f'/remote pair "{home / "remote-server/connection.txt"}"')
            client.wait("Turn off Airplane Mode before pairing.")
            assert server.path.read_text().count("Pairing request") == 2, "offline pairing opened a connection"
            client.send("/set airplane off")
            client.wait("airplane = off")
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

            server.send("/projects del two")
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
            server.send(f'/remote serve --protocol local --path "{projects[1]}" "{projects[2]}" --port {port} --loopback --name server')
            wait_for(lambda: server.path.read_text().count("Connection profile:") == 2, "restricted server startup")
            uri = (home / "remote-server/connection.txt").read_text().strip()
            loopback_profile = json.loads(base64.urlsafe_b64decode(uri.split("/")[-1]))
            assert loopback_profile["url"] == f"ws://127.0.0.1:{port}/acp", loopback_profile
            with socket.socket() as probe:
                probe.settimeout(2)
                assert probe.connect_ex((lan_address, port)) != 0, "loopback listener accepted a LAN connection"
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
            server.send("/remote del test-inspector")
            server.wait("Revoked client test-inspector.")
            WS(port, approved_token, accepted=False)
            server.send("/version")
            server.wait(version)
            print("Optional multi-path restriction and a usable REPL while serving: passed", flush=True)

            server.send("/remote stop")
            wait_for(lambda: server.path.read_text().count("Remote server stopped.") == 2, "loopback server stop")
            server.send(f'/remote serve --protocol local --loopback --address {lan_address} --port {port} --name server')
            wait_for(lambda: server.path.read_text().count("Connection profile:") == 3, "advertised address override startup")
            uri = (home / "remote-server/connection.txt").read_text().strip()
            advertised_profile = json.loads(base64.urlsafe_b64decode(uri.split("/")[-1]))
            assert advertised_profile["url"] == profile["url"], advertised_profile
            with socket.socket() as probe:
                probe.settimeout(2)
                assert probe.connect_ex((lan_address, port)) != 0, "advertised address override exposed the listener"
            active = WS(port, profile["token"])
            print("Loopback serving, pairing profile, and advertised address override isolation: passed", flush=True)
            server.send("/set airplane on")
            server.wait("airplane = on")
            def listener_stopped():
                with socket.socket() as probe:
                    return probe.connect_ex(("127.0.0.1", port)) != 0
            wait_for(listener_stopped, "airplane mode stops remote serving")
            try:
                active.receive()
                raise AssertionError("airplane mode left an active client connected")
            except (EOFError, ConnectionResetError):
                pass
            finally:
                active.close()
            server.send("/remote serve")
            server.wait("Turn off Airplane Mode before serving remote clients.")
            print("Airplane mode blocks pairing and serving and closes active remote connections: passed", flush=True)
        finally:
            if client:
                client.close()
            server.close()
        with socket.socket() as probe:
            assert probe.connect_ex(("127.0.0.1", port)) != 0, "REPL exit left its listener running"
        print("Listener shutdown on REPL exit: passed", flush=True)
        return lan_address


def run_tunnel_modes(lan_address):
    with tempfile.TemporaryDirectory(prefix="pmai-opentunnel-") as directory:
        root = Path(directory).resolve()
        home = root / "home"
        config = root / "pmai.json"
        config.write_text(json.dumps({"defaultAgent": "main",
            "providers": [{"id": "hello", "kind": "hello"}],
            "agents": [{"id": "main", "provider": "hello", "model": "hello"}]}))
        bin_dir = root / "bin"
        bin_dir.mkdir()
        command = bin_dir / "opentunnel"
        log = root / "opentunnel.log"
        state = root / "published"
        mode = root / "mode"
        command.write_text(f"#!{sys.executable}\n" + r'''
import json, os, sys, time
from pathlib import Path
args = sys.argv[1:]
assert args[0] == "--profile" and args[1].startswith("pmai-"), args
with open(os.environ["OPENTUNNEL_TEST_LOG"], "a") as out:
    out.write(json.dumps(args) + "\n")
state = Path(os.environ["OPENTUNNEL_TEST_STATE"])
mode = Path(os.environ["OPENTUNNEL_TEST_MODE"]).read_text()
if args[2:4] == ["route", "add"]:
    assert args[4].startswith("127.0.0.1:") and args[5:] == ["--name", "pmai"], args
    state.write_text(str(os.getpid()))
    if mode == "fail":
        print("fixture provisioning failed")
        sys.exit(1)
    if mode == "wait":
        time.sleep(60)
    print("https://pmai.fixture.opentunnel.xyz" if mode != "bad-url" else "invalid address")
elif args[2:] == ["status"]:
    print("Service: connected (fixture)")
elif args[2:] == ["down"]:
    state.unlink(missing_ok=True)
else:
    raise AssertionError(args)
''')
        command.chmod(0o755)
        mode.write_text("ready")
        env = clean_environment()
        env.update(PATH=str(bin_dir),
                   OPENTUNNEL_TEST_LOG=str(log), OPENTUNNEL_TEST_STATE=str(state),
                   OPENTUNNEL_TEST_MODE=str(mode))
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
        server = REPL(root, home, config, root / "server.log", environment=env)

        def profile():
            uri = (home / "remote-server/connection.txt").read_text().strip()
            return json.loads(base64.urlsafe_b64decode(uri.split("/")[-1]))

        def stopped(count):
            server.send("/remote stop")
            wait_for(lambda: server.path.read_text().count("Remote server stopped.") == count, "remote stop")

        try:
            server.send("/remote serve --protocol iroh")
            server.wait("Unknown serving protocol")
            server.send("/remote serve --protocol opentunnel --url ws://example.com/acp")
            server.wait("OpenTunnel connections require a wss:// gateway URL")
            server.send("/remote serve --protocol local --url wss://example.com/other")
            server.wait("Use a gateway URL ending in /acp")
            server.send("/remote serve --url wss://example.com/acp --address 127.0.0.1")
            server.wait("Use either --url or --address")
            hidden_command = bin_dir / "opentunnel-disabled"
            command.rename(hidden_command)
            server.send(f"/remote serve --protocol opentunnel --port {port}")
            server.wait("OpenTunnel is not installed")
            hidden_command.rename(command)
            server.send(f"/remote serve --protocol opentunnel --port {port} --url wss://external.example/acp")
            server.wait("Connection profile:")
            invitation = profile()
            assert invitation["url"] == "wss://external.example/acp", invitation
            assert invitation["connectionProtocol"] == "opentunnel" and invitation["requiresApproval"]
            assert not log.exists(), "externally managed tunnel invoked the CLI"
            pairing = WS(port, invitation["token"])
            pairing.send({"jsonrpc": "2.0", "id": 1, "method": "_pmai/pair",
                "params": {"clientID": "tunnel-client", "name": "Tunnel client"}})
            server.wait("Tunnel client from")
            server.send("/remote accept")
            _, reply = pairing.receive()
            token = json.loads(reply)["result"]["token"]
            pairing.close()
            connection = WS(port, token)
            connection.rpc("initialize", {"protocolVersion": 1})
            connection.close()
            with socket.socket() as probe:
                probe.settimeout(2)
                assert probe.connect_ex((lan_address, port)) != 0, "OpenTunnel exposed its listener on the LAN"
            stopped(1)
            assert not log.exists(), "stopping an external tunnel invoked the CLI"

            server.send(f"/remote serve --protocol opentunnel --port {port}")
            wait_for(lambda: server.path.read_text().count("Connection profile:") == 2, "managed tunnel startup")
            assert profile()["url"] == "wss://pmai.fixture.opentunnel.xyz/acp", profile()
            assert state.exists()
            first_profile = json.loads(log.read_text().splitlines()[0])[1]
            stopped(2)
            assert not state.exists(), "remote stop left the publisher running"

            for failure_mode, error in [("fail", "fixture provisioning failed"),
                                        ("bad-url", "OpenTunnel did not return a public HTTPS URL")]:
                mode.write_text(failure_mode)
                server.send(f"/remote serve --protocol opentunnel --port {port}")
                server.wait(error)
                assert not state.exists(), "failed startup left the publisher running"
                with socket.socket() as probe:
                    assert probe.connect_ex(("127.0.0.1", port)) != 0, "failed startup left the gateway running"

            mode.write_text("wait")
            server.send(f"/remote serve --protocol opentunnel --port {port}")
            wait_for(state.exists, "provisioning starts")
            server.process.send_signal(signal.SIGINT)
            wait_for(lambda: not state.exists(), "cancelled provisioning stops publisher")
            server.send("/remote status")
            server.wait("Remote server is stopped.")
            mode.write_text("ready")
            server.send(f"/remote serve --protocol opentunnel --port {port}")
            wait_for(lambda: server.path.read_text().count("Connection profile:") == 3, "managed tunnel restart")
            server.send("/set airplane on")
            server.wait("airplane = on")
            wait_for(lambda: not state.exists(), "airplane mode stops publisher")
            server.send("/set airplane off")
            server.wait("airplane = off")
            server.send(f"/remote serve --protocol opentunnel --port {port}")
            wait_for(lambda: server.path.read_text().count("Connection profile:") == 4, "managed tunnel before exit")
            assert all(json.loads(line)[1] == first_profile for line in log.read_text().splitlines())
        finally:
            server.close()
        assert not state.exists(), "REPL exit left the publisher running"
        print("Serving protocols, public pairing profile, isolated publisher lifecycle, failure cleanup, and stable identity: passed", flush=True)


if __name__ == "__main__":
    run_tunnel_modes(run())
