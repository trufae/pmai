#!/usr/bin/env python3
"""Exercise compaction decisions and slash commands through an offline REPL PTY."""
import fcntl
import json
from smoke import expect_pty
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


def main(clear_action):
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
                   '--no-stream', '--no-markdown', '--tool-approval', 'yolo']
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
            return expect_pty(master, process, output, text, timeout)

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
            send(clear_action)
            wait_for('Conversation cleared.')
            wait_for('Hello from MaiCore: fourth')
            wait_for('took')
            assert b'cancelled' not in output, output
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
            chats = list((root / '.pmai/chats').glob('*.json'))
            assert chats
            for file in chats:
                messages = json.loads(file.read_text())['messages']
                conversation = [m for m in messages if m['role'] not in ('system', 'developer')]
                assert [m['role'] for m in conversation] == ['user', 'assistant'], conversation
                assert conversation[0]['content'] == [{'text': {'_0': 'fourth'}}], conversation
                assert 'Hello from MaiCore: fourth' in json.dumps(conversation[1]), conversation
                assert 'OLD-CONTEXT' not in json.dumps(messages), messages
            print(f'PASS compaction prompt with YOLO: model changes, skip, stop, compact, {clear_action} continues')
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            os.close(master)


if __name__ == '__main__':
    for clear_action in ('x', 'clear', '/chat clear'):
        main(clear_action)
