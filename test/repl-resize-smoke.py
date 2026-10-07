#!/usr/bin/env python3
"""Check fixed REPL rows with SIGWINCH both delivered and deliberately delayed."""
import fcntl
import json
from smoke import read_pty, expect_pty
import os
from pathlib import Path
import pty
import re
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
import unicodedata
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


CSI = re.compile(r'\x1b\[[0-?]*[ -/]*[@-~]')
MOVE = re.compile(r'\x1b\[(\d+);(\d+)H')


def width(text):
    return sum(0 if unicodedata.combining(c) else
               2 if unicodedata.east_asian_width(c) in ('W', 'F') else 1
               for c in text)


def check_rows(data, rows, columns, input_rows=1, thinking_rows=0):
    text = data.decode()
    moves = list(MOVE.finditer(text))
    assert moves, repr(text)
    painted = set()
    for i, move in enumerate(moves):
        row, column = map(int, move.groups())
        assert 1 <= row <= rows and 1 <= column <= columns, (row, column, rows, columns)
        end = moves[i + 1].start() if i + 1 < len(moves) else len(text)
        content = CSI.sub('', text[move.end():end]).replace('\x1b7', '').replace('\x1b8', '')
        if content:
            assert row >= rows - input_rows - thinking_rows, (row, repr(content))
            assert column - 1 + width(content) <= columns - 1, (columns, repr(content))
            painted.add(row)
    assert rows - input_rows in painted, ('missing status/menu row', repr(text))
    assert rows in painted, ('missing input row', repr(text))
    if thinking_rows:
        assert rows - input_rows - thinking_rows in painted, ('missing thinking row', repr(text))
    return text


def exercise(binary, server, started, release):
    with tempfile.TemporaryDirectory(prefix='pmai-resize-') as directory:
        root = Path(directory)
        config = root / 'config.json'
        config.write_text(json.dumps({
            'version': 1, 'defaultAgent': 'smoke',
            'providers': [{'id': 'mock', 'kind': 'openAICompatible',
                           'baseURL': f'http://127.0.0.1:{server.server_port}/v1'}],
            'agents': [{'id': 'smoke', 'provider': 'mock', 'model': 'smoke',
                        'toolGroupNames': [], 'enabled': True}],
            'memory': {'enabled': False}, 'use': {'plan': False},
            'ui': {'bgline': 'blue', 'fg': 'cyan', 'bg': 'black'},
        }))
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(('PMAI_', 'MAI_', 'OPENAI_'))
               and k.lower() not in ('no_color', 'http_proxy', 'https_proxy', 'all_proxy')}
        env.update(TERM='xterm-256color', NO_PROXY='127.0.0.1,localhost')
        master, slave = pty.openpty()
        cooked = termios.tcgetattr(slave)

        def resize(rows, columns):
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', rows, columns, 0, 0))

        resize(40, 160)
        # The child has no controlling terminal: ioctl does not send SIGWINCH.
        # Sending it ourselves makes the race reproducible without timing luck.
        process = subprocess.Popen(
            [binary, '--config', str(config), '--home', str(root / 'home'),
             '--no-stream', '--no-markdown'], cwd=root, env=env,
            stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
        os.close(slave)
        pending = bytearray()

        def read_for(seconds):
            data = bytearray()
            read_pty(master, data, seconds)
            return bytes(data)

        def wait_for(needle):
            return expect_pty(master, process, pending, needle, 10)

        def drain():
            pending.clear()
            read_for(.15)

        try:
            wait_for('pmai> ')
            drain()
            draft = 'resize-draft-' + '界e\u0301' * 50 + '-kept'
            os.write(master, ('\x1b[200~' + draft + '\x1b[201~').encode())
            wait_for('-kept')
            drain()

            # The resize handler must safely redraw the cached, styled draft.
            for rows, columns in ((28, 37), (40, 140), (12, 18), (30, 80)):
                resize(rows, columns)
                os.kill(process.pid, signal.SIGWINCH)
                check_rows(read_for(.25), rows, columns)
            print('PASS: resize redraw clips cached styled and wide-character input')

            # A key can redraw before the queued signal handler runs. Even
            # without SIGWINCH the status and input must use the current size.
            for rows, columns in ((16, 26), (32, 110), (10, 12), (40, 160)):
                resize(rows, columns)
                os.write(master, b'\x05')  # Ctrl+E redraws without changing the draft.
                check_rows(read_for(.25), rows, columns)
                os.kill(process.pid, signal.SIGWINCH)
                assert not read_for(.1), 'late SIGWINCH redrew an already updated layout'
            print('PASS: redraw uses current dimensions before SIGWINCH delivery')

            # Submission retains all text, including the clipped portion.
            os.write(master, b'\r')
            wait_for('Reply: ' + draft)
            wait_for('✓ took')
            drain()

            os.write(master, b'/set tool.calling \t')
            wait_for('automatic')
            drain()
            resize(18, 24)
            os.kill(process.pid, signal.SIGWINCH)
            check_rows(read_for(.25), 18, 24)
            resize(20, 16)
            os.write(master, b'\t')
            check_rows(read_for(.25), 20, 16)
            os.write(master, b'\x03')
            wait_for('Nothing to cancel.')
            drain()
            print('PASS: completion menu stays inside its row during resize')

            resize(40, 160)
            os.kill(process.pid, signal.SIGWINCH)
            drain()
            os.write(master, b'animate\r')
            deadline = time.monotonic() + 10
            while not started.is_set():
                pending.extend(read_for(.05))
                assert time.monotonic() < deadline, ('mock provider was not called', pending.decode())
            wait_for('thinking')
            drain()
            for rows, columns in ((16, 26), (30, 100), (10, 15)):
                resize(rows, columns)
                # No signal or input: both the spinner and elapsed-time update
                # must adopt the size on their own, including the cached prompt.
                check_rows(read_for(1.25), rows, columns, thinking_rows=1)
            release.set()
            wait_for('Reply: animate')
            wait_for('✓ took')
            drain()
            print('PASS: animated status adopts resizes before SIGWINCH delivery')

            resize(40, 160)
            os.kill(process.pid, signal.SIGWINCH)
            drain()
            os.write(master, b'\x1b[200~first\nsecond\nthird\nlast\x1b[201~')
            wait_for('last')
            drain()
            resize(6, 20)
            os.kill(process.pid, signal.SIGWINCH)
            check_rows(read_for(.25), 6, 20)
            os.write(master, b'\x03')
            wait_for('Nothing to cancel.')
            drain()
            os.write(master, b'/exit\r')
            deadline = time.monotonic() + 10
            while process.poll() is None:
                assert time.monotonic() < deadline, 'exit timed out'
                read_for(.05)
            assert process.returncode == 0, process.returncode
            assert termios.tcgetattr(master) == cooked, 'exit did not restore terminal mode'
            print('PASS: height shrink clamps multiline input; exit restores terminal mode')
        finally:
            release.set()
            if process.poll() is None:
                process.kill()
                process.wait()
            os.close(master)


def main():
    started = threading.Event()
    release = threading.Event()

    class Provider(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            prompt = next(m['content'] for m in reversed(request['messages']) if m['role'] == 'user')
            if prompt == 'animate':
                started.set()
                release.wait(20)
            body = json.dumps({'choices': [{'message': {'role': 'assistant', 'content': 'Reply: ' + prompt},
                                           'finish_reason': 'stop'}]}).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        exercise(str(Path(sys.argv[1]).resolve()), server, started, release)
    finally:
        release.set()
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
