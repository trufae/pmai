#!/usr/bin/env python3
"""Project routing regression: real Git and CLI, fake container engine; no models or daemon."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

if os.name == 'nt':
    print('SKIP: project boxes require a macOS or Linux host')
    sys.exit(0)

binary = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix='pmai-box-') as temporary:
    root = Path(temporary).resolve()
    project = root / 'project'
    project.mkdir()
    bindir = root / 'bin'
    bindir.mkdir()
    engine = bindir / 'docker'
    engine.write_text('''#!/usr/bin/env python3
import json, os, sys
if os.environ.get("BOX_TEST_FAIL"):
    sys.exit(1)
if sys.argv[1] == "exec":
    print("BOX_WORKER " + json.dumps(sys.argv[2:]))
''')
    engine.chmod(0o755)
    env = dict(os.environ, HOME=str(root), PMAI_HOME=str(root / 'home'), PATH=str(bindir) + os.pathsep + os.environ['PATH'])
    env.pop('PMAI_CONFIG', None)

    def run(*args, cwd=project, success=True, extra=None):
        result = subprocess.run([binary, *args], cwd=cwd, env=env | (extra or {}),
                                input='', text=True, capture_output=True, timeout=60)
        assert (result.returncode == 0) == success, (args, result.stdout, result.stderr)
        return result.stdout

    def git(*args):
        subprocess.run(['git', '-C', str(project), *args], check=True, capture_output=True, env=env)

    assert 'off' in run('box', 'status')
    git('init')
    (project / 'tracked').write_text('base\n')
    (project / 'src').mkdir()
    (project / 'src' / '.keep').touch()
    git('add', '.')
    git('-c', 'user.name=Test', '-c', 'user.email=test@example.com', 'commit', '-m', 'base')
    run('box', 'create', '--binary', str(engine))
    manifests = list((root / 'home' / 'box').glob('*/box.json'))
    assert len(manifests) == 1
    record = json.loads(manifests[0].read_text())
    checkout = root / 'home' / 'worktree' / record['id'].lower()
    assert (checkout / 'tracked').read_text() == 'base\n'
    # Host configuration must not load before routing into the worker.
    (project / 'pmai.json').write_text('{invalid host configuration')
    assert 'BOX_WORKER' in run('hello')
    assert 'BOX_WORKER' in run('--acp')
    assert 'BOX_WORKER' in run('--home', str(root / 'home'), 'hello', extra={'PMAI_HOME': str(root / 'other')})
    assert 'BOX_WORKER' in run('hello', cwd=project / 'src')
    status = run('box', 'status', cwd=checkout)
    assert 'enabled' in status, (status, str(checkout), record)
    assert 'BOX_WORKER' in run('hello', cwd=checkout)
    assert 'BOX_WORKER' not in run('hello', success=False, extra={'BOX_TEST_FAIL': '1'})
    run('box', 'stop')
    assert json.loads(manifests[0].read_text())['enabled']
    run('box', 'off')
    assert not json.loads(manifests[0].read_text())['enabled']
    run('hello', success=False)  # Normal local configuration loading resumes.
    run('box', 'on')
    assert 'BOX_WORKER' in run('hello')
    run('box', 'destroy')
    assert checkout.is_dir()
    assert not json.loads(manifests[0].read_text())['enabled']
    # A failed /box create must also close an already-running host REPL.
    failed = root / 'failed-project'
    subprocess.run(['git', 'clone', '--no-local', str(project), str(failed)], check=True, capture_output=True, env=env)
    config = root / 'local.json'
    config.write_text(json.dumps({'defaultAgent': 'main', 'providers': [{'id': 'hello', 'kind': 'hello'}],
                                 'agents': [{'id': 'main', 'provider': 'hello', 'model': 'hello'}],
                                 'use': {'plan': False}}))
    result = subprocess.run([binary, '--config', str(config), '--no-markdown'], cwd=failed,
                            env=env | {'BOX_TEST_FAIL': '1'},
                            input=f'/box create --binary {engine}\n!touch escaped\n/exit\n',
                            text=True, capture_output=True, timeout=60)
    assert result.returncode == 0, result.stderr
    assert "Restart pmai" in result.stdout, (result.stdout, result.stderr)
    assert not (failed / 'escaped').exists()
print('PASS: project box routing, fail-closed startup, persistence and preserved workspace')
