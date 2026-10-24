import concurrent.futures
import json
import os
import signal
import sys
from pathlib import Path
from test_gateway import GatewayFixture, ROOT


class OnDemandTests(GatewayFixture):
    activate_runtime = False

    def configure_runtime(self, config):
        launcher = self.data / 'codex-fake'
        launcher.write_text(f'''#!{sys.executable}
import json, os, subprocess, sys, time
from pathlib import Path
root = Path(os.environ['CODEXLINK_DATA'])
command = sys.argv[1:]
with (root / 'launcher.jsonl').open('a') as log: log.write(json.dumps(command) + '\\n')
socket = root / 'shared.sock'
if command[:2] != ['app-server', 'daemon']: sys.exit(90)
if (root / 'fail-start').exists() and command[-1] == 'start': sys.exit(1)
if command[-1] == 'version' and not socket.exists(): sys.exit(1)
if command[-1] == 'start' and not socket.exists():
    for _ in range(100):
        if not (root / 'block-start').exists(): break
        time.sleep(.05)
    with (root / 'owner.log').open('w') as log:
        child = subprocess.Popen([{sys.executable!r}, {str(ROOT / 'tests/fake_shared_codex.py')!r}, str(socket)], stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
    (root / 'owner.pid').write_text(str(child.pid))
    for _ in range(100):
        if socket.exists(): break
        time.sleep(.02)
print(json.dumps({{'status': 'running' if socket.exists() else 'notRunning', 'socketPath': str(socket)}}))
''')
        launcher.chmod(0o755)
        config['codexPath'] = str(launcher)
        config['codexArguments'] = ['app-server', '--listen', 'stdio://']
        # Stop only the independent test owner, before the temporary data is removed.
        self.owner_pid = None

    def stop(self):
        pidfile = self.data / 'owner.pid'
        if pidfile.exists(): self.owner_pid = int(pidfile.read_text())
        super().stop()
        if self.owner_pid:
            try: os.kill(self.owner_pid, signal.SIGTERM)
            except ProcessLookupError: pass

    def launcher_calls(self):
        path = self.data / 'launcher.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_passive_routes_stay_idle_and_concurrent_demand_starts_once(self):
        for _ in range(3):
            state = self.request('GET', '/api/status')[1]
            self.assertEqual((state['codex'], state['codexTransport']), ('idle', None))
            self.assertEqual(self.request('GET', '/health', raw=True)[0], 200)
            self.assertEqual(self.request('GET', '/api/notifications')[0], 200)
        self.assertEqual(self.request('POST', '/api/runtime/start', auth=False, headers={'Origin': self.base})[0], 401)
        self.assertEqual(self.launcher_calls(), [])
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            results = list(pool.map(lambda _: self.request('POST', '/api/runtime/start')[0], range(6)))
        self.assertEqual(results, [200] * 6)
        self.assertEqual(self.launcher_calls(), [['app-server', 'daemon', 'version'], ['app-server', 'daemon', 'start']])
        self.assertEqual(len(self.calls('initialize')), 1)
        self.assertEqual(self.request('GET', '/api/status')[1]['codexTransport'], 'shared')
        self.proc.terminate()
        self.proc.wait(5)
        from websockets.sync.client import unix_connect
        with unix_connect(str(self.data / 'shared.sock'), uri='ws://localhost/rpc') as peer:
            peer.send(json.dumps({'id':99, 'method':'initialize', 'params':{}}))
            self.assertEqual(json.loads(peer.recv(timeout=2))['id'], 99)

    def test_failed_shared_start_is_retryable_and_never_falls_back_to_stdio(self):
        (self.data / 'fail-start').touch()
        code, result, _ = self.request('POST', '/api/runtime/start')
        self.assertEqual((code, result['code']), (503, 'codex_unavailable'))
        state = self.request('GET', '/api/status')[1]
        self.assertEqual(state['codex'], 'unavailable')
        self.assertIn('Codex', state['codexError'])
        self.assertEqual(len(self.launcher_calls()), 2)
        (self.data / 'fail-start').unlink()
        self.assertEqual(self.request('GET', '/api/models')[0], 200)
        self.assertEqual(len(self.launcher_calls()), 4)
        self.assertTrue(all(c[:2] == ['app-server', 'daemon'] for c in self.launcher_calls()))

    def test_disconnected_request_does_not_cancel_shared_startup(self):
        import socket
        blocker = self.data / 'block-start'
        blocker.touch()
        connection = socket.create_connection(('127.0.0.1', self.port))
        connection.sendall((f'POST /api/runtime/start HTTP/1.1\r\nHost: 127.0.0.1:{self.port}\r\nAuthorization: Bearer {self.token}\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{{}}').encode())
        self.until(lambda: ['app-server', 'daemon', 'start'] in self.launcher_calls())
        connection.close()
        blocker.unlink()
        self.until(lambda: self.request('GET', '/api/status')[1]['codex'] == 'ready')
        self.assertEqual(len(self.launcher_calls()), 2)
        self.assertEqual(self.request('GET', '/api/status')[1]['codexTransport'], 'shared')

    def test_existing_daemon_is_discovered_without_start(self):
        import subprocess
        config = json.loads((self.data / 'config.json').read_text())
        subprocess.run([config['codexPath'], 'app-server', 'daemon', 'start'], env={**os.environ, 'CODEXLINK_DATA':str(self.data)}, check=True, stdout=subprocess.DEVNULL)
        (self.data / 'launcher.jsonl').unlink()
        self.assertEqual(self.request('POST', '/api/runtime/start')[0], 200)
        self.assertEqual(self.launcher_calls(), [['app-server', 'daemon', 'version']])
