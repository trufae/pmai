#!/usr/bin/env python3
"""Exercise the real Windows console: empty Enter must not end the REPL."""
import os
from pathlib import Path
import subprocess
import sys


def worker(binary):
    import ctypes as c
    from ctypes import wintypes as w
    import json
    import msvcrt
    import tempfile
    import time

    from smoke import clean_environment

    kernel = c.WinDLL('kernel32', use_last_error=True)

    class Coord(c.Structure):
        _fields_ = [('X', w.SHORT), ('Y', w.SHORT)]

    class Rect(c.Structure):
        _fields_ = [('Left', w.SHORT), ('Top', w.SHORT),
                    ('Right', w.SHORT), ('Bottom', w.SHORT)]

    class ScreenInfo(c.Structure):
        _fields_ = [('size', Coord), ('cursor', Coord), ('attributes', w.WORD),
                    ('window', Rect), ('maximum', Coord)]

    class Key(c.Structure):
        _fields_ = [('down', w.BOOL), ('repeat', w.WORD), ('virtual', w.WORD),
                    ('scan', w.WORD), ('character', w.WCHAR), ('modifiers', w.DWORD)]

    class Event(c.Union):
        _fields_ = [('key', Key), ('padding', c.c_byte * 16)]

    class Record(c.Structure):
        _fields_ = [('kind', w.WORD), ('event', Event)]

    kernel.AllocConsole.argtypes = []
    kernel.AllocConsole.restype = w.BOOL
    kernel.FreeConsole.argtypes = []
    kernel.FreeConsole.restype = w.BOOL
    kernel.GetStdHandle.argtypes = [w.DWORD]
    kernel.GetStdHandle.restype = w.HANDLE
    kernel.GetConsoleScreenBufferInfo.argtypes = [w.HANDLE, c.POINTER(ScreenInfo)]
    kernel.ReadConsoleOutputCharacterW.argtypes = [w.HANDLE, w.LPWSTR, w.DWORD, Coord, c.POINTER(w.DWORD)]
    kernel.WriteConsoleInputW.argtypes = [w.HANDLE, c.POINTER(Record), w.DWORD, c.POINTER(w.DWORD)]
    kernel.FlushConsoleInputBuffer.argtypes = [w.HANDLE]

    def checked(result):
        if not result:
            raise c.WinError(c.get_last_error())

    checked(kernel.AllocConsole())
    try:
        input_handle = kernel.GetStdHandle(w.DWORD(-10).value)

        def screen():
            # CONOUT$ opens the active screen, including the alternate buffer.
            with open('CONOUT$', 'rb', buffering=0) as console:
                handle = msvcrt.get_osfhandle(console.fileno())
                info = ScreenInfo()
                checked(kernel.GetConsoleScreenBufferInfo(handle, c.byref(info)))
                first_row = max(0, info.window.Top - 40)
                length = info.size.X * (info.window.Bottom - first_row + 1)
                text = c.create_unicode_buffer(length)
                read = w.DWORD()
                checked(kernel.ReadConsoleOutputCharacterW(handle, text, length, Coord(0, first_row), c.byref(read)))
                return text[:read.value]

        def send(text):
            records = []
            for char in text:
                # Include releases, as a physical keyboard does.
                for down in (True, False):
                    record = Record()
                    record.kind = 1  # KEY_EVENT
                    record.event.key = Key(down, 1, 13 if char == '\r' else 0, 0, char, 0)
                    records.append(record)
            events = (Record * len(records))(*records)
            written = w.DWORD()
            checked(kernel.WriteConsoleInputW(input_handle, events, len(events), c.byref(written)))
            assert written.value == len(events)

        with tempfile.TemporaryDirectory(prefix='pmai-windows-console-') as directory:
            root = Path(directory)
            config = root / 'config.json'
            env = clean_environment()
            env.update(NO_COLOR='1')
            # Use classic and the persistent buffer surface, both of which
            # share the native input adapter. No provider requests are needed.
            for mode in ('classic', 'buffer'):
                checked(kernel.FlushConsoleInputBuffer(input_handle))
                config.write_text(json.dumps({
                    'version': 1, 'defaultAgent': 'test', 'ui': {'mode': mode},
                    'providers': [{'id': 'test', 'kind': 'openai', 'baseURL': 'http://127.0.0.1:1/v1'}],
                    'agents': [{'id': 'test', 'provider': 'test', 'model': 'test', 'toolNames': []}],
                }))
                # GetConsoleMode requires read access on the output handle too.
                with open('CONIN$', 'r+b', buffering=0) as console_in, open('CONOUT$', 'r+b', buffering=0) as console_out:
                    process = subprocess.Popen(
                        [binary, '--config', str(config), '--home', str(root / mode), '--no-markdown'],
                        cwd=root, env=env, stdin=console_in, stdout=console_out, stderr=console_out)

                def wait_for(text):
                    deadline = time.monotonic() + 20
                    while True:
                        output = screen()
                        assert process.poll() is None, (process.returncode, output)
                        if text in output:
                            return
                        assert time.monotonic() < deadline, (text, output)
                        time.sleep(.02)

                try:
                    # A unique response proves that startup and input both
                    # completed, without depending on a previously drawn prompt.
                    send(f'/help ready-{mode}\r')
                    wait_for(f"Unknown help topic 'ready-{mode}'")
                    send(f'\r\r/help after-enter-{mode}\r')
                    wait_for(f"Unknown help topic 'after-enter-{mode}'")
                    send('/exit\r')
                    assert process.wait(timeout=20) == 0, screen()
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.wait()
    finally:
        checked(kernel.FreeConsole())


def main():
    if os.name != 'nt':
        print('windows console smoke: skipped (Windows only)')
        return
    binary = str(Path(sys.argv[1]).resolve())
    if '--worker' in sys.argv:
        worker(binary)
    else:
        # The worker gets its own console; never inject keys into the user's
        # terminal or share its input queue with the parent test runner.
        subprocess.run([sys.executable, __file__, binary, '--worker'], check=True,
                       creationflags=subprocess.CREATE_NO_WINDOW, timeout=100)
        print('windows console smoke: ok')


if __name__ == '__main__':
    main()
