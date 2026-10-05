#!/usr/bin/env python3
"""Exercise mixed native/MCP/skill policy and learned exposure through the CLI."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


requests = []
answers = []


class Provider(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def respond(self, payload):
        body = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.respond({'data': [{'id': 'main'}]})

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append(request)
        message = answers.pop(0)
        self.respond({'choices': [{'message': message,
            'finish_reason': 'tool_calls' if message.get('tool_calls') else 'stop'}]})


def call(name, arguments):
    return {'role': 'assistant', 'content': '', 'tool_calls': [{
        'id': 'test-call', 'type': 'function',
        'function': {'name': name, 'arguments': json.dumps(arguments)}}]}


def main():
    binary = str(Path(sys.argv[1]).resolve())
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(('PMAI_', 'MAI_', 'OPENAI_'))
           and k.lower() not in ('http_proxy', 'https_proxy', 'all_proxy')}
    env.update(NO_PROXY='127.0.0.1,localhost', NO_COLOR='1')
    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix='pmai-tool-policy-') as directory:
            root = Path(directory)
            for name in ('alpha', 'beta'):
                folder = root / '.pmai/skills' / name
                folder.mkdir(parents=True)
                (folder / 'SKILL.md').write_text(
                    f'---\nname: {name}\ndescription: Review {name}\n---\nRead the code.\n')
            mcp = root / 'mcp.py'
            mcp.write_text('''import json, sys
for line in sys.stdin:
    request = json.loads(line)
    if "id" not in request:
        continue
    method = request["method"]
    if method == "initialize":
        result = {"protocolVersion": "2025-11-25", "capabilities": {"tools": {}},
                  "serverInfo": {"name": "fixture", "version": "1"}}
    elif method == "tools/list":
        result = {"tools": [{"name": name, "description": "Test " + name,
                            "inputSchema": {"type": "object", "properties": {}}}
                           for name in ("search", "read")]}
    elif method == "resources/list":
        result = {"resources": []}
    elif method == "tools/call":
        result = {"content": [{"type": "text", "text": "MCP ran"}]}
    else:
        result = {}
    print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
''')
            config = root / 'config.json'
            config.write_text(json.dumps({
                'defaultAgent': 'main',
                'providers': [{'id': 'local', 'kind': 'openAICompatible',
                               'baseURL': f'http://127.0.0.1:{server.server_port}/v1'}],
                'toolSources': [{'id': 'standard', 'kind': 'standard-tools'}],
                'mcpServers': [{'id': 'fixture', 'command': sys.executable, 'args': [str(mcp)],
                                'toolNamePrefix': 'external', 'defaultApproval': 'automatic'}],
                'agents': [{'id': 'main', 'provider': 'local', 'model': 'main',
                            'instructions': 'Rules', 'toolGroupNames': ['files', 'github', 'skills'],
                            'autocompact': {'tokens': 0}}],
                'memory': {'enabled': False}, 'use': {'plan': False},
            }))
            final = {'role': 'assistant', 'content': 'DONE'}

            def run(commands, responses):
                requests.clear()
                answers[:] = responses
                result = subprocess.run([binary, '--config', str(config), '--home', str(root / 'home'),
                    '--no-stream', '--no-markdown'], cwd=root, env=dict(env, PWD=str(root)),
                    input='\n'.join(commands + ['/exit', '']), text=True, capture_output=True, timeout=40)
                output = result.stdout + result.stderr
                assert result.returncode == 0 and 'error:' not in output, output
                assert not answers, answers
                return output, list(requests)

            output, calls = run([
                '/tools proxy github', '/tools direct github/pr', '/tools direct github/issue',
                '/tools disable github/ci_log', '/mcp direct fixture/search',
                '/skills disable beta', '/tools show github', 'Show capabilities',
            ], [final])
            assert 'github_pr [direct; 0 calls]' in output, output
            assert 'github_ci_log [disabled; 0 calls]' in output, output
            offered = {t['function']['name'] for t in calls[0]['tools']}
            assert {'files_read', 'github_pr', 'github_issue', 'external_search',
                    'list-tools', 'call-tool'} <= offered, offered
            assert not {'github_ci_log', 'skills_beta', 'skills_alpha', 'external::read'} & offered
            catalog = next(t['function']['description'] for t in calls[0]['tools']
                           if t['function']['name'] == 'list-tools')
            assert 'external::read' in catalog and 'skills_alpha' in catalog, catalog
            assert 'github_ci_log' not in catalog and 'skills_beta' not in catalog, catalog

            for _ in range(3):
                output, calls = run(['Load alpha'], [
                    call('call-tool', {'name': 'skills_alpha', 'arguments': {}}), final])
            offered = {t['function']['name'] for t in calls[-1]['tools']}
            assert 'skills_alpha' in offered, offered
            usage = json.loads((root / 'home/tool-usage.json').read_text())
            assert usage['counts'] == {'skills_alpha': 3}, usage

            # New members inherit the group without restoring a disabled member.
            folder = root / '.pmai/skills/gamma'
            folder.mkdir()
            (folder / 'SKILL.md').write_text('---\nname: gamma\ndescription: Review gamma\n---\nReview.\n')
            output, calls = run(['/skills', '/tools show skills', 'After restart'], [final])
            assert 'skills_alpha [direct; 3 calls]' in output, output
            assert 'skills_beta [disabled; 0 calls]' in output, output
            assert 'skills_gamma [proxy; 0 calls]' in output, output

            # Automatic choice is reversible and cannot undo a manual proxy pin.
            output, calls = run(['/skills proxy alpha', 'Pinned'], [final])
            assert 'skills_alpha' not in {t['function']['name'] for t in calls[0]['tools']}
            output, calls = run(['/skills inherit alpha', '/set tool.auto off', 'Auto off'], [final])
            assert 'skills_alpha' not in {t['function']['name'] for t in calls[0]['tools']}
            assert json.loads(config.read_text())['agents'][0]['toolPolicy']['automatic'] is False
            output, calls = run(['/set tool.auto on', 'Auto on'], [final])
            assert 'skills_alpha' in {t['function']['name'] for t in calls[0]['tools']}

            output, calls = run(['/tools disable mcp/fixture', '/mcp proxy fixture/search',
                                 '/mcp tools fixture', 'Restricted MCP'], [final])
            catalog = next(t['function']['description'] for t in calls[0]['tools']
                           if t['function']['name'] == 'list-tools')
            assert 'external::read' not in catalog and 'external::search' in catalog, catalog
            output, calls = run(['/tools disable mcp', '/tools inherit mcp/fixture',
                                 '/tools inherit external::search', '/tools enable mcp/fixture',
                                 '/mcp list', '/tools show agent_start', 'MCP enabled'], [final])
            catalog = next(t['function']['description'] for t in calls[0]['tools']
                           if t['function']['name'] == 'list-tools')
            assert 'external::read' in catalog and 'external::search' in catalog, catalog
            assert '0 calls' in output and 'agent_start [' in output, output
            saved = json.loads(config.read_text())['agents'][0]
            assert saved['useToolProxy'] is True
            assert saved['toolPolicy']['groups']['mcp/fixture'] == 'proxy', saved
            assert 'external::search' not in saved['toolPolicy']['tools'], saved
    finally:
        server.shutdown()
        server.server_close()
    print('tool policy CLI smoke passed')


if __name__ == '__main__':
    main()
