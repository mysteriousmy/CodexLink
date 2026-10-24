#!/usr/bin/env python3
"""Run a packaged server against a fake Codex on its native OS/architecture."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('executable', type=Path)
    args = parser.parse_args()
    executable = args.executable.resolve()
    with tempfile.TemporaryDirectory(prefix='codexlink-release-') as directory:
        data = Path(directory)
        env = {**os.environ, 'CODEXLINK_DATA': directory}
        result = subprocess.run([str(executable), '--init'], env=env, capture_output=True, timeout=30)
        if result.returncode:
            raise RuntimeError(f'--init failed ({result.returncode}): {result.stderr.decode(errors="replace")}')
        config = json.loads((data / 'config.json').read_text(encoding='utf-8'))
        token = (data / 'access-token.txt').read_text().strip()
        # Never print generated credentials or the startup log in public CI.
        assert len(token) == 64
        assert config['devices'][0]['tokenHash'] == hashlib.sha256(token.encode()).hexdigest().upper()
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        base = f'http://127.0.0.1:{port}'
        config.update(listenUrl=base, timeZone='UTC', preferSharedDaemon=False,
                      codexPath=sys.executable, codexArguments=[str(ROOT / 'tests/fake_codex.py')])
        (data / 'config.json').write_text(json.dumps(config), encoding='utf-8')

        def request(path, payload=None, auth=True, method=None):
            headers = {'Content-Type': 'application/json'}
            if auth:
                headers['Authorization'] = 'Bearer ' + token
            request = urllib.request.Request(base + path,
                data=None if payload is None else json.dumps(payload).encode(), headers=headers, method=method)
            with urllib.request.urlopen(request, timeout=10) as response:
                return response.status, response.headers, response.read()

        with (data / 'server.log').open('w', encoding='utf-8') as log:
            process = subprocess.Popen([str(executable)], env=env, stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 30
                while True:
                    if process.poll() is not None:
                        raise RuntimeError(f'Server exited before ready: {process.returncode}')
                    try:
                        if json.loads(request('/api/status')[2])['codex'] == 'ready':
                            break
                    except (OSError, ValueError, KeyError):
                        pass
                    if time.monotonic() > deadline:
                        raise TimeoutError('Server did not become ready with the fake Codex')
                    time.sleep(.1)
                try:
                    request('/api/projects', auth=False)
                    raise AssertionError('Unauthenticated API request succeeded')
                except urllib.error.HTTPError as error:
                    assert error.code == 401
                for path, mime in [('/', 'text/html'), ('/canvaskit/canvaskit.wasm', 'application/wasm'),
                                   ('/fonts/CodexLinkSans.woff2', 'font/woff2'), ('/task-notifications.js', 'javascript')]:
                    status, headers, content = request(path, auth=False)
                    assert status == 200 and mime in headers['Content-Type'] and content
                status, _, body = request('/api/threads', {'projectId': 'codex-project'})
                assert status == 201
                thread = json.loads(body)['thread']['id']
                for mode in ('read-only', 'default', 'auto-review', 'full-access'):
                    status, _, body = request(f'/api/threads/{thread}/permissions', {'preset':mode}, method='PUT')
                    assert status == 200 and json.loads(body)['preset'] == mode
                baseline = json.loads(request('/api/notifications')[2])
                assert baseline['items'] == []
                status, _, _ = request(f'/api/threads/{thread}/turns',
                    {'requestId': str(uuid.uuid4()), 'text': 'UTF-8 中文 smoke', 'attachmentIds': []})
                assert status in (200, 202)
                deadline = time.monotonic() + 10
                path = f"/api/notifications?epoch={baseline['epoch']}&after={baseline['cursor']}"
                while True:
                    notices = json.loads(request(path)[2])
                    if notices['items']:
                        assert notices['items'][0]['threadId'] == thread
                        assert notices['items'][0]['status'] == 'completed'
                        break
                    if time.monotonic() > deadline:
                        raise TimeoutError('Completion notification missing')
                    time.sleep(.05)
                stream = urllib.request.Request(base + f"/api/notifications/events?epoch={baseline['epoch']}&after={baseline['cursor']}",
                    headers={'Authorization': 'Bearer ' + token})
                with urllib.request.urlopen(stream, timeout=10) as response:
                    assert response.headers['Content-Type'].startswith('text/event-stream')
                    assert response.readline().decode().strip() == 'event: task'
                    assert response.readline().decode().strip().startswith('id: ' + baseline['epoch'] + ':')
                    notice = json.loads(response.readline().decode().removeprefix('data: '))
                    assert notice['threadId'] == thread and notice['status'] == 'completed'
                print('PASS: initialize, token digest, native child process, authentication, embedded Web/CanvasKit/CJK font/notification worker, four permission modes, turn submission and notification JSON/SSE delivery')
            except Exception:
                # The isolated fake-Codex run has no account credentials. Redact
                # its generated gateway token before exposing startup failures.
                log.flush()
                diagnostics = (data / 'server.log').read_text(encoding='utf-8', errors='replace')
                print(diagnostics.replace(token, '[REDACTED]'), file=sys.stderr)
                raise
            finally:
                if process.poll() is None:
                    if os.name == 'nt':
                        # TerminateProcess only kills the gateway. The fake peer
                        # can retain inherited log handles during its own exit.
                        subprocess.run(['taskkill', '/PID', str(process.pid), '/T', '/F'],
                                       check=True, capture_output=True, timeout=15)
                    else:
                        process.terminate()
                try:
                    process.wait(15)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(5)


if __name__ == '__main__':
    main()
