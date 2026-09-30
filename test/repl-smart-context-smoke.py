#!/usr/bin/env python3
"""Check smart context routing, prompt editing, and retained history over local HTTP."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


requests = []


class Provider(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def respond(self, payload):
        body = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.respond({'data': [{'id': 'large'}, {'id': 'tiny'}]})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append(body)
        answer = 'WORKING BRIEF' if body['model'] == 'tiny' else 'MAIN ANSWER'
        self.respond({'choices': [{'message': {'role': 'assistant', 'content': answer},
                                   'finish_reason': 'stop'}]})


def main():
    binary = str(Path(sys.argv[1]).resolve())
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(('PMAI_', 'MAI_', 'OPENAI_'))}
    environment['NO_PROXY'] = '127.0.0.1,localhost'
    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix='pmai-smart-') as directory:
            root = Path(directory)
            config = root / 'config.json'
            config.write_text(json.dumps({
                'defaultAgent': 'main',
                'providers': [{'id': 'local', 'kind': 'openAICompatible',
                               'baseURL': f'http://127.0.0.1:{server.server_port}/v1'}],
                'agents': [{'id': 'main', 'provider': 'local', 'model': 'large',
                            'instructions': 'ORIGINAL RULES', 'toolNames': [],
                            'toolGroupNames': [], 'autocompact': {'tokens': 0}}],
                'memory': {'enabled': False}, 'use': {'plan': False},
            }))
            editor = root / 'editor.py'
            editor.write_text('from pathlib import Path\nimport sys\n'
                              'Path(sys.argv[1]).write_text("CUSTOM SMART\\n{{transcript}}")\n')
            environment['EDITOR'] = f'{sys.executable} {editor}'

            def run(commands, resume=False):
                result = subprocess.run(
                    [binary, '--config', str(config), '--home', str(root / 'home'),
                     '--no-stream', '--no-markdown', *(['--resume'] if resume else [])],
                    input='\n'.join([*commands, '/exit', '']), cwd=root, env=environment,
                    text=True, capture_output=True, timeout=30)
                output = result.stdout + result.stderr
                assert result.returncode == 0 and 'error:' not in output, output
                return output

            output = run(['/model-compact local::tiny', '/set ctx.context=smart',
                          '/set ctx.strategy', '/edit prompt smart', 'Fix the parser'])
            assert 'ctx.strategy = smart' in output, output
            assert 'Smart prompt saved' in output, output
            saved = json.loads(config.read_text())
            assert saved['agents'][0]['context'] == 'smart', saved
            assert saved['prompts']['smart'] == 'CUSTOM SMART\n{{transcript}}', saved
            assert [request['model'] for request in requests] == ['tiny', 'large'], requests
            assert requests[0]['messages'][-1]['content'].startswith('CUSTOM SMART'), requests[0]
            assert 'Fix the parser' in requests[0]['messages'][-1]['content'], requests[0]
            assert not requests[0].get('tools'), requests[0]
            conversation = [m for m in requests[1]['messages'] if m['role'] not in ('system', 'developer')]
            assert conversation == [{'role': 'user', 'content': 'WORKING BRIEF'}], conversation
            assert any('ORIGINAL RULES' in m['content'] for m in requests[1]['messages']), requests[1]

            chat_file = next((root / '.pmai/chats').glob('*.json'))
            chat = json.loads(chat_file.read_text())
            assert 'Fix the parser' in json.dumps(chat['messages']), chat
            assert 'MAIN ANSWER' in json.dumps(chat['messages']), chat
            assert 'WORKING BRIEF' not in json.dumps(chat['messages']), chat
            run(['Now add tests'], resume=True)
            assert [r['model'] for r in requests] == ['tiny', 'large', 'tiny', 'large'], requests
            next_prompt = requests[2]['messages'][-1]['content']
            for text in ('Fix the parser', 'MAIN ANSWER', 'Now add tests'):
                assert text in next_prompt, next_prompt
            assert 'WORKING BRIEF' not in next_prompt, next_prompt
            output = run(['/set ctx.strategy=cache', '/set ctx.context'], resume=True)
            assert 'ctx.context = cache' in output, output
            assert json.loads(config.read_text())['agents'][0]['context'] == 'cache'
    finally:
        server.shutdown()
        server.server_close()
    print('smart context CLI smoke passed')


if __name__ == '__main__':
    main()
