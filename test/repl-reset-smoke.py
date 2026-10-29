#!/usr/bin/env python3
"""Verify stock settings recovery, confirmation, cancellation and persistence."""
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import struct
import subprocess
import sys
import tempfile
import termios
import time

from smoke import clean_environment, expect_pty, read_pty, run_repl


def settings(output):
    return dict(re.findall(r'(?:^|> )([\w.]+) = (.*)$', output, re.MULTILINE))


def main():
    binary = str(Path(sys.argv[1]).resolve())
    env = clean_environment() | {'TERM': 'xterm-256color', 'NO_COLOR': '1'}
    with tempfile.TemporaryDirectory(prefix='pmai-reset-') as directory:
        root = Path(directory)
        config = root / 'config.json'
        config.write_text(json.dumps({
            'defaultAgent': 'main',
            'providers': [{'id': 'hello', 'kind': 'hello', 'apiKey': 'keep-credential'}],
            'agents': [
                {'id': 'main', 'provider': 'hello', 'model': 'keep-model',
                 'systemPrompt': 'main', 'instructions': 'Keep my instructions.',
                 'options': {'reasoningEffort': 'low', 'temperature': 0.3},
                 'toolNames': [], 'toolGroupNames': []},
                {'id': 'other', 'provider': 'hello', 'model': '',
                 'options': {'reasoningEffort': 'high'}},
            ],
            'prompts': {'system': {'main': 'Keep my instructions.'}},
        }))
        args = [binary, '--config', str(config), '--home', str(root / 'home'), '--no-markdown']

        def run(commands, allow_errors=False):
            return run_repl(args, commands, cwd=root, env=env, allow_errors=allow_errors)

        stock = settings(run(['/set']))
        assert len(stock) > 40, stock
        original = json.loads(config.read_text())
        changes = [
            'effort max Extra reasoning guidance', 'tool.approval yolo', 'debug true',
            f'debugfile {root / "custom-debug.jsonl"}', 'airplane on', 'redact warn',
            'delegation subagent', 'tool.calling xml', 'tool.proxy all', 'tool.systemone true',
            'tool.auto off', 'limits.maxToolCalls 9', 'limits.maxModelTurns 7',
            'limits.maxSubagents 3', 'limits.maxSubagentDepth 4', 'limits.maxTotalTokens 1234',
            'limits.maxSeconds 123', 'retry.attempts 8', 'retry.delay 0.1',
            'ctx.compact 32000', 'ctx.recent 1000', 'ctx.window 50000', 'ctx.strategy smart',
            'export.tools on', 'export.thinking on', 'ui.mode classic', 'ui.scroll 7',
            'ui.scrollbar -3', 'ui.title Custom', 'ui.editor cat', 'ui.highlight needle',
            'ui.markdown off', 'ui.tools all', 'ui.thinking full', 'ui.subagents none',
            'ui.broadcast on', 'ui.toolgroups on', 'use.agentsmd on', 'use.plan off',
            'voice.input command', 'voice.output command', 'voice.provider hello',
            'voice.language ca-ES', 'voice.voice custom', 'voice.speed 2',
            'voice.mode walkie-talkie', 'voice.silenceSeconds 2', 'voice.speechThreshold 0.1',
            'voice.maximumRecordingSeconds 120', 'voice.transcriptionModel custom-input',
            'voice.speechModel custom-output',
            'voice.captureCommand {"executable":"cat"}',
            'voice.transcriptionCommand {"executable":"cat"}',
            'voice.speechCommand {"executable":"cat"}',
            'voice.playbackCommand {"executable":"cat"}',
        ]
        run(['/set ' + change for change in changes])
        modified = settings(run(['/set']))
        assert modified != stock
        # Reset each exposed setting individually, preserving every other one.
        expected = modified.copy()
        for key in stock:
            output = run(['/reset ' + key, '/set'])
            assert 'reset · cancel' not in output, (key, output)
            expected[key] = stock[key]
            current = settings(output)
            assert current == expected, (key, expected, current, output)
        # Theme colors use their UI keys and reset independently too.
        run(['/theme color bgcolor #123456', '/theme color fgprompt cyan'])
        themed = json.loads(config.read_text())
        run(['/reset ui.bgcolor'])
        themed['ui']['bgcolor'] = ''
        assert json.loads(config.read_text()) == themed
        before_invalid = config.read_bytes()
        for command in ['/reset unknown', '/reset ui.', '/reset voice', '/reset ui.scroll 2', '/reset reset']:
            output = run([command], allow_errors=True)
            assert 'error:' in output and 'reset · cancel' not in output, output
            assert config.read_bytes() == before_invalid, command
        run(['/set ' + change for change in changes])
        assert settings(run(['/set'])) == modified
        before = config.read_bytes()
        for commands in [
            ['/reset', 'cancel'], ['/reset'], ['/reset', 'yes', 'cancel'],
            ['/reset', '/set effort'],
        ]:
            output = run(commands)
            assert 'Reset all /set options to stock defaults.' not in output, output
            assert config.read_bytes() == before, commands
            assert settings(run(['/set'])) == modified, commands
        eof = subprocess.run(args, input='/reset\n', cwd=root, env=env,
                             capture_output=True, text=True, timeout=15)
        assert eof.returncode == 0 and config.read_bytes() == before, eof.stdout + eof.stderr

        output = run(['/chat rename reset-recovery', '/reset', 'reset', '/set'])
        assert 'reset · cancel' in output and 'Reset all /set options to stock defaults.' in output, output
        assert settings(output) == stock, (stock, settings(output), output)
        assert settings(run(['/set'])) == stock, 'Defaults did not survive restart'
        resumed = run_repl(args + ['-r', 'reset-recovery'], ['/set'], cwd=root, env=env)
        assert settings(resumed) == stock, 'The saved chat restored stale settings'
        saved = json.loads(config.read_text())
        for key in ['providers', 'prompts']:
            assert saved[key] == original[key], key
        assert saved['agents'][1] == original['agents'][1]
        for key in ['model', 'provider', 'instructions', 'systemPrompt', 'toolNames', 'toolGroupNames']:
            assert saved['agents'][0][key] == original['agents'][0][key], key
        assert saved['agents'][0]['options']['temperature'] == 0.3
        assert saved['approvals']['mode'] == 'ask'

        # Both interactive layouts retain settings until an explicit answer;
        # Ctrl+C and the cancel choice leave the persisted file untouched.
        capture = root / 'capture.py'
        capture.write_text('import sys,time\nwhile True:\n sys.stdout.buffer.write(bytes(3200));sys.stdout.buffer.flush();time.sleep(.1)\n')
        for mode in ['classic', 'buffer']:
            run([f'/set ui.mode {mode}', '/set voice.speed 2',
                 '/set voice.input command', '/set voice.output command',
                 '/set voice.mode walkie-talkie',
                 '/set voice.captureCommand ' + json.dumps({
                     'executable': sys.executable, 'arguments': [str(capture)]}),
                 '/set voice.transcriptionCommand {"executable":"cat"}',
                 '/set voice.speechCommand {"executable":"cat"}'])
            before = config.read_bytes()
            master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 32, 140, 0, 0))
            process = subprocess.Popen(args, cwd=root, env=env, stdin=slave, stdout=slave,
                                       stderr=slave, start_new_session=True)
            os.close(slave)
            pending = bytearray()

            def wait(text):
                return expect_pty(master, process, pending, text, 15)

            def send(text):
                os.write(master, (text + '\r').encode())

            try:
                wait('pmai>')
                send('/voice on')
                wait('walkie-talkie · listening')
                send('/reset')
                wait('reset [reset/cancel]>')
                assert config.read_bytes() == before
                os.write(master, b'\x03')
                wait('Reset cancelled.')
                wait('pmai#1>')
                assert config.read_bytes() == before
                send('/voice status')
                wait('Voice: listening')
                send('/reset')
                wait('reset [reset/cancel]>')
                send('cancel')
                wait('Reset cancelled.')
                wait('pmai#1>')
                assert config.read_bytes() == before
                send('/reset')
                wait('reset [reset/cancel]>')
                send('reset')
                wait('Reset all /set options to stock defaults.')
                send('/voice status')
                wait('Voice: off')
                send('/set voice.speed')
                wait('voice.speed = 1')
                send('/exit')
                deadline = time.monotonic() + 15
                while process.poll() is None:
                    assert time.monotonic() < deadline, pending.decode(errors='replace')
                    read_pty(master, pending, .05)
                assert process.returncode == 0
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                os.close(master)

        # Reset also works before any provider or agent has been configured.
        empty = root / 'empty.json'
        empty.write_text('{}')
        output = run_repl([binary, '--config', str(empty), '--home', str(root / 'empty-home')],
                          ['/reset', 'reset'], cwd=root, env=env)
        assert 'Reset all /set options to stock defaults.' in output, output
        assert json.loads(empty.read_text())['agents'] == []
    print('PASS /reset: individual defaults and colors, stock defaults, confirmation, cancel, EOF, Ctrl+C, both layouts, persistence')


if __name__ == '__main__':
    main()
