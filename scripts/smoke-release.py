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
                        if json.loads(request('/api/status')[2])['gateway'] == 'ready':
                            break
                    except (OSError, ValueError, KeyError):
                        pass
                    if time.monotonic() > deadline:
                        raise TimeoutError('Server did not become ready with the fake Codex')
                    time.sleep(.1)
                assert json.loads(request('/api/status')[2])['codex'] == 'idle'
                assert json.loads(request('/api/runtime/start', {})[2])['codex'] == 'ready'
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
                request(f'/api/threads/{thread}/turns', {'requestId':str(uuid.uuid4()), 'text':'questions'})
                deadline = time.monotonic() + 10
                while True:
                    approvals = json.loads(request(f'/api/threads/{thread}')[2])['approvals']
                    if approvals: break
                    if time.monotonic() > deadline: raise TimeoutError('Native questions missing')
                    time.sleep(.05)
                pending = approvals[0]
                assert pending['method'] == 'item/tool/requestUserInput'
                assert pending['params']['questions'][0]['options'][0]['label'] == '分步完成（推荐）'
                question_notice = next(n for n in json.loads(request(path)[2])['items'] if n['status'] == 'question')
                assert question_notice['threadId'] == thread and question_notice['questionId'] == 'native:' + pending['id']
                assert '选择实现方式？' in question_notice['preview'] and '输入测试用私密回答' not in question_notice['preview']
                result = {'answers': {'mode':{'answers':['分步完成（推荐）']}, 'scope':{'answers':['手机和网页']}, 'secret':{'answers':['fixture-secret']}}}
                assert request('/api/approvals/' + pending['id'], {'result':result})[0] == 204
                assert any(n['status'] == 'resolved' and n.get('questionId') == question_notice['questionId'] for n in json.loads(request(path)[2])['items'])
                deadline = time.monotonic() + 10
                while json.loads(request(f'/api/threads/{thread}')[2])['activeTurnId'] is not None:
                    if time.monotonic() > deadline: raise TimeoutError('Answered question did not complete')
                    time.sleep(.05)
                request(f'/api/threads/{thread}/turns', {'requestId':str(uuid.uuid4()), 'text':'async questions'})
                snapshot = json.loads(request(f'/api/threads/{thread}')[2])
                history = json.loads(request(f'/api/threads/{thread}/items')[2])['data']
                question = next(v['item'] for v in history if v['item'].get('questions') and v['item'].get('delivery') == 'async')
                deadline = time.monotonic() + 10
                while len([n for n in json.loads(request(path)[2])['items'] if n['status'] == 'question']) != 2:
                    if time.monotonic() > deadline: raise TimeoutError('Async question notifications missing')
                    time.sleep(.05)
                answer = {'questionItemId':json.dumps(['request_user_input_async', question['id'], 0], separators=(',', ':')),
                    'question':question['questions'][0]['title'], 'answer':'简洁（推荐）'}
                reply_text = '<send_user_message_question_reply>' + json.dumps([answer], ensure_ascii=False) + '</send_user_message_question_reply>'
                assert request(f"/api/threads/{thread}/turns/{snapshot['activeTurnId']}/steer",
                    {'requestId':str(uuid.uuid4()), 'text':reply_text})[0] == 200
                history = json.loads(request(f'/api/threads/{thread}/items')[2])['data']
                assert any(v['item'].get('content') == [{'type':'text', 'text':reply_text}] for v in history)
                assert len([n for n in json.loads(request(path)[2])['items'] if n['status'] == 'question']) == 1
                deadline = time.monotonic() + 10
                while json.loads(request(f'/api/threads/{thread}')[2])['activeTurnId'] is not None:
                    if time.monotonic() > deadline: raise TimeoutError('Asynchronous question did not complete')
                    time.sleep(.05)
                assert json.loads(request('/api/status')[2])['queuedMessages'] is True
                assert json.loads(request('/api/status')[2])['automaticInput'] is True
                turn = json.loads(request(f'/api/threads/{thread}/input', {'requestId':str(uuid.uuid4()), 'text':'hold'})[2])['turn']['id']
                queued = json.loads(request(f'/api/threads/{thread}/queue', {'requestId':str(uuid.uuid4()), 'text':'queued 中文'})[2])['submission']
                assert json.loads(request(f'/api/threads/{thread}/queue')[2])['data'] == [queued]
                withdrawn = json.loads(request(f"/api/threads/{thread}/queue/{queued['id']}/withdraw", {'requestId':str(uuid.uuid4())})[2])
                assert withdrawn['state'] == 'withdrawn' and withdrawn['submission']['text'] == 'queued 中文'
                queued = json.loads(request(f'/api/threads/{thread}/queue', {'requestId':str(uuid.uuid4()), 'text':'send now 中文'})[2])['submission']
                sent = json.loads(request(f"/api/threads/{thread}/queue/{queued['id']}/send", {'requestId':str(uuid.uuid4()), 'expectedTurnId':turn})[2])
                assert sent['state'] == 'sent'
                assert json.loads(request(f'/api/threads/{thread}/queue')[2])['data'] == []
                deadline = time.monotonic() + 10
                while json.loads(request(f'/api/threads/{thread}')[2])['activeTurnId'] is not None:
                    if time.monotonic() > deadline: raise TimeoutError('Queued steer did not complete')
                    time.sleep(.05)
                turn = json.loads(request(f'/api/threads/{thread}/input', {'requestId':str(uuid.uuid4()), 'text':'hold'})[2])['turn']['id']
                automatic = json.loads(request(f'/api/threads/{thread}/input', {'requestId':str(uuid.uuid4()), 'text':'automatic steer'})[2])
                assert automatic['submission']['text'] == 'automatic steer'
                pending = automatic['submission']
                assert json.loads(request(f"/api/threads/{thread}/queue/{pending['id']}/send", {'requestId':str(uuid.uuid4()), 'expectedTurnId':turn})[2])['state'] == 'sent'
                deadline = time.monotonic() + 10
                while json.loads(request(f'/api/threads/{thread}')[2])['activeTurnId'] is not None:
                    if time.monotonic() > deadline: raise TimeoutError('Automatic steer did not complete')
                    time.sleep(.05)
                assert json.loads(request('/api/status')[2])['threadActions'] is True
                request(f'/api/threads/{thread}/turns', {'requestId':str(uuid.uuid4()), 'text':'hold'})
                close_id = str(uuid.uuid4())
                result = json.loads(request(f'/api/threads/{thread}/close', {'requestId':close_id})[2])
                assert result['state'] == 'closing'
                assert json.loads(request(f'/api/threads/{thread}/close', {'requestId':close_id})[2]) == result
                row = json.loads(request('/api/threads')[2])['data'][0]
                assert row['status']['type'] == 'active' and row['closePending']
                assert json.loads(request(f'/api/threads/{thread}')[2])['canControl'] is False
                (data / 'close-finish').touch()
                deadline = time.monotonic() + 10
                while True:
                    row = json.loads(request('/api/threads')[2])['data'][0]
                    if row['status']['type'] == 'notLoaded' and not row['closePending']: break
                    if time.monotonic() > deadline: raise TimeoutError('Native unload did not complete')
                    time.sleep(.05)
                assert json.loads(request(f'/api/threads/{thread}?reopen=true')[2])['canControl'] is True
                history = json.loads(request(f'/api/threads/{thread}/items')[2])['data']
                assert json.loads(request(f'/api/threads/{thread}/archive', {'requestId':str(uuid.uuid4())})[2])['state'] == 'archived'
                assert json.loads(request('/api/threads')[2])['data'] == []
                assert json.loads(request('/api/threads?archived=true')[2])['data'][0]['id'] == thread
                request(f'/api/threads/{thread}/unarchive', {})
                assert json.loads(request(f'/api/threads/{thread}/items')[2])['data'] == history
                print('PASS: initialize, token digest, native child process, authentication, embedded Web/CanvasKit/CJK font/notification worker, four permission modes, automatic start/steer, notification JSON/SSE and question preview/resolution, native question replies, asynchronous question history/steer, native input queue/list/withdraw/send-now, thread close/unload/reopen/archive/restore')
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
