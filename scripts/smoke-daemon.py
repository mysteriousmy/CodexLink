#!/usr/bin/env python3
"""Verify real CLI cold start and shared lifetime in an isolated CODEX_HOME.

No account credentials, user threads, or model calls are used.
"""
import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request


@contextmanager
def isolated_home():
    root = Path(tempfile.mkdtemp(prefix='cld-'))
    try:
        yield root
    finally:
        # The CLI can acknowledge stop before its background file writers
        # finish. Bound cleanup retries and report a persistent failure.
        for attempt in range(60):
            try:
                shutil.rmtree(root)
                break
            except FileNotFoundError:
                if not root.exists(): break
                if attempt == 59: raise
            except OSError:
                if attempt == 59: raise
            time.sleep(.25)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('gateway', type=Path)
    parser.add_argument('codex', type=Path)
    parser.add_argument('--systemd-user', action='store_true', help='Exercise a transient Linux user unit with KillMode=process')
    args = parser.parse_args()
    if os.name == 'nt':
        import ctypes
        in_job = ctypes.c_int()
        assert ctypes.windll.kernel32.IsProcessInJob(ctypes.c_void_p(-1), None, ctypes.byref(in_job))
        assert not ctypes.windll.shell32.IsUserAnAdmin(), 'Run the smoke as an ordinary user'
        print(f'Windows standard-user context; process job membership: {bool(in_job.value)}', flush=True)
    gateway = args.gateway.resolve()
    codex = args.codex.resolve()
    with isolated_home() as temp:
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
            try:
                with urllib.request.urlopen(req, timeout=60) as response:
                    return json.load(response)
            except urllib.error.HTTPError as error:
                detail = error.read().decode(errors='replace').replace(token, '[redacted]')
                raise RuntimeError(f'{method} {path} returned {error.code}: {detail}') from error

        def await_gateway(process):
            end = time.monotonic() + 20
            while time.monotonic() < end:
                if process.poll() is not None: raise RuntimeError('Gateway exited during startup')
                try: return request('/api/status')
                except (OSError, ValueError): time.sleep(.1)
            raise TimeoutError('Gateway HTTP startup timed out')

        process = None
        unit = 'codexlink-smoke-' + secrets.token_hex(4)
        def launch(log):
            if args.systemd_user:
                return subprocess.Popen(['systemd-run', '--user', '--collect', '--wait', '--pipe',
                    '--unit=' + unit, '--property=KillMode=process', '--working-directory=' + str(root),
                    '--setenv=CODEX_HOME=' + str(home), '--setenv=CODEXLINK_DATA=' + str(data), *command],
                    env=env, cwd=root, stdout=log, stderr=log)
            return subprocess.Popen(command, env=env, cwd=root, stdout=log, stderr=log)

        def stop_gateway(process):
            if args.systemd_user:
                subprocess.run(['systemctl', '--user', 'stop', unit], check=True, capture_output=True, timeout=20)
            else:
                process.terminate()
            process.wait(20)

        try:
            assert daemon('version').returncode != 0, 'Isolated daemon was unexpectedly running'
            with (root / 'gateway.log').open('w') as log:
                for cycle in range(2):
                    unit = 'codexlink-smoke-' + secrets.token_hex(4)
                    process = launch(log)
                    state = await_gateway(process)
                    assert state['codex'] == 'idle' and state['codexTransport'] is None
                    if cycle == 0:
                        assert daemon('version').returncode != 0, 'Passive startup launched Codex'
                    state = request('/api/runtime/start', 'POST')
                    assert state == {'codex':'ready', 'codexTransport':'shared'}, state
                    state = request('/api/status')
                    assert state['codex'] == 'ready' and state['codexTransport'] == 'shared', state
                    stop_gateway(process); process = None
                    running = daemon('version')
                    assert running.returncode == 0, running.stderr
                    assert json.loads(running.stdout)['status'] == 'running'
                    print(f'Cycle {cycle + 1}: idle startup -> ready/shared -> gateway exit -> daemon still running', flush=True)
        except BaseException:
            logfile = root / 'gateway.log'
            if logfile.exists(): print(logfile.read_text(errors='replace').replace(token, '[redacted]')[-6000:], flush=True)
            # This home is isolated and unauthenticated. Preserve the failing
            # result, but expose the CLI's own reason before final cleanup.
            diagnostic = daemon('start')
            print('Isolated daemon diagnostic:', diagnostic.returncode,
                  diagnostic.stdout.replace(token, '[redacted]'),
                  diagnostic.stderr.replace(token, '[redacted]'), flush=True)
            raise
        finally:
            if process and process.poll() is None:
                stop_gateway(process)
            stopped = daemon('stop')
            if stopped.returncode: raise RuntimeError('Isolated daemon cleanup failed: ' + stopped.stderr)
        print('Real shared-daemon smoke passed; isolated daemon stopped.', flush=True)


if __name__ == '__main__':
    main()
