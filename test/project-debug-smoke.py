#!/usr/bin/env python3
"""Exercise the project debug switch with real model and tool calls."""
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Server(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        if any(message['role'] == 'tool' for message in request['messages']):
            message = {'role': 'assistant', 'content': 'debug smoke done'}
        else:
            message = {'role': 'assistant', 'content': None, 'tool_calls': [{
                'id': 'debug-write', 'type': 'function',
                'function': {'name': 'files_write', 'arguments': json.dumps({
                    'path': 'debug-proof.txt', 'content': 'logged tool call',
                })},
            }]}
        data = json.dumps({'choices': [{'message': message, 'finish_reason':
                           'tool_calls' if 'tool_calls' in message else 'stop'}]}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def main():
    binary = str(Path(sys.argv[1]).resolve())
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(('PMAI_', 'MAI_', 'OPENAI_'))
                   and key.lower() not in ('http_proxy', 'https_proxy', 'all_proxy')}
    environment['NO_PROXY'] = '127.0.0.1,localhost'
    server = ThreadingHTTPServer(('127.0.0.1', 0), Server)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix='pmai-debug-') as directory:
            root = Path(directory)
            project = root / 'project'
            other = root / 'other'
            project.mkdir()
            other.mkdir()
            config = root / 'config.json'
            config.write_text(json.dumps({
                'version': 1, 'defaultAgent': 'smoke',
                'providers': [{'id': 'smoke', 'kind': 'openAICompatible', 'apiKey': 'secret-key',
                               'baseURL': f'http://127.0.0.1:{server.server_port}/v1',
                               'timeout': 10}],
                'toolSources': [{'id': 'standard', 'kind': 'standard-tools',
                                 'options': {'tools': ['files_write']}}],
                'agents': [{'id': 'smoke', 'provider': 'smoke', 'model': 'smoke', 'enabled': True,
                            'toolNames': ['files_write'], 'toolGroupNames': [],
                            'retry': {'attempts': 0}}],
                'approvals': {'mode': 'ask'},
                'memory': {'enabled': False, 'scope': 'project'}, 'use': {'plan': False},
            }))

            def run(where, *commands):
                result = subprocess.run(
                    [binary, '--config', str(config), '--home', str(root / 'home'),
                     '--no-stream', '--no-markdown'], cwd=where, env=environment,
                    input='\n'.join([*commands, '/exit', '']), capture_output=True,
                    text=True, encoding='utf-8', timeout=20)
                output = result.stdout + result.stderr
                assert result.returncode == 0, output
                return output

            log = project / '.pmai' / 'debug.jsonl'
            assert 'debug = false' in run(project, '/set debug')
            assert not log.exists()
            output = run(project, '/set debug true', '/set tool.aproval yolo', 'first prompt')
            assert 'debug smoke done' in output, output
            assert (project / 'debug-proof.txt').read_text() == 'logged tool call'
            settings = json.loads((project / '.pmai' / 'settings.json').read_text())
            assert settings == {'debug': True, 'approvalMode': 'yolo'}, settings
            assert stat.S_IMODE(log.stat().st_mode) == 0o600
            entries = [json.loads(line) for line in log.read_text().splitlines()]
            kinds = [entry['kind'] for entry in entries]
            for kind in ('run.started', 'model.request', 'model.response',
                         'tool.started', 'tool.finished', 'run.finished'):
                assert kind in kinds, kinds
            requests = [entry['value'] for entry in entries if entry['kind'] == 'model.request']
            assert len(requests) >= 2, requests
            assert any('first prompt' in str(request) for request in requests), requests
            assert any('logged tool call' in str(request) for request in requests), requests
            assert all('secret-key' not in line for line in log.read_text().splitlines())
            before = len(entries)
            assert 'debug = true' in run(project, '/set debug', 'second prompt')
            before_disable = len(log.read_text().splitlines())
            assert before_disable > before, 'setting did not survive restart'
            run(project, '/set debug false', 'third prompt')
            after = len(log.read_text().splitlines())
            assert after == before_disable, 'disabling did not stop logging immediately'
            run(project, 'fourth prompt')
            assert len(log.read_text().splitlines()) == after, 'disabled logging still wrote'
            assert json.loads((project / '.pmai' / 'settings.json').read_text())['debug'] is False
            assert 'debug = false' in run(other, '/set debug')
            assert not (other / '.pmai' / 'debug.jsonl').exists()
            assert 'Usage: /set debug <true|false>' in run(project, '/set debug invalid')
            custom = root / 'debug logs' / 'first.jsonl'
            assert str(custom) in run(project, f'/set debugfile {custom}', '/set debugfile')
            assert not custom.exists(), 'setting the path while off created a log'
            assert json.loads((project / '.pmai' / 'settings.json').read_text())['debugFile'] == str(custom)
            default_count = len(log.read_text().splitlines())
            run(project, '/set debug true', 'custom prompt')
            assert len(custom.read_text().splitlines()) > 0
            assert len(log.read_text().splitlines()) == default_count
            first_count = len(custom.read_text().splitlines())
            replacement = root / 'debug logs' / 'second.jsonl'
            run(project, f'/set debugfile {replacement}', 'switched prompt')
            assert len(custom.read_text().splitlines()) == first_count
            assert 'switched prompt' in replacement.read_text()
            second_count = len(replacement.read_text().splitlines())
            run(project, 'restart prompt')
            assert len(replacement.read_text().splitlines()) > second_count
            relative = project / 'relative logs' / 'relative.jsonl'
            run(project, '/set debugfile relative logs/relative.jsonl', 'relative prompt')
            assert 'relative prompt' in relative.read_text()
            relative_setting = json.loads((project / '.pmai' / 'settings.json').read_text())['debugFile']
            assert Path(relative_setting).resolve() == relative.resolve(), relative_setting
            output = run(project, f'/set debugfile {root}', '/set debugfile')
            assert 'error:' in output and relative_setting in output, output
            run(project, '/set debugfile default', 'default prompt')
            assert 'default prompt' in log.read_text()
            assert 'debugFile' not in json.loads((project / '.pmai' / 'settings.json').read_text())
            run(project, '/set debug true')
            log.unlink()
            protected = root / 'protected.txt'
            protected.write_text('untouched')
            protected_mode = stat.S_IMODE(protected.stat().st_mode)
            log.symlink_to(protected)
            output = run(project, '/set debug false')
            assert 'warning: debug log unavailable' in output, output
            assert protected.read_text() == 'untouched'
            assert stat.S_IMODE(protected.stat().st_mode) == protected_mode
            print('PASS project debug logging, custom paths, persistence and disable')
    finally:
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
