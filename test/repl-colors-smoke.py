#!/usr/bin/env python3
"""Check theme colors in real tool output, diagnostics, diffs, and TAB completion."""
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Provider(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        last_user = max(i for i, m in enumerate(request['messages']) if m['role'] == 'user')
        results = request['messages'][last_user + 1:]
        if any(m['role'] == 'tool' for m in results):
            message = {'role': 'assistant', 'content': 'colors smoke done'}
        else:
            message = {'role': 'assistant', 'content': None, 'tool_calls': [
                {'id': f'read-{i}', 'type': 'function',
                 'function': {'name': 'files_read', 'arguments': json.dumps({'path': path})}}
                for i, path in enumerate(('diff.txt', 'plain.txt', 'missing.txt'))
            ]}
        body = json.dumps({'choices': [{'message': message, 'finish_reason':
                          'tool_calls' if 'tool_calls' in message else 'stop'}]}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    binary = str(Path(sys.argv[1]).resolve())
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(('PMAI_', 'MAI_', 'OPENAI_'))
           and k.lower() not in ('no_color', 'http_proxy', 'https_proxy', 'all_proxy')}
    env.update(TERM='xterm-256color', NO_PROXY='127.0.0.1,localhost')
    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix='pmai-colors-') as directory:
            root = Path(directory)
            config = root / 'config.json'
            config.write_text(json.dumps({
                'defaultAgent': 'smoke',
                'providers': [{'id': 'smoke', 'kind': 'openAICompatible',
                               'baseURL': f'http://127.0.0.1:{server.server_port}/v1'}],
                'toolSources': [{'id': 'standard', 'kind': 'standard-tools',
                                 'options': {'tools': ['files_read']}}],
                'agents': [{'id': 'smoke', 'provider': 'smoke', 'model': 'smoke',
                            'toolNames': ['files_read'], 'toolGroupNames': [],
                            'retry': {'attempts': 0}}],
                'approvals': {'mode': 'yolo'},
                'memory': {'enabled': False}, 'use': {'plan': False},
                'ui': {'fgerror': '#123456', 'fgwarning': '#234567',
                       'fgtoolcall': '#345678', 'fgtoolresult': '#456789',
                       'fgdiffadd': '#56789a', 'bgdiffadd': '#6789ab',
                       'fgdiffdel': '#789abc', 'bgdiffdel': '#89abcd',
                       'fgdiffheader': '#9abcde', 'fgthinking': '#abcdef',
                       'fgselection': '#bcdef0', 'bgselection': '#cdef01'},
            }))
            (root / 'diff.txt').write_text(
                '--- a/sample\n+++ b/sample\n@@ -1,3 +1,3 @@\n'
                '-old\n+new\n +context\n -context\n')
            (root / 'plain.txt').write_text('-not a diff\n+also not a diff\n')
            command = [binary, '--config', str(config), '--home', str(root / 'home'),
                       '--no-stream', '--no-markdown']

            def run(*commands, terminal=True, extra_env=None):
                data = '\n'.join([*commands, '/exit', '']).encode()
                environment = dict(env, **(extra_env or {}))
                if not terminal:
                    result = subprocess.run(command, cwd=root, env=environment, input=data,
                                            capture_output=True, timeout=20)
                    assert result.returncode == 0, result.stderr
                    return (result.stdout + result.stderr).decode()
                master, slave = pty.openpty()
                output = bytearray()

                def drain():
                    while True:
                        try:
                            chunk = os.read(master, 65536)
                        except OSError:
                            break
                        if not chunk:
                            break
                        output.extend(chunk)

                reader = threading.Thread(target=drain, daemon=True)
                try:
                    process = subprocess.Popen(command, cwd=root, env=environment,
                                               stdin=subprocess.PIPE, stdout=slave, stderr=slave)
                    os.close(slave)
                    reader.start()
                    try:
                        process.communicate(data, timeout=20)
                        assert process.returncode == 0, output.decode()
                    finally:
                        if process.poll() is None:
                            process.kill()
                            process.wait()
                    reader.join(timeout=5)
                    assert not reader.is_alive(), 'PTY did not close'
                    return output.decode().replace('\r', '')
                finally:
                    os.close(master)

            output = run('/theme use missing', 'show colors',
                         extra_env={'PMAI_THEME': 'missing'})
            for fragment in (
                '\x1b[38;2;18;52;86merror:',
                '\x1b[38;2;35;69;103mwarning:',
                '\x1b[38;2;52;86;120m→ files_read',
                '\x1b[38;2;69;103;137m← -not a diff',
                '\x1b[38;2;154;188;222m← --- a/sample',
                '\x1b[38;2;154;188;222m  +++ b/sample',
                '\x1b[38;2;154;188;222m  @@ -1,3 +1,3 @@',
                '\x1b[38;2;86;120;154;48;2;103;137;171m  +new',
                '\x1b[38;2;120;154;188;48;2;137;171;205m  -old',
                '\x1b[38;2;69;103;137m   +context',
                '\x1b[38;2;69;103;137m   -context',
                '\x1b[38;2;18;52;86m← ',
                '\x1b[38;2;171;205;239mThinking…',
            ):
                assert fragment in output, (fragment, output)
            output = run('/theme color fgerror cyan', '/theme use missing',
                         '/theme use pink', '/theme use missing',
                         '/theme color fgerror none', '/theme use missing')
            assert '\x1b[36merror:' in output, output
            assert '\x1b[38;2;255;119;119merror:' in output, output
            assert "pmai> error: Unknown theme 'missing'." in output, output
            for options in ({'terminal': False}, {'extra_env': {'NO_COLOR': '1'}},
                            {'extra_env': {'TERM': 'dumb'}}):
                output = run('/theme use missing', 'show colors', **options)
                assert '\x1b[' not in output, output
                assert 'colors smoke done' in output and '+new' in output, output

            # Exercise the actual completion menu, including live setting updates.
            master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 200, 0, 0))
            process = subprocess.Popen(command, cwd=root, env=env,
                                       stdin=slave, stdout=slave, stderr=slave)
            os.close(slave)
            output = bytearray()

            def wait_for(text):
                needle = text.encode()
                deadline = time.monotonic() + 15
                while needle not in output:
                    assert time.monotonic() < deadline, (text, output.decode())
                    if select.select([master], [], [], .05)[0]:
                        output.extend(os.read(master, 65536))
                del output[:output.index(needle) + len(needle)]

            try:
                wait_for('pmai> ')
                os.write(master, b'/theme color fgerr\tcyan\r')
                wait_for('Set theme color fgerror = cyan.')
                wait_for('pmai> ')
                for key, value in (('fgselection', '#bcdef0'), ('bgselection', '#cdef01')):
                    os.write(master, f'/theme color {key} {value}\r'.encode())
                    wait_for(f'Set theme color {key} = {value}.')
                    wait_for('pmai> ')
                os.write(master, b'/theme use \t')
                wait_for('\x1b[38;2;188;222;240;48;2;205;239;1m')
                os.write(master, b'\x03')
                wait_for('Nothing to cancel.')
                wait_for('pmai> ')
                for key in ('fgselection', 'bgselection'):
                    os.write(master, f'/theme color {key} none\r'.encode())
                    wait_for(f'Set theme color {key} = none.')
                    wait_for('pmai> ')
                os.write(master, b'/theme use \t')
                wait_for('\x1b[7mdefault')
                os.write(master, b'\x03')
                wait_for('Nothing to cancel.')
                wait_for('pmai> ')
                os.write(master, b'/theme use sky\r')
                wait_for("Applied theme 'sky'.")
                wait_for('pmai> ')
                os.write(master, b'/theme use \t')
                wait_for('\x1b[38;2;0;17;51;48;2;119;204;255m')
                os.write(master, b'\x03')
                wait_for('Nothing to cancel.')
                wait_for('pmai> ')
                os.write(master, b'/exit\r')
                deadline = time.monotonic() + 10
                while process.poll() is None:
                    assert time.monotonic() < deadline, output.decode()
                    if select.select([master], [], [], .05)[0]:
                        try:
                            output.extend(os.read(master, 65536))
                        except OSError:
                            break
                assert process.wait(timeout=5) == 0
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                os.close(master)
    finally:
        server.shutdown()
        server.server_close()
    print('REPL color smoke passed')


if __name__ == '__main__':
    main()
