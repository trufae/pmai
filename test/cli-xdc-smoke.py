#!/usr/bin/env python3
"""Exercise CLI XDC launch, build failure and the attached chat with local fixtures."""
from http.server import ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading

from smoke import clean_environment, JSONProvider, run_repl


class Provider(JSONProvider):
    def do_GET(self):
        self.respond({'data': [{'id': 'fixture'}]})

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        messages = [message.get('content') for message in request['messages']]
        if 'host context' not in messages:
            self.respond({'error': {'message': 'Missing chat history'}}, status=400)
            return
        self.respond({'choices': [{'message': {'role': 'assistant', 'content': 'context arrived'},
                                   'finish_reason': 'stop'}]})


def write_manifest(directory, manifest):
    (directory / 'manifest.json').write_text(json.dumps({'version': 1, **manifest}), encoding='utf-8')


def main():
    binary = str(Path(sys.argv[1]).resolve())
    examples = Path(__file__).resolve().parent.parent / 'examples' / 'cli-xdc'
    env = clean_environment()

    def run(directory, *args, allowed=True):
        command = [binary, 'app', 'run', *(['--allow-exec'] if allowed else []), str(directory), *args]
        return subprocess.run(command, capture_output=True, env=env, text=True, encoding='utf-8', timeout=30)

    with tempfile.TemporaryDirectory(prefix='pmai app ') as directory:
        root = Path(directory)
        source = shutil.copytree(examples / 'c', root / 'compiled app')
        compiler = shutil.which('clang') or shutil.which('cc')
        assert compiler, 'CLI XDC smoke test requires a C compiler'
        build = [compiler, '-O2', 'main.c', '-o', '{bin}']
        write_manifest(source, {'build': {'command': build}, 'run': {'command': ['{bin}']}})
        result = run(source, 'argument with spaces')
        assert result.returncode == 0 and result.stdout.strip() == 'argument with spaces', result
        (source / 'main.c').write_text('#error deliberate build failure\n', encoding='utf-8')
        result = run(source)
        assert result.returncode != 0 and 'deliberate build failure' in result.stderr and not result.stdout, result

        python = shutil.copytree(examples / 'python', root / 'python app')
        write_manifest(python, {'run': {'command': [sys.executable, 'main.py']}})
        result = run(python, 'literal & --help')
        assert result.returncode == 0 and result.stdout.strip() == 'literal & --help', result
        result = run(python, allowed=False)
        assert result.returncode != 0 and '--allow-exec' in result.stderr and not result.stdout, result
        write_manifest(python, {'run': {'command': ['pmai-fixture-missing-interpreter']}})
        result = run(python)
        assert result.returncode != 0 and 'pmai-fixture-missing-interpreter' in result.stderr, result
        if shutil.which('node'):
            result = run(examples / 'node', 'argument with spaces')
            assert result.returncode == 0 and result.stdout.strip() == 'argument with spaces', result

        server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            config = root / 'config.json'
            config.write_text(json.dumps({
                'defaultAgent': 'fixture',
                'providers': [{'id': 'local', 'kind': 'openAICompatible',
                               'baseURL': f'http://127.0.0.1:{server.server_port}/v1'}],
                'agents': [{'id': 'fixture', 'provider': 'local', 'model': 'fixture',
                            'toolNames': [], 'toolGroupNames': []}],
                'memory': {'enabled': False},
            }), encoding='utf-8')
            write_manifest(python, {'run': {'command': [sys.executable, 'main.py']}})
            output = run_repl([binary, '--config', str(config), '--home', str(root / 'home'),
                               '--no-stream', '--no-markdown'],
                              ['/msg user host context', '/app run --allow-exec --chat "python app"'],
                              cwd=root, env=dict(env, NO_PROXY='127.0.0.1'), timeout=45)
            assert 'context arrived' in output and 'App exited with status' not in output, output
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
    print('PASS: CLI XDC build, interpreted apps, launch authorization and chat RPC')


if __name__ == '__main__':
    main()
