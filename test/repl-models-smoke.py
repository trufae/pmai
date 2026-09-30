#!/usr/bin/env python3
"""Check model completion, compaction input, and idle REPL work over real HTTP."""
import fcntl
import json
import os
from pathlib import Path
import pty
import queue
import select
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


requests = queue.Queue()
release = threading.Event()
catalog_release = threading.Event()
compact_release = threading.Event()
shutdown = threading.Event()
catalog = {
    'models': [{'name': 'test.gguf', 'model': 'test.gguf'}],
    'object': 'list', 'data': [{'id': 'test.gguf', 'owned_by': 'llamacpp'}],
}


class Provider(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def handle(self):
        try:
            super().handle()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def respond(self, payload, status=200):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        requests.put((self.path, self.headers.get('Accept'), self.headers.get('Authorization')))
        if self.path.startswith('/stalled/'):
            shutdown.wait(30)
        elif self.path.startswith('/drip/'):
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', '10000')
            self.end_headers()
            while not shutdown.wait(.1):
                self.wfile.write(b' ')
                self.wfile.flush()
        elif self.path.startswith('/unavailable/'):
            self.respond({'error': {'message': 'Loading model'}}, 503)
        elif self.path.startswith('/native/'):
            self.respond({'data': None, 'models': [
                {'model': 'native.gguf', 'name': 'Native model'}, {'name': 'name-only.gguf'},
            ]})
        else:
            if self.path == '/models':
                catalog_release.wait(30)
            self.respond(catalog)

    def do_POST(self):
        length = int(self.headers['Content-Length'])
        body = json.loads(self.rfile.read(length))
        if body['messages'][-1]['content'] == 'slow':
            requests.put(('chat', length, None))
            release.wait(30)
        elif body['messages'][-1]['content'].startswith('Compact the transcript below'):
            requests.put(('compact', length, None))
            compact_release.wait(30)
        self.respond({'choices': [{'message': {'role': 'assistant', 'content': 'answer'},
                                   'finish_reason': 'stop'}]})


def main():
    binary = str(Path(sys.argv[1]).resolve())
    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    environment = {k: v for k, v in os.environ.items()
                   if not k.startswith(('PMAI_', 'MAI_', 'OPENAI_'))
                   and k.lower() not in ('http_proxy', 'https_proxy', 'all_proxy')}
    environment.update(TERM='xterm-256color', NO_PROXY='127.0.0.1,localhost')
    try:
        with tempfile.TemporaryDirectory(prefix='pmai-models-') as directory:
            root = Path(directory)
            providers = [
                {'id': name, 'kind': 'openAICompatible',
                 'baseURL': f'http://127.0.0.1:{server.server_port}{path}'}
                for name, path in [('openai', ''), ('v1', '/v1/'),
                                   ('completion', '/v1/chat/completions'),
                                   ('native', '/native'), ('unavailable', '/unavailable'),
                                   ('stalled', '/stalled'), ('lazy', '/lazy'), ('drip', '/drip')]
            ]
            providers[-1]['timeout'] = 1
            config = root / 'config.json'
            config.write_text(json.dumps({
                'version': 1, 'defaultAgent': 'test', 'providers': providers,
                'agents': [{'id': 'test', 'provider': 'openai', 'model': 'test.gguf',
                            'toolNames': [], 'toolGroupNames': [], 'retry': {'attempts': 0},
                            'autocompact': {'tokens': 0}}],
                'memory': {'enabled': False}, 'use': {'plan': False},
            }))
            command = [binary, '--config', str(config), '--home', str(root / 'home'),
                       '--no-stream', '--no-markdown']
            seed = subprocess.run(command + ['seed'], cwd=root, env=environment,
                                  capture_output=True, timeout=20)
            assert seed.returncode == 0, seed.stderr
            chat_file = next((root / '.pmai/chats').glob('*.json'))
            chat = json.loads(chat_file.read_text())
            # A saved structured tool result made each old status tick re-encode the whole value.
            chat['messages'].append({'id': 'tool', 'role': 'tool', 'content': [{
                'toolResult': {'_0': {'callID': 'fixture', 'isError': False, 'content': [],
                                     'structuredContent': [{'id': i, 'text': 'x' * 100}
                                                           for i in range(10000)]}},
            }]})
            chat_file.write_text(json.dumps(chat))
            master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 200, 0, 0))
            process = subprocess.Popen(command + ['--resume'], cwd=root, env=environment,
                                       stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
            os.close(slave)
            output = bytearray()

            def read_for(seconds):
                end = time.monotonic() + seconds
                while time.monotonic() < end:
                    if select.select([master], [], [], max(0, end - time.monotonic()))[0]:
                        try:
                            chunk = os.read(master, 65536)
                        except OSError:
                            break
                        if not chunk:
                            break
                        output.extend(chunk)

            def wait_for(text, timeout=8):
                end = time.monotonic() + timeout
                needle = text.encode()
                while needle not in output:
                    assert time.monotonic() < end, (text, output.decode(errors='replace'))
                    assert process.poll() is None, (process.returncode, output)
                    read_for(.05)
                del output[:output.index(needle) + len(needle)]

            def send(text):
                output.clear()
                os.write(master, text.replace('\n', '\r').encode())

            def next_request(timeout=5):
                end = time.monotonic() + timeout
                while requests.empty():
                    assert time.monotonic() < end, ('HTTP request timed out', output.decode(errors='replace'))
                    assert process.poll() is None, (process.returncode, output)
                    read_for(.05)
                return requests.get_nowait()

            def sample(label, idle=False):
                read_for(.5)
                output.clear()
                stat = Path(f'/proc/{process.pid}/stat')

                def cpu_seconds():
                    if not stat.exists():
                        return None
                    fields = stat.read_text().rsplit(')', 1)[1].split()
                    return (int(fields[11]) + int(fields[12])) / os.sysconf('SC_CLK_TCK')

                before = cpu_seconds()
                read_for(2)
                cpu = f'{(cpu_seconds() - before) * 50:.1f}%' if before is not None else 'not measured'
                assert b'\x1b[2K' not in output, 'Waiting redrew whole status/thinking rows'
                if idle:
                    assert not output, 'Idle prompt still animates'
                print(f'PASS {label}: CPU {cpu}, {len(output)} terminal bytes', flush=True)

            try:
                wait_for('pmai>')
                # Cold-cache discovery must leave both typing and commands live.
                assert next_request()[0] == '/models'
                send('/model te\t')
                wait_for('/model te')
                send('\x03')
                wait_for('Nothing to cancel.')
                send('/cwd\n')
                wait_for(str(root))
                send('/model \t')
                wait_for('openai::')
                catalog_release.set()
                read_for(.3)
                send('\t')
                wait_for('test.gguf')
                send('\x03')
                wait_for('Nothing to cancel.')
                send('/model te\t\n')
                wait_for('Model: openai::test.gguf')
                assert requests.empty(), 'Completion started duplicate discovery requests'
                print('PASS cold model cache: background discovery and live completion', flush=True)
                sample('idle large history', idle=True)
                # /btw leaves the large saved history on screen without sending it.
                send('/btw slow\n')
                request = next_request(timeout=10)
                assert request[0] == 'chat'
                sample(f'waiting for provider ({request[1]} request bytes)')
                release.set()
                wait_for('✓ btw took')
                sample('idle after provider reply', idle=True)
                for provider, path in [('openai', '/models'), ('v1', '/v1/models'),
                                       ('completion', '/v1/models'), ('native', '/native/models')]:
                    send(f'/models {provider}\n')
                    assert next_request() == (path, 'application/json', None)
                    if provider == 'native':
                        wait_for('name-only.gguf')
                        wait_for('native.gguf (Native model)')
                    else:
                        wait_for('test.gguf — llamacpp')
                    print(f'PASS model catalog {provider}', flush=True)
                # /models refreshes the live cache, including a prompt already open.
                catalog['data'] = [{'id': 'fresh.gguf', 'owned_by': 'llamacpp'}]
                catalog['models'] = [{'model': 'fresh.gguf'}]
                send('/models\n')
                assert next_request()[0] == '/models'
                wait_for('fresh.gguf — llamacpp')
                send('/model fre\t\n')
                wait_for('Model: openai::fresh.gguf')
                for task in ('compact', 'tool', 'approval'):
                    command = 'aproval' if task == 'approval' else task
                    send(f'/model-{command} fre\t\n')
                    wait_for(f'{task}: task-{task} (saved)')
                send('/model native::nat\t\n')
                wait_for('Model: native::native.gguf')
                wait_for('· native.gguf ·')
                send('/model name-\t\n')
                wait_for('Model: native::name-only.gguf')
                assert requests.empty(), 'Cached completion refetched a catalog'
                send('/model lazy::fre\t')
                assert next_request()[0] == '/lazy/models'
                read_for(.3)
                send('\t\n')
                wait_for('Model: lazy::fresh.gguf')
                send('/model openai::fre\t\n')
                wait_for('Model: openai::fresh.gguf')
                wait_for('· fresh.gguf ·')
                print('PASS refreshed, task, and provider-qualified model completion', flush=True)
                send('/models unavailable\n')
                wait_for('Loading model')
                assert next_request()[0] == '/unavailable/models'
                for provider, timeout in [('drip', 1), ('stalled', 15)]:
                    send(f'/models {provider}\n')
                    assert next_request()[0] == f'/{provider}/models'
                    wait_for(f'timed out after {timeout}s', timeout=timeout + 5)
                    print(f'PASS {provider} deadline', flush=True)
                send('/models stalled\n')
                assert next_request()[0] == '/stalled/models'
                send('\x03')
                wait_for('cancelled /models')
                send('/model changed.gguf\n')
                wait_for('· changed.gguf')
                sample('idle after cancellation', idle=True)
                # The summary is deliberately stalled while the editor accepts text.
                send('/chat compact\n')
                assert next_request()[0] == 'compact'
                send('draft-during-compaction')
                wait_for('draft-during-compaction')
                assert not compact_release.is_set()
                send('\x03')
                wait_for('cancelled /chat')
                # Cancellation kept the original history, so a second compact can run.
                send('/chat compact\n')
                assert next_request()[0] == 'compact'
                send('draft-after-compaction')
                wait_for('draft-after-compaction')
                compact_release.set()
                wait_for('Conversation compacted into a summary.')
                # Completion must preserve the existing draft and its cursor.
                send('-preserved')
                wait_for('draft-after-compaction-preserved')
                send('\n')
                wait_for('✓ took')
                print('PASS manual compaction: prompt, cancellation, and preserved draft', flush=True)
                send('/exit\n')
                # macOS terminal restoration waits for pending PTY output to drain.
                deadline = time.monotonic() + 10
                while process.poll() is None:
                    assert time.monotonic() < deadline, ('/exit timed out', output.decode(errors='replace'))
                    read_for(.05)
                assert process.returncode == 0, (process.returncode, output.decode(errors='replace'))
                messages = json.loads(chat_file.read_text())['messages']
                assert [m['content'][0]['text']['_0'] for m in messages if m['role'] == 'user'] == [
                    'draft-after-compaction-preserved']
            finally:
                release.set()
                catalog_release.set()
                compact_release.set()
                if process.poll() is None:
                    process.kill()
                    process.wait()
                os.close(master)
    finally:
        release.set()
        catalog_release.set()
        compact_release.set()
        shutdown.set()
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
