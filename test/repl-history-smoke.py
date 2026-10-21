#!/usr/bin/env python3
"""Check saved input history commands and live terminal recall without a model."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

from smoke import clean_environment, expect_pty, read_pty, run_repl


def main():
    binary = str(Path(sys.argv[1]).resolve())
    with tempfile.TemporaryDirectory(prefix='pmai-history-') as directory:
        root = Path(directory)
        config = root / 'config.json'
        config.write_text(json.dumps({
            'providers': [], 'agents': [], 'memory': {'enabled': False},
            'use': {'plan': False}, 'ui': {'mode': 'classic'},
        }))
        env = clean_environment() | {'NO_COLOR': '1', 'HOME': str(root), 'TERM': 'xterm-256color'}
        command = [binary, '--config', str(config), '--home', str(root / 'home'),
                   '--no-stream', '--no-markdown']
        history = root / 'home/history.json'

        def run(commands, *, args=(), environment=env):
            return run_repl(command + list(args), commands, cwd=root, env=environment)

        output = run(['/history', '/history path', '/history help', '/help history'])
        assert 'No input history.' in output and str(history) in output, output
        assert output.count('/history del N') == 2, output
        assert json.loads(history.read_text()) == ['/help history', '/exit']

        # Preserve numbering across filtering and recent limits, including multiline input.
        seed = ['Alpha first', 'two lines\nsecond line', '/version', 'alpha last']
        for query, expected in [
            ('/history', ['1. Alpha first', '2. two lines\n     second line',
                          '3. /version', '4. alpha last']),
            ('/history list', ['1. Alpha first', '4. alpha last']),
            ('/history 2', ['3. /version', '4. alpha last']),
            ('/history list 1', ['4. alpha last']),
            ('/history search ALPHA', ['1. Alpha first', '4. alpha last']),
            ('/history search two lines', ['2. two lines\n     second line']),
            ('/history search missing', ['No matching input history.']),
        ]:
            history.write_text(json.dumps(seed))
            output = run([query])
            assert all(text in output for text in expected), (query, output)
            if query in ('/history 2', '/history list 1', '/history search ALPHA'):
                assert '2. two lines' not in output, output
            assert json.loads(history.read_text()) == seed + ['/exit']

        history.write_text(json.dumps(seed))
        output = run(['/history del 2', '/history'])
        assert 'Deleted input history entry 2.' in output, output
        assert '2. /version' in output and '3. alpha last' in output, output
        assert json.loads(history.read_text()) == [seed[0], *seed[2:], '/exit']
        for invalid in ('del 0', 'del -1', 'del 999', 'del', 'del 1 extra',
                        '0', '-1', 'list 0', 'list extra', 'search', 'clear extra',
                        'path extra', 'unknown'):
            history.write_text(json.dumps(seed))
            output = run(['/history ' + invalid])
            assert 'Usage: /history' in output, (invalid, output)
            assert json.loads(history.read_text()) == seed + ['/exit'], invalid

        # Clearing persists immediately; later commands cannot resurrect old entries.
        output = run(['/history clear', '/history', '/version', '/version', '/history'])
        assert 'Input history cleared.' in output and 'No input history.' in output, output
        assert '1. /version' in output and 'Alpha first' not in output, output
        assert json.loads(history.read_text()) == ['/version', '/exit']
        assert '1. /version' in run(['/history']), 'history was not loaded on restart'

        output = run(['/history clear', 'entered user prompt', 'entered user prompt', '/history'])
        assert '1. entered user prompt' in output, output
        assert json.loads(history.read_text()) == ['entered user prompt', '/exit']
        exported = root / 'history.txt'
        run([f'/history > {exported}'])
        assert exported.read_text() == '1. entered user prompt\n2. /exit\n'

        # Both path overrides work and leave the default file alone.
        saved = history.read_bytes()
        for flag in (False, True):
            custom = root / ('flag-history.json' if flag else 'env-history.json')
            custom.write_text(json.dumps(['custom input']))
            output = run(['/history path', '/history clear', '/history'],
                         args=['--history', str(custom)] if flag else (),
                         environment=env if flag else env | {'PMAI_HISTORY': str(custom)})
            assert str(custom) in output and 'No input history.' in output, output
            assert json.loads(custom.read_text()) == ['/exit']
            assert history.read_bytes() == saved

        # A failed write reports an error and preserves the live history.
        blocked = root / 'blocked-history'
        blocked.mkdir()
        result = subprocess.run(command + ['--history', str(blocked)], cwd=root, env=env,
                                input='/version\n/history clear\n/history\n/exit\n',
                                text=True, capture_output=True, timeout=30)
        assert result.returncode == 0 and 'error:' in result.stderr, result
        assert 'Input history cleared.' not in result.stdout, result.stdout
        assert '1. /version' in result.stdout, result.stdout

        if os.name != 'nt':
            import pty
            history.write_text(json.dumps(['/about', '/version']))
            master, slave = pty.openpty()
            process = subprocess.Popen(command, cwd=root, env=env,
                                       stdin=slave, stdout=slave, stderr=slave)
            os.close(slave)
            output = bytearray()

            def wait(text):
                return expect_pty(master, process, output, text, 15)

            def line(text, expected):
                output.clear()
                os.write(master, (text + '\r').encode())
                wait(expected)
                wait('pmai> ')

            try:
                wait('pmai> ')
                line('/history del 2', 'Deleted input history entry 2.')
                # Up must recall /about after deleting /version from the live editor.
                line('\x1b[A', 'Welcome to PocketMai!')
                line('/history clear', 'Input history cleared.')
                assert json.loads(history.read_text()) == []
                # Up and Ctrl+R must not recall cleared entries.
                os.write(master, b'\x1b[A')
                read_pty(master, output, .1)
                os.write(master, b'\x12about')
                wait('failed reverse-i-search')
                os.write(master, b'\x1b')
                read_pty(master, output, .15)
                line('/history', 'No input history.')
                line('/help history', '/history del N')
                line('/history', '1. /help history')
                os.write(master, b'/exit\r')
                deadline = time.monotonic() + 15
                while process.poll() is None:
                    assert time.monotonic() < deadline, output.decode(errors='replace')
                    read_pty(master, output, .1)
                assert process.wait(timeout=5) == 0
                assert json.loads(history.read_text()) == ['/help history', '/exit']
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)
                os.close(master)

    print('REPL history smoke passed')


if __name__ == '__main__':
    main()
