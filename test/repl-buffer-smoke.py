#!/usr/bin/env python3
"""Exercise transcript navigation, live output, reflow, and terminal cleanup in a PTY."""
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

from smoke import clean_environment, JSONProvider, read_pty

CSI = re.compile(r'\x1b\[[0-?]*[ -/]*[@-~]')
MOVE = re.compile(r'\x1b\[(\d+);(\d+)H')


def main(binary):
    chunks = queue.Queue()

    class Provider(JSONProvider):
        def do_POST(self):
            self.rfile.read(int(self.headers['Content-Length']))
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.end_headers()
            while True:
                content = chunks.get(timeout=20)
                if content is None:
                    self.wfile.write(b'data: [DONE]\n\n')
                    self.wfile.flush()
                    return
                event = {'choices': [{'index': 0, 'delta': {'content': content},
                                      'finish_reason': None}]}
                self.wfile.write(('data: ' + json.dumps(event) + '\n\n').encode())
                self.wfile.flush()

    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix='pmai-buffer-') as directory:
            root = Path(directory)
            config = root / 'config.json'
            config.write_text(json.dumps({
                'defaultAgent': 'main',
                'providers': [{'id': 'mock', 'kind': 'openAICompatible',
                               'baseURL': f'http://127.0.0.1:{server.server_port}/v1'}],
                'agents': [{'id': 'main', 'provider': 'mock', 'model': 'fixture',
                            'toolNames': [], 'toolGroupNames': [], 'retry': {'attempts': 0}}],
                'memory': {'enabled': False}, 'use': {'plan': False},
                'ui': {'mode': 'buffer'},
            }))
            editor = root / 'editor.py'
            editor.write_text("from pathlib import Path\nimport sys\n"
                              "Path(sys.argv[1]).write_text('buffer editor test')\n")
            env = clean_environment() | {'TERM': 'xterm-256color',
                'NO_PROXY': '127.0.0.1,localhost', 'EDITOR': f'{sys.executable} {editor}'}
            master, slave = pty.openpty()
            original = termios.tcgetattr(slave)
            rows, columns = 24, 80
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', rows, columns, 0, 0))
            process = subprocess.Popen([binary, '--config', str(config), '--home', str(root / 'home'),
                '--no-markdown'], cwd=root, env=env, stdin=slave, stdout=slave, stderr=slave,
                start_new_session=True)
            os.close(slave)
            screen = {}
            captured = bytearray()

            def read_for(seconds=.25):
                data = bytearray()
                read_pty(master, data, seconds)
                captured.extend(data)
                text = data.decode()
                moves = list(MOVE.finditer(text))
                for index, move in enumerate(moves):
                    row, column = map(int, move.groups())
                    assert 1 <= row <= rows and 1 <= column <= columns, (row, column, rows, columns)
                    end = moves[index + 1].start() if index + 1 < len(moves) else len(text)
                    content = text[move.end():end]
                    # The renderer clears and replaces each changed row in full.
                    if column == 1 and '\x1b[2K' in content:
                        screen[row] = CSI.sub('', content).replace('\x1b7', '').replace('\x1b8', '')
                return bytes(data)

            def wait_for(text):
                deadline = time.monotonic() + 12
                while text.encode() not in captured:
                    assert process.poll() is None, captured.decode(errors='replace')
                    assert time.monotonic() < deadline, (text, captured.decode(errors='replace'))
                    read_for(.05)
                read_for(.1)

            def send(text):
                captured.clear()
                os.write(master, text.encode())

            def output():
                return tuple(screen.get(row, '') for row in range(1, rows - 2))

            try:
                wait_for('pmai> ')
                assert b'\x1b[?1006h' in captured, captured
                send('/set ui.mode classic\r')
                wait_for('\x1b[?1049l')
                send('/set ui.mode buffer\r')
                wait_for('\x1b[?1006h')
                assert json.loads(config.read_text())['ui']['mode'] == 'buffer'
                send('buffer-test\r')
                chunks.put(''.join(f'ROW{i:02d} content for scrolling\n' for i in range(70)))
                wait_for('ROW69')
                send('\x1b[200~draft first\ndraft last\x1b[201~')
                wait_for('draft last')
                assert 'draft first' in screen[rows - 1] and 'draft last' in screen[rows], screen
                assert 'ROW69' in '\n'.join(output()), screen
                send('\x1b[5~')
                read_for()
                previous = output()
                assert 'ROW69' not in '\n'.join(previous), screen
                assert 'scroll' in screen[rows - 2], screen
                assert 'draft last' in screen[rows], screen

                # Live output must not displace history or the unfinished draft.
                captured.clear()
                chunks.put('NEW OUTPUT WHILE SCROLLED\n')
                read_for(.4)
                assert output() == previous, (previous, output())
                assert 'draft last' in screen[rows], screen

                send('\x1b[<64;10;5M')
                read_for()
                assert output() != previous, screen
                send('\x1b[<65;10;5M')
                read_for()
                assert output() == previous, (previous, output())
                # Click/release packets must be consumed without editing input.
                send('\x1b[<0;10;5M\x1b[<0;10;5m\x1b[M' + chr(32) + chr(42) + chr(37))
                read_for()
                assert 'draft last' in screen[rows], screen

                # Reflow while browsing, and then restore the original width.
                for new_rows, new_columns in ((16, 22), (24, 80)):
                    rows, columns = new_rows, new_columns
                    screen.clear()
                    fcntl.ioctl(master, termios.TIOCSWINSZ,
                                struct.pack('HHHH', rows, columns, 0, 0))
                    os.kill(process.pid, signal.SIGWINCH)
                    read_for()
                    assert 'ROW' in screen[1], screen
                    assert 'draft last' in screen[rows], screen
                assert output() == previous, (previous, output())

                # Kitty Page Down follows the same navigation path as CSI 6~.
                send('\x1b[57355u' * 10)
                wait_for('NEW OUTPUT WHILE SCROLLED')
                assert 'scroll' not in screen[rows - 2], screen
                send('\x1b[57354u')
                read_for()
                assert 'scroll' in screen[rows - 2], screen
                send('\x0c')
                wait_for('NEW OUTPUT WHILE SCROLLED')
                assert 'draft last' in screen[rows], screen

                chunks.put(None)
                wait_for('✓ took')
                send('\x03')
                wait_for('Nothing to cancel.')
                # External editors leave and re-enter the alternate screen.
                send('/edit user buffer-test\r')
                wait_for('\x1b[?1049l')
                wait_for('\x1b[?1049h')
                assert b'\x1b[?1000l' in captured and b'\x1b[?1000h' in captured, captured
                send('/set ui.mode classic\r')
                wait_for('\x1b[?1049l')
                assert json.loads(config.read_text())['ui']['mode'] == 'classic'
                send('/set ui.mode buffer\r')
                wait_for('\x1b[?1049h')
                send('/exit\r')
                deadline = time.monotonic() + 10
                while process.poll() is None:
                    read_for(.05)
                    assert time.monotonic() < deadline, 'exit timed out'
                assert process.returncode == 0
                assert b'\x1b[?1000l' in captured and b'\x1b[?1049l' in captured, captured
                assert termios.tcgetattr(master) == original, 'raw tty mode leaked on exit'
                print('PASS buffer: paging, mouse packets, live history anchor, fixed multiline draft, '
                      'resize, follow, mode persistence, editor handoff and terminal cleanup')
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
    main(str(Path(sys.argv[1]).resolve()))
