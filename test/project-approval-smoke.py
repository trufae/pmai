#!/usr/bin/env python3
"""Check project approval modes across CLI restarts and real tool approvals."""
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
                'approvals': {'mode': 'ask'},
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
                return re.findall(r'tool\.aproval = (yolo|ask|smart)', output)

            def write(project, allowed, **kwargs):
                marker = project / 'yolo-proof.txt'
                marker.unlink(missing_ok=True)
                output = run(project, args=[*kwargs.pop('args', ()), 'write proof'], **kwargs)
                assert 'tool decision received' in output, output
                assert marker.exists() == allowed, output
                if allowed:
                    assert marker.read_text() == 'project choice honored'

            assert states(run(first, ['/set tool.aproval'])) == ['ask']
            original = config.read_bytes()
            output = run(first, ['/set tool.aproval yolo', '/project name Renamed', '/set tool.aproval'])
            assert states(output) == ['yolo', 'yolo'], output
            settings = first / '.pmai' / 'settings.json'
            assert settings.is_file(), 'Approval mode was not saved inside the project .pmai'
            assert json.loads(settings.read_text())['approvalMode'] == 'yolo'
            assert config.read_bytes() == original, 'Project choice changed shared configuration'
            assert states(run(first, ['/set tool.aproval'])) == ['yolo']
            assert states(run(second, ['/set tool.aproval'])) == ['ask']
            write(first, True)
            write(second, False)

            # A project choice must survive using a different configuration.
            legacy = root / 'legacy.json'
            value = json.loads(config.read_text())
            value['approvals'] = {'yolo': True}
            legacy.write_text(json.dumps(value))
            write(second, True, configuration=legacy)
            run(first, ['/set tool.aproval ask'], configuration=legacy)
            assert json.loads(settings.read_text())['approvalMode'] == 'ask'
            write(first, False, configuration=legacy)
            write(first, True, configuration=legacy, args=['--tool-aproval', 'yolo'])
            assert states(run(first, ['/set tool.aproval'], configuration=legacy)) == ['ask']
            assert json.loads(legacy.read_text())['approvals']['yolo'] is True

            assert states(run(second, ['/set tool.aproval'], args=['--tool-aproval', 'yolo'])) == ['yolo']
            assert states(run(second, ['/set tool.aproval'])) == ['ask']
            assert not (second / '.pmai' / 'settings.json').exists(), '--tool-aproval became persistent'
            output = run(first, ['/set tool.aproval invalid', '/set tool.aproval'])
            assert 'Usage: /set tool.aproval <yolo|ask|smart>' in output and states(output) == ['ask'], output

            run(first, ['/set tool.aproval smart'])
            assert json.loads(settings.read_text())['approvalMode'] == 'smart'
            assert states(run(first, ['/set tool.aproval'])) == ['smart']

            # Old project settings still load, then save using the new key.
            for enabled, mode in ((True, 'yolo'), (False, 'ask')):
                settings.write_text(json.dumps({'yolo': enabled}))
                assert states(run(first, ['/set tool.aproval'])) == [mode]
                write(first, enabled)
            run(first, ['/set tool.aproval ask'])
            assert json.loads(settings.read_text()) == {'approvalMode': 'ask'}

            # /cd changes tool cwd; settings still belong to the opened project.
            run(first, [f'/cd {second}', '/set tool.aproval yolo'], args=['--state', str(root / 'chats')])
            assert json.loads(settings.read_text())['approvalMode'] == 'yolo'
            assert states(run(second, ['/set tool.aproval'])) == ['ask']
            assert config.read_bytes() == original
            print('PASS project approval persistence, isolation, legacy settings and --tool-aproval')
    finally:
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
