#!/usr/bin/env python3
"""Exercise /remote serving, project discovery, CLI pairing, and durable sessions."""
import base64
import fcntl
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
import os
from pathlib import Path
import pty
import shlex
import signal
import socket
import subprocess
import struct
import sys
import termios
import tempfile
import threading
import time
import uuid
from urllib.parse import parse_qs, unquote, urlsplit

from smoke import clean_environment, expect_pty, read_pty

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


def live_shells(root, home, config, host_root):
    """Stateful shells, host interrupts, resize, and returning ownership to the REPL."""
    before = set(chats(root))
    master, slave = pty.openpty()
    original = termios.tcgetattr(slave)
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 100, 0, 0))
    local_shell = root / 'local-shell'
    local_shell.write_text("#!/bin/sh\nprintf 'local-shell-ready\\n'\nexec /bin/sh -i\n")
    local_shell.chmod(0o700)
    env = dict(clean_environment(), TERM='xterm-256color', SHELL=str(local_shell), ENV='/dev/null')
    process = subprocess.Popen([PMAI, '--home', str(home), '--config', str(config),
        '--no-markdown'], cwd=root, env=env, stdin=slave, stdout=slave, stderr=slave)
    output = bytearray()

    def send(text):
        os.write(master, text.encode())

    def wait(text):
        return expect_pty(master, process, output, text, 30)

    def repl(label):
        send('/help shell-barrier-' + label + '\r')
        wait("Unknown help topic 'shell-barrier-" + label + "'")

    try:
        wait('> ')
        send('/remote connect server\r')
        wait('Connected to server.')
        send('/shell local\r')
        wait('Local shell.')
        wait('local-shell-ready\r\n')
        send("stty -echo; export SHELL_STATE=local; cd /; printf '\\n%s\\n' local-ready\r")
        wait('\r\nlocal-ready\r\n')
        send("printf 'local-%s:%s\\n' \"$SHELL_STATE\" \"$PWD\"\r")
        wait('local-local:/')
        send('exit\r')
        wait('Left local shell.')
        repl('local')
        assert set(chats(root)) == before, 'local shell created a chat'

        send('/shell live\r')
        wait('Live shell server.')
        send("stty -echo; export SHELL_STATE=remote; cd /; printf '\\n%s\\n' remote-ready\r")
        wait('\r\nremote-ready\r\n')
        send("printf 'remote-%s:%s\\n' \"$SHELL_STATE\" \"$PWD\"\r")
        wait('remote-remote:/')
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 37, 111, 0, 0))
        # A query proves the resize reached the PTY; retry the query until that
        # result arrives rather than assuming SIGWINCH delivery after a sleep.
        deadline = time.monotonic() + 30
        while True:
            send("printf 'size-'; stty size; printf 'size-%s\\n' done\r")
            response = wait('size-done')
            if '37 111' in response:
                break
            assert time.monotonic() < deadline, response
        # The foreground job installs its handler before announcing readiness;
        # a parent-shell trap does not receive interrupts sent to the job group.
        interrupt_job = "trap 'printf \"interrupt-%s\\n\" ack; exit 130' INT; printf 'interrupt-%s\\n' ready; read ignored"
        send("sh -c " + shlex.quote(interrupt_job) + "\r")
        wait('interrupt-ready')
        send('\x03')
        wait('interrupt-ack')
        send("printf 'interrupt-%s\\n' stopped\r")
        wait('interrupt-stopped')
        send('exit\r')
        wait('Left remote shell server.')
        repl('exit')

        # Auto selects live on a TTY. Ctrl+] closes even a busy host program.
        send('/shell\r')
        wait('Live shell server.')
        send("stty -echo; echo $$ > relay-shell.pid; printf '\\n%s\\n' escape-ready; sleep 60\r")
        wait('\r\nescape-ready\r\n')
        pid = int((host_root / 'relay-shell.pid').read_text())
        send('\x1d')
        wait('Left remote shell server.')
        repl('escape')
        def shell_stopped():
            try:
                os.kill(pid, 0)
                return False
            except ProcessLookupError:
                return True
        wait_for(shell_stopped, 'escape closes host shell')

        send('/remote shell server cmd\r')
        wait('Command mode:')
        send("printf 'cmd-%s\\n' result\r")
        wait('cmd-result')
        send('exit\r')
        wait('Left remote shell server.')
        repl('cmd')
        assert set(chats(root)) == before, 'shell access created a chat'
        send('/quit\r')
        deadline = time.monotonic() + 30
        while process.poll() is None:
            assert time.monotonic() < deadline, output.decode(errors='replace')
            read_pty(master, output, .05)
        assert process.returncode == 0
        restored = termios.tcgetattr(slave)
        # BSD can set PENDIN while restoring canonical input; it asks the
        # kernel to retype pending input and is not a terminal mode leak.
        restored[3] &= ~getattr(termios, 'PENDIN', 0)
        original[3] &= ~getattr(termios, 'PENDIN', 0)
        assert restored == original, ('shell handoff did not restore terminal modes', original, restored)
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)
        os.close(slave)
    print('Local and remote live shells, persistent state, Ctrl+C, resize, escape cleanup, cmd mode and tty restoration: passed', flush=True)


def remote_terminal_sessions(server, port, token, root):
    resume = str(uuid.uuid4())
    def connect():
        ws = WS(port, token)
        ws.sock.settimeout(30)
        ws.rpc('initialize', {'protocolVersion': 1, '_meta': {'pmai': {'resumeId': resume}}})
        return ws
    ws = connect()
    method = '_pmai/workspace/terminal'
    def request(action, **fields):
        return ws.rpc(method, dict(action=action, **fields))[0]
    terminal = request('open', cwd=str(root), columns=80, rows=24)['id']
    offset = 0
    def send(text):
        request('write', id=terminal, data=base64.b64encode(text.encode()).decode())
    def until(marker):
        nonlocal offset
        data = b''
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            chunk = request('read', id=terminal, offset=offset)
            data += base64.b64decode(chunk['data'])
            offset = chunk['offset']
            if marker in data:
                return data
            assert chunk.get('exitCode') is None, data
        raise AssertionError('terminal did not produce ' + repr(marker))
    try:
        send("stty -echo; printf '\\n%s\\n' echo-disabled\n")
        until(b'\r\necho-disabled\r\n')
        send("export PMAI_TERMINAL_STATE=retained; printf '%s\\n' $$ > terminal.pid; printf 'state-%s\\n' saved\n")
        until(b'state-saved')
        pid = (root / 'terminal.pid').read_text()
        ws.close()
        ws = connect()
        assert request('attach', id=terminal)['attached']
        assert terminal in request('list')['ids']
        send("printf '%s\\n' \"$PMAI_TERMINAL_STATE\" > terminal-state; printf 'resume-%s\\n' ready\n")
        until(b'resume-ready')
        assert (root / 'terminal-state').read_text() == 'retained\n'
        assert (root / 'terminal.pid').read_text() == pid
        second = request('open', cwd=str(root), columns=60, rows=20)['id']
        assert second != terminal
        request('close', id=second)
        assert not request('attach', id=second)['attached']
        assert request('attach', id=terminal)['attached']
        request('close', id=terminal)
        assert not request('attach', id=terminal)['attached']
        idle = request('open', cwd=str(root), columns=80, rows=24)['id']
        server.send('/set limits.terminalTimeout 3m20s')
        server.wait('Set limits.terminalTimeout = 200 seconds.')
        server.send('/set limits.terminalTimeout 1h20m')
        server.wait('Set limits.terminalTimeout = 4800 seconds.')
        server.send('/set limits.terminalTimeout 9223372036854775807h')
        server.wait('Usage: /set limits.terminalTimeout')
        assert json.loads((root.parent / 'pmai.json').read_text())['remoteTerminalTimeoutSeconds'] == 4800
        server.send('/set limits.terminalTimeout 2')
        server.wait('Set limits.terminalTimeout = 2 seconds.')
        wait_for(lambda: not request('attach', id=idle)['attached'], 'configured terminal idle expiry', timeout=30)
        server.send('/set limits.terminalTimeout 0')
        server.wait('Set limits.terminalTimeout = 0 seconds.')
        print('Persistent PTY state across disconnect, multiple terminals, explicit close and live idle timeout: passed', flush=True)
    finally:
        request('close_all')
        ws.close()


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
                    "agents": [{"id": "main", "provider": "hello", "model": "hello",
                                "toolNames": ["run_shell"]}],
                    "toolSources": [{"id": "standard", "kind": "standard-tools",
                                     "options": {"tools": ["run_shell"]}}],
                    "approvals": {"mode": "yolo"},
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
            remote_terminal_sessions(server, port, approved_token, projects[0])

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
            payload = bytes([0, 255, 128, 10]) * 150_000
            (client_dir / "local input.bin").write_bytes(payload)
            before = set(chats(projects[0]))
            client.send('/remote put server "local input.bin" "remote upload.bin"')
            client.wait(f"Uploaded {len(payload)} bytes")
            assert (projects[0] / "remote upload.bin").read_bytes() == payload
            (projects[0] / "listed-only.txt").write_text("listing")
            client.send('/remote ls server')
            client.wait("listed-only.txt")
            client.send('/remote get server "remote upload.bin" "downloaded file.bin"')
            client.wait(f"Downloaded {len(payload)} bytes")
            assert (client_dir / "downloaded file.bin").read_bytes() == payload
            client.send('/remote run server printf \'%s\\n\' "remote $((2+3))" | cat > command.txt; cat command.txt')
            client.wait("remote 5")
            assert (projects[0] / "command.txt").read_text() == "remote 5\n"
            assert not (client_dir / "command.txt").exists(), "remote redirect ran locally"
            client.send('/remote shell server')
            client.wait("Remote shell server.")
            client.send('/bin/echo "shell $((6*7))" > shell.txt; cat shell.txt')
            client.wait("shell 42")
            assert (projects[0] / "shell.txt").read_text() == "shell 42\n"
            assert not (client_dir / "shell.txt").exists(), "shell-mode redirect ran locally"
            client.send('exit')
            client.wait("Left remote shell server.")
            assert set(chats(projects[0])) == before, "workspace commands created a chat"
            errors = client.path.read_text().count("error:")
            client.send('/remote get server missing.bin "downloaded file.bin"')
            wait_for(lambda: client.path.read_text().count("error:") > errors, "failed remote download")
            assert (client_dir / "downloaded file.bin").read_bytes() == payload, "failed download replaced local data"
            print("Remote binary transfers, paths with spaces, shell quoting, and chat isolation: passed", flush=True)
            live_shells(client_dir, client_home, client_config, projects[0])
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
            server.send("/remote list")
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


def run_opencode():
    payload = bytes([0, 255, 128, 10])
    script = 'printf \'%s\\n\' "$PWD" | cat > paths.txt'
    shell_script = '/bin/echo "$PWD" > paths.txt'
    uploaded = []
    commands = []
    sessions = {}
    prompts = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def reply(self, data, status=200, headers=None):
            self.send_response(status)
            self.send_header("Content-Length", str(len(data)))
            for key, value in (headers or {}).items():
                self.send_header(key, value)
            self.end_headers()
            self.wfile.write(data)

        def handle_request(self):
            url = urlsplit(self.path)
            if url.path == "/auth/connect/code":
                return self.reply(b'{"token":"test-token"}')
            assert self.headers.get("Authorization") == "Basic " + base64.b64encode(b"opencode:test-token").decode()
            query = parse_qs(url.query)
            if url.path == '/api/project':
                return self.reply(b'[{"canonical":"/work"}]')
            if url.path == '/api/session':
                if self.command == 'POST':
                    body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                    assert body['location']['directory'] == '/work', body
                    session = f'ses_{len(sessions) + 1}'
                    sessions[session] = []
                    return self.reply(json.dumps({'data': {'id': session}}).encode())
                return self.reply(b'{"data":[]}')
            parts = url.path.strip('/').split('/')
            if len(parts) == 4 and parts[:2] == ['api', 'session']:
                session, action = parts[2:]
                assert session in sessions, parts
                if action == 'prompt':
                    body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                    prompts.append((session, body['text']))
                    index = len(prompts)
                    sessions[session] += [
                        {'id': f'user_{index}', 'type': 'user', 'text': body['text']},
                        {'id': f'answer_{index}', 'type': 'assistant', 'content': [
                            {'type': 'reasoning', 'text': f'remote-thought-{index}'},
                            {'type': 'tool', 'id': f'call_{index}', 'name': 'remote_probe',
                             'state': {'status': 'completed', 'input': {},
                                       'content': [{'type': 'text', 'text': f'host-tool-output-{index}'}]}},
                            {'type': 'text', 'text': f'remote-reply-{index}'}]},
                        {'id': f'idle_{index}', 'type': 'idle', 'outcome': 'succeeded'}]
                    return self.reply(b'{}')
                if action in ('context', 'message'):
                    return self.reply(json.dumps({'data': sessions[session]}).encode())
                if action == 'permission':
                    return self.reply(b'{"data":[]}')
            if parts[:3] == ['api', 'experimental', 'session'] and parts[-1] == 'wait':
                return self.reply(b'{}')
            assert query["location[directory]"] == ["/work"]
            if url.path == "/api/fs/list":
                assert query["path"] == ["/work"]
                return self.reply(json.dumps({"data": [{"path": f"file-{i:03}", "type": "file"}
                                                       for i in range(501)]}).encode())
            if unquote(url.path) == "/api/fs/read/binary file.bin":
                return self.reply(payload, headers={"ETag": "v1"})
            if url.path == "/api/experimental/fs/write":
                assert self.command == "POST" and self.headers["Content-Type"] == "application/octet-stream"
                assert query["path"] == ["/work/uploaded file.bin"]
                uploaded.append(self.rfile.read(int(self.headers["Content-Length"])))
                return self.reply(b'{"data":{"path":"/work/uploaded file.bin"}}')
            if url.path == "/api/shell" and self.command == "POST":
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                assert body["command"] in (script, shell_script) and body["cwd"] == "/work"
                commands.append(body["command"])
                return self.reply(b'{"data":{"id":"sh_test"}}')
            if url.path == "/api/shell/sh_test" and self.command == "GET":
                return self.reply(b'{"data":{"status":"exited","exit":0}}')
            if url.path == "/api/shell/sh_test/output":
                output = f"mock shell result {len(commands)}"
                return self.reply(json.dumps({"data": {"output": output, "cursor": len(output), "size": len(output)}}).encode())
            if url.path == "/api/shell/sh_test" and self.command == "DELETE":
                return self.reply(b'{}')
            raise AssertionError("Unexpected OpenCode request: " + self.path)

        do_GET = do_POST = do_DELETE = handle_request

    with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory(prefix="pmai-opencode-repl-") as directory:
                root = Path(directory)
                config = root / "config.json"
                config.write_text(json.dumps({"defaultAgent": "main", "providers": [{"id": "hello", "kind": "hello"}],
                    "agents": [{"id": "main", "provider": "hello", "model": "hello"}], "ui": {"tools": -1}}))
                client = REPL(root, root / "home", config, root / "client.log")
                try:
                    client.send(f'/remote pair "http://127.0.0.1:{server.server_port}/auth/connect/code" "dev host" /work')
                    client.wait("Paired dev host.")
                    client.send('/remote ls "dev host"')
                    client.wait("file-500")
                    client.send('/remote get "dev host" "binary file.bin"')
                    client.wait("Downloaded 4 bytes")
                    assert (root / "binary file.bin").read_bytes() == payload
                    client.send('/remote put "dev host" "binary file.bin" "uploaded file.bin"')
                    client.wait("Uploaded 4 bytes")
                    assert uploaded == [payload]
                    client.send('/remote run "dev host" ' + script)
                    client.wait("mock shell result 1")
                    client.send('/remote shell "dev host"')
                    client.wait("Remote shell dev host.")
                    client.send(shell_script)
                    client.wait("mock shell result 2")
                    assert commands == [script, shell_script]
                    assert not (root / "paths.txt").exists(), "OpenCode redirect ran locally"
                    client.send('exit')
                    client.wait("Left remote shell dev host.")
                    assert not chats(root), "OpenCode workspace commands created a chat"
                    client.send("local-after-shell")
                    client.wait("took ")
                    client.send('/remote connect "dev host"')
                    client.wait('Connected to dev host.')
                    client.send('first native OpenCode prompt')
                    client.wait('remote-reply-1')
                    saved = wait_for(lambda: next((c for c in chats(root).values()
                        if 'remote-reply-1' in json.dumps(c)), None), 'OpenCode chat saved')
                    assert 'host-tool-output-1' in client.path.read_text(), 'remote tool output was lost'
                    client.send('/shell')
                    wait_for(lambda: client.path.read_text().count('Remote shell dev host.') == 2,
                             '/shell follows the active OpenCode host')
                    client.send(shell_script)
                    client.wait('mock shell result 3')
                    assert commands == [script, shell_script, shell_script]
                    client.send('exit')
                    wait_for(lambda: client.path.read_text().count('Left remote shell dev host.') == 2,
                             'return from active-host shell')
                    client.send('/shell local')
                    client.wait('A local shell requires a terminal.')
                    client.send('/remote disconnect')
                    client.wait('Using your local chat.')
                    client.close()
                    client = REPL(root, root / 'home', config, root / 'resume.log', ['--resume', saved['id']])
                    client.send('second native OpenCode prompt')
                    client.wait('remote-reply-2')
                    wait_for(lambda: 'remote-reply-2' in json.dumps(chats(root)), 'resumed OpenCode response saved')
                    assert prompts == [('ses_1', 'first native OpenCode prompt'),
                                       ('ses_1', 'second native OpenCode prompt')], prompts
                    assert len(sessions) == 1, 'restart created another OpenCode conversation'
                    assert 'remote-reply-1' not in client.path.read_text().split('second native OpenCode prompt')[-1], 'old answer replayed as a new response'
                    client.send('/remote connect "dev host"')
                    client.wait('Connected to dev host.')
                    client.send('separate native OpenCode prompt')
                    client.wait('remote-reply-3')
                    assert prompts[-1] == ('ses_2', 'separate native OpenCode prompt'), prompts
                finally:
                    client.close()
        finally:
            server.shutdown()
            thread.join()
    print("OpenCode pairing, files, native chats, active-host shells, restart recovery and chat isolation: passed", flush=True)


if __name__ == "__main__":
    run_opencode()
    run_tunnel_modes(run())
