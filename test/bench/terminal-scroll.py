#!/usr/bin/env python3
"""Opt-in PTY scrolling benchmark. Drains output without terminal rendering costs."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import pty
import resource
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from smoke import clean_environment, read_chat, run_repl


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('--lines', type=int, default=200)
    parser.add_argument('--events', type=int, default=100)
    parser.add_argument('--rows', type=int, default=48)
    parser.add_argument('--columns', type=int, default=160)
    parser.add_argument('--sample', type=Path, help='Save a macOS sample during scrolling')
    args = parser.parse_args()
    if min(args.lines, args.events, args.rows, args.columns) < 1:
        parser.error('fixture sizes and event count must be positive')
    binary = args.binary.resolve()
    with tempfile.TemporaryDirectory(prefix='pmai-scroll-bench-') as directory:
        root = Path(directory)
        config = root / 'config.json'
        config.write_text(json.dumps({
            'defaultAgent': 'hello', 'providers': [{'id': 'hello', 'kind': 'hello'}],
            'agents': [{'id': 'hello', 'provider': 'hello', 'model': 'hello'}],
            'memory': {'enabled': False}, 'use': {'plan': False},
            'ui': {'mode': 'buffer', 'scrollbar': 1, 'markdown': False},
        }))
        env = clean_environment() | {'TERM': 'xterm-256color'}
        env.pop('NO_COLOR', None)
        command = [str(binary), '--config', str(config), '--home', str(root / 'home'),
                   '--no-stream', '--no-markdown']
        run_repl(command, ['Seed'], cwd=root, env=env)
        saved = next((root / '.pmai/chats').glob('*.json'))
        chat = read_chat(saved)
        text = '\n'.join(f'ROW_{i:06d} ' + 'abcdefghij ' * 8 for i in range(args.lines))
        chat['messages'] = [{'id': 'scroll-fixture', 'role': 'assistant',
                             'content': [{'text': {'_0': text}}]}]
        saved.write_text(json.dumps(chat))
        before = resource.getrusage(resource.RUSAGE_CHILDREN)
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ,
                    struct.pack('HHHH', args.rows, args.columns, 0, 0))
        process = subprocess.Popen(command + ['--resume', chat['id']], cwd=root, env=env,
                                   stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        os.set_blocking(master, False)
        received = 0
        tail = b''

        def receive():
            nonlocal received, tail
            data = os.read(master, 65536)
            received += len(data)
            tail = (tail + data)[-65536:]

        def send(data):
            # A PTY has small queues in both directions. Drain output while
            # sending a burst, otherwise writer and reader can block each other.
            deadline = time.monotonic() + 120
            while data:
                assert time.monotonic() < deadline, 'input queue stalled'
                readable, writable, _ = select.select([master], [master], [], .05)
                if readable:
                    receive()
                if writable:
                    try:
                        data = data[os.write(master, data):]
                    except BlockingIOError:
                        pass

        def drain_until(marker, timeout=120):
            nonlocal received, tail
            deadline = time.monotonic() + timeout
            while marker not in tail:
                assert process.poll() is None, tail.decode(errors='replace')
                assert time.monotonic() < deadline, tail.decode(errors='replace')
                if select.select([master], [], [], .05)[0]:
                    receive()

        def barrier(label):
            send(f'/help bench-{label}\r'.encode())
            drain_until(f"Unknown help topic 'bench-{label}'".encode())

        sampler = None
        try:
            drain_until(b'pmai> ')
            barrier('ready')
            # Leave room to scroll in both directions.
            send(b'\x1b[5~' * 8)
            barrier('positioned')
            if args.sample:
                sampler = subprocess.Popen(['sample', str(process.pid), '3', '-file',
                                            str(args.sample.resolve())],
                                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            received = 0
            started = time.perf_counter()
            # Short bursts model queued wheel reports, with direction changes.
            for start in range(0, args.events, 100):
                count = min(100, args.events - start)
                packet = b'\x1b[<64;10;5M' if (start // 100) % 2 == 0 else b'\x1b[<65;10;5M'
                send(packet * count)
                barrier(f'burst-{start}')
            elapsed = time.perf_counter() - started
            output_bytes = received
            send(b'/exit\r')
            while process.poll() is None:
                if select.select([master], [], [], .05)[0]:
                    try:
                        os.read(master, 65536)
                    except OSError:
                        break
            process.wait(timeout=10)
            assert process.returncode == 0
            after = resource.getrusage(resource.RUSAGE_CHILDREN)
            print(json.dumps({
                'binary': str(binary), 'lines': args.lines, 'events': args.events,
                'size': [args.rows, args.columns], 'wall_seconds': round(elapsed, 4),
                'ms_per_event': round(elapsed * 1000 / args.events, 4),
                'output_bytes': output_bytes,
                'process_cpu_seconds_including_startup': round(
                    after.ru_utime + after.ru_stime - before.ru_utime - before.ru_stime, 4),
            }), flush=True)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            os.close(master)
            if sampler:
                sampler.wait(timeout=10)


if __name__ == '__main__':
    main()
