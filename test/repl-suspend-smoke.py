#!/usr/bin/env python3
"""Exercise Ctrl+Z/fg through a job-controlling shell, without a network provider."""
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import select
import shlex
import shutil
import signal
import struct
import sys
import tempfile
import termios
import time

PROMPT = re.compile(rb'pmai(?:#[0-9]+)?>')


def main():
    binary = str(Path(sys.argv[1]).resolve())
    with tempfile.TemporaryDirectory(prefix='pmai-suspend-') as directory:
        root = Path(directory)
        config = root / 'config.json'
        config.write_text(json.dumps({
            'version': 1, 'defaultAgent': 'smoke',
            'providers': [{'id': name, 'kind': 'hello'} for name in ('offline', 'other')],
            'agents': [{'id': 'smoke', 'provider': 'offline', 'model': 'hello',
                        'toolGroupNames': [], 'enabled': True}],
            'memory': {'enabled': False, 'scope': 'project'},
            'use': {'plan': False},
        }))
        editor = root / 'editor.py'
        editor.write_text('''import json, pathlib, signal, sys
root = pathlib.Path(__file__).parent
count = root / 'editor-count'
number = int(count.read_text()) + 1 if count.exists() else 1
count.write_text(str(number))
blocked = signal.pthread_sigmask(signal.SIG_BLOCK, [])
assert not blocked.intersection({signal.SIGINT, signal.SIGTSTP, signal.SIGTTIN, signal.SIGTTOU}), blocked
assert all(signal.getsignal(number) != signal.SIG_IGN
           for number in (signal.SIGINT, signal.SIGTSTP, signal.SIGTTIN, signal.SIGTTOU))
path = pathlib.Path(sys.argv[1])
(root / ('seen-' + str(number))).write_bytes(path.read_bytes())
print('EDITOR_READY_' + str(number), flush=True)
action = input()
if action == 'save':
    path.write_bytes((root / 'next-provider').read_bytes())
elif action == 'fail':
    sys.exit(7)
''')
        # A child in an isolated session alone has no shell to implement fg;
        # an orphaned process group can even discard SIGTSTP entirely.
        pid, master = pty.fork()
        if pid == 0:
            os.chdir(root)
            env = {k: v for k, v in os.environ.items()
                   if not k.startswith(('PMAI_', 'MAI_', 'OPENAI_'))}
            env.update(TERM='xterm-256color', PS1='SHELL_READY> ',
                       PROMPT_COMMAND='', LC_ALL='C', EDITOR=shlex.join([sys.executable, str(editor)]))
            env.pop('NO_COLOR', None)
            os.execvpe('bash', ['bash', '--noprofile', '--norc', '-i'], env)

        output = bytearray()
        job_pid = None

        def send(data):
            os.write(master, data)

        def wait_for(text):
            needle = re.compile(re.escape(text.encode())) if isinstance(text, str) else text
            deadline = time.monotonic() + 15
            while (match := needle.search(output)) is None:
                assert time.monotonic() < deadline, (text, output.decode(errors='replace'))
                if select.select([master], [], [], .1)[0]:
                    output.extend(os.read(master, 65536))
            end = match.end()
            captured = bytes(output[:end])
            del output[:end]
            return captured

        def wait_for_foreground():
            deadline = time.monotonic() + 15
            while os.tcgetpgrp(master) != job_pid:
                assert time.monotonic() < deadline, output.decode(errors='replace')
                if select.select([master], [], [], .01)[0]:
                    output.extend(os.read(master, 65536))

        try:
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 100, 0, 0))
            wait_for('SHELL_READY> ')
            # Disable bash's line editor, so shell termios are directly testable.
            send(b'set +o emacs; set +o vi\n')
            wait_for('SHELL_READY> ')
            cooked = termios.tcgetattr(master)
            command = shlex.join([binary, '--config', str(config), '--home',
                                  str(root / 'home'), '--no-stream', '--no-markdown'])
            send(command.encode() + b'\n')
            wait_for(PROMPT)
            job_pid = os.tcgetpgrp(master)
            assert job_pid != pid, 'pmai must have its own foreground process group'

            # Finish the current word before offering its arguments. Commands
            # inferred from longer candidates must appear only once in the menu.
            for prefix, options in (
                ('/model', ('/model', '/model-aproval', '/model-chat', '/model-compact',
                            '/model-tool', '/models', '/model')),
                ('/provider', ('/provider', '/providers', '/provider')),
                ('/edit memory', ('memory', 'memory-prompt', 'memory')),
            ):
                send(prefix.encode())
                for option in options:
                    send(b'\t')
                    wait_for(f'\x1b[97;44m{option}\x1b[0m')
                send(b'\x03')
                wait_for('Nothing to cancel.')
            send(b'/model \t')
            wait_for('hello\x1b[0m')
            send(b'\x03')
            wait_for('Nothing to cancel.')
            send(b'/mcp\t')
            wait_for('/mcp \x1b[0m')
            send(b'\t')
            wait_for('\x1b[97;44madd\x1b[0m')
            send(b'\x03')
            wait_for('Nothing to cancel.')
            print('PASS: command and argument completion respects word boundaries')

            # Every Tab applies the highlighted item, including items which
            # were offscreen. Enter must submit that item, and editing resets
            # the menu instead of retaining the old completion candidates.
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 32, 0, 0))
            send(b'/set tool.calling ')
            for option in ('automatic', 'json', 'native', 'text', 'xml', 'automatic', 'json'):
                send(b'\t')
                wait_for(f'\x1b[97;44m{option}\x1b[0m')
            send(b'\r')
            wait_for('Set tool.calling = json')
            send(b'/set tool.calling \t')
            wait_for('\x1b[97;44mautomatic\x1b[0m')
            send(b'\x7f\t\r')
            wait_for('Set tool.calling = automatic')
            send(b'/provider use o\t')
            wait_for('/provider use offline')
            send(b'\t')
            wait_for('/provider use other')
            send(b'\r')
            wait_for('Provider: other (saved for agent smoke)')
            send(b'/edit provider\t')
            wait_for('/edit provider \x1b[0m')
            send(b'o\t')
            wait_for('/edit provider offline')
            send(b'\t')
            wait_for('/edit provider other')
            send(b'\x03')
            wait_for('Nothing to cancel.')
            send(b'/edit provider o\t')
            wait_for('/edit provider offline')
            send(b'\x03')
            wait_for('Nothing to cancel.')
            print('PASS: completion selection, wraparound, narrow rows and editing')

            for cycle in range(8):
                # Keep an unfinished line across suspension and a shell command.
                prefix = f'resume-{cycle}'
                send(prefix.encode())
                wait_for(prefix)
                send(b'\x1a')
                wait_for('Stopped')
                wait_for('SHELL_READY> ')
                assert termios.tcgetattr(master) == cooked, 'shell tty was not restored'
                send(b'echo SHELL_WORKS\n')
                wait_for('SHELL_READY> ')
                fcntl.ioctl(master, termios.TIOCSWINSZ,
                            struct.pack('HHHH', 32 + cycle, 90 + cycle, 0, 0))
                send(b'fg\n')
                wait_for(PROMPT)
                raw = termios.tcgetattr(master)
                assert not raw[3] & (termios.ICANON | termios.ECHO | termios.ISIG), raw
                assert not raw[0] & (termios.ICRNL | termios.IXON), raw
                # Editing and Enter must work, with the original draft retained.
                send(b'x\x7f-ok\r')
                wait_for(f'Hello from MaiCore: {prefix}-ok')
                # The persistent prompt is redrawn as soon as Enter is accepted,
                # before the response arrives. Waiting for it after the response
                # races with that redraw and times out even though the editor is
                # ready. Synchronize on the turn-completion note instead.
                wait_for('✓ took')

            print('PASS: 8 Ctrl+Z/fg cycles preserve input, editing, Enter and shell termios')

            # An editor must inherit normal signals even when launched from a
            # Swift worker. Ctrl+Z must stop the whole job, including pmai.
            send(b'/edit provider other\r')
            wait_for('EDITOR_READY_1')
            for _ in range(2):
                send(b'\x1a')
                wait_for('Stopped')
                wait_for('SHELL_READY> ')
                assert termios.tcgetattr(master) == cooked
                send(b'echo EDITOR_SHELL_WORKS\n')
                wait_for('SHELL_READY> ')
                send(b'fg\n')
                # fg echoes the command before the resumed editor reads again.
                wait_for(command)
                wait_for_foreground()

            before = config.read_bytes()
            current = json.loads((root / 'seen-1').read_text())
            assert all(field in current for field in ('displayName', 'timeout', 'headers',
                                                      'headerEnvironment', 'options'))
            assert any('precedence' in line for line in current['_credentialHelp'])
            provider = {'id': 'other', 'kind': 'openAICompatible',
                        'baseURL': 'http://127.0.0.1:1/v1', 'defaultModel': 'draft-model'}
            invalid = [
                (json.dumps(provider | {'baseUrL': 'old'}), "Use 'baseURL' instead of 'baseUrL'"),
                (json.dumps(provider | {'timeout': 'old'}), 'positive number of seconds'),
                (json.dumps(provider | {'timeout': -1}), 'positive number of seconds'),
                (json.dumps(provider | {'headers': 3}), 'object of header names to string values'),
                (json.dumps(provider | {'headerEnvironment': {'X-Token': 'PMAI_UNSET_TEST_TOKEN'}}),
                 'Export PMAI_UNSET_TEST_TOKEN before starting pmai'),
                (json.dumps(provider | {'apiKeyFile': str(root / 'missing-key')}), 'read permissions'),
                (json.dumps(provider | {'kind': 'OpenAICompatible'}), "Check kind's spelling and case"),
                (json.dumps(provider | {'baseURL': 'old-url'}), 'Use the API endpoint'),
                (json.dumps({key: value for key, value in provider.items() if key != 'kind'}),
                 "Invalid value for 'kind'"),
                ('{"id": "other", bad', 'Check commas, matching braces'),
            ]
            for number, (draft, hint) in enumerate(invalid, 1):
                (root / 'next-provider').write_text(draft)
                send(b'save\n')
                wait_for(hint)
                wait_for('Press Enter to reopen the provider editor (Ctrl+C to cancel)> ')
                # No launch until Enter, and no invalid data persisted.
                time.sleep(.15)
                assert int((root / 'editor-count').read_text()) == number
                assert config.read_bytes() == before
                if number == 1:
                    # The retry prompt uses normal REPL job-control handling.
                    send(b'\x1a')
                    wait_for('Stopped')
                    wait_for('SHELL_READY> ')
                    assert termios.tcgetattr(master) == cooked
                    send(b'fg\n')
                    wait_for('Press Enter to reopen')
                send(b'\r')
                wait_for(f'EDITOR_READY_{number + 1}')
                assert (root / f'seen-{number + 1}').read_text() == draft

            (root / 'next-provider').write_text(json.dumps(provider))
            send(b'save\n')
            wait_for("Provider 'other' saved")
            wait_for('and reloaded.')
            saved = next(p for p in json.loads(config.read_text())['providers'] if p['id'] == 'other')
            # The legacy provider kind is accepted, then saved under its canonical name.
            assert saved == provider | {'kind': 'openai', 'headers': {}, 'headerEnvironment': {}, 'options': {}}, saved
            print('PASS: provider retry pauses, contextual hints, draft retention, save and Ctrl+Z/fg')

            # Ctrl+C and EOF at the error prompt cancel only the invalid edit.
            for number, cancel in ((12, b'\x03'), (13, b'\x04')):
                before = config.read_bytes()
                send(b'/edit provider other\r')
                wait_for(f'EDITOR_READY_{number}')
                (root / 'next-provider').write_text(json.dumps(provider | {'baseURL': 'bad'}))
                send(b'save\n')
                wait_for('Press Enter to reopen the provider editor (Ctrl+C to cancel)> ')
                send(cancel)
                wait_for('Provider edit canceled')
                assert config.read_bytes() == before
                assert int((root / 'editor-count').read_text()) == number

            # Closing a reopened invalid draft without changes cancels it.
            before = config.read_bytes()
            send(b'/edit provider other\r')
            wait_for('EDITOR_READY_14')
            send(b'save\n')
            wait_for('Press Enter to reopen the provider editor (Ctrl+C to cancel)> ')
            send(b'\r')
            wait_for('EDITOR_READY_15')
            send(b'quit\n')
            wait_for('Provider edit canceled')
            assert config.read_bytes() == before

            # Real Vim uses its own raw mode and suspend handler. Exercise that
            # path too, including modified buffer retention across fg.
            if shutil.which('vim'):
                ready = root / 'vim-ready'
                vim = f"vim -Nu NONE -n -i NONE -c \"call writefile(['ready'], '{ready}')\""
                send(('/set ui.editor ' + vim + '\r').encode())
                wait_for('Set ui.editor =')
                send(b'/edit provider other\r')
                deadline = time.monotonic() + 15
                while not ready.exists():
                    assert time.monotonic() < deadline
                    if select.select([master], [], [], .1)[0]:
                        output.extend(os.read(master, 65536))
                send(b'gg0i \x1b')
                for _ in range(2):
                    send(b'\x1a')
                    wait_for('Stopped')
                    wait_for('SHELL_READY> ')
                    assert termios.tcgetattr(master) == cooked
                    send(b'fg\n')
                    wait_for(command)
                    wait_for_foreground()
                    time.sleep(.1)
                send(b':wq\r')
                wait_for("Provider 'other' saved")
                wait_for('and reloaded.')
                print('PASS: real Vim preserves its modified buffer through repeated Ctrl+Z/fg')

            # Shell escapes share the same launcher and must also recover
            # after a terminal interrupt or a nonzero editor exit.
            send(b'!kill -STOP $$; echo SHELL_RESUMED\r')
            wait_for('Stopped')
            wait_for('SHELL_READY> ')
            assert termios.tcgetattr(master) == cooked
            send(b'fg\n')
            wait_for('SHELL_RESUMED\r\n')
            wait_for_foreground()
            wait_for(PROMPT)
            send(b'!echo SLEEP_READY; exec sleep 30\r')
            wait_for('SLEEP_READY\r\n')
            send(b'\x03')
            wait_for('killed by signal 2')
            send(b'/set ui.editor command-that-does-not-exist-pmai\r')
            wait_for('Set ui.editor =')
            send(b'/edit provider other\r')
            wait_for('Editor exited with status 127')
            send(b'/provider\r')
            wait_for('Current provider: other')
            print('PASS: error cancellation, Ctrl+C in shell command, missing editor and REPL recovery')

            send(b'/exit\r')
            wait_for('SHELL_READY> ')
            assert termios.tcgetattr(master) == cooked, 'exit left the tty in raw mode'
        finally:
            if job_pid is not None:
                try:
                    os.killpg(job_pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
            os.close(master)


if __name__ == '__main__':
    main()
