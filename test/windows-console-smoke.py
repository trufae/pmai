#!/usr/bin/env python3
"""Exercise native Windows input, Unicode output, and console restoration."""
import os
from pathlib import Path
import subprocess
import sys
from contextlib import ExitStack


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
    kernel.GetConsoleScreenBufferInfo.argtypes = [w.HANDLE, c.POINTER(ScreenInfo)]
    kernel.ReadConsoleOutputCharacterW.argtypes = [w.HANDLE, w.LPWSTR, w.DWORD, Coord, c.POINTER(w.DWORD)]
    kernel.WriteConsoleInputW.argtypes = [w.HANDLE, c.POINTER(Record), w.DWORD, c.POINTER(w.DWORD)]
    kernel.FlushConsoleInputBuffer.argtypes = [w.HANDLE]
    kernel.GetConsoleMode.argtypes = [w.HANDLE, c.POINTER(w.DWORD)]
    kernel.GetConsoleMode.restype = w.BOOL
    kernel.SetConsoleMode.argtypes = [w.HANDLE, w.DWORD]
    kernel.SetConsoleMode.restype = w.BOOL
    kernel.GetConsoleOutputCP.argtypes = []
    kernel.GetConsoleOutputCP.restype = w.UINT
    kernel.SetConsoleOutputCP.argtypes = [w.UINT]
    kernel.SetConsoleOutputCP.restype = w.BOOL

    def checked(result):
        if not result:
            raise c.WinError(c.get_last_error())

    checked(kernel.AllocConsole())
    handles = ExitStack()
    try:
        # Standard handles may still refer to the CI runner's redirected pipes.
        # Open the allocated console explicitly, preserving stdout for diagnostics.
        console_in = handles.enter_context(open('CONIN$', 'r+b', buffering=0))
        console_out = handles.enter_context(open('CONOUT$', 'r+b', buffering=0))
        input_handle = msvcrt.get_osfhandle(console_in.fileno())
        output_handle = msvcrt.get_osfhandle(console_out.fileno())

        def console_mode(handle):
            mode = w.DWORD()
            checked(kernel.GetConsoleMode(handle, c.byref(mode)))
            return mode.value

        initial_input_mode = console_mode(input_handle)
        initial_output_mode = console_mode(output_handle)

        def screen(full=False):
            # CONOUT$ opens the active screen, including the alternate buffer.
            with open('CONOUT$', 'rb', buffering=0) as console:
                handle = msvcrt.get_osfhandle(console.fileno())
                info = ScreenInfo()
                checked(kernel.GetConsoleScreenBufferInfo(handle, c.byref(info)))
                first_row = 0 if full else max(0, info.window.Top - 40)
                length = info.size.X * (info.window.Bottom - first_row + 1)
                text = c.create_unicode_buffer(length)
                read = w.DWORD()
                checked(kernel.ReadConsoleOutputCharacterW(handle, text, length, Coord(0, first_row), c.byref(read)))
                return text[:read.value].encode('utf-16-le', 'surrogatepass').decode('utf-16-le', 'surrogatepass')

        def send(text):
            records = []
            encoded = text.encode('utf-16-le')
            for offset in range(0, len(encoded), 2):
                char = chr(int.from_bytes(encoded[offset:offset + 2], 'little'))
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
            mode_probe = root / 'console-modes.py'
            mode_probe.write_text('''import ctypes as c, json, msvcrt, sys
from ctypes import wintypes as w
from pathlib import Path
kernel = c.WinDLL('kernel32', use_last_error=True)
kernel.GetConsoleMode.argtypes = [w.HANDLE, c.POINTER(w.DWORD)]
modes = []
for name in ('CONIN$', 'CONOUT$'):
    with open(name, 'r+b', buffering=0) as console:
        mode = w.DWORD()
        if not kernel.GetConsoleMode(msvcrt.get_osfhandle(console.fileno()), c.byref(mode)):
            raise c.WinError(c.get_last_error())
        modes.append(mode.value)
Path(sys.argv[1]).write_text(json.dumps(modes))
''')
            # Use classic and the persistent buffer surface, both of which
            # share the native input adapter. No provider requests are needed.
            for mode in ('classic', 'buffer'):
                baseline_input = initial_input_mode & ~0x0200  # ENABLE_VIRTUAL_TERMINAL_INPUT
                if mode == 'buffer':
                    baseline_input &= ~0x0006  # Inherited noncanonical mode, without echo.
                baseline_output = initial_output_mode & ~0x0005  # Processed output and VT.
                checked(kernel.SetConsoleMode(input_handle, baseline_input))
                checked(kernel.SetConsoleMode(output_handle, baseline_output))
                checked(kernel.SetConsoleOutputCP(437))
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
                    for label, character in [('accent', 'é'), ('cjk', '漢'), ('emoji', '🙂')]:
                        topic = f'{label}-{mode}-{character}'
                        send(f'/help {topic}\r')
                        wait_for(f"Unknown help topic '{topic}")
                    if mode == 'classic':
                        # The marker is assembled by cmd, so echoed input
                        # cannot satisfy this shell Unicode output check.
                        send('!for %x in (shell) do @echo %x-é\r')
                        wait_for('shell-é')
                    for status in (7, 256):
                        send(f'!exit {status}\r')
                        wait_for(f'exit status {status}')
                    assert kernel.GetConsoleOutputCP() == 65001
                    send(f'\r\r/help after-enter-{mode}\r')
                    wait_for(f"Unknown help topic 'after-enter-{mode}'")
                    modes_file = root / f'{mode}-modes.json'
                    # Extra outer quotes preserve a quoted executable path
                    # when the CRT invokes cmd /c for a terminal handoff.
                    probe_command = '"' + subprocess.list2cmdline([
                        sys.executable, str(mode_probe), str(modes_file)]) + '"'
                    send(f'!{probe_command}\r/help modes-returned-{mode}\r')
                    wait_for(f"Unknown help topic 'modes-returned-{mode}'")
                    assert json.loads(modes_file.read_text()) == [baseline_input, baseline_output]
                    # chcp never reads stdin. The following unique reply proves
                    # the child finished and pmai reclaimed its output encoding.
                    send(f'!chcp 437 >nul\r/help resumed-{mode}-é\r')
                    wait_for(f"Unknown help topic 'resumed-{mode}-é")
                    assert kernel.GetConsoleOutputCP() == 65001
                    send('/exit\r')
                    assert process.wait(timeout=20) == 0, screen()
                    assert console_mode(input_handle) == baseline_input
                    assert console_mode(output_handle) == baseline_output
                    assert kernel.GetConsoleOutputCP() == 437
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.wait()
            # Early return uses buffered Swift print; errors call exit(2) and
            # write directly to stderr. Both must display Unicode and restore CP.
            for arguments, status, expected, stderr_only in [
                (['--help'], 0, 'pmai — the Pocket Mai command-line agent', False),
                (['--unknown-é'], 2, 'Unknown option: --unknown-é', True),
            ]:
                checked(kernel.SetConsoleOutputCP(437))
                with open('CONOUT$', 'r+b', buffering=0) as console_out:
                    result = subprocess.run([binary, *arguments], cwd=root, env=env,
                                            stdin=subprocess.DEVNULL,
                                            stdout=subprocess.DEVNULL if stderr_only else console_out,
                                            stderr=console_out, timeout=20)
                assert result.returncode == status, result.returncode
                assert expected in screen(full=True), screen(full=True)
                assert kernel.GetConsoleOutputCP() == 437
            # Redirected output remains UTF-8 and must leave the shared console alone.
            checked(kernel.SetConsoleOutputCP(437))
            redirected = subprocess.run([binary, '--unknown-é'], cwd=root, env=env,
                                        stdin=subprocess.DEVNULL, capture_output=True, timeout=20)
            assert redirected.returncode == 2
            assert 'Unknown option: --unknown-é' in redirected.stderr.decode('utf-8')
            assert kernel.GetConsoleOutputCP() == 437
    finally:
        handles.close()
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
        result = subprocess.run([sys.executable, __file__, binary, '--worker'],
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                creationflags=subprocess.CREATE_NO_WINDOW, timeout=100)
        sys.stdout.buffer.write(result.stdout)
        result.check_returncode()
        print('windows console smoke: ok')


if __name__ == '__main__':
    main()
