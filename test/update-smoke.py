#!/usr/bin/env python3
"""Exercise CLI updates and the installer with local, checksum-verified releases."""
import functools
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import zipfile


class Releases(SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        self.server.requests.append(self.path)
        super().do_GET()


def main():
    binary = Path(sys.argv[1]).resolve()
    repository = Path(__file__).resolve().parent.parent
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(('PMAI_', 'MAI_', 'OPENAI_', 'ANDROID_', 'TERMUX_'))}
    version = subprocess.check_output([binary, '--version'], env=environment, text=True).strip()
    with tempfile.TemporaryDirectory(prefix='pmai-update-') as directory:
        root = Path(directory)
        releases, shims = root / 'releases', root / 'shims'
        releases.mkdir()
        shims.mkdir()
        shutil.copy2(repository / 'www/install.sh', releases / 'install.sh')
        handler = functools.partial(Releases, directory=str(releases))
        server = ThreadingHTTPServer(('127.0.0.1', 0), handler)
        server.requests = []
        threading.Thread(target=server.serve_forever, daemon=True).start()
        environment.update({
            'PATH': str(shims) + os.pathsep + environment['PATH'],
            'NO_PROXY': '127.0.0.1,localhost',
            'PMAI_LIBC': 'glibc',
            'PMAI_CONFIG': str(root / 'missing-config.json'),
            'SMOKE_RELEASES': f'http://127.0.0.1:{server.server_port}',
            'SMOKE_CURL': shutil.which('curl'),
            'SMOKE_LATEST': 'v99.0.0',
            'SMOKE_INSTALL_MARKER': str(root / 'partial-installer-ran'),
        })
        curl = shims / 'curl'
        curl.write_text('#!' + sys.executable + '\n' + '''
import os, sys
args = sys.argv[1:]
for i, arg in enumerate(args):
    if arg == 'https://raw.githubusercontent.com/trufae/pmai/main/www/install.sh':
        if os.environ.get('SMOKE_CURL_FAIL'):
            print('touch "$SMOKE_INSTALL_MARKER"')
            sys.exit(7)
        args[i] = os.environ['SMOKE_RELEASES'] + '/install.sh'
    elif arg == 'https://github.com/trufae/pmai/releases/latest':
        if os.environ.get('SMOKE_LATEST_FAIL'):
            sys.exit(22)
        print('https://github.com/trufae/pmai/releases/tag/' + os.environ['SMOKE_LATEST'])
        sys.exit(0)
    elif arg.startswith('https://github.com/trufae/pmai/releases/download/'):
        args[i] = os.environ['SMOKE_RELEASES'] + '/' + arg.split('/download/', 1)[1]
os.execv(os.environ['SMOKE_CURL'], [os.environ['SMOKE_CURL'], *args])
''')
        curl.chmod(0o755)

        def release(tag, valid_checksum=True):
            folder = releases / tag
            folder.mkdir()
            payload = '#!/bin/sh\nprintf "%s\\n" "' + tag.removeprefix('v') + '"\n'
            checksums = []
            for platform, arch in (('linux', 'x64'), ('linux', 'arm64'),
                                   ('macos', 'x64'), ('macos', 'arm64'), ('android', 'arm64')):
                archive = folder / f'pmai-{platform}-{arch}.zip'
                with zipfile.ZipFile(archive, 'w') as bundle:
                    bundle.writestr('pmai', payload)
                    if platform == 'android':
                        bundle.writestr('libc++_shared.so', 'fixture runtime')
                digest = hashlib.sha256(archive.read_bytes()).hexdigest()
                checksums.append(f'{digest if valid_checksum else "0" * 64}  {archive.name}\n')
            (folder / 'SHA256SUMS').write_text(''.join(checksums))

        def run(command, env=None, status=0):
            server.requests.clear()
            result = subprocess.run(command, cwd=root, env=env or environment,
                                    capture_output=True, text=True, timeout=30)
            output = result.stdout + result.stderr
            assert result.returncode == status, (result.returncode, status, output)
            assert not (root / '.pmai').exists(), 'Updating initialized project state'
            return output

        try:
            release('v99.0.0')
            release('99.0.1', valid_checksum=False)
            installed = root / "installed ' copy"
            installed.mkdir()
            target = installed / 'pmai'
            installer = ['sh', str(repository / 'www/install.sh')]
            env = {**environment, 'PMAI_INSTALL_DIR': str(installed)}
            assert 'installed ' in run(installer, env)
            assert subprocess.check_output([target, '--version'], text=True).strip() == '99.0.0'
            original = target.read_bytes()
            assert 'No updates available' in run(installer, env)
            assert not server.requests, server.requests
            assert target.read_bytes() == original

            env = {**environment, 'PATH': str(installed) + os.pathsep + environment['PATH']}
            assert 'No updates available' in run(installer, env)
            assert not server.requests, server.requests
            pinned = root / 'pinned'
            env.update(PMAI_VERSION='v99.0.0', PMAI_INSTALL_DIR=str(pinned),
                       PMAI_RELEASE_BASE=environment['SMOKE_RELEASES'] + '/v99.0.0',
                       SMOKE_LATEST_FAIL='1')
            assert 'installed ' in run(installer, env)
            assert (pinned / 'pmai').is_file()
            print('PASS fresh install, matching versions, PATH install and pinned release')

            shutil.copy2(binary, target)
            original = target.read_bytes()
            env = {**environment, 'PATH': str(installed) + os.pathsep + environment['PATH'],
                   'SMOKE_LATEST': 'v' + version}
            assert '-U, --update' in run([str(target), '--help', '-U'], env)
            assert not server.requests
            run([str(target), '--system', '--update', '--print-config'], env)
            assert not server.requests, '--update was consumed as a flag value'
            assert 'No updates available' in run(['pmai', '-U'], env)
            assert server.requests == ['/install.sh'], server.requests
            assert target.read_bytes() == original

            run([str(target), '--update'], {**env, 'SMOKE_CURL_FAIL': '1'}, status=7)
            assert not Path(environment['SMOKE_INSTALL_MARKER']).exists()
            assert target.read_bytes() == original
            output = run([str(target), '--update'], {**env, 'SMOKE_LATEST_FAIL': '1'}, status=1)
            assert 'could not check the latest release' in output
            output = run([str(target), '--update'], {**env, 'SMOKE_LATEST': '99.0.1'}, status=1)
            assert 'checksum verification failed' in output
            assert target.read_bytes() == original
            print('PASS CLI help, -U, flag values, download failure and checksum failure')

            override = root / 'override'
            output = run([str(target), '--update'],
                         {**environment, 'PMAI_INSTALL_DIR': str(override)})
            assert 'installed ' in output, output
            assert (override / 'pmai').is_file()
            assert target.read_bytes() == original

            aliases = root / 'aliases'
            aliases.mkdir()
            alias = aliases / 'pmai'
            alias.symlink_to(target)
            env = {**environment, 'PATH': str(pinned) + os.pathsep + environment['PATH']}
            output = run([str(alias.relative_to(root)), '--update'], env)
            assert 'installed ' in output, output
            assert alias.is_symlink()
            assert target.read_bytes() != original
            assert (pinned / 'pmai').read_bytes() == target.read_bytes()
            assert subprocess.check_output([alias, '--version'], text=True).strip() == '99.0.0'
            assert any(path.startswith('/v99.0.0/pmai-') for path in server.requests)
            print('PASS --update replaces the running copy through a relative symlink')

            uname = shims / 'uname'
            uname.write_text('#!/bin/sh\nprintf "%s\\n" aarch64\n')
            uname.chmod(0o755)
            android = root / 'android'
            env = {**environment, 'ANDROID_ROOT': '/system', 'PMAI_INSTALL_DIR': str(android)}
            assert 'installed android/arm64' in run(installer, env)
            assert (android / 'pmai-android').exists()
            assert (android / 'libc++_shared.so').exists()
            assert 'No updates available' in run(installer, env)
            assert not server.requests
            print('PASS Android wrapper version check without downloading the runtime again')
        finally:
            server.shutdown()
            server.server_close()


if __name__ == '__main__':
    main()
