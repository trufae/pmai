#!/usr/bin/env python3
"""Exercise redaction commands, restart persistence and restored tool paths."""
import json
import re
import shlex
import subprocess
import sys
import tempfile
import threading
from http.server import ThreadingHTTPServer
from pathlib import Path
from smoke import JSONProvider, clean_environment, run_repl

requests = []
responses = []


class Provider(JSONProvider):
    def do_GET(self):
        self.respond({'data': [{'id': 'fixture'}]})

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append(request)
        response = responses.pop(0)
        message = response(request) if callable(response) else response
        self.respond({'choices': [{'message': message,
            'finish_reason': 'tool_calls' if message.get('tool_calls') else 'stop'}]})


def main():
    binary = str(Path(sys.argv[1]).resolve())
    env = clean_environment()
    env.update(NO_PROXY='127.0.0.1,localhost', NO_COLOR='1')
    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix='pmai-redact-') as directory:
            root = Path(directory)
            home = root / 'home with spaces'
            editor = root / 'editor.py'
            editor.write_text('''from pathlib import Path
import sys
file = Path(sys.argv[1])
assert file.name == "redact.txt", file
file.write_text("alice\\n/\\\\b(?:\\\\d{4}-){3}\\\\d{4}\\\\b/\\n")
''')
            env['EDITOR'] = shlex.join([sys.executable, str(editor)])
            secret = root / 'Alice.txt'
            secret.write_text('ALICE card: 4111-1111-1111-1111\n')
            config = root / 'config.json'
            config.write_text(json.dumps({
                'defaultAgent': 'main',
                'providers': [{'id': 'fixture', 'kind': 'openAICompatible',
                    'baseURL': f'http://127.0.0.1:{server.server_port}/v1'}],
                'toolSources': [{'id': 'standard', 'kind': 'standard-tools'}],
                'agents': [{'id': 'main', 'provider': 'fixture', 'model': 'fixture',
                    'instructions': 'Help', 'toolNames': ['files_read'], 'toolGroupNames': [],
                    'autocompact': {'tokens': 0}, 'retry': {'attempts': 0}}],
                'approvals': {'mode': 'yolo'}, 'memory': {'enabled': False},
                'use': {'plan': False, 'agentsmd': 'off'},
                # Released configurations used a filename here. Startup must
                # ignore it; /edit redact still edits only the fixed rules file.
                'redact': 'safe2.txt', 'ui': {'thinking': 'obsolete-mode'},
            }))
            command = [binary, '--config', str(config), '--home', str(home),
                '--no-stream', '--no-markdown']
            final = {'role': 'assistant', 'content': 'DONE'}

            def read_file(request):
                text = '\n'.join(str(m.get('content', '')) for m in request['messages'])
                token = re.search(r'__PMAI_[A-Za-z0-9_]+__', text).group()
                return {'role': 'assistant', 'content': '', 'tool_calls': [{
                    'id': 'read', 'type': 'function', 'function': {
                        'name': 'files_read', 'arguments': json.dumps({
                            'path': str(root / (token + '.txt'))})}}]}

            def summary(request):
                token = re.search(r'__PMAI_[A-Za-z0-9_]+__', json.dumps(request)).group()
                return {'role': 'assistant', 'content': 'Summary ' + token}

            responses[:] = [read_file, final, summary]
            output = run_repl(command, ['/set redact', '/edit redact', '/set redact warn',
                f'Read {secret}', '/chat compact', '/set redact'], cwd=root, env=env)
            assert 'redact = off' in output, output
            assert len(requests) == 3 and not responses, (requests, output)
            assert '4111-1111-1111-1111' in output, output
            assert output.count('warning: redacted ') == 3, output
            assert json.loads(config.read_text())['redact'] == 'warn'
            saved_chats = [p.read_text() for p in (root / '.pmai/chats').glob('*.json')]
            assert saved_chats and any('Summary Alice' in chat for chat in saved_chats), saved_chats
            assert all('__PMAI_' not in chat for chat in saved_chats), saved_chats
            assert (home / 'redact.txt').stat().st_mode & 0o777 == 0o600
            for request in requests:
                wire = json.dumps(request).lower()
                assert 'alice' not in wire and '4111' not in wire, wire

            # A fresh process must load the enabled filter, including /btw.
            requests.clear()
            responses[:] = [final]
            output = run_repl(command, ['/btw Ask ALICE'], cwd=root, env=env)
            assert 'alice' not in json.dumps(requests).lower(), requests
            assert 'warning: redacted ' in output, output

            # On is silent, while off sends literal text and remains off after restart.
            requests.clear()
            responses[:] = [final, final]
            output = run_repl(command, ['/set redact on', '/btw Ask Alice',
                '/set redact off', '/btw Ask ALICE', '/set redact /tmp/not-a-mode'], cwd=root, env=env)
            assert 'warning: redacted ' not in output, output
            assert 'Usage: /set redact on|off|warn' in output, output
            assert 'alice' not in json.dumps(requests[0]).lower(), requests[0]
            assert 'ALICE' in json.dumps(requests[1]), requests[1]
            assert json.loads(config.read_text())['redact'] == 'off'

            # Invalid enabled rules must stop startup before any provider request.
            settings = json.loads(config.read_text())
            settings['redact'] = 'on'
            config.write_text(json.dumps(settings))
            (home / 'redact.txt').write_text('/[invalid/\n')
            requests.clear()
            failed = subprocess.run(command + ['Do not send Alice'], cwd=root, env=env,
                capture_output=True, text=True, timeout=30)
            assert failed.returncode != 0 and not requests, (failed.stdout, failed.stderr, requests)
            assert 'Invalid redaction rule on line 1' in failed.stderr, failed.stderr
    finally:
        server.shutdown()
    print('Redaction CLI smoke passed')


if __name__ == '__main__':
    main()
