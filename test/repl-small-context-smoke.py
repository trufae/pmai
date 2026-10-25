#!/usr/bin/env python3
"""Compact an oversized saved chat through a provider with a hard 32k window."""
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import threading
from http.server import ThreadingHTTPServer

from smoke import clean_environment, JSONProvider, read_chat


requests = []
rejects = []
fail_after = None


class Provider(JSONProvider):
    def do_GET(self):
        self.respond({'data': [{'id': 'small'}]})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append(body)
        text = '\n'.join(message.get('content', '') for message in body['messages'])
        tokens = len(text.encode()) // 4 + body.get('max_tokens', 512)
        if tokens > 32768:
            rejects.append(body)
            self.respond({'error': {
                'code': 'context_length_exceeded',
                'message': f"This model's maximum context length is 32768 tokens. Requested {tokens}.",
            }}, 400)
            return
        if fail_after is not None and len(requests) > fail_after:
            self.respond({'error': {'message': 'Partial summary failed'}}, 500)
            return
        markers = sorted(set(re.findall(r'\bKEEP-\d+\b', text)))
        answer = 'Saved facts: ' + ' '.join(markers) if markers else 'Ready.'
        self.respond({'choices': [{'message': {'role': 'assistant', 'content': answer},
                                   'finish_reason': 'stop'}]})


def main():
    global fail_after
    binary = str(Path(sys.argv[1]).resolve())
    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    environment = clean_environment()
    environment['NO_PROXY'] = '127.0.0.1,localhost'
    try:
        with tempfile.TemporaryDirectory(prefix='pmai-small-context-') as directory:
            root = Path(directory)
            config = root / 'config.json'
            config.write_text(json.dumps({
                'defaultAgent': 'main',
                'providers': [{'id': 'local', 'kind': 'openAICompatible',
                               'baseURL': f'http://127.0.0.1:{server.server_port}/v1'}],
                'agents': [{'id': 'main', 'provider': 'local', 'model': 'small',
                            'toolNames': [], 'toolGroupNames': [],
                            'autocompact': {'tokens': 0}, 'retry': {'attempts': 0}}],
                'memory': {'enabled': False}, 'use': {'plan': False},
            }))
            command = [binary, '--config', str(config), '--home', str(root / 'home'),
                       '--no-stream', '--no-markdown']

            def run(commands, resume=True):
                result = subprocess.run(command + (['--resume'] if resume else []),
                    input='\n'.join([*commands, '/exit', '']), cwd=root, env=environment,
                    text=True, capture_output=True, timeout=30)
                output = result.stdout + result.stderr
                assert result.returncode == 0, output
                return output

            run(['seed'], resume=False)
            chat_file = next((root / '.pmai/chats').glob('*.json'))
            chat = read_chat(chat_file)
            source = '\n'.join(f'KEEP-{index} ' + 'evidence ' * 6000 for index in range(12))
            chat['messages'].extend([
                {'id': 'huge', 'role': 'assistant', 'content': [{'text': {'_0': source}}]},
                {'id': 'latest', 'role': 'user', 'content': [{'text': {'_0': 'Continue my exact task.'}}]},
            ])
            chat_file.write_text(json.dumps(chat))
            requests.clear()
            output = run(['/set ctx.window 32768', '/chat compact'])
            assert 'Conversation compacted into a summary.' in output, output
            assert 'error:' not in output and not rejects, (output, rejects)
            assert len(requests) > 2, len(requests)
            assert all(body.get('max_tokens', 0) <= 2048 for body in requests)
            saved = json.loads(config.read_text())
            assert saved['agents'][0]['options']['contextWindowTokens'] == 32768, saved
            compacted = read_chat(chat_file)
            text = json.dumps(compacted['messages'])
            for index in range(12):
                assert f'KEEP-{index}' in text, text
            assert 'Continue my exact task.' in text
            assert len(text) < len(source) // 10

            # A failure after one successful chunk must not replace any history.
            chat_file.write_text(json.dumps(chat))
            requests.clear()
            fail_after = 1
            output = run(['/chat compact'])
            assert 'Partial summary failed' in output, output
            assert len(requests) == 2, len(requests)
            assert read_chat(chat_file)['messages'] == chat['messages']
            print('PASS 32k chunked compaction, persisted context window, and atomic failure')
    finally:
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
