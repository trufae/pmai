#!/usr/bin/env python3
"""Exercise Files scope commands and mandatory path prompts in yolo mode."""
import fcntl
import json
import os
from pathlib import Path
import pty
import queue
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
from http.server import ThreadingHTTPServer
from smoke import JSONProvider, clean_environment, expect_pty, read_pty, run_repl


answers = queue.Queue()
requests = []


class Provider(JSONProvider):
    def do_GET(self):
        self.respond({'data': [{'id': 'main'}]})

    def do_POST(self):
        requests.append(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
        message = answers.get(timeout=20)
        self.respond({'choices': [{'message': message,
            'finish_reason': 'tool_calls' if message.get('tool_calls') else 'stop'}]})


def call(name, **arguments):
    return {'role': 'assistant', 'content': '', 'tool_calls': [{
        'id': 'path-test', 'type': 'function',
        'function': {'name': name, 'arguments': json.dumps(arguments)}}]}


def enqueue(message, final='TURN FINISHED'):
    answers.put(message)
    answers.put({'role': 'assistant', 'content': final})


def canonical(text):
    # Foundation resolves macOS /private/var aliases to /var; Python uses /private/var.
    return str(text).replace('/private/var/', '/var/')


def main():
    binary = str(Path(sys.argv[1]).resolve())
    env = clean_environment()
    env.update(NO_PROXY='127.0.0.1,localhost', NO_COLOR='1', TERM='xterm-256color')
    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix='pmai-path-') as directory:
            base = Path(directory).resolve()
            user_home = base / 'user'
            user_home.mkdir()
            env['HOME'] = str(user_home)
            root = base / 'workspace'
            external = base / 'external dir'
            for folder in (root, external, root / 'private'):
                folder.mkdir()
            (root / 'private/secret.txt').write_text('LOCAL SECRET')
            (root / '.env').write_text('HIDDEN SECRET')
            (external / 'outside.txt').write_text('EXTERNAL SECRET')
            (base / 'outside.txt').write_text('PROMPT GRANT')
            (root / 'new-cwd').mkdir()
            config = base / 'config.json'
            config.write_text(json.dumps({
                'defaultAgent': 'main',
                'providers': [{'id': 'local', 'kind': 'openAICompatible',
                               'baseURL': f'http://127.0.0.1:{server.server_port}/v1'}],
                'toolSources': [{'id': 'standard', 'kind': 'standard-tools'}],
                'agents': [{'id': 'main', 'provider': 'local', 'model': 'main',
                            'instructions': 'Rules', 'toolGroupNames': ['files', 'pmai'],
                            'retry': {'attempts': 0}, 'autocompact': {'tokens': 0}}],
                'memory': {'enabled': False}, 'use': {'plan': False, 'agentsmd': 'off'},
                'approvals': {'mode': 'yolo'}, 'ui': {'toolResultLines': 0}}))
            original_config = config.read_text()
            command = [binary, '--config', str(config), '--home', str(base / 'home'),
                       '--no-stream', '--no-markdown']

            output = run_repl(command, ['/pwd', '/path', '/help path',
                '/path allow "../external dir"', '/path deny private', '/path ask .',
                '/path outside deny', '/path', '/path remove .', '/path remove "../external dir"',
                '/cd new-cwd', '/path'], cwd=root, env=env)
            assert canonical(f'Current directory: {root}') in canonical(output), output
            assert canonical(f'allow {external}') in canonical(output) and canonical(f'deny {root / "private"}') in canonical(output), output
            assert canonical(f'ask {root}') in canonical(output) and 'Outside allowed paths: deny' in output, output
            assert canonical(f'Current directory: {root / "new-cwd"}') in canonical(output), output
            assert 'Hidden paths: ask' in output, output
            settings = json.loads(config.read_text())['fileAccess']
            assert settings['hidden'] == 'ask' and settings['outside'] == 'deny', settings
            assert any(rule['path'].endswith('/etc') and rule['access'] == 'ask'
                       for rule in settings['rules']), settings
            assert any(rule['path'].endswith('/.ssh') and rule['access'] == 'ask'
                       for rule in settings['rules']), settings
            assert any(rule['path'].endswith('/.config') and rule['access'] == 'ask'
                       for rule in settings['rules']), settings

            # Saved edits survive restarts; removing all defaults does not reseed them.
            output = run_repl(command, ['/path', '/path hidden deny', '/path remove /etc',
                '/path remove ~/.ssh', '/path remove ~/.config', '/path remove private'], cwd=root, env=env)
            assert canonical(f'deny {root / "private"}') in canonical(output), output
            assert 'Outside allowed paths: deny' in output, output
            output = run_repl(command, ['/path'], cwd=root, env=env)
            assert 'Hidden paths: deny' in output, output
            assert json.loads(config.read_text())['fileAccess']['rules'] == [], config.read_text()

            # Startup defaults require a person even for hidden prompt-named paths in yolo.
            config.write_text(original_config)
            for path in ['.env', str(root / '.env'), '/etc/pmai-policy-smoke']:
                enqueue(call('files_read', path=path))
            output = run_repl(command, ['Read hidden', 'Inspect ' + str(root / '.env'),
                'Read system settings'], cwd=root, env=env)
            tool_messages = [json.dumps(m) for req in requests for m in req['messages'] if m['role'] == 'tool']
            assert sum('was not approved' in m for m in tool_messages) >= 3, tool_messages
            assert not any('HIDDEN SECRET' in m for m in tool_messages), tool_messages
            assert '[granted from prompt]' not in run_repl(command, ['/path'], cwd=root, env=env)
            requests.clear()

            # Noninteractive policy prompts fail closed even with normal tool approval in yolo.
            config.write_text(original_config)
            enqueue(call('files_read', path='private/secret.txt'))
            enqueue(call('files_read', path=str(external / 'outside.txt')))
            enqueue(call('files_read', path=str(external / 'outside.txt')))
            enqueue(call('files_read', path=str(external / 'outside.txt')))
            enqueue(call('pmai_run', command='/path allow /'))
            enqueue(call('pmai_run', command='/cd /'))
            output = run_repl(command, ['/path deny private',
                '/tools set files filesDisplayName sandbox', 'Read private',
                '/path outside ask', 'Read outside', '/path allow "../external dir"', 'Read granted',
                '/path ask "../external dir"', 'Read asked', 'Change policy', 'Change cwd'],
                cwd=root, env=env)
            tool_messages = [json.dumps(m) for req in requests for m in req['messages'] if m['role'] == 'tool']
            assert any('Files access denied' in m for m in tool_messages), tool_messages
            assert any('EXTERNAL SECRET' in m for m in tool_messages), tool_messages
            assert sum('was not approved' in m for m in tool_messages) >= 2, tool_messages
            assert any('Only the person at the REPL' in m for m in tool_messages), tool_messages
            assert 'TURN FINISHED' in output, output
            requests.clear()

            # Existing explicit-prompt grants in yolo remain automatic, with a teaching hint.
            config.write_text(original_config)
            enqueue(call('files_read', path=str(base / 'outside.txt')))
            output = run_repl(command, ['Inspect ' + str(base / 'outside.txt'), '/path'], cwd=root, env=env)
            assert 'Use /path to review, deny, or require prompts' in output, output
            assert '[granted from prompt]' in output, output
            assert 'PROMPT GRANT' in json.dumps(requests[-1]), requests[-1]
            requests.clear()

            # A fixed Files root is listed separately from the process cwd.
            fixed = json.loads(config.read_text())
            fixed['toolSources'][0]['options']['filesRoot'] = str(external)
            fixed_config = base / 'fixed.json'
            fixed_config.write_text(json.dumps(fixed))
            output = run_repl([binary, '--config', str(fixed_config), '--home', str(base / 'fixed-home')],
                              ['/path'], cwd=root, env=env)
            assert canonical(f'allow {external}') in canonical(output) and 'fixed root' in output, output

            # Real terminal: yolo cannot auto-approve asks or release pending path prompts.
            config.write_text(original_config)
            master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 36, 180, 0, 0))
            process = subprocess.Popen(command, cwd=root, env=env, stdin=slave,
                                       stdout=slave, stderr=slave, start_new_session=True)
            os.close(slave)
            pending = bytearray()
            def send(text):
                os.write(master, (text + '\r').encode())
            def expect(text):
                return expect_pty(master, process, pending, canonical(text), 20)
            try:
                expect('pmai>')
                send('/path ask private')
                expect(f'Files policy: ask {root / "private"}')
                enqueue(call('files_read', path='private/secret.txt'), 'FIRST FINISHED')
                send('Read private')
                expect('answer y (yes, this access)')
                send('/set tool.aproval yolo')
                expect('yolo')
                assert len(requests) == 1, requests
                send('y')
                expect('FIRST FINISHED')
                enqueue(call('files_read', path='private/secret.txt'), 'SECOND FINISHED')
                send('Read again')
                expect('answer y (yes, this access)')
                send('n')
                expect('SECOND FINISHED')
                assert 'was not approved' in json.dumps(requests[-1]), requests[-1]

                # The default hidden rule also asks on every access.
                for answer, final in [('y', 'HIDDEN FIRST'), ('n', 'HIDDEN SECOND')]:
                    enqueue(call('files_read', path='.env'), final)
                    send('Read hidden')
                    expect('answer y (yes, this access)')
                    send(answer)
                    expect(final)
                assert 'was not approved' in json.dumps(requests[-1]), requests[-1]

                # Prompt-named external paths get a grant and teach /path.
                send('/path outside ask')
                expect('Files access outside allowed paths: ask')
                answers.put({'role': 'assistant', 'content': 'GRANT FINISHED'})
                send('Inspect ' + str(base / 'outside.txt'))
                expect("tool 'files_path_access'")
                send('y')
                expect('Use /path to review, deny, or require prompts')
                expect('GRANT FINISHED')
                send('/path')
                expect(f'allow {base / "outside.txt"} [granted from prompt]')
                send('/path remove ' + str(base / 'outside.txt'))
                expect('Removed explicit Files rule/grant')
                send('/exit')
                deadline = time.monotonic() + 10
                while process.poll() is None and time.monotonic() < deadline:
                    read_pty(master, pending, .1)
                assert process.poll() == 0, pending.decode(errors='replace')
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                os.close(master)
    finally:
        server.shutdown()
        server.server_close()
    print('path policy CLI smoke passed')


if __name__ == '__main__':
    main()
