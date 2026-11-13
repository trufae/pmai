#!/usr/bin/env python3
"""Opt-in Mac chat scrolling benchmark. Run `make mac` first; opens a sample window."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sample', type=Path, help='Save a macOS CPU stack sample')
    args = parser.parse_args()
    build = (ROOT / 'MaiCore/.build/debug').resolve()
    description = json.loads((build / 'description.json').read_text())
    mac = next(v for v in description['swiftCommands'].values() if v['moduleName'] == 'MaiMac')
    flags = ['-I', str(build / 'Modules')]
    arguments = iter(mac['otherArguments'])
    for flag in arguments:
        if flag in ('-Xcc', '-I', '-F', '-L', '-sdk', '-target', '-swift-version',
                    '-module-cache-path', '-plugin-path'):
            flags += [flag, next(arguments)]
    with tempfile.TemporaryDirectory(prefix='pmai-mac-scroll-') as directory:
        binary = Path(directory) / 'scroll-bench'
        subprocess.run([mac['executable'], *flags, '-parse-as-library',
                        str(Path(__file__).with_suffix('.swift')),
                        '@' + str(build / 'pmai-mac.product/Objects.LinkFileList'),
                        '-L', str(build), '-lforwiroh', '-lc++', '-lresolv', '-liconv',
                        '-framework', 'SystemConfiguration', '-framework', 'Network',
                        '-framework', 'Security', '-o', str(binary)], check=True)
        process = subprocess.Popen([str(binary), directory])
        sampler = None
        if args.sample:
            sampler = subprocess.Popen(['sample', str(process.pid), '6', '5',
                                        '-file', str(args.sample.resolve())],
                                       stdout=subprocess.DEVNULL)
        result = process.wait()
        if sampler:
            sampler.wait()
        raise SystemExit(result)


if __name__ == '__main__':
    main()
