#!/usr/bin/env python3
"""Check the REPL's del commands and persistent/live MCP removal offline."""
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
from smoke import clean_environment, run_repl


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
                            'inputSchema': {'type': 'object', 'properties': {}}}]}
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
                 'toolNamePrefix': 'external'},
                {'id': 'dormant', 'enabled': False, 'url': 'http://127.0.0.1:1/mcp'},
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

        topics = ['mcp', 'path', 'vdb', 'todo', 'prompts', 'agents', 'skills', 'stats',
                  'chat', 'project', 'projects', 'queue', 'remote']
        for topic, output in zip(topics, run(['/help ' + topic for topic in topics], split=True)):
            assert ' del ' in output or ' del\n' in output, (topic, output)
            assert not re.search(r'/\w+ (?:remove|rm|delete|forget|drop|revoke)\b', output), output

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
                           for n in item['toolNames'] + item['proxyExposedTools']), item
            assert not {'mcp/fixture', 'mcp/dormant'} & set(item['toolGroupNames']), item
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

        # Other suites cover project, remote and skill deletion.
        document = root / 'notes.txt'
        document.write_text('A searchable note about zeppelins.\n')
        output = run(['/todo add Keep', '/todo add Discard', '/todo del 2', '/todo',
                      '/prompts add disposable-user Some text', '/prompts del disposable-user',
                      '/prompt add disposable-system Some rules', '/prompt del disposable-system',
                      '/agent add disposable-agent', '/agent del disposable-agent',
                      '/vdb index notes.txt', '/vdb del notes.txt', '/vdb status',
                      '/queue push Queued text', '/queue del', '/queue',
                      'A chat message', '/chat del 1', '/stats del hello'], split=True)
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
