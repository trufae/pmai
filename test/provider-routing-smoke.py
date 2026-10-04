#!/usr/bin/env python3
"""Check provider selection, connection precedence, endpoint edits, and rename."""
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

    def reply(self, value):
        body = json.dumps(value).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.reply({'data': [{'id': 'org/model:tag'}]})

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append((self.path, dict(self.headers), request))
        self.reply({'choices': [{'message': {'role': 'assistant', 'content': 'Done.'},
                                 'finish_reason': 'stop'}]})


def main():
    binary = str(Path(sys.argv[1]).resolve())
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(('PMAI_', 'MAI_', 'OPENAI_'))
                   and key.lower() not in ('http_proxy', 'https_proxy', 'all_proxy')}
    environment['NO_PROXY'] = '127.0.0.1,localhost'
    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix='pmai-providers-') as directory:
            root = Path(directory)
            base = f'http://127.0.0.1:{server.server_port}'
            config = root / 'config.json'
            key_file = root / 'key'
            key_file.write_text('file-key\n')
            config.write_text(json.dumps({
                'defaultAgent': 'main', 'taskAgents': {'compact': 'summary'},
                'providers': [
                    {'id': 'local', 'kind': 'openAICompatible', 'baseURL': f'{base}/local/v1',
                     'apiKey': 'local-key'},
                    {'id': 'remote', 'kind': 'openAICompatible', 'baseURL': f'{base}/remote/v1',
                     'apiKeyFile': str(key_file), 'timeout': 73,
                     'headers': {'x-provider': 'remote'}, 'options': {'custom': True}},
                    {'id': 'envkey', 'kind': 'openAICompatible', 'baseURL': f'{base}/envkey/v1',
                     'apiKeyEnvironment': 'REMOTE_KEY'},
                    {'id': 'fallback', 'kind': 'openAICompatible', 'baseURL': f'{base}/fallback/v1'},
                ],
                'agents': [{'id': name, 'provider': provider, 'model': name + '-model',
                            'stream': False, 'retry': {'attempts': 0}}
                           for name, provider in [('main', 'local'), ('summary', 'remote')]],
                'memory': {'enabled': False}, 'use': {'plan': False},
            }))
            ambient = {'PMAI_BASE_URL': f'{base}/wrong/v1', 'PMAI_API_KEY': 'wrong-key',
                       'REMOTE_KEY': 'environment-key'}

            def run(commands=(), args=(), env=None, error=False):
                result = subprocess.run(
                    [binary, '--config', str(config), '--home', str(root / 'home'),
                     '--no-stream', '--no-markdown', *args],
                    cwd=root, env=environment | ambient | (env or {}),
                    input='\n'.join([*commands, '/exit', '']),
                    capture_output=True, text=True, timeout=30)
                output = result.stdout + result.stderr
                if not error:
                    assert result.returncode == 0 and 'error:' not in output, output
                else:
                    assert 'error:' in output, output
                return output

            def check_request(route, key, model='org/model:tag'):
                path, headers, request = requests[-1]
                assert path == route + '/chat/completions', requests[-1]
                assert headers.get('Authorization') == (None if key is None else 'Bearer ' + key), headers
                assert request['model'] == model, request

            # Flags and all environment model aliases split provider::model.
            run(args=['--model', 'remote::org/model:tag', 'Flag selection.'])
            check_request('/remote/v1', 'file-key')
            assert requests[-1][1]['x-provider'] == 'remote'
            for alias in ('PMAI_MODEL', 'MAI_MODEL', 'OPENAI_MODEL'):
                run(args=['Environment selection.'], env={alias: 'remote::org/model:tag'})
                check_request('/remote/v1', 'file-key')
            run(args=['--model', 'remote::org/model::', 'Preserve remaining model syntax.'])
            check_request('/remote/v1', 'file-key', 'org/model::')
            run(args=['--model', 'envkey::org/model:tag', 'Provider environment key.'])
            check_request('/envkey/v1', 'environment-key')
            run(args=['--model', 'fallback::org/model:tag', 'Ad-hoc key fallback.'])
            check_request('/fallback/v1', 'wrong-key')
            run(args=['--model', 'remote::org/model:tag', 'Ignore unused ambient errors.'],
                env={'PMAI_BASE_URL': 'bad url', 'PMAI_API_KEY_FILE': '/missing-key'})
            check_request('/remote/v1', 'file-key')

            # Explicit flags override only the chosen provider, without saving defaults.
            before = config.read_bytes()
            run(args=['--model', 'remote::org/model:tag', '--base-url', f'{base}/flag/v1',
                      '--api-key', 'flag-key', 'Explicit connection.'])
            check_request('/flag/v1', 'flag-key')
            assert config.read_bytes() == before
            run(args=['--model', 'remote::org/model:tag', '--api-key', '', 'Explicit empty key.'])
            check_request('/remote/v1', None)
            run(args=['--provider', 'local', 'Explicit provider.'],
                env={'PMAI_MODEL': 'remote::org/model:tag'})
            check_request('/local/v1', 'local-key')
            for selector in ('::model', 'remote::', 'missing::model'):
                run(args=['--model', selector, 'Invalid selection.'], error=True)

            # A targeted setting edits another connection without selecting it.
            output = run(['/set provider.baseurl remote',
                          f'/set provider baseurl remote {base}/edited/v1',
                          '/provider', '/model-chat remote::org/model:tag', 'Edited endpoint.'])
            assert "Current provider: local" in output, output
            check_request('/edited/v1', 'file-key')
            saved = json.loads(config.read_text())
            remote = next(p for p in saved['providers'] if p['id'] == 'remote')
            assert remote['timeout'] == 73 and remote['options'] == {'custom': True}
            assert remote['apiKeyFile'] == str(key_file) and remote['headers']['x-provider'] == 'remote'
            assert next(p for p in saved['providers'] if p['id'] == 'local')['baseURL'] == f'{base}/local/v1'

            # '=' syntax preserves URL query values; old slash commands remain scoped aliases.
            query = f'{base}/query/v1?tenant=one&mode=two'
            run([f'/set provider.baseurl={query}', '/set provider.baseurl'])
            assert next(p for p in json.loads(config.read_text())['providers']
                        if p['id'] == 'remote')['baseURL'] == query
            run([f'/baseurl {base}/alias/v1', f'/provider baseurl remote {base}/edited/v1'])

            # Renaming preserves connection data, updates primary/task agents, and survives resume.
            output = run(['/chat rename renamed-chat', '/provider rename remote renamed',
                          '/providers', '/model', 'Renamed connection.'])
            check_request('/edited/v1', 'file-key')
            assert 'Chat: renamed::org/model:tag' in output, output
            assert 'summary — renamed::summary-model' in output, output
            saved = json.loads(config.read_text())
            assert all(p['id'] != 'remote' for p in saved['providers'])
            assert all(a['provider'] == 'renamed' for a in saved['agents'])
            renamed = next(p for p in saved['providers'] if p['id'] == 'renamed')
            assert renamed == remote | {'id': 'renamed'}, (renamed, remote)
            run(args=['-r', 'renamed-chat', 'Resume renamed connection.'])
            check_request('/edited/v1', 'file-key')
            before = config.read_bytes()
            run(['/provider rename renamed local'], error=True)
            assert config.read_bytes() == before, 'rename collision changed configuration'
            run(['/provider rename final', '/model'])
            assert next(a for a in json.loads(config.read_text())['agents']
                        if a['id'] == 'main')['provider'] == 'final'
            print('PASS providers: qualified models, URL/key precedence, explicit overrides, '
                  'scoped settings, aliases, rename, task references, collision, and resume')
    finally:
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
