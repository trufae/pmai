#!/usr/bin/env python3
"""Keep command output visible after paging, refreshes and terminal redraws."""
import fcntl
import json
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
import time

from smoke import clean_environment, read_chat, read_pty, run_repl

CSI = re.compile(r'\x1b\[[0-?]*[ -/]*[@-~]')
MOVE = re.compile(r'\x1b\[(\d+);(\d+)H')


def main(binary):
    with tempfile.TemporaryDirectory(prefix='pmai-buffer-commands-') as directory:
        root = Path(directory)
        config = root / 'config.json'
        config.write_text(json.dumps({
            'defaultAgent': 'hello', 'providers': [{'id': 'hello', 'kind': 'hello'}],
            'agents': [{'id': 'hello', 'provider': 'hello', 'model': 'hello',
                        'options': {'reasoningEffort': 'low'}}],
            'memory': {'enabled': False}, 'use': {'plan': False},
            'ui': {'mode': 'buffer', 'scrollbar': 0, 'markdown': False},
        }))
        env = clean_environment() | {'TERM': 'xterm-256color', 'NO_COLOR': '1'}
        command = [binary, '--config', str(config), '--home', str(root / 'home'),
                   '--no-stream', '--no-markdown']
        run_repl(command, ['Seed'], cwd=root, env=env)
        saved = next((root / '.pmai/chats').glob('*.json'))
        template = read_chat(saved)

        for count in (8, 64, 65, 130):
            fixture = [
                {'id': f'message-{i}', 'role': 'user' if i % 2 == 0 else 'assistant',
                 'content': [{'text': {'_0': f'HISTORY_{i:03}'}}]}
                for i in range(count)
            ]
            saved.write_text(json.dumps(template | {'messages': fixture, 'subagents': []}))
            master, slave = pty.openpty()
            rows, columns = 24, 160
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', rows, columns, 0, 0))
            process = subprocess.Popen(command + ['--resume', template['id']], cwd=root, env=env,
                                       stdin=slave, stdout=slave, stderr=slave)
            os.close(slave)
            captured = bytearray()
            screen = {}

            def read(seconds=.1):
                data = bytearray()
                read_pty(master, data, seconds)
                captured.extend(data)
                # Reparse complete cursor moves, including ones split across reads.
                text = captured.decode(errors='replace')
                moves = list(MOVE.finditer(text))
                for index, move in enumerate(moves):
                    row, column = map(int, move.groups())
                    end = moves[index + 1].start() if index + 1 < len(moves) else len(text)
                    content = text[move.end():end]
                    if column == 1 and '\x1b[2K' in content:
                        screen[row] = CSI.sub('', content).replace('\x1b7', '').replace('\x1b8', '')

            def wait(text):
                deadline = time.monotonic() + 15
                while text.encode() not in captured:
                    assert process.poll() is None, captured.decode(errors='replace')
                    assert time.monotonic() < deadline, (text, captured.decode(errors='replace'))
                    read(.05)
                read()

            def send(text):
                os.write(master, text.encode())

            def output():
                return '\n'.join(screen.get(row, '') for row in range(1, rows - 1))

            def barrier(label):
                send(f'/help buffer-barrier-{label}\r')
                wait(f"Unknown help topic 'buffer-barrier-{label}'")

            try:
                wait('pmai> ')
                send('/set effort\r')
                barrier('effort')
                assert 'effort = low' in output(), (count, output())
                if count == 8:
                    # Terminal filters are retained, including slow ones; elapsed
                    # time alone must not switch to an interactive screen.
                    start = len(captured)
                    send('/set | grep "^effort =" | sed "s/^/PIPE_FILTER: /"\r')
                    wait('PIPE_FILTER: effort = low')
                    barrier('pipe-filter')
                    assert 'PIPE_FILTER: effort = low' in output(), output()
                    send('/version | sh -c \'sleep 0.3; printf "SLOW\\137FILTER\\137RESULT: "; cat\'\r')
                    wait('SLOW_FILTER_RESULT: ')
                    barrier('slow-pipe-filter')
                    assert 'SLOW_FILTER_RESULT: ' in output(), output()
                    send('/version | sh -c \'cat >/dev/null; printf "PIPE_STDERR\\n" >&2; exit 7\'\r')
                    wait('pipe exited with status 7')
                    barrier('failed-pipe-filter')
                    assert 'PIPE_STDERR' in output() and 'pipe exited with status 7' in output(), output()
                    assert b'\x1b[?1049l' not in captured[start:], captured[start:]
                    assert b'\x1b[?1049h' not in captured[start:], captured[start:]
                    send('\x0c')
                    read()
                    assert 'SLOW_FILTER_RESULT: ' in output() and 'PIPE_STDERR' in output(), output()
                if count > 64:
                    # Loading full context for a command must not move the
                    # displayed page or corrupt subsequent history navigation.
                    for _ in range(20):
                        send('\x1b[5~')
                        read(.1)
                        if 'HISTORY_000' in output():
                            break
                    assert 'HISTORY_000' in output(), (count, output())
                    send('/set effort\r')
                    barrier('earlier-effort')
                    assert 'effort = low' in output(), (count, output())
                    for _ in range(20):
                        send('\x1b[5~')
                        read(.1)
                        if 'HISTORY_000' in output():
                            break
                    assert 'HISTORY_000' in output(), (count, output())
                    for _ in range(20):
                        send('\x1b[6~')
                        read(.1)
                        if f'HISTORY_{count - 1:03}' in output():
                            break
                    assert f'HISTORY_{count - 1:03}' in output(), (count, output())
                send('/msg log\r')
                barrier('log')
                assert f'Total messages: {count}' in output(), (count, output())
                assert f'(id: message-{count - 1})' in output(), (count, output())
                if count == 130:
                    send('/fork --empty Buffer child\r')
                    wait('and switched to it.')
                    send('/set effort\r')
                    barrier('child-effort')
                    assert 'effort = low' in output(), output()
                    assert 'HISTORY_' not in output(), output()
                    send('/msg log\r')
                    barrier('child-log')
                    assert 'HISTORY_' not in output(), output()
                    send('/subagents main\r')
                    barrier('return-main')
                    assert f'Total messages: {count}' in output(), output()
                send('unfinished-draft')
                read()
                fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 28, columns, 0, 0))
                rows = 28
                os.kill(process.pid, signal.SIGWINCH)
                read(.2)
                assert f'Total messages: {count}' in output(), (count, output())
                assert 'unfinished-draft' in screen.get(rows, ''), screen
                send('\x7f' * len('unfinished-draft') + '/exit\r')
                deadline = time.monotonic() + 15
                while process.poll() is None:
                    assert time.monotonic() < deadline, captured.decode(errors='replace')
                    read(.05)
                assert process.returncode == 0
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)
                os.close(master)
    print('PASS buffer command output across history paging, refresh, typing and resize')


if __name__ == '__main__':
    main(str(Path(sys.argv[1]).resolve()))
