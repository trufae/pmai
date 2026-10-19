#!/usr/bin/env python3
"""Check chat chopping, linked tool messages, persistence, and real modal input."""
import fcntl
import json
import os
from pathlib import Path
import pty
import struct
import subprocess
import sys
import tempfile
import termios
import time

from smoke import clean_environment, expect_pty, read_pty, run_repl


def main():
    binary = str(Path(sys.argv[1]).resolve())
    with tempfile.TemporaryDirectory(prefix='pmai-chop-') as directory:
        root = Path(directory)
        config = root / 'config.json'
        config.write_text(json.dumps({
            'defaultAgent': 'main', 'providers': [{'id': 'hello', 'kind': 'hello'}],
            'agents': [{'id': 'main', 'provider': 'hello', 'model': 'hello'}],
            'memory': {'enabled': False}, 'use': {'plan': False},
            'ui': {'fginfo': 'cyan'},
        }))
        history = root / 'history.json'
        env = clean_environment()
        env.pop('NO_COLOR', None)
        env.update(TERM='xterm-256color', PWD=str(root))
        command = [binary, '--config', str(config), '--home', str(root / 'home'),
                   '--history', str(history), '--no-stream']
        run_repl(command, ['/chat rename Chop fixture', 'Seed'], cwd=root, env=env)
        saved = next((root / '.pmai/chats').glob('*.json'))
        chat = json.loads(saved.read_text())
        command += ['-r', chat['id']]

        def message(identifier, role, content):
            return {'id': identifier, 'role': role, 'content': content}

        def text(identifier, role, value):
            return message(identifier, role, [{'text': {'_0': value}}])

        fixture = [
            text('system', 'system', 'Saved instructions.'),
            text('first', 'user', 'First question'),
            message('calls', 'assistant', [{'toolCall': {'_0': {
                'id': identifier, 'name': 'example', 'arguments': {}}}}
                for identifier in ('a', 'b')]),
            *[message('result-' + identifier, 'tool', [{'toolResult': {'_0': {
                'callID': identifier, 'isError': False, 'importance': 'normal',
                'content': [{'text': {'_0': '**Result ' + identifier + '**'}}]}}}])
              for identifier in ('a', 'b')],
            text('answer', 'assistant', 'First answer'),
            text('second', 'user', 'Second question'),
            text('last', 'assistant', '**Last answer**'),
        ]

        def reset(messages=fixture):
            saved.write_text(json.dumps(chat | {'messages': messages}))

        def messages():
            return json.loads(saved.read_text())['messages']

        def ids():
            return [m['id'] for m in messages()]

        def run(commands):
            return run_repl(command, commands, cwd=root, env=env)

        reset()
        output = run(['/chat chop', 'n', 'p', 'd', 'p', 'p', 'd', 'x', 'p', 'x', 'p', 'p', 'q'])
        assert '## [8/8] Assistant' in output and 'Already at the last message.' in output, output
        assert 'Removed 3 messages (including linked tool messages).' in output, output
        assert '## [3/4] Assistant (id: answer)' in output, output
        assert 'Already at the first message.' in output, output
        assert ids() == ['system', 'first'], messages()
        assert 'Hello from MaiCore:' not in output, output

        # A cut inside a tool transaction removes the incomplete transaction,
        # and selects the last retained message instead of an invalid index.
        reset()
        output = run(['/chat chop', 'p', 'p', 'p', 'p', 'x', 'q'])
        assert 'Trimmed 6 messages; kept through message 2.' in output, output
        assert '## [2/2] User (id: first)' in output, output
        assert ids() == ['system', 'first'], messages()

        reset([fixture[1], fixture[-1]])
        output = run(['/chat chop', 'd', 'd', '/chat chop'])
        assert 'No conversation messages left.' in output and 'No conversation messages to chop.' in output, output
        assert messages() == [], messages()
        reset(fixture[:1])
        assert 'No conversation messages to chop.' in run(['/chat chop'])
        reset()
        output = run(['/chat chop invalid', '/chat chop', '/chat new Another chat', '/chat chop'])
        assert 'Usage: /chat chop' in output and 'Chat chop closed.' in output, output
        assert 'No conversation messages to chop.' in output and messages() == fixture, output

        # Real terminal input exercises the modal prompt, Tab, Markdown,
        # immediate disk writes, Ctrl+C, /stop, and EOF without a model call.
        reset()
        master, slave = pty.openpty()
        cooked = termios.tcgetattr(slave)
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 32, 120, 0, 0))
        process = subprocess.Popen(command, cwd=root, env=env,
                                   stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        output = bytearray()

        def wait(value):
            return expect_pty(master, process, output, value, 15)

        def send(value):
            output.clear()
            os.write(master, value.encode())

        def open_chop():
            send('/chat chop\r')
            return wait('chop [n/p/d/x/q]> ')

        try:
            wait('pmai> ')
            shown = open_chop()
            assert '\x1b[1;36m## [8/8] Assistant' in shown, repr(shown)
            assert '\x1b[1mLast answer\x1b[0m' in shown, repr(shown)
            for invalid in ('not a choice', '$invalid', '@main invalid', '!invalid'):
                send(invalid + '\r')
                wait('Choose n (next)')
                wait('chop [n/p/d/x/q]> ')
                assert messages() == fixture, messages()
            send('p\t\r')
            wait('## [7/8] User (id: second)')
            wait('chop [n/p/d/x/q]> ')
            send('d\r')
            wait('## [7/7] Assistant (id: last)')
            wait('chop [n/p/d/x/q]> ')
            assert ids() == [m['id'] for m in fixture if m['id'] != 'second'], messages()
            send('\x03')
            wait('Chat chop closed.')
            wait('pmai> ')
            open_chop()
            send('/stop\r')
            wait('Chat chop closed.')
            wait('pmai> ')
            open_chop()
            send('q\r')
            wait('Chat chop closed.')
            wait('pmai> ')
            open_chop()
            send('\x04')
            deadline = time.monotonic() + 10
            while process.poll() is None:
                assert time.monotonic() < deadline, output.decode(errors='replace')
                read_pty(master, output, .05)
            assert process.wait(timeout=5) == 0
            assert termios.tcgetattr(master) == cooked
            saved_history = json.loads(history.read_text())
            for answer in ('n', 'p', 'd', 'x', 'q', 'not a choice', '$invalid', '@main invalid', '!invalid'):
                assert answer not in saved_history, saved_history
            assert ids() == [m['id'] for m in fixture if m['id'] != 'second'], messages()
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            os.close(master)
    print('PASS chat chop: navigation, linked deletion and trimming, immediate persistence, modal input and exits')


if __name__ == '__main__':
    main()
