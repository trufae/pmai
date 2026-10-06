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

            output = run(['/model-compact local::tiny', '/set ctx.strategy=smart',
                          '/set ctx.strategy', '/set', '/help set',
                          '/edit prompt smart', 'Fix the parser'])
            assert 'ctx.strategy = smart' in output, output
            assert 'ctx.strategy = smart\n' in output, output
            assert '/set ctx.strategy <cache|size|smart|tools>' in output, output
            assert 'ctx.context' not in output and 'ctx.strategy alias' not in output, output
            assert 'Smart prompt saved' in output, output
            saved = json.loads(config.read_text())
            assert saved['agents'][0]['context'] == 'smart', saved
            assert saved['prompts']['smart'] == 'CUSTOM SMART\n{{transcript}}', saved
            assert [request['model'] for request in requests] == ['large'], requests
            conversation = [m for m in requests[0]['messages'] if m['role'] not in ('system', 'developer')]
            assert conversation == [{'role': 'user', 'content': 'Fix the parser'}], conversation
            assert any('ORIGINAL RULES' in m['content'] for m in requests[0]['messages']), requests[0]

            chat_file = next((root / '.pmai/chats').glob('*.json'))
            chat = json.loads(chat_file.read_text())
            assert 'Fix the parser' in json.dumps(chat['messages']), chat
            assert 'MAIN ANSWER' in json.dumps(chat['messages']), chat
            assert 'WORKING BRIEF' not in json.dumps(chat['messages']), chat
            run(['Now add tests'], resume=True)
            assert [r['model'] for r in requests] == ['large', 'large'], requests
            next_prompt = str(requests[1]['messages'])
            for text in ('Fix the parser', 'MAIN ANSWER', 'Now add tests'):
                assert text in next_prompt, next_prompt
            assert 'WORKING BRIEF' not in next_prompt, next_prompt
            # Large earlier tasks need a brief, but the next exact request
            # stays outside it. Small tool loops never pay this round trip.
            run(['Earlier constraints: ' + 'evidence ' * 9000], resume=True)
            run(['Now review the parser'], resume=True)
            assert [r['model'] for r in requests] == ['large', 'large', 'large', 'tiny', 'large']
            preparation = requests[-2]
            assert preparation['messages'][-1]['content'].startswith('CUSTOM SMART')
            assert 'Earlier constraints' in preparation['messages'][-1]['content']
            assert 'Now review the parser' in preparation['messages'][-1]['content']
            assert not preparation.get('tools')
            assert 'ORIGINAL RULES' not in str(preparation['messages'])
            assert 'WORKING BRIEF' in str(requests[-1]['messages'])
            assert 'Now review the parser' in str(requests[-1]['messages'])
            output = run(['/set ctx.strategy=cache', '/set ctx.strategy'], resume=True)
            assert 'ctx.strategy = cache' in output, output
            assert json.loads(config.read_text())['agents'][0]['context'] == 'cache'
            saved_config = config.read_bytes()
            output = run(['/set ctx.strategy invalid', '/set ctx.context smart',
                          '/set ctx.strategy'], resume=True)
            assert 'Usage: /set ctx.strategy <cache|size|smart|tools>' in output, output
            assert "Unknown setting 'ctx.context'." in output, output
            assert 'ctx.context' not in output.split('Available settings:', 1)[1], output
            assert 'ctx.strategy = cache' in output, output
            assert config.read_bytes() == saved_config, 'invalid settings changed the configuration'
    finally:
        server.shutdown()
        server.server_close()
    print('smart context CLI smoke passed')


if __name__ == '__main__':
    main()
