#!/usr/bin/env python3
"""Check REPL deletion commands, MCP details, and persistent/live removal offline."""
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import threading
from http.server import ThreadingHTTPServer
from smoke import JSONProvider, clean_environment, run_repl


class HTTPMCP(JSONProvider):
    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        if 'id' not in request:
            self.send_response(204)
            self.end_headers()
            return
        method = request['method']
        if method == 'initialize':
            result = {'protocolVersion': '2025-11-25', 'capabilities': {},
                      'serverInfo': {'name': 'Wordcraft fixture', 'version': '1'}}
        elif method == 'tools/list':
            result = {'tools': [{'name': 'echo', 'description': 'HTTP fixture echo',
                                'inputSchema': {'type': 'object'}}]}
        else:
            result = {'resources': []}
        self.respond({'jsonrpc': '2.0', 'id': request['id'], 'result': result})


def main():
    binary = str(Path(sys.argv[1]).resolve())
    with tempfile.TemporaryDirectory(prefix='pmai-del-') as directory:
        root = Path(directory).resolve()
        env = dict(clean_environment(), NO_COLOR='1', PWD=str(root))
        mcp = root / 'mcp.py'
        mcp.write_text('''import json, sys
for line in sys.stdin:
    request = json.loads(line)
    if 'id' not in request:
        continue
    method = request['method']
    if method == 'initialize':
        result = {'protocolVersion': '2025-11-25', 'capabilities': {},
                  'serverInfo': {'name': 'fixture', 'version': '1'}}
    elif method == 'tools/list':
        result = {'tools': [{'name': 'echo', 'description': 'Fixture echo',
                            'inputSchema': {'type': 'object', 'properties': {
                                'text': {'type': 'string', 'description': 'Text to echo'}}}}]}
    elif method == 'resources/list':
        result = {'resources': [{'uri': 'fixture://notes', 'name': 'Notes'}]}
    else:
        result = {}
    print(json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'result': result}), flush=True)
''')
        agent = {
            'provider': 'hello', 'model': 'hello', 'autocompact': {'tokens': 0},
            'toolNames': ['files_read', 'external::echo', 'external::stale', 'dormant::echo'],
            'toolGroupNames': ['files', 'mcp/fixture', 'mcp/dormant', 'mcp/keeper'],
            'proxyExposedTools': ['files_read', 'external::echo', 'dormant::echo'],
            'toolPolicy': {
                'groups': {'mcp/fixture': 'direct', 'mcp/dormant': 'hidden', 'mcp/keeper': 'disabled'},
                'tools': {'files_read': 'direct', 'external::stale': 'hidden', 'dormant::echo': 'direct'},
            },
        }
        config = root / 'config.json'
        config.write_text(json.dumps({
            'defaultAgent': 'main', 'providers': [{'id': 'hello', 'kind': 'hello'}],
            'toolSources': [{'id': 'standard', 'kind': 'standard-tools'}],
            'mcpServers': [
                {'id': 'fixture', 'command': sys.executable, 'args': [str(mcp)],
                 'displayName': 'Fixture MCP', 'cwd': str(root), 'timeout': 45,
                 'env': {'FIXTURE_SECRET': 'environment-secret'},
                 'toolNamePrefix': 'external'},
                {'id': 'dormant', 'enabled': False, 'url': 'http://127.0.0.1:1/mcp',
                 'headers': {'X-Key': 'header-secret'}, 'bearerToken': 'bearer-secret'},
                {'id': 'keeper', 'enabled': False, 'command': 'unused'},
            ],
            'agents': [dict(agent, id='main'), dict(agent, id='worker')],
            'fileAccess': {'hidden': 'allow'},
            'memory': {'enabled': False}, 'use': {'plan': False},
        }))
        command = [binary, '--config', str(config), '--home', str(root / 'home'),
                   '--no-stream', '--no-markdown']

        def run(commands, split=False):
            return run_repl(command, commands, cwd=root, env=env, split=split, timeout=40)

        (root / 'home').mkdir()
        usage = {'counts': {'external::echo': 4, 'external::resources_read': 2,
                            'dormant::echo': 3, 'files_read': 8}, 'recent': []}
        (root / 'home/tool-usage.json').write_text(json.dumps(usage))
        topics = ['mcp', 'path', 'vdb', 'todo', 'prompts', 'agents', 'skills', 'stats',
                  'chat', 'project', 'projects', 'queue', 'remote']
        for topic, output in zip(topics, run(['/help ' + topic for topic in topics], split=True)):
            assert ' del ' in output or ' del\n' in output, (topic, output)
            assert not re.search(r'/\w+ (?:remove|rm|delete|forget|drop|revoke)\b', output), output

        # Info shares tool help and lifetime counters, and works without connecting disabled servers.
        output = run(['/mcp info fixture', '/tools show mcp/fixture', '/mcp info dormant',
                      '/mcp info', '/mcp info missing', '/mcp info fixture extra'], split=True)
        for text in ('MCP server: fixture', 'Name: Fixture MCP', 'State: connected',
                     'Transport: stdio', 'Command:', str(mcp), f'Working directory: {root}',
                     'Timeout: 45 seconds', 'Tool prefix: external', 'Approval: confirm',
                     'Environment variables: FIXTURE_SECRET', 'Protocol: 2025-11-25', 'Resources: 1',
                     '2 tools, 6 calls', 'external::echo',
                     'external::resources_read', 'Fixture echo', 'Text to echo'):
            assert text in output[0], (text, output[0])
        tool_help = output[1][output[1].index('MCP fixture (mcp/fixture)'):].strip()
        assert tool_help in output[0], (tool_help, output[0])
        for text in ('State: disabled', 'Transport: streamable-http', 'URL: http://127.0.0.1:1/mcp',
                     'Timeout: 180 seconds', 'Headers: X-Key', 'Bearer token: configured',
                     '3 recorded calls', 'dormant::echo [not connected; 3 calls]'):
            assert text in output[2], (text, output[2])
        assert all(f'MCP server: {name}' in output[3] for name in ('fixture', 'dormant', 'keeper')), output[3]
        assert "Unknown MCP server 'missing'" in output[4], output[4]
        assert 'Usage: /mcp info [ID]' in output[5], output[5]
        assert not any(secret in '\n'.join(output) for secret in
                       ('environment-secret', 'header-secret', 'bearer-secret')), output
        assert json.loads((root / 'home/tool-usage.json').read_text()) == usage

        # Old MCP spellings must not delete the saved or connected server.
        run(['/mcp del', '/mcp remove fixture', '/mcp rm fixture', '/mcp delete fixture'])
        assert any(s['id'] == 'fixture' for s in json.loads(config.read_text())['mcpServers'])
        output = run(['/mcp tools fixture', '/mcp del fixture', '/mcp list', '/tools list',
                      '/mcp del dormant', '/mcp list'], split=True)
        assert 'external::echo' in output[0] and 'external::resources_read' in output[0], output
        assert "Removed MCP 'fixture' and removed 2 live tools." in output[1], output
        assert 'fixture' not in output[2] and 'external::' not in output[3], output
        assert "Removed MCP 'dormant' and removed 0 live tools." in output[4], output
        assert 'dormant' not in output[5], output
        saved = json.loads(config.read_text())
        assert [s['id'] for s in saved['mcpServers']] == ['keeper'], saved
        for item in saved['agents']:
            assert not any(n.startswith(('external::', 'dormant::'))
                           for n in item['toolNames'] + item.get('proxyExposedTools', [])), item
            assert not {'mcp/fixture', 'mcp/dormant'} & set(item['toolGroupNames']), item
            if item['id'] in ('main', 'worker'):
                assert item['toolPolicy']['groups'] == {'mcp/keeper': 'disabled'}, item
                assert item['toolPolicy']['tools'] == {'files_read': 'direct'}, item
        assert 'fixture' not in run(['/mcp list']), 'deleted server returned after restart'

        # Reusing a deleted ID and deleting a server disabled in this session both work.
        add = '/mcp add --name fixture --prefix external -- ' + shlex.join([sys.executable, str(mcp)])
        output = run([add, '/mcp disable fixture', '/mcp del fixture', '/mcp list'])
        assert "Added and connected stdio MCP 'fixture'" in output, output
        assert "Removed MCP 'fixture' and removed 0 live tools." in output, output
        before = json.loads(config.read_text())
        result = subprocess.run(command, input='/mcp del missing\n/exit\n', cwd=root, env=env,
                                capture_output=True, text=True, timeout=40)
        assert result.returncode == 0, result.stderr
        assert "MCP server 'missing' is not configured." in result.stderr, result.stderr
        assert json.loads(config.read_text()) == before, 'unknown ID changed configuration'

        # URL additions must connect over HTTP, save that transport, and reconnect after restart.
        with ThreadingHTTPServer(('127.0.0.1', 0), HTTPMCP) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                url = f'http://127.0.0.1:{server.server_port}'
                output = run([f'/mcp add --name wordcraft -- {url}',
                              '/mcp info wordcraft'])
                for text in ("Added and connected streamable-http MCP 'wordcraft'",
                             'Transport: streamable-http', f'URL: {url}', 'wordcraft::echo'):
                    assert text in output, (text, output)
                saved = next(s for s in json.loads(config.read_text())['mcpServers']
                             if s['id'] == 'wordcraft')
                assert saved['kind'] == 'streamable-http' and saved['url'] == url, saved
                assert saved.get('command') is None, saved
                assert 'State: connected' in run(['/mcp info wordcraft'])
                run(['/mcp del wordcraft'])
            finally:
                server.shutdown()
                thread.join(timeout=10)

        # Bad endpoints/HTTP-only misuse and failed subprocess launches leave the REPL usable.
        before = json.loads(config.read_text())
        output = run_repl(command, ['/mcp add --name bad -- http://',
                                    '/mcp add --name bad -- ftp://127.0.0.1/mcp',
                                    '/mcp add --name bad -- http://127.0.0.1 extra',
                                    '/mcp add --name bad --cwd . -- http://127.0.0.1',
                                    '/mcp add --name bad --env KEY=value -- http://127.0.0.1',
                                    f'/mcp add --name bad -- {root}/missing-command',
                                    '/mcp list'], cwd=root, env=env, allow_errors=True)
        assert 'Invalid MCP URL' in output and 'HTTP MCP servers accept one URL' in output, output
        assert 'Unable to launch MCP command' in output and 'keeper' in output, output
        assert json.loads(config.read_text()) == before, 'failed addition changed configuration'

        # A URL mistakenly saved as a stdio command must report an error instead of aborting.
        broken = dict(before, mcpServers=before['mcpServers'] + [
            {'id': 'bad-stdio', 'kind': 'stdio', 'enabled': False,
             'command': 'http://127.0.0.1:9090'}])
        config.write_text(json.dumps(broken))
        output = run_repl(command, ['/mcp enable bad-stdio', '/mcp list'], cwd=root, env=env,
                          allow_errors=True)
        assert 'Unable to launch MCP command' in output and 'keeper' in output, output
        assert json.loads(config.read_text()) == broken, 'failed enable changed configuration'
        config.write_text(json.dumps(before))

        # Other suites cover project, remote and skill deletion.
        document = root / 'notes.txt'
        document.write_text('A searchable note about zeppelins.\n')
        output = run(['/todo add Keep', '/todo add Discard', '/todo del 2', '/todo',
                      '/prompts add disposable-user Some text', '/prompts del disposable-user',
                      '/prompt add disposable-system Some rules', '/prompt del disposable-system',
                      '/agent add disposable-agent', '/agent del disposable-agent',
                      '/vdb index notes.txt', '/vdb del notes.txt', '/vdb status',
                      '/queue push Queued text', '/queue del', '/queue',
                      'A chat message', '/msg del 1', '/stats del hello'], split=True)
        assert 'Keep' in output[3] and 'Discard' not in output[3], output[3]
        assert "Removed user prompt 'disposable-user'" in output[5], output[5]
        assert "Removed system prompt 'disposable-system'" in output[7], output[7]
        assert 'disposable-agent' not in {a['id'] for a in json.loads(config.read_text())['agents']}
        assert '0 sources' in output[12] and document.exists(), output[12]
        assert 'Dropped 1 queued message' in output[14] and 'Nothing is queued' in output[15], output[14:16]
        assert 'Removed' in output[17], output[17]
        assert "Removed the statistics of 'hello'" in output[18], output[18]
    print('del CLI smoke passed: help, MCP disconnect/persistence, and renamed deletion handlers')


if __name__ == '__main__':
    main()
