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
    # Keep connections open to exercise session cleanup with cached sockets.
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def do_GET(self):
        self.server.requests.append(self.path)
        if self.path in self.server.failures:
            self.server.failures.remove(self.path)
            self.send_error(503)
            return
        self.path = self.path.removeprefix('/releases/download')
        super().do_GET()

    def do_HEAD(self):
        self.server.requests.append(self.path)
        if self.path == '/releases/latest':
            if self.server.latest is None:
                self.send_error(404)
                return
            self.send_response(302)
            self.send_header('Location', '/releases/tag/' + self.server.latest)
            self.send_header('Content-Length', '0')
            self.end_headers()
        elif self.path.startswith('/releases/tag/'):
            self.send_response(200)
            self.send_header('Content-Length', '0')
            self.end_headers()
        else:
            self.send_error(404)


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
        handler = functools.partial(Releases, directory=str(releases))
        server = ThreadingHTTPServer(('127.0.0.1', 0), handler)
        server.requests = []
        server.latest = 'v99.0.0'
        server.failures = []
        threading.Thread(target=server.serve_forever, daemon=True).start()
        environment.update({
            'PATH': str(shims) + os.pathsep + environment['PATH'],
            'NO_PROXY': '127.0.0.1,localhost',
            'PMAI_LIBC': 'glibc',
            'PMAI_CONFIG': str(root / 'missing-config.json'),
            'SMOKE_RELEASES': f'http://127.0.0.1:{server.server_port}',
            'SMOKE_CURL': shutil.which('curl'),
            'SMOKE_LATEST': 'v99.0.0',
            'SMOKE_EXTERNAL_MARKER': str(root / 'external-tool-ran'),
            'PMAI_RELEASES_URL': f'http://127.0.0.1:{server.server_port}/releases',
        })
        curl = shims / 'curl'
        curl.write_text('#!' + sys.executable + '\n' + '''
import os, sys
if os.environ.get('SMOKE_NATIVE'):
    open(os.environ['SMOKE_EXTERNAL_MARKER'], 'w').close()
    sys.exit(97)
args = sys.argv[1:]
for i, arg in enumerate(args):
    if arg == 'https://github.com/trufae/pmai/releases/latest':
        if os.environ.get('SMOKE_LATEST_FAIL'):
            sys.exit(22)
        print('https://github.com/trufae/pmai/releases/tag/' + os.environ['SMOKE_LATEST'])
        sys.exit(0)
    elif arg.startswith('https://github.com/trufae/pmai/releases/download/'):
        args[i] = os.environ['SMOKE_RELEASES'] + '/' + arg.split('/download/', 1)[1]
os.execv(os.environ['SMOKE_CURL'], [os.environ['SMOKE_CURL'], *args])
''')
        curl.chmod(0o755)
        for name in ('unzip', 'sha256sum', 'shasum', 'openssl'):
            original_tool = shutil.which(name)
            if original_tool is None:
                continue
            tool = shims / name
            tool.write_text('#!' + sys.executable + '\n' + f'''
import os, sys
if os.environ.get('SMOKE_NATIVE'):
    open(os.environ['SMOKE_EXTERNAL_MARKER'], 'w').close()
    sys.exit(97)
tool = {original_tool!r}
os.execv(tool, [tool, *sys.argv[1:]])
''')
            tool.chmod(0o755)

        def release(tag, valid_checksum=True, payload_version=None, startup_status=0):
            folder = releases / tag
            folder.mkdir()
            payload = ('#!/bin/sh\nif [ "$1" = --help ]; then exit ' + str(startup_status)
                       + '; fi\nprintf "%s\\n" "' + (payload_version or tag.removeprefix('v')) + '"\n')
            checksums = []
            for platform, arch in (('linux', 'x64'), ('linux', 'arm64'),
                                   ('linux', 'x64-musl'), ('linux', 'arm64-musl'),
                                   ('macos', 'x64'), ('macos', 'arm64'), ('android', 'arm64')):
                archive = folder / f'pmai-{platform}-{arch}.zip'
                with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED) as bundle:
                    bundle.writestr('pmai', payload)
                    if platform == 'macos':
                        bundle.writestr('mlx.metallib', 'fixture shaders')
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
            assert '_MultiHandle' not in output, output
            assert not (root / '.pmai').exists(), 'Updating initialized project state'
            assert not Path(environment['SMOKE_EXTERNAL_MARKER']).exists(), 'CLI used an external tool'
            assert '% Total' not in output and 'Dload' not in output, output
            assert not list(root.glob('**/.pmai-update-*')), 'Updater left staging files behind'
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
            assert run(installer, env) == 'pmai: 99.0.0 is up to date (No updates available)\n'
            assert not server.requests, server.requests
            assert target.read_bytes() == original

            env = {**environment, 'PATH': str(installed) + os.pathsep + environment['PATH']}
            assert run(installer, env) == 'pmai: 99.0.0 is up to date (No updates available)\n'
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
                   'SMOKE_NATIVE': '1'}
            server.latest = 'v' + version
            assert '-U, --update' in run([str(target), '--help', '-U'], env)
            assert not server.requests
            run([str(target), '--system', '--update', '--print-config'], env)
            assert not server.requests, '--update was consumed as a flag value'
            assert run(['pmai', '-U'], env) == f'pmai: {version} is up to date (No updates available)\n'
            assert server.requests == ['/releases/latest', '/releases/tag/v' + version], server.requests
            assert target.read_bytes() == original

            server.latest = None
            output = run([str(target), '--update'], env, status=2)
            assert 'could not check the latest release' in output
            server.latest = 'v99.0.0'
            output = run([str(target), '--update'], {**env, 'PMAI_VERSION': 'missing'}, status=2)
            assert 'HTTP 404' in output
            output = run([str(target), '--update'], {**env, 'PMAI_VERSION': '99.0.1'}, status=2)
            assert 'checksum verification failed' in output
            assert target.read_bytes() == original
            release('v99.0.2', payload_version='98.0.0')
            output = run([str(target), '--update'], {**env, 'PMAI_VERSION': 'v99.0.2'}, status=2)
            assert 'release version mismatch' in output
            release('v99.0.3', startup_status=1)
            output = run([str(target), '--update'], {**env, 'PMAI_VERSION': 'v99.0.3'}, status=2)
            assert 'failed its startup check' in output
            assert target.read_bytes() == original
            print('PASS CLI versions, help, -U, flag values, network/checksum/version/startup failures')

            override = root / 'override'
            server.failures = ['/releases/download/v99.0.0/SHA256SUMS']
            output = run([str(target), '--update'],
                         {**env, 'PMAI_INSTALL_DIR': str(override)})
            assert f'updating {version} → 99.0.0' in output, output
            assert f'updated {version} → 99.0.0 at {override}/pmai' in output, output
            assert len(output.splitlines()) == 3, output
            assert server.requests.count('/releases/download/v99.0.0/SHA256SUMS') == 2
            assert (override / 'pmai').is_file()
            assert target.read_bytes() == original
            assert (override / 'pmai').stat().st_mode & 0o111
            if sys.platform == 'darwin':
                assert (override / 'mlx.metallib').read_text() == 'fixture shaders'
            print('PASS quiet native download, retry, version transition, resources and install override')

            # A pinned file mirror needs no latest-release request or network access.
            mirror = root / 'mirror-installed'
            mirror_env = {**env, 'PMAI_INSTALL_DIR': str(mirror), 'PMAI_VERSION': 'v99.0.0',
                          'PMAI_RELEASE_BASE': (releases / 'v99.0.0').as_uri()}
            output = run([str(target), '-U'], mirror_env)
            assert f'updated {version} → 99.0.0' in output
            assert not server.requests
            output = run([str(target), '-U'], mirror_env)
            assert '99.0.0 is up to date' in output
            assert not server.requests

            if sys.platform == 'darwin':
                release('v99.0.4')
                folder = releases / 'v99.0.4'
                universal = folder / 'pmai-macos-universal.zip'
                (folder / 'pmai-macos-arm64.zip').rename(universal)
                (folder / 'pmai-macos-x64.zip').unlink()
                digest = hashlib.sha256(universal.read_bytes()).hexdigest()
                (folder / 'SHA256SUMS').write_text(f'{digest} *{universal.name}\n')
                output = run([str(target), '-U'], {**env, 'PMAI_INSTALL_DIR': str(override),
                             'PMAI_VERSION': 'v99.0.4'})
                assert 'trying universal macOS release' in output
                assert 'updated 99.0.0 → 99.0.4' in output
                print('PASS macOS universal fallback')

            aliases = root / 'aliases'
            aliases.mkdir()
            alias = aliases / 'pmai'
            alias.symlink_to(target)
            env = {**environment, 'PATH': str(pinned) + os.pathsep + environment['PATH'],
                   'SMOKE_NATIVE': '1'}
            output = run([str(alias.relative_to(root)), '--update'], env)
            assert f'updated {version} → 99.0.0' in output, output
            assert alias.is_symlink()
            assert target.read_bytes() != original
            assert (pinned / 'pmai').read_bytes() == target.read_bytes()
            assert subprocess.check_output([alias, '--version'], text=True).strip() == '99.0.0'
            assert any(path.startswith('/releases/download/v99.0.0/pmai-') for path in server.requests)
            print('PASS --update replaces the running copy through a relative symlink')

            uname = shims / 'uname'
            uname.write_text('#!/bin/sh\nprintf "%s\\n" aarch64\n')
            uname.chmod(0o755)
            android = root / 'android'
            env = {**environment, 'ANDROID_ROOT': '/system', 'PMAI_INSTALL_DIR': str(android)}
            assert 'installed android/arm64' in run(installer, env)
            assert (android / 'pmai-android').exists()
            assert (android / 'libc++_shared.so').exists()
            assert run(installer, env) == 'pmai: 99.0.0 is up to date (No updates available)\n'
            assert not server.requests
            print('PASS Android wrapper version check without downloading the runtime again')
        finally:
            server.shutdown()
            server.server_close()


if __name__ == '__main__':
    main()
