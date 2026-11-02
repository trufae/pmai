#!/usr/bin/env python3
"""Exercise the Termux PTY relay without an Android device or a Termux install."""
import base64
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile

RELAY = Path(__file__).resolve().parents[1] / 'app/src/main/assets/termux-terminal.py'


class Session:
    def __init__(self, home):
        self.listener = socket.socket()
        self.listener.bind(('127.0.0.1', 0))
        self.listener.listen(1)
        self.listener.settimeout(30)
        self.process = subprocess.Popen([sys.executable, str(RELAY), str(self.listener.getsockname()[1]),
            'test-token', '80', '24'], env=dict(os.environ, HOME=home, PREFIX='/usr', SHELL='/bin/bash'),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.socket, _ = self.listener.accept()
        self.socket.settimeout(30)
        self.reader = self.socket.makefile('rb')
        assert self.reader.readline() == b'test-token\n'
        self.output = b''

    def request(self, **fields):
        self.socket.sendall(json.dumps(fields).encode() + b'\n')

    def send(self, text):
        self.request(data=base64.b64encode(text.encode()).decode())

    def until(self, text):
        start = len(self.output)
        while text not in self.output[start:]:
            message = json.loads(self.reader.readline())
            assert 'exit' not in message, self.output
            self.output += base64.b64decode(message.get('data', ''))
        return self.output[start:]

    def close(self):
        self.reader.close()
        self.socket.close()
        self.listener.close()
        try:
            self.process.communicate(timeout=30)
        except subprocess.TimeoutExpired:
            self.process.kill()
            raise
        assert self.process.returncode == 0


with tempfile.TemporaryDirectory() as home:
    sessions = []
    try:
        first = Session(home); sessions.append(first)
        second = Session(home); sessions.append(second)
        # Disable echo so a marker only proves that the shell actually ran it.
        for session in sessions:
            session.send("stty -echo; export PS1='PMAI_READY> '; printf '\\nREADY_%s\\n' marker\n")
            session.until(b'READY_marker\r\n')
        first.send("export PMAI_TAB=first; printf 'DIR:%s\\n' \"$PWD\"; stty size; printf 'DONE_%s\\n' one\n")
        output = first.until(b'DONE_one\r\n')
        assert ('DIR:' + home).encode() in output, output
        assert b'24 80' in output, output
        second.send("printf 'OTHER:%s\\n' \"${PMAI_TAB-unset}\"; printf 'DONE_%s\\n' two\n")
        assert b'OTHER:unset' in second.until(b'DONE_two\r\n')
        first.request(columns=100, rows=35)
        first.send("stty size; printf 'RESIZED_%s\\n' ok\n")
        assert b'35 100' in first.until(b'RESIZED_ok\r\n')
        # Emit readiness from the foreground job, after bash has handed over
        # the tty; a marker from bash itself races with starting that job.
        first.send("sh -c 'printf \"SLEEP_%s\\n\" started; exec sleep 120'\n")
        first.until(b'SLEEP_started\r\n')
        first.send('\x03')
        # Wait for the shell to regain the foreground. Sending the next command
        # alongside Ctrl-C can legitimately flush that command from the PTY.
        first.until(b'PMAI_READY> ')
        first.send("printf 'INTERRUPTED_%s\\n' ok\n")
        first.until(b'INTERRUPTED_ok\r\n')
        second.send("printf '☃\\n'; exit 7\n")
        while True:
            message = json.loads(second.reader.readline())
            if 'exit' in message:
                assert message['exit'] == 7, message
                break
            second.output += base64.b64decode(message.get('data', ''))
        assert '☃'.encode() in second.output
    finally:
        for session in sessions:
            session.close()
print('Termux relay: independent PTYs, home, resize, Ctrl-C, UTF-8 and exit status passed')
