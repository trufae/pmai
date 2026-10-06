#!/usr/bin/env python3
"""Build the MLX Metal resource omitted by command-line SwiftPM builds."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import os
from pathlib import Path
import platform
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package-path', default='MaiCore')
    parser.add_argument('--bin-dir', required=True)
    args = parser.parse_args()
    if sys.platform != 'darwin' or platform.machine() != 'arm64' or 'PMAI_NO_MLX' in os.environ:
        return
    package = Path(args.package_path).resolve()
    sources = package / '.build/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal'
    shaders = sorted(sources.rglob('*.metal'))
    if not shaders:
        raise SystemExit('MLX shaders are missing; run swift build before building the Metal library.')
    destination = Path(args.bin_dir).resolve()
    destination.mkdir(parents=True, exist_ok=True)
    # MLX resolves mlx.metallib relative to the executable, independently of cwd.
    library = destination / 'mlx.metallib'
    stamp = destination / '.pmai-mlx-metal.sha256'
    flags = ['-std=metal3.1', '-fno-fast-math', '-Wno-c++17-extensions',
             '-Wno-c++20-extensions', '-mmacosx-version-min=15.0', '-I', str(sources)]
    sdk_version = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-version'])
    digest = hashlib.sha256(sdk_version + repr(flags).encode())
    for path in sorted(sources.rglob('*')):
        if path.is_file():
            digest.update(str(path.relative_to(sources)).encode())
            digest.update(path.read_bytes())
    fingerprint = digest.hexdigest()
    if library.exists() and stamp.exists() and stamp.read_text() == fingerprint:
        return
    build = package / '.build/pmai-mlx-metal'
    build.mkdir(parents=True, exist_ok=True)

    def compile_shader(source):
        target = build / (str(source.relative_to(sources)).replace('/', '_') + '.air')
        subprocess.run(['xcrun', '--sdk', 'macosx', 'metal', *flags,
                        '-c', str(source), '-o', str(target)], check=True)
        return target

    with ThreadPoolExecutor(max_workers=min(4, os.cpu_count() or 1)) as pool:
        objects = list(pool.map(compile_shader, shaders))
    temporary = library.with_suffix('.metallib.tmp')
    subprocess.run(['xcrun', '--sdk', 'macosx', 'metallib',
                    *map(str, objects), '-o', str(temporary)], check=True)
    temporary.replace(library)
    stamp.write_text(fingerprint)
    print(f'Built MLX Metal shaders: {library}')


if __name__ == '__main__':
    main()
