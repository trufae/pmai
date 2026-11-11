#!/usr/bin/env python3
"""Exercise visible editing, saved source, cancellation, and terminal restoration."""
import fcntl
import os
from pathlib import Path
import re
import select
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time


class Session:
    def __init__(self, binary, root):
        self.master, self.slave = os.openpty()
        self.original = termios.tcgetattr(self.slave)
        self.resize(100, 30)
        self.process = subprocess.Popen([binary, '--root', str(root)], stdin=self.slave,
                                        stdout=self.slave, stderr=self.slave)
        self.output = b''

    def resize(self, columns, rows):
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack('HHHH', rows, columns, 0, 0))

    def wait(self, text):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            visible = re.sub(rb'\x1b\[[0-?]*[ -/]*[@-~]', b'', self.output).decode(errors='replace')
            if text in visible:
                return
            if self.process.poll() is not None:
                raise AssertionError(f'Editor exited early: {visible[-3000:]}')
            if select.select([self.master], [], [], max(0, deadline - time.monotonic()))[0]:
                self.output += os.read(self.master, 65536)
        raise AssertionError(f'Missing {text!r}: {self.output[-3000:]!r}')

    def send(self, keys, expected):
        self.output = b''
        os.write(self.master, keys)
        self.wait(expected)

    def finish(self, keys=None, signum=None):
        if keys:
            os.write(self.master, keys)
        if signum:
            self.process.send_signal(signum)
        # Drain output while waiting, so the PTY cannot block terminal cleanup.
        deadline = time.monotonic() + 10
        while self.process.poll() is None and time.monotonic() < deadline:
            if select.select([self.master], [], [], 0.1)[0]:
                self.output += os.read(self.master, 65536)
        assert self.process.poll() is not None, 'Editor did not exit'
        assert self.process.returncode == (128 + signum if signum else 0), self.output
        restored = termios.tcgetattr(self.slave)
        # macOS may set PENDIN while changing back to canonical input; it is a
        # kernel retype request, not a terminal mode the editor failed to restore.
        restored[3] &= ~getattr(termios, 'PENDIN', 0)
        original = self.original.copy()
        original[3] &= ~getattr(termios, 'PENDIN', 0)
        assert restored == original, 'Terminal settings were not restored'

    def close(self):
        if self.process.poll() is None:
            self.process.kill()
            self.process.wait()
        os.close(self.master)
        os.close(self.slave)


def main():
    binary = str(Path(sys.argv[1]).resolve())
    repository = Path(__file__).resolve().parents[3]
    theme_path = Path('MaiCore/Sources/MaiCLI/Terminal/TerminalTheme.swift')
    config_path = Path('MaiCore/Sources/MaiCore/Configuration.swift')
    with tempfile.TemporaryDirectory(prefix='pmai-theme-editor-') as directory:
        root = Path(directory)
        for path in [theme_path, config_path]:
            (root / path).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(repository / path, root / path)
        original = (root / theme_path).read_text()
        session = Session(binary, root)
        try:
            session.wait('Ready. Edits stay in memory')
            session.wait('◢')
            session.wait('Update the greeting and add a test.')
            session.wait('Tool call')
            session.wait('Markdown italic')
            session.send(b'e#123456\r', 'default.backgroundLine = #123456')
            session.send(b'\t', 'PMAI THEME EDITOR  |  ansi')
            # The Text row contains foreground, background and the bold flag.
            session.send(b'jfn', 'ansi.foreground = none')
            session.send(b'beblue\r', 'ansi.background = blue')
            session.send(b'\t', 'PMAI THEME EDITOR  |  mono')
            session.send(b'e#808080\r1\x1b[C\x1b[1;2C', 'mono.background = #918080')
            # Both directions retain the selected component and unsaved drafts.
            session.send(b'\x1b[Z', 'bgcolor = blue')
            session.send(b'\t', 'bgcolor = #918080')
            session.send(b's', 'Saved 4 changes')
            saved = (root / theme_path).read_text()
            expected = original.replace('"default": .init()', '"default": .init(\n      backgroundLine: "#123456")')
            expected = expected.replace('backgroundLine: "", foreground: "white", background: "",',
                                        'backgroundLine: "", foreground: "", background: "blue",', 1)
            expected = expected.replace('backgroundLine: "black", foreground: "white", background: "",',
                                        'backgroundLine: "black", foreground: "white", background: "#918080",', 1)
            assert saved == expected, 'Saving changed unexpected source text'
            session.resize(60, 18)
            session.wait('Resize to at least 78 x 24')
            session.resize(80, 24)
            session.output = b''
            session.wait('◢')
            session.wait('Ask a follow-up…')
            # Selecting Error reveals its sample even in a short terminal.
            session.send(b'jjjjjf', 'error: expected')
            session.send(b'\x1b[6~', 'GreetingTests.swift')
            session.send(b'.', 'error: expected')
            session.send(b'gjb', 'bgcolor = #918080')
            session.send(b'e#ffffff\r', 'mono.background = #ffffff')
            session.send(b'q', 'Unsaved edits:')
            session.finish(b'd')
            assert (root / theme_path).read_text() == saved, 'Discard saved unwanted edits'
        finally:
            session.close()
        session = Session(binary, root)
        try:
            session.wait('Ready. Edits stay in memory')
            # SIGTERM must also restore the shell's terminal modes.
            session.finish(signum=signal.SIGTERM)
            assert (root / theme_path).read_text() == saved
        finally:
            session.close()
    print('Theme editor terminal smoke passed.')


if __name__ == '__main__':
    main()
