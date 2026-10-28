#!/usr/bin/env python3
"""Check slash-command stdout redirection and bracketed-paste provenance."""
import fcntl
import json
import os
from pathlib import Path
import pty
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile
import termios
import time

from smoke import clean_environment, expect_pty, read_pty


def controlling_terminal():
    os.setsid()
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)


def main():
    binary = str(Path(sys.argv[1]).resolve())
    env = clean_environment() | {'TERM': 'xterm-256color', 'NO_COLOR': '1'}
    with tempfile.TemporaryDirectory(prefix='pmai-redirection-') as directory:
        root = Path(directory)
        config = root / 'config.json'
        config.write_text(json.dumps({
            'defaultAgent': 'main',
            'providers': [{'id': 'offline', 'kind': 'hello'}],
            'agents': [{'id': 'main', 'provider': 'offline', 'model': 'hello',
                        'toolGroupNames': []}],
            'memory': {'enabled': False}, 'use': {'plan': False, 'agentsmd': 'off'},
            'ui': {'mode': 'classic'},
        }))
        command = [binary, '--config', str(config), '--home', str(root / 'home'),
                   '--no-stream', '--no-markdown']
        noisy_filter = shlex.join([sys.executable, '-c',
            'import sys; sys.stderr.write("E"*150000); sys.stdout.write("O"*150000); sys.stdin.read()'])
        (root / 'version.txt').write_text('REPLACE THIS CONTENT')
        result = subprocess.run(command, cwd=root, env=env, capture_output=True, text=True,
                                input='\n'.join([
                                    'banana café',
                                    '/msg last > "last response.txt"',
                                    '/version > version.txt',
                                    '/version >> version.txt',
                                    '/msg log > history.txt',
                                    '/msg last | grep banana | tr a-z A-Z',
                                    '/msg last | cat > pipe.txt',
                                    '/msg last | head -c 1',
                                    '/version | ' + noisy_filter,
                                    '/help shell > help.txt',
                                    '/btw banana side question > btw.txt',
                                    'ordinary > literal.txt | cat',
                                    '/msg last > ordinary.txt',
                                    '/version > missing/directory/file.txt',
                                    '/version | sh -c "cat >/dev/null; exit 7"',
                                    '/version >',
                                    '/version > recovered.txt',
                                    '/exit', '',
                                ]), timeout=30)
        assert result.returncode == 0, result.stdout + result.stderr
        response = 'Hello from MaiCore: banana café\n'
        assert (root / 'last response.txt').read_text() == response
        assert (root / 'pipe.txt').read_text() == response
        version = (root / 'recovered.txt').read_text()
        assert version.strip() and (root / 'version.txt').read_text() == version * 2
        assert 'banana café' in (root / 'history.txt').read_text()
        assert '\x1b' not in (root / 'history.txt').read_text()
        assert 'BANANA CAFé' in result.stdout, result.stdout
        assert 'O' * 150000 in result.stdout and 'E' * 150000 in result.stderr
        assert 'banana side question' in (root / 'btw.txt').read_text()
        assert 'ordinary > literal.txt | cat' in (root / 'ordinary.txt').read_text()
        assert not (root / 'literal.txt').exists()
        assert '/COMMAND >> FILE' in (root / 'help.txt').read_text()
        assert 'redirection:' in result.stderr and 'pipe exited with status 7' in result.stderr

        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 160, 0, 0))
        process = subprocess.Popen(command, cwd=root, env=env,
                                   stdin=slave, stdout=slave, stderr=slave, preexec_fn=controlling_terminal)
        os.close(slave)
        pending = bytearray()

        def wait(text):
            return expect_pty(master, process, pending, text, 10)

        def submit(data):
            os.write(master, data + b'\r')
            # A separate command gives a deterministic barrier after the output.
            os.write(master, b'/help redirection-test-barrier\r')
            wait("Unknown help topic 'redirection-test-barrier'")

        def paste(text):
            return b'\x1b[200~' + text.encode() + b'\x1b[201~'

        try:
            wait('pmai> ')
            os.write(master, b'banana terminal\r')
            wait('✓ took')
            if shutil.which('less'):
                os.write(master, b'/msg log|less\r')
                wait('(END)')
                os.write(master, b'q')
                wait('pmai#1> ')
                submit(b'/version > after-pager.txt')
                assert (root / 'after-pager.txt').read_text() == version
            submit(paste('/msg last > pasted.txt'))
            assert not (root / 'pasted.txt').exists()
            submit(paste('/msg last > literal.txt') + b' > typed.txt')
            assert not (root / 'literal.txt').exists()
            assert 'banana terminal' in (root / 'typed.txt').read_text()
            submit(b'/msg last > ' + paste('"pasted filename.txt"'))
            assert 'banana terminal' in (root / 'pasted filename.txt').read_text()
            submit(paste('/msg last > shifted.txt') + b'\x01  ')
            assert not (root / 'shifted.txt').exists()
            submit(b'xx' + paste('/msg last > deleted.txt') + b'\x01\x1b[3~\x1b[3~')
            assert not (root / 'deleted.txt').exists()
            # Operators inside quoted/escaped text do not start a process or file.
            submit(b'/msg last "| cat > quoted.txt"')
            submit(b'/msg last \\> escaped.txt')
            assert not (root / 'quoted.txt').exists() and not (root / 'escaped.txt').exists()
            os.write(master, b'/version | touch pipe-ready; sleep 30\r')
            deadline = time.monotonic() + 10
            while not (root / 'pipe-ready').exists():
                assert time.monotonic() < deadline, pending.decode(errors='replace')
                read_pty(master, pending, .05)
            read_pty(master, pending, .2)
            os.write(master, b'\x03')
            wait('pipe exited with status')
            submit(b'/version > after-cancel.txt')
            assert (root / 'after-cancel.txt').read_text() == version
            os.write(master, b'/exit\r')
            read_pty(master, pending, .5)
            assert process.wait(timeout=10) == 0
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            os.close(master)
    print('PASS: overwrite, append, shell filters, errors, literal messages, and paste-aware redirection')


if __name__ == '__main__':
    main()
