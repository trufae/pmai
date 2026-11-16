#!/usr/bin/env python3
"""Goals pause, persist, resume and clear through the real REPL and local HTTP."""
import json
from pathlib import Path
import sys
import tempfile
import threading
from http.server import ThreadingHTTPServer

from smoke import JSONProvider, clean_environment, project_storage, read_chat, run_repl


class Provider(JSONProvider):
    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        reviews = [call for message in request['messages']
                   for call in message.get('tool_calls', [])
                   if call['function']['name'] == 'goal_review']
        status = 'complete' if reviews else 'continue'
        self.respond({'choices': [{'message': {
            'role': 'assistant', 'content': None, 'tool_calls': [{
                'id': f'review-{len(reviews)}', 'type': 'function', 'function': {
                    'name': 'goal_review', 'arguments': json.dumps({
                        'status': status, 'summary': 'Reviewed fixture',
                        'evidence': 'Fixture result verified',
                        'next': '' if reviews else 'Verify the remaining fixture',
                    })},
            }]}, 'finish_reason': 'tool_calls'}]})


def main():
    binary = str(Path(sys.argv[1]).resolve())
    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix='pmai-goal-') as directory:
            root = Path(directory).resolve()
            home = root / 'home'
            config = root / 'config.json'
            config.write_text(json.dumps({
                'defaultAgent': 'main',
                'providers': [{'id': 'fixture', 'kind': 'openai',
                               'baseURL': f'http://127.0.0.1:{server.server_port}/v1'}],
                'agents': [{'id': 'main', 'provider': 'fixture', 'model': 'fixture',
                            'toolGroupNames': [], 'stream': False,
                            'retry': {'attempts': 0}}],
                'memory': {'enabled': False}, 'use': {'plan': False},
            }))
            command = [binary, '--config', str(config), '--home', str(home),
                       '--no-stream', '--no-markdown']
            env = clean_environment()
            output = run_repl(command, ['/goal --iterations 1 Verify fixture'], cwd=root, env=env)
            assert 'Goal: paused' in output and '/goal resume' in output, output
            saved = next((project_storage(home, root) / 'chats').glob('*.json'))
            goal = read_chat(saved)['goal']
            assert goal['status'] == 'paused' and goal['iterations'] == 1, goal
            assert goal['nextStep'] == 'Verify the remaining fixture', goal

            command += ['-r', read_chat(saved)['id']]
            output = run_repl(command, ['/goal', '/goal resume', '/goal'], cwd=root, env=env)
            assert 'Goal: paused' in output and 'Goal: complete' in output, output
            goal = read_chat(saved)['goal']
            assert goal['status'] == 'complete' and goal['iterations'] == 2, goal
            output = run_repl(command, ['/goal resume', '/goal clear', '/goal'], cwd=root, env=env)
            assert 'This goal is complete' in output and 'No goal saved' in output, output
            assert read_chat(saved).get('goal') is None

            output = run_repl(command, ['/set tool.calling off', '/goal Impossible', '/goal'],
                              cwd=root, env=env, allow_errors=True)
            assert 'Goals require tools enabled' in output and 'No goal saved' in output, output
            print('PASS /goal: bounded review, saved state, resume, completion, clear and tool policy')
    finally:
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
