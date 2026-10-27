#!/usr/bin/env python3
"""Exercise voice settings, diagnostics and state controls without microphone access."""
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
    env = clean_environment()
    env.update(TERM='xterm-256color', NO_COLOR='1')
    with tempfile.TemporaryDirectory(prefix='pmai-voice-settings-') as directory:
        root = Path(directory)
        config = root / 'config.json'
        config.write_text(json.dumps({
            'version': 1, 'defaultAgent': 'test', 'ui': {'mode': 'buffer'},
            'providers': [{'id': 'test', 'kind': 'openai', 'baseURL': 'http://127.0.0.1:1/v1'}],
            'agents': [{'id': 'test', 'provider': 'test', 'model': 'test', 'toolNames': []}],
            'voice': {'language': 'ca-ES', 'input': 'command', 'output': 'command'},
        }))
        args = [binary, '--config', str(config), '--home', str(root / 'home'), '--no-markdown']
        invalid = [
            ('/set voice.input typo', "Unknown voice.input backend 'typo'"),
            ('/set voice.output typo', "Unknown voice.output backend 'typo'"),
            ('/set voice.provider missing', "Unknown voice.provider 'missing'"),
            ('/set voice.mode walkie', 'voice.mode must be realtime or walkie-talkie'),
            ('/set voice.speed fast', 'voice.speed expects a finite number'),
            ('/set voice.speed null', 'voice.speed expects a finite number'),
            ('/set voice.speed 0', 'voice.speed must be a number'),
            ('/set voice.silenceSeconds 11', 'voice.silenceSeconds must be a number'),
            ('/set voice.speechThreshold 0', 'voice.speechThreshold must be a number'),
            ('/set voice.maximumRecordingSeconds 301', 'voice.maximumRecordingSeconds must be a number'),
            ('/set voice.language ""', 'voice.language must be a language tag'),
            ('/set voice.voice ""', 'voice.voice must not be empty'),
            ('/set voice.speechCommand say hello', 'voice.speechCommand expects a JSON object'),
            ('/set voice.captureCommand {"executable":"cat","args":[]}', 'voice.captureCommand expects a JSON object'),
            ('/set voice. language ca-ES', 'Choose a setting: /set voice.KEY VALUE'),
            ('/set voice.typo true', 'Unknown voice setting'),
        ]
        # Let normal first-run configuration migrations finish before checking setters.
        run_repl(args, [], cwd=root, env=env)
        before = config.read_text()
        output = run_repl(args, [command for command, _ in invalid], cwd=root, env=env)
        for _, message in invalid:
            assert message in output, (message, output)
        assert config.read_text() == before, ('An invalid setting modified the config', before, config.read_text())
        output = run_repl(args, ['/voice ' + c for c in ('send', 'resume', 'record', 'discard', 'pause', 'cancel')]
                          + ['/voice typo', '/voice status', '/set voice.speed', '/set voice.captureCommand'], cwd=root, env=env)
        for command in ('send', 'resume', 'record', 'discard', 'pause', 'cancel'):
            assert f'Cannot {command}: voice is off' in output, output
        assert "Unknown command 'typo'" in output and 'Configured: mode=' in output, output
        assert 'Range: 0.25–4' in output and 'raw 16 kHz' in output, output

        capture = root / 'capture.py'
        capture.write_text('import sys,time\nwhile True:\n sys.stdout.buffer.write(bytes(3200));sys.stdout.buffer.flush();time.sleep(.1)\n')
        values = {
            'language': 'ca_ES', 'mode': 'walkie-talkie', 'input': 'command', 'output': 'command',
            'speed': 1.25, 'silenceSeconds': .2, 'speechThreshold': .0001, 'maximumRecordingSeconds': 300,
            'captureCommand': {'executable': sys.executable, 'arguments': [str(capture)]},
            'transcriptionCommand': {'executable': '/usr/bin/printf', 'arguments': ['']},
            'speechCommand': {'executable': '/bin/cat'},
            'playbackCommand': {'executable': '/bin/cat', 'arguments': ['{audio}']},
            'provider': 'test', 'transcriptionModel': 'fixture-input', 'speechModel': 'fixture-output',
            'voice': 'fixture-voice',
        }
        output = run_repl(args, [f'/set voice.{key} {json.dumps(value)}' for key, value in values.items()]
                          + ['/set voice.language ca_ES'] + [f'/set voice.{key}' for key in values], cwd=root, env=env)
        saved = json.loads(config.read_text())['voice']
        for key, value in values.items():
            expected = dict(value, arguments=[]) if isinstance(value, dict) and 'arguments' not in value else value
            assert saved[key] == expected, (key, saved)
            assert f'Set voice.{key}.' in output and f'voice.{key} =' in output, (key, output)
        assert 'Speech still uses voice ID' in output, output

        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 180, 0, 0))
        process = subprocess.Popen(args, cwd=root, env=env, stdin=slave, stdout=slave, stderr=slave,
                                   start_new_session=True)
        os.close(slave)
        pending = bytearray()

        def wait(text):
            return expect_pty(master, process, pending, text, 15)

        def send(text):
            os.write(master, (text + '\r').encode())

        try:
            wait('pmai>')
            send('/set voice.mode rea\t')
            wait('/set voice.mode realtime')
            wait('Set voice.mode')
            send('/set voice.mode walkie-talkie')
            wait('Set voice.mode')
            send('/voice on')
            wait('walkie-talkie · listening')
            send('/voice record')
            wait('already recording')
            send('/voice on')
            wait('already enabled')
            send('/set voice.speed 2')
            wait('Set voice.speed')
            send('/voice status')
            wait('speed=1.25')
            wait('Saved settings differ from active voice')
            send('/voice send')
            wait('No speech was recognized')
            send('/voice status')
            wait('Voice: error')
            wait('No speech was recognized')
            send('/voice resume')
            wait('walkie-talkie · listening')
            send('/voice pause')
            wait('walkie-talkie · paused')
            send('/voice send')
            wait('Nothing to send while paused')
            send('/voice off')
            wait('Voice: off')
            send('/set voice.captureCommand {"executable":"/this-capture-program-does-not-exist"}')
            wait('Set voice.captureCommand')
            send('/voice on')
            wait('Voice program failed (exit 127)')
            wait('/this-capture-program-does-not-exist')
            send('/voice off')
            wait('Voice: off')
            send('/exit')
            deadline = time.monotonic() + 10
            while process.poll() is None:
                assert time.monotonic() < deadline, pending.decode(errors='replace')
                read_pty(master, pending, .05)
            assert process.returncode == 0
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)
            os.close(master)
        run_repl(args, [f'/set voice.{key} null' for key in
                       ('provider', 'captureCommand', 'transcriptionCommand', 'speechCommand', 'playbackCommand')],
                 cwd=root, env=env)
        saved = json.loads(config.read_text())['voice']
        for key in ('provider', 'captureCommand', 'transcriptionCommand', 'speechCommand', 'playbackCommand'):
            assert saved.get(key) is None, (key, saved)
    print('repl voice settings smoke: ok')


if __name__ == '__main__':
    main()
