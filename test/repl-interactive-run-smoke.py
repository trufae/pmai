#!/usr/bin/env python3
"""Verify run_shell terminal handoffs against a fixture provider and a real tty."""
import fcntl
import json
import os
from pathlib import Path
import queue
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


requests = queue.Queue()
release = threading.Event()
arguments = {}


class Provider(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        self.reply({'data': [{'id': 'smoke'}]})

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.put(request)
        if not any(m['role'] == 'tool' for m in request['messages']):
            assert release.wait(15)
            message = {'role': 'assistant', 'content': None, 'tool_calls': [{
                'id': 'run-1', 'type': 'function', 'function': {
                    'name': 'run_shell', 'arguments': json.dumps(arguments)}}]}
        else:
            message = {'role': 'assistant', 'content': 'HANDOFF-DONE'}
        self.reply({'choices': [{'message': message,
                                'finish_reason': 'tool_calls' if 'tool_calls' in message else 'stop'}]})

    def reply(self, value):
        data = json.dumps(value).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def controlling_terminal():
    os.setsid()
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)


def main():
    global arguments
    binary = str(Path(sys.argv[1]).resolve())
    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        for case in sys.argv[2:] or ('vim', 'read', 'interrupt', 'cancel', 'timeout', 'exit', 'oneshot', 'piped'):
            release.clear()
            while not requests.empty():
                requests.get_nowait()
            with tempfile.TemporaryDirectory(prefix='pmai-interactive-') as tmp:
                root = Path(tmp)
                work = root / "work's space"
                work.mkdir()
                config = root / 'config.json'
                config.write_text(json.dumps({
                    'version': 1, 'defaultAgent': 'smoke',
                    'providers': [{'id': 'smoke', 'kind': 'openAICompatible',
                                   'baseURL': f'http://127.0.0.1:{server.server_port}/v1', 'apiKey': 'test'}],
                    'toolSources': [{'id': 'standard', 'kind': 'standard-tools',
                                     'options': {'tools': ['run_shell'], 'runTimeoutSeconds': 1}}],
                    'agents': [{'id': 'smoke', 'provider': 'smoke', 'model': 'smoke',
                                'toolNames': ['run_shell'], 'toolGroupNames': [], 'enabled': True,
                                'retry': {'attempts': 0}}],
                    'approvals': {'mode': 'yolo'}, 'memory': {'enabled': False},
                    'use': {'plan': False, 'agentsmd': 'off'},
                }))
                arguments = {'command': '/bin/sh ../fixture.sh "$1"', 'args': ['a b'],
                             'cwd': str(work), 'interactive': True}
                script = 'test -t 0 && test -t 1 && test -t 2 || exit 80\n'
                script += 'test "$TERM" = xterm-256color || exit 81\n'
                script += 'printf "%s" "$1" > arg.txt\npwd > cwd.txt\n'
                if case == 'vim':
                    script += 'exec vim -Nu NONE -n -i NONE -c \'call writefile(["ready"], "ready")\' notes.txt\n'
                elif case in ('read', 'oneshot'):
                    script += 'echo ready > ready\nread -r text\nprintf "%s" "$text" > typed.txt\n'
                elif case in ('interrupt', 'cancel', 'timeout'):
                    if case == 'timeout':
                        script += 'stty -echo -icanon\n'
                    script += 'echo $$ > child.pid\necho ready > ready\nexec sleep 30\n'
                    if case == 'timeout':
                        arguments['timeout_seconds'] = 1
                else:
                    script += 'exit 7\n'
                (root / 'fixture.sh').write_text(script)
                env = {k: v for k, v in os.environ.items()
                       if not k.startswith(('PMAI_', 'MAI_', 'OPENAI_'))
                       and k.lower() not in ('http_proxy', 'https_proxy', 'all_proxy')}
                env.update(TERM='xterm-256color', NO_PROXY='127.0.0.1,localhost')
                command = [binary, '--config', str(config), '--home', str(root / 'home'),
                           '--no-stream', '--no-markdown']
                if case in ('oneshot', 'piped'):
                    command += ['open program']
                if case == 'piped':
                    release.set()
                    result = subprocess.run(command, cwd=root, env=env, input='', text=True,
                                            capture_output=True, timeout=20)
                    assert result.returncode == 0, result.stderr
                    sent = []
                    while not requests.empty():
                        sent.append(requests.get_nowait())
                    tool = next(m for m in sent[-1]['messages'] if m['role'] == 'tool')
                    assert 'no terminal to hand over' in tool['content'], tool
                    assert not (work / 'arg.txt').exists()
                    print('PASS piped: clear error, no process launched', flush=True)
                    continue

                master, slave = os.openpty()
                cooked = termios.tcgetattr(slave)
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 35, 120, 0, 0))
                process = subprocess.Popen(command, cwd=root, env=env, stdin=slave, stdout=slave,
                                           stderr=slave, preexec_fn=controlling_terminal)
                os.close(slave)
                output = bytearray()

                def pump():
                    if select.select([master], [], [], .05)[0]:
                        try:
                            output.extend(os.read(master, 65536))
                        except OSError:
                            pass

                def wait_until(predicate, description, timeout=15):
                    deadline = time.monotonic() + timeout
                    while not predicate():
                        assert time.monotonic() < deadline, (case, description, output.decode(errors='replace'))
                        assert process.poll() is None, (case, process.returncode, output.decode(errors='replace'))
                        pump()

                def send(data):
                    os.write(master, data)

                try:
                    if case != 'oneshot':
                        wait_until(lambda: b'pmai>' in output, 'initial prompt')
                        send(b'open program\r')
                    wait_until(lambda: not requests.empty(), 'first request')
                    first = requests.get_nowait()
                    definition = next(t['function'] for t in first['tools'] if t['function']['name'] == 'run_shell')
                    assert 'interactive' in definition['parameters']['properties']
                    if case == 'vim':
                        send(b'preserved draft')
                        # Confirm the input reader consumed the draft before the handoff.
                        wait_until(lambda: b'preserved draft' in output, 'draft rendered')
                    release.set()
                    if case in ('vim', 'read', 'oneshot', 'interrupt', 'cancel', 'timeout'):
                        wait_until(lambda: (work / 'ready').exists(), 'child ready')
                        if case == 'vim':
                            wait_until(lambda: not termios.tcgetattr(master)[3] & termios.ICANON, 'vim raw mode')
                            # The group's default timeout is one second; interactive runs ignore it.
                            until = time.monotonic() + 1.3
                            while time.monotonic() < until:
                                pump()
                            send(b'iprivate vim text\x1b:wq\r')
                        elif case in ('read', 'oneshot'):
                            send(b'private typed text\r')
                        elif case == 'interrupt':
                            send(b'\x03')
                        elif case == 'cancel':
                            os.kill(process.pid, signal.SIGINT)
                    if case == 'cancel':
                        wait_until(lambda: '✗ took'.encode() in output, 'cancelled turn')
                        assert requests.empty(), 'model called after cancellation'
                        send(b'/exit\r')
                        deadline = time.monotonic() + 10
                        while process.poll() is None and time.monotonic() < deadline:
                            pump()
                        assert process.wait(timeout=1) == 0
                        assert termios.tcgetattr(master) == cooked
                        print('PASS cancel: process stopped and terminal restored', flush=True)
                        continue
                    wait_until(lambda: not requests.empty(), 'tool result sent to model')
                    after = requests.get_nowait()
                    tool = next(m for m in after['messages'] if m['role'] == 'tool')
                    body = tool['content']
                    assert 'terminal input and output were not captured' in body, body
                    assert 'private' not in body, body
                    if case == 'exit':
                        assert 'exit code 7' in body, body
                    elif case == 'interrupt':
                        assert 'exit code' in body and 'exit code 0' not in body, body
                    elif case == 'timeout':
                        assert 'timed out after 1 seconds' in body, body
                    else:
                        assert 'exit code 0' in body, body
                    assert (work / 'arg.txt').read_text() == 'a b'
                    assert Path((work / 'cwd.txt').read_text().strip()) == work.resolve()
                    if case == 'vim':
                        assert (work / 'notes.txt').read_text() == 'private vim text\n'
                    if case in ('read', 'oneshot'):
                        assert (work / 'typed.txt').read_text() == 'private typed text'
                    if case != 'oneshot':
                        wait_until(lambda: b'HANDOFF-DONE' in output, 'assistant resumed')
                        if case == 'vim':
                            send(b'\r')
                            wait_until(lambda: not requests.empty(), 'preserved draft submitted')
                            draft = requests.get_nowait()
                            assert [m['content'] for m in draft['messages'] if m['role'] == 'user'][-1] == 'preserved draft'
                            # Wait for the reply before sending /exit.
                            output.clear()
                            wait_until(lambda: b'HANDOFF-DONE' in output, 'draft answered')
                        send(b'/exit\r')
                    deadline = time.monotonic() + 10
                    while process.poll() is None and time.monotonic() < deadline:
                        pump()
                    assert process.wait(timeout=1) == 0
                    assert termios.tcgetattr(master) == cooked, 'terminal modes not restored'
                    print(f'PASS {case}: terminal handoff and restoration', flush=True)
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.wait()
                    child = work / 'child.pid'
                    if child.exists():
                        try:
                            os.kill(int(child.read_text()), signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                    os.close(master)
    finally:
        release.set()
        server.shutdown()


if __name__ == '__main__':
    main()
