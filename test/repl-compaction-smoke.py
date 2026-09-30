#!/usr/bin/env python3
"""Exercise compaction decisions and slash commands through an offline REPL PTY."""
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import struct
import subprocess
import sys
import tempfile
import termios
import time


def main():
    binary = str(Path(sys.argv[1]).resolve())
    environment = {k: v for k, v in os.environ.items()
                   if not k.startswith(('PMAI_', 'MAI_', 'OPENAI_'))}
    environment['TERM'] = 'xterm-256color'
    with tempfile.TemporaryDirectory(prefix='pmai-compaction-') as directory:
        root = Path(directory)
        config = root / 'config.json'
        config.write_text(json.dumps({
            'defaultAgent': 'main', 'providers': [{'id': 'hello', 'kind': 'hello'}],
            'agents': [{'id': 'main', 'provider': 'hello', 'model': 'original',
                        'autocompact': {'tokens': 1}, 'toolNames': [], 'toolGroupNames': []}],
            'memory': {'enabled': False}, 'use': {'plan': False},
        }))
        command = [binary, '--config', str(config), '--home', str(root / 'home'),
                   '--no-stream', '--no-markdown', '--tool-aproval', 'yolo']
        seed = subprocess.run(command + ['OLD-CONTEXT ' * 300], cwd=root, env=environment,
                              capture_output=True, timeout=20)
        assert seed.returncode == 0, seed.stderr
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 200, 0, 0))
        process = subprocess.Popen(command + ['--resume'], cwd=root, env=environment,
                                   stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        output = bytearray()

        def wait_for(text, timeout=15):
            needle = text.encode()
            end = time.monotonic() + timeout
            while needle not in output:
                assert time.monotonic() < end, (text, output.decode(errors='replace'))
                assert process.poll() is None, (process.returncode, output)
                if select.select([master], [], [], .05)[0]:
                    output.extend(os.read(master, 65536))
            del output[:output.index(needle) + len(needle)]

        def send(text):
            output.clear()
            os.write(master, (text + '\r').encode())

        try:
            wait_for('pmai> ')
            send('second')
            wait_for('[y] summarize')
            send('m')
            wait_for('Use /model NAME')
            send('/model hello::replacement')
            wait_for('Model: hello::replacement')
            send('/model -compact hello::summarizer')
            wait_for('compact: task-compact (saved)')
            send('n')
            wait_for('Hello from MaiCore: second')
            send('third')
            wait_for('[y] summarize')
            send('c')
            wait_for('cancelled')
            send('/continue')
            wait_for('[y] summarize')
            send('y')
            wait_for('compacting')
            wait_for('Hello from MaiCore: third')
            send('fourth')
            wait_for('[y] summarize')
            send('x')
            wait_for('Conversation cleared.')
            send('/exit')
            # Drain output while exiting so the PTY cannot block persistence.
            end = time.monotonic() + 10
            while process.poll() is None:
                assert time.monotonic() < end, output
                if select.select([master], [], [], .05)[0]:
                    try:
                        output.extend(os.read(master, 65536))
                    except OSError:
                        break
            assert process.wait(timeout=5) == 0
            for file in (root / '.pmai/chats').glob('*.json'):
                messages = json.loads(file.read_text())['messages']
                assert not any(message['role'] == 'user' for message in messages), messages
            print('PASS compaction prompt with YOLO: model changes, skip, stop, compact, clear')
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            os.close(master)


if __name__ == '__main__':
    main()
