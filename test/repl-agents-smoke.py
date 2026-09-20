#!/usr/bin/env python3
"""Check recursive agents, trees and addressed queues against a local provider."""
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import select
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


leaf_started = threading.Event()
release_leaf = threading.Event()
requests = []
max_depth = 3


class Provider(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        users = [m['content'] for m in request['messages'] if m['role'] == 'user']
        depth = int(re.search(r'level (\d+)', users[0])[1])
        requests.append((depth, request))
        results = [m for m in request['messages'] if m['role'] == 'tool']
        message = {'role': 'assistant', 'content': f'level {depth} done'}
        if depth == max_depth:
            leaf_started.set()
            release_leaf.wait(60)
        elif not results:
            arguments = {'task': f'level {depth + 1}', 'output': 'One line.',
                         'wait': request['model'].endswith('blocking')}
            if request['model'].startswith('named'):
                arguments['agent'] = 'worker'
            message = {'role': 'assistant', 'content': None, 'tool_calls': [{
                'id': f'start-{depth}', 'type': 'function',
                'function': {'name': 'agent_start', 'arguments': json.dumps(arguments)},
            }]}
        body = json.dumps({'choices': [{'message': message,
                                       'finish_reason': 'tool_calls' if 'tool_calls' in message else 'stop'}]}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass


def main():
    binary = str(Path(sys.argv[1]).resolve())
    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        for mode in ('named-blocking', 'derived-blocking', 'named-background', 'derived-background'):
            leaf_started.clear()
            release_leaf.clear()
            requests.clear()
            with tempfile.TemporaryDirectory(prefix='pmai-agents-') as directory:
                root = Path(directory)
                config = root / 'config.json'
                config.write_text(json.dumps({
                    'version': 1, 'defaultAgent': 'worker',
                    'providers': [{'id': 'smoke', 'kind': 'openAICompatible',
                                   'baseURL': f'http://127.0.0.1:{server.server_port}/v1',
                                   'apiKey': 'smoke', 'timeout': 60}],
                    'agents': [{'id': 'worker', 'provider': 'smoke', 'model': mode,
                                'toolGroupNames': ['agents'], 'subagentNames': ['worker'],
                                'stream': False, 'retry': {'attempts': 0},
                                'limits': {'maxSubagents': 1, 'maxSubagentDepth': max_depth}}],
                    'approvals': {'confirm': 'allow', 'dangerous': 'deny'},
                    'memory': {'enabled': False}, 'use': {'plan': False},
                }))
                master, slave = pty.openpty()
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 220, 0, 0))
                env = {k: v for k, v in os.environ.items()
                       if not k.startswith(('PMAI_', 'MAI_', 'OPENAI_'))
                       and k.lower() not in ('http_proxy', 'https_proxy', 'all_proxy')}
                env.update(TERM='xterm-256color', NO_PROXY='127.0.0.1,localhost')
                process = subprocess.Popen(
                    [binary, '--config', str(config), '--home', str(root / 'home'),
                     '--no-stream', '--no-markdown'], cwd=root, env=env,
                    stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
                os.close(slave)
                output = bytearray()

                def send(text):
                    os.write(master, (text + '\r').encode())

                def wait_for(text):
                    deadline = time.monotonic() + 15
                    needle = text.encode()
                    while needle not in output:
                        assert time.monotonic() < deadline, (mode, text, output.decode(errors='replace'))
                        assert process.poll() is None, (process.returncode, output)
                        if select.select([master], [], [], .1)[0]:
                            output.extend(os.read(master, 65536))
                    end = output.index(needle) + len(needle)
                    captured = bytes(output[:end]).decode(errors='replace')
                    del output[:end]
                    return re.sub(r'\x1b(?:\[[0-?]*[ -/]*[@-~]|[78])', '', captured).replace('\r', '')

                def check_tree(state):
                    tree = wait_for('Total:')
                    for depth in range(1, max_depth + 1):
                        name = 'worker' if mode.startswith('named') else 'worker' + '.worker' * depth
                        prefix = '    ' * (depth - 1) + '└── '
                        assert re.search(rf'(?m)^{prefix}#\d+ {re.escape(name)}\s+\[{state}\]', tree), tree
                    return re.findall(r'#(\d+) \S+\s+\[', tree)

                def check_queue(expected):
                    send('/queue')
                    listing = wait_for('Each is delivered')
                    copies = re.findall(r'(?m)^  \d+\. agent#(\d+) \S+  (.+)$', listing)
                    displayed = [(pid, ' '.join(text.split())) for pid, text in expected]
                    assert sorted(copies) == sorted(displayed), (mode, copies, displayed, listing)

                def set_broadcast(enabled):
                    value = 'on' if enabled else 'off'
                    send(f'/set ui.broadcast {value}')
                    wait_for(f'Set ui.broadcast = {value}.')
                    assert json.loads(config.read_text())['ui']['broadcast'] is enabled

                try:
                    wait_for('pmai>')
                    send('/set ui.broadcast')
                    wait_for('ui.broadcast = off')
                    for prefix in ('', '/queue push '):
                        send(prefix + '@* nobody is active')
                        wait_for('No active agents.')
                    assert not requests, requests
                    send('level 0')
                    assert leaf_started.wait(15), f'{mode}: recursive leaf never started'
                    send('/agents')
                    pids = check_tree('run')
                    assert len(pids) == max_depth + 1, pids
                    main_pid, first, second, leaf = pids
                    if mode.endswith('background'):
                        send(f'/agents stop {first}')
                        wait_for('then waits.')
                    recipients = pids if mode.endswith('blocking') else pids[1:]
                    aliases = 'main,chat,0,' if mode.endswith('blocking') else ''
                    expected = [(pid, 'queued note') for pid in recipients]
                    send('/queue push @' + aliases + ','.join(recipients) + ' queued note')
                    wait_for(f'Queued for agent#{leaf}')
                    check_queue(expected)
                    for prefix in ('', '/queue push '):
                        send(f'{prefix}@{first},99999 must not arrive')
                        wait_for('No agent #99999')
                        send(f'{prefix}@*,99999 must not arrive')
                        wait_for('No agent #99999')
                        send(f'{prefix}@{first},bad must not arrive')
                        wait_for('Invalid recipients:')
                        send(f'{prefix}@{first} @{second}')
                        wait_for('A message is required')
                    check_queue(expected)
                    send(f'/agents focus {second}')
                    wait_for(f'Messages go to agent#{second}')
                    send(f'@{first} @#{second} @agent#{leaf} @{first} direct note')
                    wait_for(f'queued for agent#{leaf}')
                    expected += [(pid, 'direct note') for pid in pids[1:]]
                    send('focused note')
                    wait_for(f'queued for agent#{second}')
                    expected.append((second, 'focused note'))
                    send(f'@{first},{leaf} @README.md keep  spacing')
                    wait_for(f'queued for agent#{leaf}')
                    expected += [(pid, '@README.md keep  spacing') for pid in (first, leaf)]
                    send(f'/queue push @{first} @{leaf} discard me')
                    wait_for(f'Queued for agent#{leaf}')
                    for pid in (first, leaf):
                        send(f'/queue pop {pid}')
                        wait_for(f'Dropped from agent#{pid}: discard me')
                    check_queue(expected)
                    send(f'@*,{first} @* @agent#{leaf} broadcast note')
                    wait_for(f'queued for agent#{leaf}')
                    expected += [(pid, 'broadcast note') for pid in pids]
                    send('/queue push @* wildcard queued note')
                    wait_for(f'Queued for agent#{leaf}')
                    expected += [(pid, 'wildcard queued note') for pid in pids]
                    set_broadcast(True)
                    wait_for('pmai@*>')
                    send('/agents focus')
                    wait_for('Messages go to every active agent.')
                    send('default broadcast note')
                    wait_for(f'queued for agent#{leaf}')
                    expected += [(pid, 'default broadcast note') for pid in pids]
                    send('/queue push default queued note')
                    wait_for(f'Queued for agent#{leaf}')
                    expected += [(pid, 'default queued note') for pid in pids]
                    send(f'@{second} explicit override')
                    wait_for(f'queued for agent#{second}')
                    expected.append((second, 'explicit override'))
                    send(f'/queue push @{second} explicit queue override')
                    wait_for(f'Queued for agent#{second}')
                    expected.append((second, 'explicit queue override'))
                    set_broadcast(False)
                    send('restored focus note')
                    wait_for(f'queued for agent#{second}')
                    expected.append((second, 'restored focus note'))
                    set_broadcast(True)
                    if mode.endswith('background'):
                        send(f'/agents continue {first}')
                        wait_for('Continued ')
                    release_leaf.set()
                    wait_for('✓ took')
                    send('/agents tree')
                    check_tree('done')
                    assert {depth for depth, _ in requests} == set(range(max_depth + 1)), requests
                    for depth, request in requests:
                        tools = {t['function']['name'] for t in request.get('tools', [])}
                        assert ('agent_start' in tools) == (depth < max_depth), (depth, tools)
                    all_notes = {text for _, text in expected}
                    for depth, request in dict(requests).items():
                        users = [m['content'] for m in request['messages'] if m['role'] == 'user']
                        notes = [text for pid, text in expected if pid == pids[depth]]
                        assert [text for text in users if text in all_notes] == notes, (depth, users, notes)
                        assert not any(text in ('discard me', 'must not arrive') for text in users), users
                        if depth < max_depth:
                            role = 'tool' if mode.endswith('blocking') else 'user'
                            assert any(f'level {depth + 1} done' in m['content']
                                       for m in request['messages'] if m['role'] == role), request
                    for prefix in ('', '/queue push '):
                        send(f'{prefix}@main,{leaf} must not arrive')
                        wait_for('has finished;')
                    send('/queue')
                    wait_for('Nothing is queued')
                    count = len(requests)
                    for prefix in ('', '/queue push '):
                        send(prefix + '@* nobody is active')
                        wait_for('No active agents.')
                        send(prefix + 'default with no active agents')
                        wait_for('No active agents.')
                    assert len(requests) == count, requests
                    send('@main start idle chat')
                    wait_for('✓ took')
                    assert requests[-1][0] == 0, requests[-1]
                    users = [m['content'] for m in requests[-1][1]['messages'] if m['role'] == 'user']
                    assert users[-1] == 'start idle chat', users
                    send('/exit')
                    process.wait(timeout=10)
                    assert process.returncode == 0, process.returncode
                    reloaded = subprocess.run(
                        [binary, '--config', str(config), '--home', str(root / 'home'),
                         '--no-stream', '--no-markdown'], cwd=root, env=env,
                        input='/set ui.broadcast\n/exit\n', capture_output=True, text=True, timeout=15)
                    assert reloaded.returncode == 0, reloaded.stderr
                    assert 'ui.broadcast = on' in reloaded.stdout, reloaded.stdout
                    print(f'PASS {mode}: addressed queues, broadcasts and saved default routing')
                finally:
                    release_leaf.set()
                    if process.poll() is None:
                        process.kill()
                        process.wait()
                    os.close(master)
    finally:
        release_leaf.set()
        server.shutdown()


if __name__ == '__main__':
    main()
