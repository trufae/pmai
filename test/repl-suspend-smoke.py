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
            'providers': [{'id': 'offline', 'kind': 'hello'}],
            'agents': [{'id': 'smoke', 'provider': 'offline', 'model': 'hello',
                        'toolGroupNames': [], 'enabled': True}],
            'memory': {'enabled': False, 'scope': 'project'},
            'use': {'plan': False},
        }))
        # A child in an isolated session alone has no shell to implement fg;
        # an orphaned process group can even discard SIGTSTP entirely.
        pid, master = pty.fork()
        if pid == 0:
            os.chdir(root)
            env = {k: v for k, v in os.environ.items()
                   if not k.startswith(('PMAI_', 'MAI_', 'OPENAI_'))}
            env.update(TERM='xterm-256color', PS1='SHELL_READY> ',
                       PROMPT_COMMAND='', LC_ALL='C')
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

            # Every Tab applies the highlighted item, including items which
            # were offscreen. Enter must submit that item, and editing resets
            # the menu instead of retaining the old completion candidates.
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 32, 0, 0))
            send(b'/set tool.calling ')
            for option in ('automatic', 'json', 'native', 'text', 'xml', 'automatic', 'json'):
                send(b'\t')
                wait_for(re.compile(rb'\x1b\[44m\x1b\[97m' + option.encode() + rb'\x1b\[0m'))
            send(b'\r')
            wait_for('Set tool.calling = json')
            send(b'/set tool.calling \t')
            wait_for(re.compile(rb'\x1b\[44m\x1b\[97mautomatic\x1b\[0m'))
            send(b'\x7f\t\r')
            wait_for('Set tool.calling = automatic')
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

            send(b'/exit\r')
            wait_for('SHELL_READY> ')
            assert termios.tcgetattr(master) == cooked, 'exit left the tty in raw mode'
            print('PASS: 8 Ctrl+Z/fg cycles preserve input, editing, Enter and shell termios')
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
