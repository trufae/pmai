#!/usr/bin/env python3
"""Failing run_shell output reaches both the CLI and the model, without a live model."""
import json
from http.server import ThreadingHTTPServer
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading

from smoke import JSONProvider, clean_environment


requests = []
tool_call = {}


class Provider(JSONProvider):
    def do_GET(self):
        self.respond({'data': [{'id': 'fixture'}]})

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append(request)
        if len(requests) == 1:
            message = {'role': 'assistant', 'content': '', 'tool_calls': [tool_call]}
        else:
            message = {'role': 'assistant', 'content': 'CHECK-COMPLETE'}
        self.respond({'choices': [{'message': message,
            'finish_reason': 'tool_calls' if 'tool_calls' in message else 'stop'}]})


def main():
    global tool_call
    binary = str(Path(sys.argv[1]).resolve())
    fixture = Path(__file__).resolve().parent.parent / 'MaiCore/Tests/Fixtures/run-failure.sh'
    diagnostic = fixture.read_text().splitlines()[1].removeprefix("echo '").removesuffix("'")
    env = clean_environment()
    env.update(NO_PROXY='127.0.0.1,localhost', NO_COLOR='1')
    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        for proxy in (False, True):
            for key in ('script', 'command', 'commands', 'args'):
                requests.clear()
                with tempfile.TemporaryDirectory(prefix='pmai-run-failure-') as directory:
                    root = Path(directory)
                    (root / 'sys').mkdir()
                    script = root / 'sys/lint.sh'
                    shutil.copyfile(fixture, script)
                    script.chmod(0o700)
                    arguments = {key: ['sys/lint.sh'] if key in ('args', 'commands') else 'sys/lint.sh'}
                    tool_call = {'id': 'run-failure', 'type': 'function', 'function': {
                        'name': 'call-tool' if proxy else 'run_shell',
                        'arguments': json.dumps({'name': 'run_shell', 'arguments': arguments}
                                                if proxy else arguments)}}
                    config = root / 'config.json'
                    config.write_text(json.dumps({
                        'defaultAgent': 'main',
                        'providers': [{'id': 'local', 'kind': 'openAICompatible',
                                       'baseURL': f'http://127.0.0.1:{server.server_port}/v1'}],
                        'toolSources': [{'id': 'standard', 'kind': 'standard-tools',
                                         'options': {'tools': ['run_shell']}}],
                        'agents': [{'id': 'main', 'provider': 'local', 'model': 'fixture',
                                    'toolNames': ['run_shell'], 'toolGroupNames': [],
                                    'retry': {'attempts': 0}, 'autocompact': {'tokens': 0}}],
                        'approvals': {'mode': 'yolo'}, 'memory': {'enabled': False},
                        'use': {'plan': False, 'agentsmd': 'off'},
                    }))
                    result = subprocess.run([
                        binary, '--config', str(config), '--home', str(root / 'home'),
                        '--no-stream', '--no-markdown'],
                        input='Run sys/lint.sh\n/exit\n', cwd=root, env=dict(env, PWD=str(root)),
                        text=True, capture_output=True, timeout=30)
                    output = result.stdout + result.stderr
                    assert result.returncode == 0, output
                    assert len(requests) == 2, (requests, output)
                    results = [m['content'] for m in requests[-1]['messages'] if m['role'] == 'tool']
                    assert len(results) == 1, results
                    assert diagnostic in results[0] and '[exit code 1]' in results[0], results
                    assert diagnostic in output and '[exit code 1]' in output, output
                    assert 'CHECK-COMPLETE' in output, output
                    print(f'PASS {"proxy" if proxy else "native"} {key}: stdout and exit code 1 preserved')
    finally:
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
