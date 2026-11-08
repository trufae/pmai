#!/usr/bin/env python3
"""Exercise CLI XDC launch, build failure and the attached chat with local fixtures."""
from http.server import ThreadingHTTPServer
import json
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
        answer = 'context saved' if messages[-1] == 'host context' else 'context arrived'
        self.respond({'choices': [{'message': {'role': 'assistant', 'content': answer},
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
        if shutil.which('pkg-config.exe' if sys.platform == 'win32' else 'pkg-config'):
            (root / 'cli-xdc-test.pc').write_text(
                'Name: cli-xdc-test\nDescription: Test compiler flags\nVersion: 1\n'
                'Cflags: -DCLI_XDC_PKG_CONFIG\n', encoding='utf-8')
            env['PKG_CONFIG_PATH'] = str(root)
            main_c = source / 'main.c'
            main_c.write_text('#ifndef CLI_XDC_PKG_CONFIG\n#error Missing pkg-config flags\n#endif\n'
                              + main_c.read_text(encoding='utf-8'), encoding='utf-8')
            write_manifest(source, {'build': {'command': build, 'pkg_config': ['cli-xdc-test']},
                                    'run': {'command': ['{bin}']}})
            result = run(source, 'pkg-config')
            assert result.returncode == 0 and result.stdout.strip() == 'pkg-config', result

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
                'toolSources': [{'id': 'standard', 'kind': 'standard-tools'}],
                'agents': [{'id': 'fixture', 'provider': 'local', 'model': 'fixture',
                            'toolGroupNames': ['files'], 'retry': {'attempts': 0}}],
                'approvals': {'mode': 'yolo'}, 'memory': {'enabled': False},
            }), encoding='utf-8')
            (root / 'fixture.txt').write_text('Tool result from host workspace', encoding='utf-8')
            (python / 'bridge.py').write_text('''import json
import os
from urllib.request import Request, urlopen

def rpc(method, **params):
    body = json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params})
    with urlopen(Request(os.environ['PMAI_APP_RPC'], data=body.encode()), timeout=20) as response:
        return json.load(response)['result']

context = rpc('chat/context')
assert any(message['text'] == 'host context' for message in context['messages']), context
assert 'files_read' in {tool['name'] for tool in rpc('tools/list')['tools']}
result = rpc('tools/call', name='files_read', arguments={'path': 'fixture.txt'})
assert not result['isError'] and 'Tool result from host workspace' in result['text'], result
assert rpc('tools/call', name='pmai-fixture-unavailable')['isError']
print(rpc('chat/prompt', text='Use the active chat.')['text'])
''', encoding='utf-8')
            write_manifest(python, {'run': {'command': [sys.executable, 'bridge.py']}})
            command = [binary, '--config', str(config), '--home', str(root / 'home'),
                       '--no-stream', '--no-markdown']
            env['NO_PROXY'] = '127.0.0.1'
            output = run_repl(command, ['/chat rename xdc-fixture', 'host context'], cwd=root, env=env)
            assert 'context saved' in output, output
            output = run_repl([*command, '-r', 'xdc-fixture'],
                              ['/app run --allow-exec --chat "python app"'],
                              cwd=root, env=env, timeout=45)
            assert 'context arrived' in output and 'App exited with status' not in output, output
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
    print('PASS: CLI XDC build, interpreted apps, launch authorization and chat RPC')


if __name__ == '__main__':
    main()
