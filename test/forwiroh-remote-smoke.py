#!/usr/bin/env python3
"""Pair two pmai CLIs, prompt over Forwiroh, reconnect, then revoke the device.
Usage: python3 test/forwiroh-remote-smoke.py /path/to/pmai
"""
import base64
import importlib.util
import json
from pathlib import Path
import socket
import subprocess
import sys
import tempfile

spec = importlib.util.spec_from_file_location("remote_smoke", Path(__file__).with_name("remote-repl-smoke.py"))
remote = importlib.util.module_from_spec(spec)
spec.loader.exec_module(remote)


def run():
    with tempfile.TemporaryDirectory(prefix="pmai-forwiroh-") as directory:
        root = Path(directory)
        project, local = root / "project", root / "local"
        project.mkdir()
        local.mkdir()
        home, client_home = root / "host", root / "client"
        settings = {"defaultAgent": "main", "providers": [{"id": "hello", "kind": "hello"}],
                    "agents": [{"id": "main", "provider": "hello", "model": "hello"}], "use": {"plan": False}}
        config, client_config = root / "host.json", root / "client.json"
        config.write_text(json.dumps(settings))
        client_config.write_text(json.dumps(settings))
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
        server = remote.REPL(project, home, config, root / "host.log")
        client = None
        try:
            # Omitting --protocol must publish a usable Forwiroh endpoint.
            server.send(f"/remote serve --port {port} --name workstation")
            server.wait("Connection profile:")
            profile_file = home / "remote-server/connection.txt"
            profile = json.loads(base64.urlsafe_b64decode(profile_file.read_text().strip().split("/")[-1]))
            assert profile["connectionProtocol"] == "forwiroh"
            assert profile["url"].startswith("forwiroh://")
            assert profile["forwirohInvitation"].startswith("forwiroh:")
            client = remote.REPL(local, client_home, client_config, root / "client.log")
            client.send(f'/remote pair "{profile_file}"')
            server.wait("Forwiroh pairing:")
            assert not (client_home / "remotes/hosts.json").exists()
            server.send("/remote accept")
            server.wait("Pairing request ")
            assert not (client_home / "remotes/hosts.json").exists(), "device approval bypassed ACP approval"
            server.send("/remote accept")
            client.wait("Paired workstation.")
            state = json.loads((home / "remote-server/forwiroh/peers.json").read_text())
            peer_id, peer = next(iter(state["peers"].items()))
            assert peer["policy"]["restricted"] is True
            assert peer["policy"]["services"] == {"pmai-acp": f"127.0.0.1:{port}"}
            client_state = json.loads((client_home / "forwiroh-client/peers.json").read_text())
            assert all(p["policy"]["restricted"] and not p["policy"]["services"] for p in client_state["peers"].values())
            client.send("/remote connect workstation")
            client.wait("Connected to workstation.")
            client.send("hello over forwiroh")
            client.wait("took ")
            remote.wait_for(lambda: any("hello over forwiroh" in json.dumps(c) for c in remote.chats(project).values()), "remote prompt delivered")
            client.close()
            host = json.loads((client_home / "remotes/hosts.json").read_text())[0]
            agent_id = "remote." + host["id"].lower()
            result = subprocess.run([remote.PMAI, "--home", str(client_home), "--config", str(client_config),
                "--agent", agent_id, "--no-markdown", "one shot over forwiroh"], cwd=local,
                env=remote.clean_environment(), capture_output=True, text=True, timeout=30)
            assert result.returncode == 0, result.stderr + result.stdout
            remote.wait_for(lambda: any("one shot over forwiroh" in json.dumps(c) for c in remote.chats(project).values()), "one-shot prompt delivered")
            client = remote.REPL(local, client_home, client_config, root / "reconnect.log")
            client.send("/remote connect workstation")
            client.wait("Connected to workstation.")
            client.send("after restart")
            client.wait("took ")
            assert server.path.read_text().count("Forwiroh pairing:") == 1
            server.send(f"/remote del fw-{peer_id}")
            server.wait("Revoked client fw-")
            client.send("revoked request")
            client.wait("error:")
            server.send("/remote stop")
            server.wait("Remote server stopped.")
            with socket.socket() as probe:
                assert probe.connect_ex(("127.0.0.1", port)) != 0
            print("Forwiroh device and ACP approval, restricted policies, remote chat, restart and revocation: passed")
        except Exception:
            print(server.path.read_text(), file=sys.stderr)
            if client: print(client.path.read_text(), file=sys.stderr)
            raise
        finally:
            if client: client.close()
            server.close()


if __name__ == "__main__":
    run()
