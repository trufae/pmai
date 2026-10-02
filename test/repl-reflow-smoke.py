#!/usr/bin/env python3
"""Check real screen reflow, not just emitted widths, using headless Ghostty.

Usage: python3 test/repl-reflow-smoke.py BINARY /path/to/ghostty-web
The engine is supplied separately; see test/README.md for setup.
"""
import base64
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time


def main():
    binary = str(Path(sys.argv[1]).resolve())
    engine_path = str(Path(sys.argv[2]).resolve())
    with tempfile.TemporaryDirectory(prefix='pmai-reflow-') as directory:
        root = Path(directory)
        config = root / 'config.json'
        config.write_text(json.dumps({
            'defaultAgent': 'smoke',
            'providers': [{'id': 'offline', 'kind': 'hello'}],
            'agents': [{'id': 'smoke', 'provider': 'offline', 'model': 'hello',
                        'toolGroupNames': []}],
            'memory': {'enabled': False}, 'use': {'plan': False},
            'ui': {'bgline': '#123456'},
        }))
        engine = subprocess.Popen(
            ['node', str(Path(__file__).with_name('ghostty-screen.mjs')), engine_path],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)

        def screen_event(**event):
            engine.stdin.write(json.dumps(event) + '\n')
            engine.stdin.flush()
            response = engine.stdout.readline()
            assert response, 'headless Ghostty stopped'
            return json.loads(response)

        master, slave = pty.openpty()
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 160, 0, 0))
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(('PMAI_', 'MAI_', 'OPENAI_')) and k != 'NO_COLOR'}
        env['TERM'] = 'xterm-256color'
        process = subprocess.Popen(
            [binary, '--config', str(config), '--home', str(root / 'home'),
             '--no-stream', '--no-markdown'], cwd=root, env=env,
            stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
        os.close(slave)
        pending = bytearray()

        def drain(seconds=.2):
            deadline = time.monotonic() + seconds
            while time.monotonic() < deadline:
                if select.select([master], [], [], .02)[0]:
                    data = os.read(master, 65536)
                    pending.extend(data)
                    screen_event(write=base64.b64encode(data).decode())

        def wait_for(text):
            needle = text.encode()
            deadline = time.monotonic() + 10
            while needle not in pending:
                assert process.poll() is None, process.returncode
                assert time.monotonic() < deadline, (text, pending.decode(errors='replace'))
                drain(.05)
            del pending[:pending.index(needle) + len(needle)]

        def check_screen(rows):
            state = screen_event()
            assert state['statusRows'] == [rows - 2], state
            assert not state['statusHistory'], state
            # Keeping autowrap disabled between frames hides the footer bug
            # but truncates transcript lines when narrowing the screen.
            transcript = ''.join(state['history'] + state['screen'][:-2])
            assert message in transcript, ('transcript was truncated', state)
            assert state['screen'][-1].startswith('pmai'), state
            assert state['wraps'], 'normal transcript reflow must remain enabled'

        try:
            wait_for('pmai> ')
            message = 'KEEP_TRANSCRIPT_' + '0123456789' * 20 + '_COMPLETE'
            os.write(master, ('\x1b[200~' + message + '\x1b[201~\r').encode())
            wait_for('Hello from MaiCore: ' + message)
            wait_for('✓ took')
            drain()
            check_screen(40)
            # The emulator resizes BEFORE the application receives SIGWINCH,
            # just as a real window does. Inspect both screen and scrollback.
            sizes = ((40, 120), (40, 90), (40, 60), (40, 40), (40, 140),
                     (48, 140), (25, 100), (40, 160))
            for _ in range(3):
                for rows, columns in sizes:
                    screen_event(resize=[columns, rows])
                    fcntl.ioctl(master, termios.TIOCSWINSZ,
                                struct.pack('HHHH', rows, columns, 0, 0))
                    os.kill(process.pid, signal.SIGWINCH)
                    wait_for(f'\x1b[{rows};')
                    drain(.05)
                    check_screen(rows)
                    pending.clear()
            os.write(master, b'/exit\r')
            deadline = time.monotonic() + 10
            while process.poll() is None:
                assert time.monotonic() < deadline, 'exit timed out'
                try:
                    drain(.05)
                except OSError:
                    break
            assert process.wait(timeout=5) == 0
            assert screen_event()['wraps'], 'exit left wrapping disabled'
            print('PASS: 24 Ghostty resizes leave one status row, clean scrollback, and intact transcript')
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            os.close(master)
            engine.stdin.close()
            engine.wait(timeout=5)


if __name__ == '__main__':
    main()
