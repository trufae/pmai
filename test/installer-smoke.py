#!/usr/bin/env python3
"""Verify release installation with and without the colocated MLX resource."""
import hashlib
import os
from pathlib import Path
import platform
import subprocess
import tempfile
import zipfile


def main():
    installer = Path(__file__).resolve().parents[1] / 'www/install.sh'
    system = 'macos' if platform.system() == 'Darwin' else 'linux'
    architecture = 'arm64' if platform.machine() in ('arm64', 'aarch64') else 'x64'
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(('PMAI_', 'ANDROID_', 'TERMUX_'))}
    with tempfile.TemporaryDirectory(prefix='pmai-installer-') as directory:
        root = Path(directory)
        for with_shader in (True, False):
            release = root / ('mlx-release' if with_shader else 'portable-release')
            release.mkdir()
            destination = root / (release.name + '-installed')
            archive = release / f'pmai-{system}-{architecture}.zip'
            binary = '#!/bin/sh\n'
            if with_shader:
                binary += 'test -f "$(dirname "$0")/mlx.metallib" || exit 1\n'
            binary += 'if [ "$1" = --version ]; then echo local-fixture; fi\nexit 0\n'
            with zipfile.ZipFile(archive, 'w') as payload:
                payload.writestr('pmai', binary)
                if with_shader:
                    payload.writestr('mlx.metallib', b'fixture metal resource')
            checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
            (release / 'SHA256SUMS').write_text(f'{checksum}  {archive.name}\n')
            settings = environment | {
                'PMAI_VERSION': 'local-fixture', 'PMAI_LIBC': 'glibc',
                'PMAI_RELEASE_BASE': release.as_uri(), 'PMAI_INSTALL_DIR': str(destination),
            }
            result = subprocess.run(['sh', str(installer)], env=settings,
                                    text=True, capture_output=True, timeout=30)
            assert result.returncode == 0, result.stdout + result.stderr
            assert (destination / 'pmai').read_text() == binary
            shader = destination / 'mlx.metallib'
            assert shader.exists() == with_shader
            if with_shader:
                assert shader.read_bytes() == b'fixture metal resource'
            result = subprocess.run(['sh', str(installer)], env=settings,
                                    text=True, capture_output=True, timeout=30)
            assert result.returncode == 0, result.stdout + result.stderr
            assert 'No updates available' in result.stdout
    print('PASS installer: checksummed releases, MLX resource, portable binary, and current-version check')


if __name__ == '__main__':
    main()
