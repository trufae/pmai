#!/usr/bin/env python3
"""Check recap routing, prompt editing, and unchanged chat state over local HTTP."""
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


requests = []
reply_mode = 'normal'
recap_started = threading.Event()
recap_release = threading.Event()


class Provider(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def respond(self, payload, status=200):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        self.respond({'data': [{'id': 'large'}, {'id': 'tiny'}]})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append((self.path, body))
        if reply_mode == 'slow':
            recap_started.set()
            recap_release.wait(20)
        if reply_mode == 'error':
            self.respond({'error': {'message': 'Recap fixture failure'}}, 500)
            return
        prompt = body['messages'][-1]['content']
        if reply_mode == 'empty':
            answer = ''
        elif prompt.startswith(('Write a short', 'CUSTOM RECAP')):
            answer = '<think>PRIVATE REASONING</think>🎯 Goals: fix parser.\n✅ Done: tests passed.\n⏳ Pending: release.'
        elif prompt.startswith('Compact the transcript'):
            answer = 'COMPACTED GOAL: fix parser; tests passed; release pending.'
        else:
            answer = 'Inspected the parser; release remains pending.'
        self.respond({'choices': [{'message': {'role': 'assistant', 'content': answer},
                                   'finish_reason': 'stop'}]})


def check_terminal(command, root, environment):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 200, 0, 0))
    process = subprocess.Popen(command + ['--resume'], cwd=root, env=environment,
                               stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
    os.close(slave)
    output = bytearray()

    def wait_for(text):
        needle = text.encode()
        end = time.monotonic() + 10
        while needle not in output:
            assert time.monotonic() < end, (text, output.decode(errors='replace'))
            assert process.poll() is None, process.returncode
            if select.select([master], [], [], .05)[0]:
                output.extend(os.read(master, 65536))
        del output[:output.index(needle) + len(needle)]

    def send(text):
        output.clear()
        os.write(master, text.replace('\n', '\r').encode())

    try:
        wait_for('pmai> ')
        for draft in ('cancelled-draft', 'preserved-draft'):
            recap_started.clear()
            send('/chat recap\n')
            end = time.monotonic() + 10
            while not recap_started.is_set():
                assert time.monotonic() < end, (draft, output.decode(errors='replace'))
                if select.select([master], [], [], .05)[0]:
                    output.extend(os.read(master, 65536))
            send(draft)
            wait_for(draft)
            if draft == 'cancelled-draft':
                send('\x03')
                wait_for('cancelled /chat')
            else:
                recap_release.set()
                wait_for('✅ Done: tests passed.')
                send('-still-here')
                wait_for('preserved-draft-still-here')
                send('\x03')
                wait_for('Nothing to cancel.')
        send('/exit\n')
        end = time.monotonic() + 10
        while process.poll() is None:
            assert time.monotonic() < end, output.decode(errors='replace')
            if select.select([master], [], [], .05)[0]:
                try:
                    output.extend(os.read(master, 65536))
                except OSError:
                    break
        assert process.wait(timeout=5) == 0
    finally:
        recap_release.set()
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)


def main():
    global reply_mode
    binary = str(Path(sys.argv[1]).resolve())
    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(('PMAI_', 'MAI_', 'OPENAI_'))
                   and key.lower() not in ('http_proxy', 'https_proxy', 'all_proxy')}
    environment['NO_PROXY'] = '127.0.0.1,localhost'
    environment['TERM'] = 'xterm-256color'
    try:
        with tempfile.TemporaryDirectory(prefix='pmai-recap-') as directory:
            root = Path(directory)
            config = root / 'config.json'
            config.write_text(json.dumps({
                'defaultAgent': 'main',
                'providers': [{'id': name, 'kind': 'openAICompatible',
                               'baseURL': f'http://127.0.0.1:{server.server_port}/{name}/v1'}
                              for name in ('primary', 'summarizer')],
                'agents': [{'id': 'main', 'provider': 'primary', 'model': 'large',
                            'instructions': 'MAIN INSTRUCTIONS', 'toolNames': [],
                            'toolGroupNames': [], 'retry': {'attempts': 0},
                            'autocompact': {'tokens': 0}}],
                'memory': {'enabled': False}, 'use': {'plan': False},
            }))
            editor = root / 'editor.py'
            editor.write_text(
                'from pathlib import Path\nimport sys\n'
                'root = Path(__file__).parent\n'
                'target = Path(sys.argv[1])\n'
                '(root / "editor-before").write_text(target.read_text())\n'
                'target.write_text((root / "editor-after").read_text())\n')
            environment['EDITOR'] = f'{sys.executable} {editor}'
            command = [binary, '--config', str(config), '--home', str(root / 'home'),
                       '--no-stream', '--no-markdown']

            def run(commands, resume=True):
                selection = ['--resume', resume] if isinstance(resume, str) else ['--resume'] if resume else []
                result = subprocess.run(command + selection,
                                        input='\n'.join([*commands, '/exit', '']),
                                        cwd=root, env=environment, text=True,
                                        capture_output=True, timeout=30)
                output = result.stdout + result.stderr
                assert result.returncode == 0, output
                return output

            assert 'Nothing to recap yet.' in run(['/chat recap'], resume=False)
            assert not requests
            run(['Fix the parser and prepare a release.',
                 '/model-compact summarizer::tiny', '/model-tool summarizer::tiny'])
            saved = json.loads(config.read_text())
            assert saved['prompts']['system']['compact']
            assert saved['prompts']['system']['tool']
            assert 'task-compact' not in saved['prompts']['system']
            for agent in saved['agents']:
                agent['retry'] = {'attempts': 0}
            config.write_text(json.dumps(saved))
            chat_file = next((root / '.pmai/chats').glob('*.json'))
            chat = json.loads(chat_file.read_text())
            chat['messages'].insert(1, {
                'id': 'summary', 'role': 'system', 'content': [{
                    'text': {'_0': 'Conversation summary (compacted): EARLIER GOAL'}}]})
            chat['messages'].extend([
                {'id': 'call', 'role': 'assistant', 'content': [{'toolCall': {'_0': {
                    'id': 'check', 'name': 'run_shell', 'arguments': {'command': 'make test'}}}}]},
                {'id': 'result', 'role': 'tool', 'content': [{'toolResult': {'_0': {
                    'callID': 'check', 'isError': False, 'importance': 'normal',
                    'content': [{'text': {'_0': 'TEST EVIDENCE: all checks passed'}}]}}}]},
            ])
            chat['pendingContent'] = [{'text': {'_0': 'UNSENT ATTACHMENT'}}]
            chat_file.write_text(json.dumps(chat))

            def assert_unchanged(before=chat):
                after = json.loads(chat_file.read_text())
                for key in ('messages', 'pendingContent', 'primaryAgent', 'sessionID'):
                    assert after.get(key) == before.get(key), (key, before, after)

            def recap():
                before = len(requests)
                output = run(['/chat recap'])
                assert len(requests) == before + 1, requests[before:]
                assert '✅ Done: tests passed.' in output, output
                assert 'PRIVATE REASONING' not in output, output
                assert_unchanged()
                return requests[-1]

            endpoint, body = recap()
            assert endpoint.startswith('/summarizer/'), endpoint
            assert body['model'] == 'tiny' and not body.get('tools'), body
            prompt = body['messages'][-1]['content']
            for evidence in ('EARLIER GOAL', 'Fix the parser', 'make test', 'TEST EVIDENCE'):
                assert evidence in prompt, prompt
            assert 'MAIN INSTRUCTIONS' not in prompt
            assert 'UNSENT ATTACHMENT' not in prompt

            (root / 'editor-after').write_text('CUSTOM RECAP\n{{transcript}}')
            assert 'Recap prompt saved' in run(['/edit prompt recap'])
            assert '🎯 Goals' in (root / 'editor-before').read_text()
            assert recap()[1]['messages'][-1]['content'].startswith('CUSTOM RECAP')
            previous = config.read_bytes()
            (root / 'editor-after').write_text('Invalid template')
            assert 'must contain {{transcript}}' in run(['/edit prompt recap'])
            assert config.read_bytes() == previous
            (root / 'editor-after').write_text('')
            assert 'Recap prompt restored' in run(['/edit prompt recap'])
            assert 'recap' not in json.loads(config.read_text())['prompts']

            for name in ('compact', 'tool'):
                (root / 'editor-after').write_text(f'CUSTOM {name} SYSTEM')
                assert f"Saved system prompt '{name}'" in run([f'/edit prompt {name}'])
                saved = json.loads(config.read_text())
                assert saved['prompts']['system'][name] == f'CUSTOM {name} SYSTEM'
            assert any(message['content'] == 'CUSTOM compact SYSTEM'
                       for message in recap()[1]['messages'])

            for mode in ('empty', 'error'):
                reply_mode = mode
                output = run(['/chat recap'])
                assert 'error:' in output, output
                if mode == 'empty':
                    assert 'empty response' in output or 'empty summary' in output, output
                assert_unchanged()
            reply_mode = 'normal'
            run(['/model-compact -'])
            endpoint, body = recap()
            assert endpoint.startswith('/primary/') and body['model'] == 'large', (endpoint, body)

            reply_mode = 'slow'
            check_terminal(command, root, environment)
            assert_unchanged()
            reply_mode = 'normal'

            assert 'Conversation compacted' in run(['/chat compact'])
            compacted = json.loads(chat_file.read_text())
            output = run(['/chat recap'], resume=chat['id'])
            assert '✅ Done: tests passed.' in output, output
            assert 'COMPACTED GOAL' in requests[-1][1]['messages'][-1]['content']
            assert_unchanged(compacted)
            print('PASS recap: model routing, tool evidence, compacted context, unchanged history, prompt edits/reset, failures, cancellation, preserved draft')
    finally:
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
