#!/usr/bin/env python3
"""Check project YOLO choices across CLI restarts and real tool approvals."""
import json
import os
from pathlib import Path
import re
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
            message = {'role': 'assistant', 'content': 'tool decision received'}
        else:
            message = {'role': 'assistant', 'content': None, 'tool_calls': [{
                'id': 'write-proof', 'type': 'function',
                'function': {'name': 'files_write', 'arguments': json.dumps({
                    'path': 'yolo-proof.txt', 'content': 'project choice honored',
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
        with tempfile.TemporaryDirectory(prefix='pmai-yolo-') as directory:
            root = Path(directory)
            first, second = root / 'first', root / 'second'
            first.mkdir()
            second.mkdir()
            config = root / 'config.json'
            config.write_text(json.dumps({
                'version': 1, 'defaultAgent': 'smoke',
                'providers': [{'id': 'smoke', 'kind': 'openAICompatible', 'apiKey': 'smoke',
                               'baseURL': f'http://127.0.0.1:{server.server_port}/v1', 'timeout': 10}],
                'toolSources': [{'id': 'standard', 'kind': 'standard-tools',
                                 'options': {'tools': ['files_write']}}],
                'agents': [{'id': 'smoke', 'provider': 'smoke', 'model': 'smoke', 'enabled': True,
                            'toolNames': ['files_write'], 'toolGroupNames': [],
                            'retry': {'attempts': 0}}],
                'approvals': {'confirm': 'ask', 'dangerous': 'ask', 'yolo': False},
                'memory': {'enabled': False, 'scope': 'project'}, 'use': {'plan': False},
            }))

            def run(project, commands=(), args=(), configuration=config):
                result = subprocess.run(
                    [binary, '--config', str(configuration), '--home', str(root / 'home'),
                     '--no-stream', '--no-markdown', *args], cwd=project, env=environment,
                    input='\n'.join([*commands, '/exit', '']), capture_output=True,
                    text=True, encoding='utf-8', timeout=20)
                output = result.stdout + result.stderr
                assert result.returncode == 0, output
                return output

            def states(output):
                return re.findall(r'yolo = (on|off)', output)

            def write(project, allowed, **kwargs):
                marker = project / 'yolo-proof.txt'
                marker.unlink(missing_ok=True)
                output = run(project, args=[*kwargs.pop('args', ()), 'write proof'], **kwargs)
                assert 'tool decision received' in output, output
                assert marker.exists() == allowed, output
                if allowed:
                    assert marker.read_text() == 'project choice honored'

            assert states(run(first, ['/set yolo'])) == ['off']
            original = config.read_bytes()
            output = run(first, ['/set yolo on', '/project name Renamed', '/set yolo'])
            assert states(output) == ['on'], output
            settings = first / '.pmai' / 'settings.json'
            assert settings.is_file(), 'YOLO was not saved inside the project .pmai'
            assert json.loads(settings.read_text())['yolo'] is True
            assert config.read_bytes() == original, 'Project choice changed shared configuration'
            assert states(run(first, ['/set yolo'])) == ['on']
            assert states(run(second, ['/set yolo'])) == ['off']
            write(first, True)
            write(second, False)

            # A project choice must survive using a different configuration.
            legacy = root / 'legacy.json'
            value = json.loads(config.read_text())
            value['approvals']['yolo'] = True
            legacy.write_text(json.dumps(value))
            write(second, True, configuration=legacy)
            run(first, ['/set yolo off'], configuration=legacy)
            assert json.loads(settings.read_text())['yolo'] is False
            write(first, False, configuration=legacy)
            write(first, True, configuration=legacy, args=['-y'])
            assert states(run(first, ['/set yolo'], configuration=legacy)) == ['off']
            assert json.loads(legacy.read_text())['approvals']['yolo'] is True

            assert states(run(second, ['/set yolo'], args=['-y'])) == ['on']
            assert states(run(second, ['/set yolo'])) == ['off']
            assert not (second / '.pmai' / 'settings.json').exists(), '-y became persistent'
            output = run(first, ['/set yolo invalid', '/set yolo'])
            assert 'Usage: /set yolo <on|off>' in output and states(output) == ['off'], output

            # /cd changes tool cwd; settings still belong to the opened project.
            run(first, [f'/cd {second}', '/set yolo on'], args=['--state', str(root / 'chats')])
            assert json.loads(settings.read_text())['yolo'] is True
            assert states(run(second, ['/set yolo'])) == ['off']
            assert config.read_bytes() == original
            print('PASS project YOLO persistence, isolation, approvals, legacy defaults and -y')
    finally:
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
