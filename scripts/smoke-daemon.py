#!/usr/bin/env python3
"""Verify real CLI cold start and shared lifetime in an isolated CODEX_HOME.

No account credentials, user threads, or model calls are used.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('gateway', type=Path)
    parser.add_argument('codex', type=Path)
    args = parser.parse_args()
    gateway = args.gateway.resolve()
    codex = args.codex.resolve()
    with tempfile.TemporaryDirectory(prefix='cld-') as temp:
        root = Path(temp)
        home, data = root / 'codex', root / 'gateway'
        home.mkdir(); data.mkdir()
        token = secrets.token_hex(32)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0)); port = sock.getsockname()[1]
        base = f'http://127.0.0.1:{port}'
        config = {'listenUrl':base, 'codexPath':str(codex), 'preferSharedDaemon':True,
                  'devices':[{'id':'smoke', 'name':'smoke', 'tokenHash':hashlib.sha256(token.encode()).hexdigest().upper()}]}
        (data / 'config.json').write_text(json.dumps(config))
        env = {**os.environ, 'CODEX_HOME':str(home), 'CODEXLINK_DATA':str(data)}
        command = ['dotnet', str(gateway)] if gateway.suffix == '.dll' else [str(gateway)]

        def daemon(action):
            return subprocess.run([str(codex), 'app-server', 'daemon', action], env=env,
                                  cwd=root, capture_output=True, text=True, timeout=45)

        def request(path, method='GET'):
            req = urllib.request.Request(base + path, data=b'{}' if method == 'POST' else None,
                headers={'Authorization':'Bearer ' + token, 'Content-Type':'application/json'}, method=method)
            with urllib.request.urlopen(req, timeout=60) as response:
                return json.load(response)

        def await_gateway(process):
            end = time.monotonic() + 20
            while time.monotonic() < end:
                if process.poll() is not None: raise RuntimeError('Gateway exited during startup')
                try: return request('/api/status')
                except (OSError, ValueError): time.sleep(.1)
            raise TimeoutError('Gateway HTTP startup timed out')

        process = None
        try:
            assert daemon('version').returncode != 0, 'Isolated daemon was unexpectedly running'
            with (root / 'gateway.log').open('w') as log:
                for cycle in range(2):
                    process = subprocess.Popen(command, env=env, cwd=root, stdout=log, stderr=log)
                    state = await_gateway(process)
                    assert state['codex'] == 'idle' and state['codexTransport'] is None
                    if cycle == 0:
                        assert daemon('version').returncode != 0, 'Passive startup launched Codex'
                    state = request('/api/runtime/start', 'POST')
                    assert state == {'codex':'ready', 'codexTransport':'shared'}, state
                    state = request('/api/status')
                    assert state['codex'] == 'ready' and state['codexTransport'] == 'shared', state
                    process.terminate(); process.wait(20); process = None
                    running = daemon('version')
                    assert running.returncode == 0, running.stderr
                    assert json.loads(running.stdout)['status'] == 'running'
                    print(f'Cycle {cycle + 1}: idle startup -> ready/shared -> gateway exit -> daemon still running', flush=True)
        finally:
            if process and process.poll() is None:
                process.terminate(); process.wait(20)
            stopped = daemon('stop')
            if stopped.returncode: raise RuntimeError('Isolated daemon cleanup failed: ' + stopped.stderr)
        print('Real shared-daemon smoke passed; isolated daemon stopped.', flush=True)


if __name__ == '__main__':
    main()
