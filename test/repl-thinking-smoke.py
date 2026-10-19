#!/usr/bin/env python3
"""Check compact thinking streams through a real PTY with a paced local provider."""
import fcntl
import json
import os
from pathlib import Path
import pty
import queue
import re
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
from http.server import ThreadingHTTPServer

from smoke import clean_environment, expect_pty, JSONProvider, read_pty


CSI = re.compile(r'\x1b\[[0-?]*[ -/]*[@-~]')
MOVE = re.compile(r'\x1b\[(\d+);(\d+)H')


def paints(data):
    text = data.decode()
    moves = list(MOVE.finditer(text))
    result = []
    for index, move in enumerate(moves):
        end = moves[index + 1].start() if index + 1 < len(moves) else len(text)
        content = CSI.sub('', text[move.end():end]).replace('\x1b7', '').replace('\x1b8', '')
        if content:
            result.append((*map(int, move.groups()), content))
    return result


def exercise(binary, mode, count):
    chunks = queue.Queue()
    started = threading.Event()

    class Provider(JSONProvider):
        def do_POST(self):
            request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            assert request['stream']
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.end_headers()
            started.set()
            try:
                while True:
                    delta = chunks.get(timeout=15)
                    if delta is None:
                        break
                    event = {'choices': [{'index': 0, 'delta': delta, 'finish_reason': None}]}
                    self.wfile.write(('data: ' + json.dumps(event) + '\n\n').encode())
                    self.wfile.flush()
                self.wfile.write(b'data: [DONE]\n\n')
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass

    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix='pmai-thinking-') as directory:
            root = Path(directory)
            config = root / 'config.json'
            config.write_text(json.dumps({
                'defaultAgent': 'main',
                'providers': [{'id': 'mock', 'kind': 'openAICompatible',
                               'baseURL': f'http://127.0.0.1:{server.server_port}/v1'}],
                'agents': [{'id': 'main', 'provider': 'mock', 'model': 'fixture',
                            'toolNames': [], 'toolGroupNames': [], 'retry': {'attempts': 0}}],
                'memory': {'enabled': False}, 'use': {'plan': False},
                'ui': {'thinking': mode},
            }))
            env = clean_environment() | {'TERM': 'xterm-256color', 'NO_PROXY': '127.0.0.1,localhost'}
            env.pop('NO_COLOR', None)
            if mode == 'five':
                env['NO_COLOR'] = '1'
            master, slave = pty.openpty()

            def resize(rows, columns):
                fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', rows, columns, 0, 0))

            resize(40, 48)
            process = subprocess.Popen(
                [binary, '--config', str(config), '--home', str(root / 'home'), '--no-markdown'],
                cwd=root, env=env, stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
            os.close(slave)
            pending = bytearray()

            def read_for(seconds=.25):
                output = bytearray()
                read_pty(master, output, seconds)
                return bytes(output)

            def wait_for(text):
                return expect_pty(master, process, pending, text, 10)

            def stream(text):
                chunks.put({'reasoning_content': text})

            def check_frame(data, text, rows=40, columns=48):
                height = min(count, rows // 4)
                first = rows - height - 1
                expected = text[-height * (columns - 1):]
                actual = {row: content for row, column, content in paints(data)
                          if first <= row < rows - 1 and column == 1}
                assert actual == {first + i: expected[i * (columns - 1):(i + 1) * (columns - 1)]
                                  for i in range(height)}, (mode, actual, expected, data)

            try:
                wait_for('pmai> ')
                os.write(master, b'think\r')
                deadline = time.monotonic() + 10
                while not started.is_set():
                    pending.extend(read_for(.05))
                    assert time.monotonic() < deadline, pending
                read_for(.3)
                first = 40 - count - 1

                stream('alpha\n\nbeta\r\ngamma\t')
                data = read_for()
                assert b'\x1b[2K' not in data, data
                assert (first, 1, 'alpha beta gamma') in paints(data), data

                # These arrive inside one redraw interval; the trailing chunk
                # must become visible even if no further reasoning arrives.
                stream('d')
                stream('elta')
                data = read_for()
                assert b'\x1b[2K' not in data, data
                updates = [(column, content) for row, column, content in paints(data) if row == first]
                assert updates and all(column >= 17 for column, _ in updates), data
                assert any('elta' in content for _, content in updates), data

                text = 'alpha beta gamma delta' + '0123456789' * 40
                stream('0123456789' * 40)
                data = read_for()
                assert b'\x1b[2K' not in data, data
                check_frame(data, text)
                stream('Z')
                data = read_for()
                text += 'Z'
                assert b'\x1b[2K' not in data, data
                check_frame(data, text)

                # Idle animation and typing must leave the preview untouched.
                data = read_for(1.1)
                assert not any(first <= row < 39 for row, _, _ in paints(data)), data
                os.write(master, b'draft-kept')
                data = read_for()
                assert b'draft-kept' in data, data
                assert not any(first <= row < 39 for row, _, _ in paints(data)), data

                # Reflow retained text without a new provider token; growing
                # back restores all five rows, including after height clamping.
                for rows, columns in ((12, 32), (40, 48)):
                    resize(rows, columns)
                    os.kill(process.pid, signal.SIGWINCH)
                    check_frame(read_for(), text, rows, columns)

                chunks.put({'content': 'ANSWER'})
                chunks.put(None)
                wait_for('ANSWER')
                wait_for('✓ took')
                read_for()
                assert not read_for(.2), 'finished thinking kept redrawing'
                os.write(master, b'\x03')
                wait_for('Nothing to cancel.')
                os.write(master, b'/exit\r')
                deadline = time.monotonic() + 10
                while process.poll() is None:
                    pending.extend(read_for(.05))
                    assert time.monotonic() < deadline, ('exit timed out', pending.decode())
                assert process.returncode == 0
                print(f'PASS thinking {mode}: continuous rows, incremental writes, resize and cleanup')
            finally:
                chunks.put(None)
                if process.poll() is None:
                    process.kill()
                    process.wait()
                os.close(master)
    finally:
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    binary = str(Path(sys.argv[1]).resolve())
    for mode, count in (('line', 1), ('three', 3), ('five', 5)):
        exercise(binary, mode, count)
