#!/usr/bin/env python3
"""Deterministic CLI skill checks, including deliberately lossy smart briefs."""
import json
from smoke import JSONProvider, clean_environment, run_repl
from html import escape
from pathlib import Path
import sys
import tempfile
import threading
from http.server import ThreadingHTTPServer

requests = []
answers = []
BODY = 'EXACT SKILL STEPS: read input.txt; answer ALPHA DONE; task=$ARGUMENTS'


class Provider(JSONProvider):
    def do_GET(self):
        self.respond({'data': [{'id': 'main'}, {'id': 'compact'}]})

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append(request)
        message = {'role': 'assistant', 'content': 'LOSSY BRIEF'} if request['model'] == 'compact' else answers.pop(0)
        self.respond({'choices': [{'message': message,
            'finish_reason': 'tool_calls' if message.get('tool_calls') else 'stop'}]})


def call(name, arguments, protocol):
    if protocol == 'json':
        return {'role': 'assistant', 'content': json.dumps({'tool': name, 'arguments': arguments})}
    if protocol in ('text', 'xml'):
        values = {key: json.dumps(value) if isinstance(value, dict) else value
                  for key, value in arguments.items()}
        content = ('TOOL_CALL\ntool: ' + name + '\n' + '\n'.join(f'{k}: {v}' for k, v in values.items())
                   + '\nEND_TOOL_CALL') if protocol == 'text' else (
            f'<tool_call name="{name}">' + ''.join(f'<arg name="{k}">{escape(v)}</arg>'
                                                  for k, v in values.items()) + '</tool_call>')
        return {'role': 'assistant', 'content': content}
    return {'role': 'assistant', 'content': '', 'tool_calls': [{
        'id': name, 'type': 'function', 'function': {'name': name, 'arguments': json.dumps(arguments)}}]}


def main():
    binary = str(Path(sys.argv[1]).resolve())
    env = clean_environment()
    env['NO_PROXY'] = '127.0.0.1,localhost'
    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix='pmai-skills-') as directory:
            root = Path(directory)
            (root / 'input.txt').write_text('payload')
            for name in ('alpha', 'beta'):
                folder = root / '.pmai/skills' / name
                folder.mkdir(parents=True)
                (folder / 'SKILL.md').write_text(f'---\nname: {name}\ndescription: Do {name}\n---\n' + BODY)
            config = root / 'config.json'
            base = {
                'defaultAgent': 'main',
                'providers': [{'id': 'local', 'kind': 'openAICompatible',
                               'baseURL': f'http://127.0.0.1:{server.server_port}/v1'}],
                'toolSources': [{'id': 'standard', 'kind': 'standard-tools'}],
                'agents': [{'id': 'main', 'provider': 'local', 'model': 'main',
                            'instructions': 'Rules', 'toolNames': ['files_read'],
                            'toolGroupNames': ['skills'], 'autocompact': {'tokens': 0}}],
                'memory': {'enabled': False}, 'use': {'plan': False},
            }

            def run(commands, responses):
                requests.clear()
                answers[:] = responses
                output = run_repl([binary, '--config', str(config), '--home', str(root / 'home'),
                    '--no-stream', '--no-markdown'], commands,
                    cwd=root, env=dict(env, PWD=str(root)), timeout=30)
                assert not answers, answers
                return [r for r in requests if r['model'] == 'main']

            final = {'role': 'assistant', 'content': 'ALPHA DONE'}
            # The complete 32-case matrix runs in SmartContextTests without CLI startup.
            # Keep both exposure paths for every protocol and context at the CLI boundary.
            modes = ('cache', 'size', 'smart', 'tools')
            protocols = ('native', 'json', 'xml', 'text')
            cases = ([(mode, protocol) for mode in modes for protocol in protocols]
                     if '--exhaustive' in sys.argv[2:] else list(zip(modes, protocols)))
            for mode, protocol in cases:
                for proxied in (False, True):
                    base['agents'][0].update(context=mode, toolCallingStrategy=protocol, useToolProxy=proxied)
                    config.write_text(json.dumps(base))
                    load_name = 'call-tool' if proxied else 'skills_alpha'
                    load_args = {'name': 'skills_alpha', 'arguments': {'arguments': 'input.txt'}} if proxied else {'arguments': 'input.txt'}
                    primary = run(['/model-compact local::compact', 'Use alpha for input.txt'], [
                        call(load_name, load_args, protocol),
                        call('files_read', {'path': 'input.txt'}, protocol), final])
                    assert len(primary) == 3, primary
                    expected = BODY.replace('$ARGUMENTS', 'input.txt')
                    for request in primary[1:]:
                        loaded = [m for m in request['messages'] if expected in str(m.get('content'))]
                        assert len(loaded) == 1 and loaded[0]['role'] == 'system', request
                    if mode == 'smart':
                        assert not any(r['model'] == 'compact' for r in requests), requests
                        assert all(any('Use alpha for input.txt' in str(m.get('content'))
                                       for m in r['messages'] if m['role'] == 'user') for r in primary)
                        for request in requests:
                            if request['model'] == 'compact':
                                evidence = str(request['messages'])
                                assert 'EXACT SKILL STEPS' not in evidence and 'Rules' not in evidence, request
                                assert 'Tools are available through' not in evidence, request
            base['agents'][0].update(context='smart', toolCallingStrategy='native', useToolProxy=False)
            for command in ('$alpha input.txt', '/skills prompt alpha input.txt'):
                config.write_text(json.dumps(base))
                primary = run(['/model-compact local::compact', command], [final])
                loaded = [m for m in primary[0]['messages']
                          if BODY.replace('$ARGUMENTS', 'input.txt') in str(m.get('content'))]
                assert len(loaded) == 1 and loaded[0]['role'] == 'system', primary
                assert 'input.txt' in primary[0]['messages'][-1]['content'], primary
                assert not any(r['model'] == 'compact' for r in requests), requests
            base['agents'][0].update(context='cache')
            config.write_text(json.dumps(base))
            primary = run(['/skills disable alpha', 'Check availability'], [final])
            names = {t['function']['name'] for t in primary[0]['tools']}
            assert 'skills_alpha' not in names and 'skills_beta' in names, names
            saved = json.loads(config.read_text())['agents'][0]
            assert 'skills' in saved['toolGroupNames'], saved
            assert saved['toolPolicy']['tools']['skills_alpha'] == 'disabled', saved
            primary = run(['/skills enable all', '/skills enable alpha', '/skills disable beta', 'Check availability'], [final])
            names = {t['function']['name'] for t in primary[0]['tools']}
            assert 'skills_alpha' in names and 'skills_beta' not in names, names
    finally:
        server.shutdown()
        server.server_close()
    print(f'skills CLI smoke passed: {len(cases) * 2} protocol/context/proxy cases, '
          '2 explicit prompts, 2 disable cases')


if __name__ == '__main__':
    main()
