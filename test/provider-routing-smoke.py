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
            editor = root / 'provider-editor.py'
            editor.write_text('''import json, os, pathlib, sys
path = pathlib.Path(sys.argv[1])
provider = json.loads(path.read_text())
assert provider['_credentialHelp']
assert any('baseURL:' in line for line in provider['_credentialHelp'])
assert any('defaultModel:' in line for line in provider['_credentialHelp'])
assert all(field in provider for field in ('apiKey', 'apiKeyEnvironment', 'apiKeyFile'))
assert 'defaultModel' in provider
if 'TEST_EDIT_URL' in os.environ and 'TEST_EDIT_RETRY' not in os.environ:
    provider['baseURL'] = os.environ['TEST_EDIT_URL']
if 'TEST_EDIT_DEFAULT_MODEL' in os.environ:
    provider['defaultModel'] = os.environ['TEST_EDIT_DEFAULT_MODEL']
if 'TEST_EDIT_KEY_ENV' in os.environ:
    provider['apiKeyEnvironment'] = os.environ['TEST_EDIT_KEY_ENV'] or None
if 'TEST_EDIT_KEY' in os.environ:
    provider['apiKey'] = os.environ['TEST_EDIT_KEY']
if 'TEST_EDIT_RETRY' in os.environ:
    state = pathlib.Path(os.environ['TEST_EDIT_RETRY'])
    if not state.exists():
        state.write_text('1')
        provider['baseUrL'] = 'misspelled field'
    elif state.read_text() == '1':
        assert provider.pop('baseUrL') == 'misspelled field'
        assert provider['defaultModel'] == os.environ['TEST_EDIT_DEFAULT_MODEL']
        state.write_text('2')
        provider['baseURL'] = 'not-a-url'
    else:
        assert provider['baseURL'] == 'not-a-url'
        provider['baseURL'] = os.environ['TEST_EDIT_URL']
        state.write_text('3')
path.write_text(json.dumps(provider))
''')
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

            def run(commands=(), args=(), env=None, error=False, ambient_defaults=True):
                result = subprocess.run(
                    [binary, '--config', str(config), '--home', str(root / 'home'),
                     '--no-stream', '--no-markdown', *args],
                    cwd=root, env=environment | (ambient if ambient_defaults else {}) | (env or {}),
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

            # The welcome commands turn an empty config into a working keyed connection.
            fresh_config = root / 'fresh.json'
            fresh_config.write_text('{}')
            output = run(['/provider add myai ' + base + '/first/v1 --api-key first-key',
                          '/models myai', '/model myai::org/model:tag', 'First request.'],
                         args=['--config', str(fresh_config)], ambient_defaults=False)
            assert 'Welcome to PocketMai!' in output, output
            assert 'first-key' not in output, output
            check_request('/first/v1', 'first-key')
            assert [p['id'] for p in json.loads(fresh_config.read_text())['providers']] == ['myai']
            run(args=['--config', str(fresh_config), 'Saved first connection.'], ambient_defaults=False)
            check_request('/first/v1', 'first-key')

            # Flags split provider::model. Environment aliases only bootstrap unsaved profiles.
            run(args=['--model', 'remote::org/model:tag', 'Flag selection.'])
            check_request('/remote/v1', 'file-key')
            assert requests[-1][1]['x-provider'] == 'remote'
            bootstrap_config = root / 'bootstrap.json'
            bootstrap = json.loads(config.read_text())
            bootstrap.update(agents=[], taskAgents={})
            bootstrap.pop('defaultAgent', None)
            bootstrap_config.write_text(json.dumps(bootstrap))
            for alias in ('PMAI_MODEL', 'MAI_MODEL', 'OPENAI_MODEL'):
                run(args=['--config', str(bootstrap_config), 'Environment bootstrap.'],
                    env={alias: 'remote::org/model:tag'})
                check_request('/remote/v1', 'file-key')
                run(args=['Saved selection.'], env={alias: 'remote::org/model:tag'})
                check_request('/local/v1', 'local-key', 'main-model')
            run(args=['--model', 'remote::org/model::', 'Preserve remaining model syntax.'])
            check_request('/remote/v1', 'file-key', 'org/model::')
            run(args=['--model', 'envkey::org/model:tag', 'Provider environment key.'])
            check_request('/envkey/v1', 'environment-key')
            run(args=['--model', 'fallback::org/model:tag', 'Ad-hoc key fallback.'])
            check_request('/fallback/v1', 'wrong-key')
            run(['/edit provider fallback'],
                env={'EDITOR': f'python3 {editor}', 'TEST_EDIT_KEY_ENV': 'REMOTE_KEY'})
            run(args=['--model', 'fallback::org/model:tag', 'Edited key source.'])
            check_request('/fallback/v1', 'environment-key')
            saved_fallback = next(p for p in json.loads(config.read_text())['providers']
                                  if p['id'] == 'fallback')
            assert saved_fallback['apiKeyEnvironment'] == 'REMOTE_KEY'
            assert '_credentialHelp' not in saved_fallback
            run(['/edit provider fallback'],
                env={'EDITOR': f'python3 {editor}', 'TEST_EDIT_KEY_ENV': '',
                     'TEST_EDIT_KEY': 'saved-key'})
            run(args=['--model', 'fallback::org/model:tag', 'Edited direct key.'])
            check_request('/fallback/v1', 'saved-key')
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
            check_request('/local/v1', 'local-key', 'main-model')
            for selector in ('::model', 'remote::', 'missing::model'):
                run(args=['--model', selector, 'Invalid selection.'], error=True)

            # Edit another connection without selecting it.
            output = run(['/edit provider remote', '/provider',
                          '/model-chat remote::org/model:tag', 'Edited endpoint.'],
                         env={'EDITOR': f'python3 {editor}',
                              'TEST_EDIT_URL': f'{base}/edited/v1'})
            assert "Current provider: local" in output, output
            check_request('/edited/v1', 'file-key')
            saved = json.loads(config.read_text())
            remote = next(p for p in saved['providers'] if p['id'] == 'remote')
            assert remote['timeout'] == 73 and remote['options'] == {'custom': True}
            assert remote['apiKeyFile'] == str(key_file) and remote['headers']['x-provider'] == 'remote'
            assert next(p for p in saved['providers'] if p['id'] == 'local')['baseURL'] == f'{base}/local/v1'

            retry_state = root / 'editor-retries'
            output = run(['/edit provider remote'],
                         env={'EDITOR': f'python3 {editor}',
                              'TEST_EDIT_URL': f'{base}/edited/v1',
                              'TEST_EDIT_DEFAULT_MODEL': 'remote-default',
                              'TEST_EDIT_RETRY': str(retry_state)}, error=True)
            assert 'Unknown provider field: baseUrL' in output, output
            assert 'baseURL must be an http:// or https:// URL' in output, output
            assert 'Reopening provider editor' in output, output
            assert retry_state.read_text() == '3'
            remote = next(p for p in json.loads(config.read_text())['providers']
                          if p['id'] == 'remote')
            assert remote['defaultModel'] == 'remote-default' and 'baseUrL' not in remote
            run(['/provider use remote', 'Provider default model.'])
            check_request('/edited/v1', 'file-key', 'remote-default')
            run(args=['Saved connection without environment variables.'], ambient_defaults=False)
            check_request('/edited/v1', 'file-key', 'remote-default')
            run(args=['--provider', 'remote', 'Provider flag default model.'])
            check_request('/edited/v1', 'file-key', 'remote-default')
            run(['/model-chat remote::org/model:tag'])

            # JSON editing preserves URL query values. Old setters cannot change the URL.
            query = f'{base}/query/v1?tenant=one&mode=two'
            run(['/edit provider remote'],
                env={'EDITOR': f'python3 {editor}', 'TEST_EDIT_URL': query})
            assert next(p for p in json.loads(config.read_text())['providers']
                        if p['id'] == 'remote')['baseURL'] == query
            before = config.read_bytes()
            output = run([f'/set provider.baseurl={base}/wrong/v1',
                          f'/baseurl {base}/wrong/v1',
                          f'/provider baseurl remote {base}/wrong/v1'])
            assert output.count('Change baseURL with /edit provider remote.') == 3, output
            assert config.read_bytes() == before
            run(['/edit provider remote'],
                env={'EDITOR': f'python3 {editor}',
                     'TEST_EDIT_URL': f'{base}/edited/v1'})

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
                  'provider editing, rename, task references, collision, and resume')
    finally:
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
