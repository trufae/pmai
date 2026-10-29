#!/usr/bin/env python3
"""Measure prompt readiness and keep catalog/completion work off startup."""
import fcntl
import json
import os
from pathlib import Path
import pty
import queue
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
from http.server import ThreadingHTTPServer

from smoke import JSONProvider, clean_environment, expect_pty, read_pty


requests = queue.Queue()
release = threading.Event()


class Provider(JSONProvider):
    def do_GET(self):
        requests.put(self.path)
        release.wait(15)
        try:
            self.respond({'data': [{'id': 'fixture-one'}, {'id': 'fixture-two'}]})
        except (BrokenPipeError, ConnectionResetError):
            pass


def main():
    binary = str(Path(sys.argv[1]).resolve())
    version = subprocess.check_output([binary, '--version'], text=True).strip()
    env = clean_environment()
    env.update(TERM='xterm-256color', NO_COLOR='1', NO_PROXY='127.0.0.1,localhost')
    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        for mode in ('classic', 'buffer'):
            release.clear()
            with tempfile.TemporaryDirectory(prefix='pmai-startup-') as directory:
                root = Path(directory)
                config = root / 'config.json'
                config.write_text(json.dumps({
                    'version': 1, 'defaultAgent': 'test', 'ui': {'mode': mode},
                    'providers': [{'id': 'test', 'kind': 'openai',
                                   'baseURL': f'http://127.0.0.1:{server.server_port}/v1'}],
                    'agents': [{'id': 'test', 'provider': 'test', 'model': 'test', 'toolNames': []}],
                    'voice': {'input': 'command', 'output': 'openai', 'provider': 'test'},
                }))
                master, slave = pty.openpty()
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 180, 0, 0))
                started = time.monotonic()
                process = subprocess.Popen(
                    [binary, '--config', str(config), '--home', str(root / 'home'), '--no-markdown'],
                    cwd=root, env=env, stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
                os.close(slave)
                output = bytearray()

                def wait(text):
                    return expect_pty(master, process, output, text, 8)

                def send(text):
                    os.write(master, text.replace('\n', '\r').encode())

                def next_request():
                    deadline = time.monotonic() + 8
                    while requests.empty():
                        assert time.monotonic() < deadline, output.decode(errors='replace')
                        read_pty(master, output, .05)
                    return requests.get_nowait()

                try:
                    wait('pmai>')
                    prompt_seconds = time.monotonic() - started
                    send('/version\n')
                    wait(version)
                    ready_seconds = time.monotonic() - started
                    read_pty(master, output, .2)
                    assert requests.empty(), 'Startup eagerly fetched a model or voice catalog'
                    print(f'{mode}: prompt {prompt_seconds:.3f}s; first command {ready_seconds:.3f}s', flush=True)

                    # A slow skill source must not be scanned just to hand input
                    # back after a local command. No writer opens this FIFO.
                    skill = root / 'home/skills/slow/SKILL.md'
                    skill.parent.mkdir(parents=True)
                    os.mkfifo(skill)
                    try:
                        send('/version\n')
                        wait(version)
                        send('/version\n')
                        wait(version)
                    finally:
                        skill.unlink()

                    send('/model fi\t')
                    assert next_request() == '/v1/models'
                    send('\x03')
                    wait('Nothing to cancel.')
                    send('/set voice.voice fi\t')
                    assert next_request().endswith('/voices')
                    send('\x03')
                    wait('Nothing to cancel.')
                    send('/version\n')
                    wait(version)  # Both HTTP catalogs are still stalled.
                    release.set()
                    send('/voice voices\n')
                    wait('fixture-two')
                    assert next_request().endswith('/voices')
                    send('/set voice.voice fixture-o\t')
                    wait('/set voice.voice fixture-one')
                    send('\x03')
                    wait('Nothing to cancel.')
                    read_pty(master, output, .2)
                    assert requests.empty(), 'Explicit voice listing was fetched again for completion'
                    send('/exit\n')
                    deadline = time.monotonic() + 8
                    while process.poll() is None:
                        assert time.monotonic() < deadline, output.decode(errors='replace')
                        read_pty(master, output, .05)
                    assert process.returncode == 0
                finally:
                    release.set()
                    if process.poll() is None:
                        process.kill()
                        process.wait()
                    os.close(master)
                traced = subprocess.run(
                    [binary, '--config', str(config), '--home', str(root / 'home'), '--no-markdown'],
                    input='/exit\n', text=True, capture_output=True, cwd=root,
                    env=dict(env, PMAI_STARTUP_TIMING='1'), timeout=15)
                assert traced.returncode == 0, traced.stderr
                for phase in ('main entered', 'chat workspace loaded', 'provider test registered',
                              'prompt input released'):
                    assert phase in traced.stderr, traced.stderr
    finally:
        release.set()
        server.shutdown()
        server.server_close()
    print('repl startup smoke: ok')


if __name__ == '__main__':
    main()
