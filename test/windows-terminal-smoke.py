#!/usr/bin/env python3
"""Exercise Windows ConPTY hosting over ACP stdio, using only local fixtures."""
import base64
import json
import os
from pathlib import Path
import queue
import re
import subprocess
import sys
import tempfile
import threading
import time

ANSI = re.compile(r'\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1b]*(?:\x07|\x1b\\)|[@-_])')
TERMINAL = '_pmai/workspace/terminal'


class ACP:
    def __init__(self, binary, root, env, config):
        self.process = subprocess.Popen([binary, '--acp', '--acp-root', str(root),
                                         '--config', str(config), '--home', str(root / 'home')],
                                        cwd=root, env=env, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.messages = queue.Queue()
        self.errors = bytearray()
        self.number = 0
        self.offsets = {}
        self.output = {}

        def read():
            try:
                for line in self.process.stdout:
                    self.messages.put(json.loads(line))
            except Exception as error:
                self.messages.put(RuntimeError(f'Invalid ACP frame {line!r}: {error}'))
            finally:
                self.messages.put(None)

        def errors():
            self.errors.extend(self.process.stderr.read())

        threading.Thread(target=read, daemon=True).start()
        threading.Thread(target=errors, daemon=True).start()

    def rpc(self, method, params=None, allow_error=False):
        self.number += 1
        self.process.stdin.write((json.dumps({'jsonrpc': '2.0', 'id': self.number,
                                            'method': method, 'params': params or {}}) + '\n').encode())
        self.process.stdin.flush()
        deadline = time.monotonic() + 45
        while True:
            message = self.messages.get(timeout=max(0, deadline - time.monotonic()))
            if isinstance(message, Exception):
                raise message
            assert message is not None, self.errors.decode(errors='replace')
            if message.get('id') != self.number:
                continue
            if allow_error and 'error' in message:
                return message
            assert 'error' not in message, message
            return message.get('result')

    def terminal(self, action, **fields):
        return self.rpc(TERMINAL, {'action': action, **fields})

    def open(self, root):
        identifier = self.terminal('open', cwd=str(root), columns=80, rows=24)['id']
        self.offsets[identifier] = 0
        self.output[identifier] = bytearray()
        return identifier

    def write(self, identifier, text):
        self.terminal('write', id=identifier, data=base64.b64encode(text.encode('utf-8')).decode())

    def read_until(self, identifier, predicate):
        deadline = time.monotonic() + 45
        while True:
            chunk = self.terminal('read', id=identifier, offset=self.offsets[identifier])
            self.offsets[identifier] = chunk['offset']
            self.output[identifier].extend(base64.b64decode(chunk['data']))
            text = ANSI.sub('', self.output[identifier].decode('utf-8', errors='replace'))
            if predicate(text, chunk.get('exitCode')):
                return text, chunk.get('exitCode')
            assert chunk.get('exitCode') is None, text
            assert time.monotonic() < deadline, text

    def close(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            try:
                self.process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=10)
                raise


def main():
    if os.name != 'nt':
        print('windows terminal smoke: skipped (Windows only)')
        return
    import ctypes as c
    from ctypes import wintypes as w
    kernel = c.WinDLL('kernel32', use_last_error=True)
    kernel.OpenProcess.argtypes = [w.DWORD, w.BOOL, w.DWORD]
    kernel.OpenProcess.restype = w.HANDLE
    kernel.WaitForSingleObject.argtypes = [w.HANDLE, w.DWORD]
    kernel.CloseHandle.argtypes = [w.HANDLE]
    binary = str(Path(sys.argv[1]).resolve())
    with tempfile.TemporaryDirectory(prefix='pmai-conpty-') as temporary:
        root = Path(temporary) / 'workspace ü'
        root.mkdir()
        config = root / 'config.json'
        config.write_text(json.dumps({
            'version': 1, 'defaultAgent': 'test',
            'providers': [{'id': 'offline', 'kind': 'hello'}],
            'toolSources': [{'id': 'standard', 'kind': 'standard-tools',
                             'options': {'tools': ['run_shell']}}],
            'agents': [{'id': 'test', 'provider': 'offline', 'model': 'hello',
                        'toolNames': ['run_shell'], 'toolGroupNames': []}],
            'approvals': {'mode': 'yolo'}, 'memory': {'enabled': False},
        }))
        helper = root / 'probe.py'
        helper.write_text('''import ctypes as c, os, signal, subprocess, sys, time
from ctypes import wintypes as w
from pathlib import Path
if sys.argv[1] == 'cwd':
    Path(__file__).with_name('cwd.json').write_text(os.getcwd(), encoding='utf-8')
    print('PTY_CWD_SAVED_' + sys.argv[2], flush=True)
elif sys.argv[1] == 'size':
    class Coord(c.Structure): _fields_ = [('x', w.SHORT), ('y', w.SHORT)]
    class Rect(c.Structure): _fields_ = [('left', w.SHORT), ('top', w.SHORT), ('right', w.SHORT), ('bottom', w.SHORT)]
    class Info(c.Structure): _fields_ = [('size', Coord), ('cursor', Coord), ('attributes', w.WORD), ('window', Rect), ('maximum', Coord)]
    kernel = c.WinDLL('kernel32', use_last_error=True)
    kernel.GetStdHandle.argtypes = [w.DWORD]; kernel.GetStdHandle.restype = w.HANDLE
    kernel.GetConsoleScreenBufferInfo.argtypes = [w.HANDLE, c.POINTER(Info)]
    info = Info()
    assert kernel.GetConsoleScreenBufferInfo(kernel.GetStdHandle(w.DWORD(-11).value), c.byref(info))
    print('PTY_SIZE=%d,%d' % (info.window.right - info.window.left + 1, info.window.bottom - info.window.top + 1), flush=True)
elif sys.argv[1] == 'wait':
    def interrupted(signum, frame):
        os.write(1, b'PTY_INTERRUPTED\\n')
        raise SystemExit(0)
    signal.signal(signal.SIGINT, interrupted)
    print('PTY_WAITING', flush=True)
    time.sleep(300)
else:
    child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(300)'])
    print('PTY_CHILD=%d' % child.pid, flush=True)
    sys.stdout.write('x' * (512 * 1024)); sys.stdout.flush()
    time.sleep(300)
''')
        env = {key: value for key, value in os.environ.items()
               if not key.startswith(('PMAI_', 'MAI_', 'OPENAI_'))}
        env['PMAI_SHELL'] = str(Path(os.environ['SYSTEMROOT']) / 'System32/cmd.exe')
        client = ACP(binary, root, env, config)
        try:
            initialized = client.rpc('initialize', {'protocolVersion': 1})
            assert initialized['agentCapabilities']['_meta']['pmai']['workspaceTerminal'] == 1
            identifier = client.open(root)
            command = subprocess.list2cmdline([sys.executable, str(helper)])
            client.write(identifier, 'chcp 65001 >nul\r\nfor %a in (PTY_) do @echo %aREADY-é漢🙂\r\n')
            client.read_until(identifier, lambda text, _: 'PTY_READY-é漢🙂' in text)
            client.write(identifier, command + ' cwd initial\r\n')
            client.read_until(identifier, lambda text, _: 'PTY_CWD_SAVED_initial' in text)
            assert Path((root / 'cwd.json').read_text(encoding='utf-8')).resolve() == root.resolve()
            nested = root / 'sub space'
            nested.mkdir()
            client.write(identifier, 'cd /d "sub space"\r\n' + command + ' cwd nested\r\n')
            client.read_until(identifier, lambda text, _: 'PTY_CWD_SAVED_nested' in text)
            assert Path((root / 'cwd.json').read_text(encoding='utf-8')).resolve() == nested.resolve()
            client.terminal('resize', id=identifier, columns=97, rows=31)
            client.write(identifier, command + ' size\r\n')
            client.read_until(identifier, lambda text, _: 'PTY_SIZE=97,31' in text)
            client.write(identifier, command + ' wait\r\n')
            client.read_until(identifier, lambda text, _: 'PTY_WAITING' in text)
            client.write(identifier, '\x03')
            client.read_until(identifier, lambda text, _: 'PTY_INTERRUPTED' in text)
            client.write(identifier, 'exit 37\r\n')
            _, status = client.read_until(identifier, lambda text, status: status is not None)
            assert status == 37, status
            client.terminal('close', id=identifier)
            for disconnect in (False, True):
                identifier = client.open(root)
                client.write(identifier, command + ' tree\r\n')
                text, _ = client.read_until(identifier, lambda text, _: re.search(r'PTY_CHILD=(\d+)', text))
                pid = int(re.search(r'PTY_CHILD=(\d+)', text).group(1))
                child = kernel.OpenProcess(0x00100000, False, pid)  # SYNCHRONIZE
                assert child, c.WinError(c.get_last_error())
                try:
                    # Exercise teardown while input/output can be backpressured.
                    for _ in range(16):
                        response = client.rpc(TERMINAL, {'action': 'write', 'id': identifier,
                                              'data': base64.b64encode(b'a' * (16 * 1024)).decode()}, allow_error=True)
                        if isinstance(response, dict) and 'error' in response:
                            assert 'queue is full' in response['error']['message'], response
                            break
                    if disconnect:
                        client.close()
                    else:
                        client.terminal('close', id=identifier)
                    assert kernel.WaitForSingleObject(child, 30000) == 0, 'Terminal descendant survived teardown'
                finally:
                    kernel.CloseHandle(child)
            print('windows terminal smoke: cwd, Unicode, resize, Ctrl+C, exit, close and disconnect passed')
        finally:
            client.close()


if __name__ == '__main__':
    main()
