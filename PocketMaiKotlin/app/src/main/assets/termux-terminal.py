# Runs inside Termux's UID; PocketMai only owns the authenticated loopback peer.
import base64
import errno
import fcntl
import json
import os
import pty
import select
import signal
import socket
import struct
import sys
import termios

port, token, columns, rows = sys.argv[1:]
peer = socket.create_connection(('127.0.0.1', int(port)), timeout=30)
peer.settimeout(None)
peer.sendall(token.encode() + b'\n')
pid, master = pty.fork()
if pid == 0:
    peer.close()
    os.chdir(os.environ['HOME'])
    os.environ.update(TERM='xterm-256color', COLORTERM='truecolor')
    shell = os.environ.get('SHELL', os.environ['PREFIX'] + '/bin/bash')
    os.execv(shell, [shell, '-l'])


def resize(cols, lines):
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', int(lines), int(cols), 0, 0))


def reply(**fields):
    peer.sendall(json.dumps(fields).encode() + b'\n')


resize(columns, rows)
requests = b''
waiting = b''
os.set_blocking(master, False)
try:
    while True:
        readable, writable, _ = select.select([master, peer], [master] if waiting else [], [])
        if master in writable:
            try:
                written = os.write(master, waiting)
                waiting = waiting[written:]
            except BlockingIOError:
                pass
        if master in readable:
            try:
                data = os.read(master, 16384)
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
                data = b''
            if not data:
                _, code = os.waitpid(pid, 0)
                reply(exit=os.waitstatus_to_exitcode(code))
                break
            reply(data=base64.b64encode(data).decode())
        if peer in readable:
            data = peer.recv(16384)
            if not data:
                break
            requests += data
            if len(requests) > 256 * 1024:
                raise ValueError('Terminal request too large')
            while b'\n' in requests:
                line, requests = requests.split(b'\n', 1)
                request = json.loads(line)
                if 'data' in request:
                    waiting += base64.b64decode(request['data'], validate=True)
                    if len(waiting) > 256 * 1024:
                        raise ValueError('Terminal input queue is full')
                if 'columns' in request:
                    resize(request['columns'], request['rows'])
finally:
    try:
        foreground = os.tcgetpgrp(master)
        if foreground > 0:
            os.killpg(foreground, signal.SIGKILL)
    except (ProcessLookupError, OSError):
        pass
    try:
        os.killpg(pid, signal.SIGKILL)
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    os.close(master)
    peer.close()
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass
