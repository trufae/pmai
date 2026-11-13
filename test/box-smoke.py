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

import fcntl
import select
import signal
import termios
import time

binary = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix='pmai-box-') as temporary:
    root = Path(temporary).resolve()
    project = root / "project's workspace"
    project.mkdir()
    bindir = root / 'bin'
    bindir.mkdir()
    engine = bindir / 'docker'
    engine.write_text('''#!/usr/bin/env python3
import json, os, sys, termios
from pathlib import Path
if os.environ.get("BOX_TEST_FAIL"):
    sys.exit(1)
state = Path(os.environ["BOX_TEST_CONTAINER"])
if sys.argv[1:3] == ["container", "ls"] and state.exists():
    args = json.loads(state.read_text())
    print(args[args.index("--name") + 1])
elif sys.argv[1] == "create":
    state.write_text(json.dumps(sys.argv[2:]))
elif sys.argv[1] == "rm":
    state.unlink(missing_ok=True)
elif sys.argv[1] == "commit" and os.environ.get("BOX_TEST_COMMIT_FAIL"):
    sys.exit(1)
if sys.argv[1] == "exec":
    print("BOX_WORKER " + json.dumps(sys.argv[2:]))
    if "-it" in sys.argv and "BOX_TEST_PID" in os.environ:
        Path(os.environ["BOX_TEST_PID"]).write_text(str(os.getpid()))
        modes = termios.tcgetattr(0)
        modes[3] &= ~termios.ECHO
        termios.tcsetattr(0, termios.TCSANOW, modes)
        print("BOX_READY", flush=True)
        print("BOX_INPUT " + input(), flush=True)
''')
    engine.chmod(0o755)
    env = dict(os.environ, HOME=str(root), PMAI_HOME=str(root / 'home'),
               BOX_TEST_CONTAINER=str(root / 'container.json'),
               PATH=str(bindir) + os.pathsep + os.environ['PATH'])
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

    # Interactive entry must read input without a background terminal stop,
    # then restore the caller's terminal modes. No container daemon is needed.
    def controlling_terminal():
        os.setsid()
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)

    for arguments in ([], ['box', 'shell']):
        master, slave = os.openpty()
        cooked = termios.tcgetattr(slave)
        engine_pid = root / 'engine.pid'
        engine_pid.unlink(missing_ok=True)
        process = subprocess.Popen([binary, *arguments], cwd=project,
                                   env=env | {'BOX_TEST_PID': str(engine_pid)},
                                   stdin=slave, stdout=slave, stderr=slave,
                                   preexec_fn=controlling_terminal)
        os.close(slave)
        output = bytearray()

        def wait_for(marker):
            deadline = time.monotonic() + 20
            while marker not in output:
                assert time.monotonic() < deadline, (arguments, output.decode(errors='replace'))
                if select.select([master], [], [], .1)[0]:
                    chunk = os.read(master, 65536)
                    assert chunk, (arguments, output)
                    output.extend(chunk)

        try:
            wait_for(b'BOX_READY')
            os.write(master, b'box input works\n')
            wait_for(b'BOX_INPUT box input works')
            assert process.wait(timeout=20) == 0, output
            assert termios.tcgetattr(master) == cooked
        finally:
            if process.poll() is None:
                # Also clean up an engine stopped in its own group on regression.
                if engine_pid.exists():
                    try:
                        os.kill(int(engine_pid.read_text()), signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=20)
            os.close(master)

    assert 'BOX_WORKER' not in run('hello', success=False, extra={'BOX_TEST_FAIL': '1'})
    run('box', 'stop')
    assert json.loads(manifests[0].read_text())['enabled']
    run('box', 'off')
    assert not json.loads(manifests[0].read_text())['enabled']
    run('hello', success=False)  # Normal local configuration loading resumes.
    run('box', 'on')
    assert 'BOX_WORKER' in run('hello')

    # Opt-in sharing must survive later launches, protect box policy, and leave
    # private state intact. A failed package snapshot must keep the old container.
    shared_config = root / '.config' / 'pmai'
    shared_config.mkdir(parents=True)
    shared_config.joinpath('config.json').write_text(json.dumps({
        'providers': [{'id': 'hello', 'kind': 'hello', 'apiKey': 'fixture-secret'}]}))
    local_state = project / '.pmai'
    local_state.mkdir()
    (local_state / 'history.json').write_text('["previous input"]')
    private_config = manifests[0].parent / 'home' / 'config.json'
    previous_private_config = private_config.read_bytes()
    run('box', 'share-home', success=False, extra={'BOX_TEST_COMMIT_FAIL': '1'})
    assert (root / 'container.json').exists()
    assert json.loads(manifests[0].read_text()).get('sharedConfigurationDirectory') is None
    run('box', 'share-home')
    assert Path(json.loads(manifests[0].read_text())['sharedConfigurationDirectory']).samefile(shared_config)
    assert 'shared with host' in run('box', 'status')
    assert private_config.read_bytes() == previous_private_config
    container = json.loads((root / 'container.json').read_text())
    mounts = [dict(part.split('=', 1) for part in container[i + 1].split(','))
              for i, arg in enumerate(container) if arg == '--mount']
    sources = {mount['dst']: Path(mount['src']) for mount in mounts}
    assert sources['/pmai/state'].samefile(root / 'home')
    assert sources['/pmai/config'].samefile(shared_config)
    assert sources[record['project'] + '/.pmai'].samefile(local_state)
    assert not sources[record['project']].samefile(project)
    for name in ('box', 'worktree'):
        assert f'/pmai/state/{name}:ro,nosuid,nodev,noexec,size=64k' in container
    assert sources['/pmai/state/remote-server'].samefile(manifests[0].parent / 'runtime-state' / 'remote-server')
    assert sources['/pmai/state/acp'].samefile(manifests[0].parent / 'runtime-state' / 'acp')
    assert 'fixture-secret' not in json.dumps(container)
    assert 'BOX_WORKER' in run('hello')
    # Moving configuration into PMAI_HOME needs no separate configuration mount.
    # The legacy directory symlink still works with old binaries and policies.
    preferred_config = root / 'home' / 'config'
    shared_config.rename(preferred_config)
    shared_config.symlink_to(preferred_config, target_is_directory=True)
    run('box', 'share-home')
    assert Path(json.loads(manifests[0].read_text())['sharedConfigurationDirectory']).samefile(preferred_config)
    container = json.loads((root / 'container.json').read_text())
    assert 'PMAI_CONFIG=/pmai/state/config/config.json' in container
    assert not any('dst=/pmai/config' in arg for arg in container)
    assert private_config.read_bytes() == previous_private_config
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
    fresh = root / 'shared-project'
    subprocess.run(['git', 'clone', '--no-local', str(project), str(fresh)], check=True, capture_output=True, env=env)
    run('box', 'create', '--share-home', '--binary', str(engine), cwd=fresh)
    assert 'shared with host' in run('box', 'status', cwd=fresh)
print('PASS: project box routing, terminal input/restoration, fail-closed startup, persistence and preserved workspace')
