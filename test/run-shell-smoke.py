#!/usr/bin/env python3
"""Failing run_shell output reaches both the CLI and the model, without a live model."""
import json
import os
from datetime import datetime
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
        if request['messages'][-1]['role'] == 'user':
            message = {'role': 'assistant', 'content': '', 'tool_calls': [tool_call]}
        else:
            message = {'role': 'assistant', 'content': 'CHECK-COMPLETE'}
        self.respond({'choices': [{'message': message,
            'finish_reason': 'tool_calls' if 'tool_calls' in message else 'stop'}]})


def check_timeout_setting(binary, server, env):
    global tool_call
    for proxy in (False, True):
        with tempfile.TemporaryDirectory(prefix='pmai-run-timeout-') as directory:
            root = Path(directory)
            config = root / 'config.json'
            config.write_text(json.dumps({
                'defaultAgent': 'main',
                'providers': [{'id': 'local', 'kind': 'openAICompatible',
                               'baseURL': f'http://127.0.0.1:{server.server_port}/v1'}],
                'toolSources': [{'id': 'standard', 'kind': 'standard-tools',
                                 'options': {'tools': ['run_shell'], 'runTimeoutSeconds': 1}}],
                'agents': [{'id': 'main', 'provider': 'local', 'model': 'fixture',
                            'toolNames': ['run_shell'], 'toolGroupNames': [],
                            'retry': {'attempts': 0}, 'autocompact': {'tokens': 0}}],
                'approvals': {'mode': 'yolo'}, 'memory': {'enabled': False},
                'use': {'plan': False, 'agentsmd': 'off'},
            }))
            arguments = {'script': 'sleep 1.2; printf timeout-setting-ok'}
            tool_call = {'id': 'timeout', 'type': 'function', 'function': {
                'name': 'call-tool' if proxy else 'run_shell',
                'arguments': json.dumps({'name': 'run_shell', 'arguments': arguments}
                                        if proxy else arguments)}}
            command = [binary, '--config', str(config), '--home', str(root / 'home'),
                       '--no-stream', '--no-markdown']
            for seconds in (2, 1):
                requests.clear()
                result = subprocess.run(command,
                    input=f'/set limits.runTimeoutSeconds {seconds}\nRun the command\n/exit\n',
                    cwd=root, env=dict(env, PWD=str(root)), text=True, capture_output=True, timeout=20)
                output = result.stdout + result.stderr
                assert result.returncode == 0, output
                assert len(requests) == 2, (requests, output)
                body = '\n'.join(m['content'] for m in requests[-1]['messages'] if m['role'] == 'tool')
                if seconds == 2:
                    assert 'timeout-setting-ok' in body and 'timed out' not in body, body
                else:
                    assert 'timed out after 1 seconds' in body, body
                assert json.loads(config.read_text())['agents'][0]['limits']['runTimeoutSeconds'] == seconds
            result = subprocess.run(command,
                input='/set limits.runTimeoutSeconds 5m\n/set limits.runTimeoutSeconds 601\n'
                      '/set limits.runTimeoutSeconds\n/set limits.runTimeoutSeconds default\n'
                      '/set limits.\n/exit\n',
                cwd=root, env=dict(env, PWD=str(root)), text=True, capture_output=True, timeout=20)
            output = result.stdout + result.stderr
            assert result.returncode == 0, output
            assert 'limits.runTimeoutSeconds = 5m' in output, output
            assert '1-600 seconds per shell call' in output, output
            assert 'limits.runTimeoutSeconds = default' in output, output
            assert 'runTimeoutSeconds' not in json.loads(config.read_text())['agents'][0]['limits']
            print(f'PASS {"proxy" if proxy else "native"}: /set shell timeout execution and persistence')


def check_windows(binary):
    """Keep Run visible and executable on a stock Windows installation."""
    global tool_call
    env = clean_environment()
    env.update(NO_PROXY='127.0.0.1,localhost', NO_COLOR='1')
    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix='pmai run ü ') as directory:
            root = Path(directory)
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

            def invoke(arguments, proxy=False):
                global tool_call
                requests.clear()
                tool_call = {'id': 'windows-run', 'type': 'function', 'function': {
                    'name': 'call-tool' if proxy else 'run_shell',
                    'arguments': json.dumps({'name': 'run_shell', 'arguments': arguments}
                                            if proxy else arguments)}}
                result = subprocess.run([
                    binary, '--config', str(config), '--home', str(root / 'home'),
                    '--no-stream', '--no-markdown'], input='Run the command\n/exit\n',
                    cwd=root, env=dict(env, PWD=str(root), TMP=str(root), TEMP=str(root)), encoding='utf-8',
                    capture_output=True, timeout=90)
                output = result.stdout + result.stderr
                assert result.returncode == 0, output
                assert len(requests) == 2, (requests, output)
                body = '\n'.join(m['content'] for m in requests[-1]['messages'] if m['role'] == 'tool')
                assert 'CHECK-COMPLETE' in output, output
                if 'timed out' in body:
                    print(output, flush=True)
                return body

            for proxy in (False, True):
                body = invoke({'script': "[Console]::Write('out ü'); [Console]::Error.Write('err'); exit 3"}, proxy)
                assert 'out ü' in body and '[stderr]\nerr' in body and '[exit code 3]' in body, body
            literals = ['', 'two words', '"quoted"', 'C:\\path with spaces\\', '$(bad)', '& echo injected', 'ü']
            body = invoke({'args': [sys.executable, '-X', 'utf8', '-c',
                                   'import json,sys; print(json.dumps(sys.argv[1:], ensure_ascii=False)); assert sys.stdin.read() == \"input\"',
                                   *literals], 'stdin': 'input'})
            assert json.loads(body) == literals, body
            print('PASS Windows native argv and stdin', flush=True)
            body = invoke({
                'command': "[Console]::Write(($args -join '|') + ':' + [Console]::In.ReadToEnd()); "
                           "Set-Content -LiteralPath result.txt -Value 'saved'",
                'args': ['two words', 'ü'], 'stdin': 'input', 'cwd': str(root),
            })
            assert 'two words|ü:input' in body and 'Error:' not in body, body
            assert (root / 'result.txt').read_text().strip() == 'saved'
            body = invoke({'args': ['cmd.exe', '/d', '/s', '/c', 'echo native-cmd']})
            assert body.strip() == 'native-cmd', body
            body = invoke({'commands': ["Write-Output 'one'", "Write-Output 'two'"]})
            assert body.strip().splitlines() == ['one', 'two'], body

            settings = json.loads(config.read_text())
            settings['toolSources'][0]['options']['runShell'] = 'cmd.exe'
            config.write_text(json.dumps(settings))
            body = invoke({'script': 'echo cmd:%~1\nexit /b 7', 'args': ['two words']})
            assert 'cmd:two words' in body and '[exit code 7]' in body, body
            del settings['toolSources'][0]['options']['runShell']
            config.write_text(json.dumps(settings))

            # The timeout must stop the spawned child too, not just PowerShell.
            body = invoke({'script':
                "$child = Start-Process powershell.exe -ArgumentList '-NoProfile', '-Command', "
                "'Start-Sleep -Seconds 120' -PassThru; Write-Output $child.Id; Start-Sleep -Seconds 120",
                'timeout_seconds': 10})
            assert 'timed out after 10 seconds' in body, body
            pid = int(body.splitlines()[0])
            probe = subprocess.run(['powershell.exe', '-NoProfile', '-Command',
                f'if (Get-Process -Id {pid} -ErrorAction SilentlyContinue) {{ exit 1 }}'],
                capture_output=True, timeout=30)
            try:
                assert probe.returncode == 0, f'Timed-out child {pid} is still running'
            finally:
                if probe.returncode:
                    subprocess.run(['taskkill.exe', '/PID', str(pid), '/T', '/F'],
                                   capture_output=True, timeout=30)
            print('PASS Windows run_shell: registration, aliases, Unicode, stdin, cwd, argv, exit status and timeout tree cleanup')
    finally:
        server.shutdown()
        server.server_close()


def main():
    global tool_call
    binary = str(Path(sys.argv[1]).resolve())
    if os.name == 'nt':
        return check_windows(binary)
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
                        'ui': {'tools': -1},
                        'use': {'plan': False, 'agentsmd': 'off'},
                    }))
                    result = subprocess.run([
                        binary, '--config', str(config), '--home', str(root / 'home'),
                        '--no-stream', '--no-markdown'],
                        input='Run sys/lint.sh\n/ps -ap\n/exit\n', cwd=root, env=dict(env, PWD=str(root)),
                        text=True, capture_output=True, timeout=30)
                    output = result.stdout + result.stderr
                    assert result.returncode == 0, output
                    assert len(requests) == 2, (requests, output)
                    results = [m['content'] for m in requests[-1]['messages'] if m['role'] == 'tool']
                    assert len(results) == 1, results
                    assert diagnostic in results[0] and '[exit code 1]' in results[0], results
                    assert diagnostic in output and '[exit code 1]' in output, output
                    assert 'CHECK-COMPLETE' in output, output
                    chat_path = next((root / '.pmai/chats').glob('*.json'))
                    saved = json.loads(chat_path.read_text())
                    commands = saved['commands']
                    assert len(commands) == 1, commands
                    process = commands[0]
                    assert process['pid'] > 0 and process['exitCode'] == 1, process
                    assert process['state'] == 'exited' and process['endedAt'], process
                    assert process['run']['agentID'] == 'main', process
                    assert process['callID'] == 'run-failure', process
                    assert f"{process['pid']}\tmain\t" in output, output
                    restored = subprocess.run([
                        binary, '--config', str(config), '--home', str(root / 'home'),
                        '-r', saved['id'], '--no-markdown'],
                        input='/ps -ap\n/ps\n/ps -k ' + str(process['pid']) + '\n/exit\n',
                        cwd=root, env=dict(env, PWD=str(root)), text=True, capture_output=True, timeout=30)
                    restored_output = restored.stdout + restored.stderr
                    assert restored.returncode == 0, restored_output
                    assert f"{process['pid']}\tmain\t" in restored_output, restored_output
                    assert 'No matching commands.' in restored_output, restored_output
                    assert f"No live process {process['pid']} owned by this chat" in restored_output, restored_output
                    restored_commands = json.loads(chat_path.read_text())['commands']
                    assert len(restored_commands) == len(commands)
                    for before, after in zip(commands, restored_commands):
                        for stamp in ('startedAt', 'endedAt'):
                            a = datetime.fromisoformat(before[stamp].replace('Z', '+00:00'))
                            b = datetime.fromisoformat(after[stamp].replace('Z', '+00:00'))
                            assert abs((a - b).total_seconds()) < .002
                        assert ({k: v for k, v in before.items() if k not in ('startedAt', 'endedAt')}
                                == {k: v for k, v in after.items() if k not in ('startedAt', 'endedAt')})
                    # Pre-feature chat files only carried the run call and its result.
                    legacy = json.loads(chat_path.read_text())
                    del legacy['commands']
                    chat_path.write_text(json.dumps(legacy))
                    recovered = subprocess.run([
                        binary, '--config', str(config), '--home', str(root / 'home'),
                        '-r', saved['id'], '--no-markdown'], input='/ps -ap\n/exit\n',
                        cwd=root, env=dict(env, PWD=str(root)), text=True, capture_output=True, timeout=30)
                    recovered_output = recovered.stdout + recovered.stderr
                    assert recovered.returncode == 0, recovered_output
                    assert 'sys/lint.sh' in recovered_output or key == 'args', recovered_output
                    recovered_commands = json.loads(chat_path.read_text())['commands']
                    assert len(recovered_commands) == 1, recovered_commands
                    assert recovered_commands[0]['exitCode'] == 1
                    assert recovered_commands[0]['durationMs'] >= 0
                    assert 'startedAt' not in recovered_commands[0]
                    print(f'PASS {"proxy" if proxy else "native"} {key}: stdout and exit code 1 preserved')
        check_timeout_setting(binary, server, env)
    finally:
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
