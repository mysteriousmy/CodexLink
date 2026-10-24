"""Black-box contract tests for either the managed or published AOT executable."""

import concurrent.futures, hashlib, http.client, json, os, secrets, shlex, socket, subprocess, sys, tempfile, time, unittest, urllib.error, urllib.parse, urllib.request, uuid
from pathlib import Path
from websockets.sync.client import connect

ROOT = Path(__file__).resolve().parents[1]
COMMAND = shlex.split(
    os.environ.get(
        "CODEXLINK_TEST_COMMAND",
        "dotnet "
        + str(
            ROOT / "server/CodexLink.Server/bin/Release/net10.0/CodexLink.Server.dll"
        ),
    )
)


class GatewayFixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="codexlink-test-")
        self.data = Path(self.temp.name)
        self.token = secrets.token_hex(32)
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            self.port = s.getsockname()[1]
        self.base = f"http://127.0.0.1:{self.port}"
        config = {
            "listenUrl": self.base,
            "codexPath": sys.executable,
            "codexArguments": [str(ROOT / "tests/fake_codex.py")],
            "projects": [{"id": "test", "name": "Test", "path": str(self.data)}],
            "devices": [
                {
                    "id": "device",
                    "name": "Test",
                    "tokenHash": hashlib.sha256(self.token.encode())
                    .hexdigest()
                    .upper(),
                }
            ],
            "maxFileBytes": 1024,
            "maxStorageBytes": 4096,
            "timeZone": "UTC",
        }
        self.configure_runtime(config)
        (self.data / "config.json").write_text(json.dumps(config))
        self.log = (self.data / "gateway.log").open("w")
        self.proc = subprocess.Popen(
            COMMAND,
            env={**os.environ, "CODEXLINK_DATA": str(self.data)},
            stdout=self.log,
            stderr=subprocess.STDOUT,
        )
        self.addCleanup(self.stop)
        self.until(lambda: self.request("GET", "/api/status")[1].get("gateway") == "ready")
        if getattr(self, "activate_runtime", True):
            self.assertEqual(self.request("POST", "/api/runtime/start")[0], 200)

    def configure_runtime(self, config):
        pass

    def stop(self):
        self.proc.terminate()
        try:
            self.proc.wait(5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
        self.log.close()
        self.temp.cleanup()

    def until(self, fn, seconds=8):
        end = time.monotonic() + seconds
        last = None
        while time.monotonic() < end:
            try:
                last = fn()
                if last:
                    return last
            except (OSError, ValueError, KeyError):
                pass
            time.sleep(0.025)
        self.fail("Timed out: " + str(last))

    def request(self, method, path, body=None, headers=None, auth=True, raw=False):
        h = {"Content-Type": "application/json"}
        if auth:
            h["Authorization"] = "Bearer " + self.token
        h.update(headers or {})
        if body is not None and not isinstance(body, bytes):
            body = json.dumps(body).encode()
        if body is None and method in ["POST", "PUT"]:
            body = b"{}"
        req = urllib.request.Request(
            self.base + path, data=body, headers=h, method=method
        )
        try:
            r = urllib.request.urlopen(req, timeout=5)
        except urllib.error.HTTPError as e:
            r = e
        data = r.read()
        r.close()
        return (
            r.status,
            (data if raw else json.loads(data) if data else None),
            r.headers,
        )

    def create(self):
        code, data, _ = self.request("POST", "/api/threads", {"projectId": "codex-project"})
        self.assertEqual(code, 201)
        return data["thread"]["id"]

    def send(self, tid, text="hello", request=None, files=None):
        return self.request(
            "POST",
            f"/api/threads/{tid}/turns",
            {
                "requestId": request or str(uuid.uuid4()),
                "text": text,
                "attachmentIds": files or [],
            },
        )

    def calls(self, method):
        return [
            x
            for x in map(
                json.loads, (self.data / "rpc-calls.jsonl").read_text().splitlines()
            )
            if x.get("method") == method
        ]

    def ws(self, epoch="", after=0, origin=None):
        return connect(
            self.base.replace("http:", "ws:")
            + f"/api/events?epoch={epoch}&after={after}",
            additional_headers={"Authorization": "Bearer " + self.token},
            origin=origin,
            open_timeout=5,
        )

    def upload(self, tid, data=b"hello", name="data.txt"):
        return self.request(
            "POST",
            f"/api/attachments?threadId={tid}",
            data,
            {
                "Content-Type": "application/octet-stream",
                "X-File-Name": urllib.parse.quote(name),
            },
        )

class GatewayTests(GatewayFixture):
    def test_auth_origin_cookie_and_allowlist(self):
        self.assertEqual(self.request("GET", "/api/projects", auth=False)[0], 401)
        self.assertEqual(
            self.request(
                "GET", "/api/projects", headers={"Origin": "https://evil.test"}
            )[0],
            403,
        )
        code, _, headers = self.request(
            "POST",
            "/api/auth/session",
            {"token": self.token},
            auth=False,
            headers={"Origin": self.base},
        )
        self.assertEqual(code, 200)
        cookie = headers["Set-Cookie"]
        self.assertIn("httponly", cookie.lower())
        self.assertIn("samesite=strict", cookie.lower())
        self.assertEqual(
            self.request(
                "GET",
                "/api/projects",
                auth=False,
                headers={"Cookie": cookie.split(";")[0]},
            )[0],
            200,
        )
        self.assertEqual(self.request("GET", "/api/threads/invalid-metadata")[0], 409)

    def test_empty_thread_and_concurrent_rpc_pairing(self):
        tid = self.create()
        self.assertEqual(
            self.request("GET", f"/api/threads/{tid}/items")[1]["data"], []
        )
        with concurrent.futures.ThreadPoolExecutor(8) as pool:
            results = list(
                pool.map(lambda _: self.request("GET", "/api/models"), range(24))
            )
        self.assertTrue(all(r[1]["data"][0]["id"] == "fixture" for r in results))

    def test_idempotency_and_conflicting_payload(self):
        tid = self.create()
        rid = str(uuid.uuid4())
        with concurrent.futures.ThreadPoolExecutor(2) as pool:
            results = list(pool.map(lambda _: self.send(tid, "hold", rid), range(2)))
        self.assertEqual(results[0][1], results[1][1])
        self.assertEqual(len(self.calls("turn/start")), 1)
        self.assertEqual(self.send(tid, "different", rid)[0], 409)
        self.assertEqual(
            self.request("GET", "/api/operations/" + rid)[1]["state"], "accepted"
        )

    def test_steer_expected_turn_and_project_serialization(self):
        tid = self.create()
        other = self.create()
        turn = self.send(tid, "hold")[1]["turn"]["id"]
        self.assertEqual(self.send(other)[1]["code"], "project_busy")
        body = {
            "requestId": str(uuid.uuid4()),
            "text": "direction",
            "attachmentIds": [],
        }
        self.assertEqual(
            self.request("POST", f"/api/threads/{tid}/turns/wrong/steer", body)[1][
                "code"
            ],
            "turn_changed",
        )
        body["requestId"] = str(uuid.uuid4())
        self.assertEqual(
            self.request("POST", f"/api/threads/{tid}/turns/{turn}/steer", body)[0], 200
        )
        self.until(
            lambda: (
                self.request("GET", f"/api/threads/{tid}")[1]["activeTurnId"] is None
            )
        )
        self.assertEqual(self.calls("turn/steer")[0]["params"]["expectedTurnId"], turn)

    def test_disconnect_does_not_cancel_and_replay_has_offsets(self):
        tid = self.create()
        with self.ws() as ws:
            hello = json.loads(ws.recv())
            ready = json.loads(ws.recv())
            self.assertEqual(hello["method"], "stream/resync")
            epoch, seq = ready["epoch"], ready["seq"]
            self.send(tid, "delayed")
        self.until(
            lambda: (
                self.request("GET", f"/api/threads/{tid}")[1]["activeTurnId"] is None
            )
        )
        with self.ws(epoch, seq) as ws:
            events = []
            while True:
                e = json.loads(ws.recv(timeout=3))
                events.append(e)
                if e["method"] == "stream/ready":
                    break
        self.assertEqual(events[0]["method"], "stream/replay")
        deltas = [
            e["params"] for e in events if e["method"] == "item/agentMessage/delta"
        ]
        self.assertEqual([d["clientOffset"] for d in deltas], [0, 6])
        self.assertEqual("".join(d["delta"] for d in deltas), "Hello 世界")
        self.assertEqual(self.calls("turn/interrupt"), [])

    def test_replay_overflow_requests_snapshot(self):
        tid = self.create()
        with self.ws() as ws:
            a = json.loads(ws.recv())
            ws.recv()
        self.send(tid, "burst")
        self.until(
            lambda: (
                self.request("GET", f"/api/threads/{tid}")[1]["activeTurnId"] is None
            )
        )
        with self.ws(a["epoch"], a["seq"]) as ws:
            self.assertEqual(json.loads(ws.recv())["method"], "stream/resync")

    def test_attachment_binary_binding_limits_and_cleanup(self):
        tid = self.create()
        other = self.create()
        payload = bytes(range(128))
        code, file, _ = self.upload(tid, payload, "../../data.txt")
        self.assertEqual(code, 201)
        self.assertEqual(
            self.request("GET", "/api/attachments/" + file["id"], raw=True)[1], payload
        )
        self.assertEqual(self.upload(tid, b"x" * 1025)[0], 413)
        self.assertEqual(
            self.send(other, "read", files=[file["id"]])[1]["code"], "attachment_owner"
        )
        turn = self.send(tid, "hold", files=[file["id"]])[1]["turn"]["id"]
        self.assertEqual(
            self.request("DELETE", "/api/attachments/" + file["id"] + "?cleanup=true")[
                1
            ]["code"],
            "attachment_in_use",
        )
        self.request("POST", f"/api/threads/{tid}/turns/{turn}/interrupt")
        self.assertEqual(
            self.request("DELETE", "/api/attachments/" + file["id"])[1]["code"],
            "attachment_referenced",
        )
        self.assertEqual(
            self.request("DELETE", "/api/attachments/" + file["id"] + "?cleanup=true")[
                0
            ],
            204,
        )
        manifest = self.calls("turn/start")[0]["params"]["input"][-1]["text"]
        self.assertIn(file["id"] + ".bin", manifest)

    def test_images_use_local_image_input(self):
        tid = self.create()
        file = self.upload(tid, b"\x89PNG\r\n\x1a\n" + b"x" * 20, "picture.png")[1]
        self.assertTrue(file["isImage"])
        self.send(tid, files=[file["id"]])
        self.assertEqual(
            self.calls("turn/start")[0]["params"]["input"][1]["type"], "localImage"
        )

    def test_goal_budget_omission_pause_and_interrupt(self):
        tid = self.create()
        path = f"/api/threads/{tid}/goal"
        self.request(
            "PUT",
            path,
            {
                "objective": "test objective",
                "tokenBudget": 5000,
                "budgetSpecified": True,
            },
        )
        self.request("PUT", path, {"status": "paused"})
        self.assertNotIn("tokenBudget", self.calls("thread/goal/set")[-1]["params"])
        self.request(
            "PUT",
            path,
            {"status": "active", "tokenBudget": None, "budgetSpecified": True},
        )
        self.assertIsNone(self.calls("thread/goal/set")[-1]["params"]["tokenBudget"])
        turn = self.send(tid, "hold")[1]["turn"]["id"]
        self.request("POST", f"/api/threads/{tid}/turns/{turn}/interrupt")
        self.assertEqual(self.request("GET", path)[1]["goal"]["status"], "paused")
        self.assertTrue(
            all(x["params"]["origin"] == "user" for x in self.calls("thread/goal/set"))
        )
        self.assertEqual(self.request("DELETE", path)[0], 204)

    def test_approval_survives_reconnect_and_resolves_once(self):
        tid = self.create()
        self.send(tid, "approve")
        approvals = self.until(lambda: self.request("GET", "/api/approvals")[1])
        aid = approvals[0]["id"]
        with self.ws() as ws:
            ws.recv()
            ws.recv()
        self.assertEqual(
            self.request(
                "POST", "/api/approvals/" + aid, {"result": {"decision": "accept"}}
            )[0],
            204,
        )
        self.assertEqual(
            self.request(
                "POST", "/api/approvals/" + aid, {"result": {"decision": "accept"}}
            )[0],
            409,
        )
        self.until(
            lambda: (
                self.request("GET", f"/api/threads/{tid}")[1]["activeTurnId"] is None
            )
        )

    def test_account_unavailable_is_not_zero_and_error_is_cached(self):
        (self.data / "usage-error").touch()
        first = self.request("GET", "/api/account/usage")[1]
        second = self.request("GET", "/api/account/usage")[1]
        self.assertIsNone(first["tokens"])
        self.assertIn("unavailable", first["tokensError"])
        self.assertEqual(first["tokensError"], second["tokensError"])
        self.assertEqual(len(self.calls("account/usage/read")), 1)
        self.assertIsNone(first["rateLimits"]["rateLimits"]["primary"])

    def test_process_exit_leaves_operation_unknown_and_restarts(self):
        tid = self.create()
        rid = str(uuid.uuid4())
        self.assertEqual(self.send(tid, "crash", rid)[0], 503)
        self.assertEqual(
            self.request("GET", "/api/operations/" + rid)[1]["state"], "unknown"
        )
        self.until(
            lambda: self.request("GET", "/api/status")[1].get("codex") == "ready"
        )
        self.assertEqual(self.request("GET", "/api/models")[0], 200)

    def test_slow_consumer_is_disconnected_without_blocking_rpc(self):
        from websockets.exceptions import ConnectionClosed

        tid = self.create()
        with connect(
            self.base.replace("http:", "ws:") + "/api/events",
            additional_headers={"Authorization": "Bearer " + self.token},
            max_queue=1,
        ) as ws:
            ws.recv()
            ws.recv()
            self.send(tid, "flood")
            time.sleep(0.4)
            self.assertEqual(self.request("GET", "/api/models")[0], 200)
            with self.assertRaises(ConnectionClosed):
                for _ in range(250):
                    ws.recv(timeout=3)

    def test_shutdown_closes_websocket_and_releases_child_promptly(self):
        with self.ws() as ws:
            ws.recv()
            ws.recv()
            start = time.monotonic()
            self.proc.terminate()
            self.proc.wait(3)
            self.assertLess(time.monotonic() - start, 3)

    def test_active_goal_reserves_project_and_pause_releases_it(self):
        tid = self.create()
        other = self.create()
        self.request(
            "PUT", f"/api/threads/{tid}/goal", {"objective": "reserved project"}
        )
        self.assertEqual(self.send(other)[1]["code"], "project_busy")
        self.assertEqual(
            self.request(
                "PUT", f"/api/threads/{other}/goal", {"objective": "conflicting goal"}
            )[1]["code"],
            "project_busy",
        )
        self.request("PUT", f"/api/threads/{tid}/goal", {"status": "paused"})
        self.assertEqual(self.send(other)[0], 200)


class IntegrationFeatureTests(GatewayFixture):
    def test_all_threads_pagination_filter_and_existing_external_workspace(self):
        for _ in range(3): self.create()
        code, page, _ = self.request('GET', '/api/threads')
        self.assertEqual(code, 200)
        self.assertEqual(len(page['data']), 2)
        self.assertIsNotNone(page['nextCursor'])
        params = self.calls('thread/list')[-1]['params']
        self.assertNotIn('cwd', params)
        self.assertEqual(params['modelProviders'], [])
        self.assertEqual(len(params['sourceKinds']), 10)
        self.assertEqual(len(self.request('GET', '/api/threads?cursor='+page['nextCursor'])[1]['data']), 1)
        self.request('GET', '/api/threads?projectId=codex-project&search=Fixture&archived=true')
        params = self.calls('thread/list')[-1]['params']
        self.assertEqual(params['projectId'], 'codex-project')
        self.assertNotIn('cwd', params)
        self.assertTrue(params['archived'])
        self.assertEqual(params['searchTerm'], 'Fixture')
        self.assertEqual(self.request('GET', '/api/threads/outside')[0], 200)
        self.assertEqual(self.request('POST', '/api/threads', {'projectId':'arbitrary'})[0], 404)

    def test_archived_thread_is_read_only_until_unarchived(self):
        tid = self.create()
        snapshot = self.request('GET', '/api/threads/'+tid+'?archived=true')[1]
        self.assertFalse(snapshot['canControl'])
        self.assertTrue(snapshot['archived'])
        self.assertEqual(self.request('POST', '/api/threads/'+tid+'/unarchive')[0], 200)
        self.assertTrue(self.request('GET', '/api/threads/'+tid)[1]['canControl'])

    def test_skills_files_and_mcp_use_real_protocol_and_validate_selection(self):
        tid = self.create()
        (self.data/'notes.txt').write_text('Referenced file')
        skills = self.request('GET', f'/api/threads/{tid}/skills')[1]['data'][0]['skills']
        self.assertEqual(skills[0]['name'], 'fixture-skill')
        files = self.request('GET', f'/api/threads/{tid}/file-search?query=note')[1]['files']
        self.assertEqual(files[0]['file_name'], 'notes.txt')
        self.assertEqual(self.calls('fuzzyFileSearch')[-1]['params']['roots'], [str(self.data)])
        self.assertEqual(self.request('GET', f'/api/threads/{tid}/mcp')[1]['data'][0]['runtimeStatus'], 'connected')
        body = {'requestId':str(uuid.uuid4()), 'text':'use references', 'references':[{'type':'skill','name':'fixture-skill','path':skills[0]['path']},{'type':'file','name':'notes.txt','path':str(self.data/'notes.txt')}]}
        self.assertEqual(self.request('POST', f'/api/threads/{tid}/turns', body)[0], 200)
        inputs = self.calls('turn/start')[-1]['params']['input']
        self.assertEqual([x for x in inputs if x['type']=='skill'][0]['path'], skills[0]['path'])
        self.assertTrue(any(str(self.data/'notes.txt') in x.get('text','') for x in inputs))
        self.until(lambda: self.request('GET', '/api/threads/'+tid)[1]['activeTurnId'] is None)
        body['requestId'] = str(uuid.uuid4())
        body['references'][0]['path'] = '/forged/SKILL.md'
        self.assertEqual(self.request('POST', f'/api/threads/{tid}/turns', body)[1]['code'], 'skill_unavailable')

    def test_media_is_binary_not_base64_text_and_workspace_links_are_guarded(self):
        tid = self.create()
        with self.ws() as ws:
            ws.recv(); ws.recv()
            self.send(tid, 'rich')
            events = []
            while True:
                value = json.loads(ws.recv(timeout=3)); events.append(value)
                if value.get('method') == 'turn/completed': break
        self.assertNotIn('iVBORw0KGgo', json.dumps(events))
        history = self.request('GET', f'/api/threads/{tid}/items')[1]['data']
        image = next(x['item'] for x in history if x['item']['type']=='imageGeneration')
        view = next(x['item'] for x in history if x['item']['type']=='imageView')
        self.assertEqual(image['result'], '')
        self.assertEqual(view['media']['contentType'], 'image/svg+xml')
        url = '/api/media/'+image['media']['id']
        code, png, headers = self.request('GET', url, raw=True)
        self.assertEqual(code, 200)
        self.assertTrue(png.startswith(b'\x89PNG'))
        self.assertEqual(self.request('GET', url, auth=False)[0], 401)
        self.assertIn('attachment', self.request('GET', url+'?download=true', raw=True)[2]['Content-Disposition'])
        svg = self.request('GET', f'/api/threads/{tid}/file?path=motion.svg', raw=True)
        self.assertIn(b'<animate ', svg[1])
        self.assertIn('sandbox', svg[2]['Content-Security-Policy'])
        (self.data/'escape').symlink_to('/etc')
        self.assertEqual(self.request('GET', f'/api/threads/{tid}/file?path=escape/passwd')[0], 403)
        self.assertEqual(self.request('GET', f'/api/threads/{tid}/file?path=../secret')[0], 403)
        self.assertTrue(any(x['item'].get('phase')=='commentary' for x in history))

    def test_web_is_embedded_with_correct_types_and_no_sidecar(self):
        code, html, _ = self.request('GET', '/', raw=True, auth=False)
        self.assertEqual(code, 200)
        self.assertIn(b'flutter_bootstrap.js', html)
        code, js, headers = self.request('GET', '/main.dart.js', raw=True, auth=False)
        self.assertEqual(code, 200)
        self.assertIn('javascript', headers['Content-Type'])
        self.assertGreater(len(js), 100000)
        self.assertEqual(headers['Cache-Control'], 'no-cache')
        code, data, headers = self.request('GET', '/canvaskit/canvaskit.wasm', raw=True, auth=False)
        self.assertEqual(code, 200)
        self.assertEqual(headers['Content-Type'], 'application/wasm')
        self.assertTrue(data.startswith(b'\0asm'))
        for font in ['CodexLinkSans', 'CodexLinkMono', 'CodexLinkSymbols', 'CodexLinkEmoji']:
            code, data, headers = self.request('GET', f'/fonts/{font}.woff2', raw=True, auth=False)
            self.assertEqual(code, 200)
            self.assertEqual(headers['Content-Type'], 'font/woff2')
            self.assertTrue(data.startswith(b'wOF2'))


class ConfigurationDefaultsTests(GatewayFixture):
    def configure_runtime(self, config):
        config.pop("maxFileBytes")
        config.pop("maxStorageBytes")
        config.pop("timeZone")
    def test_omitted_json_settings_keep_declared_defaults(self):
        self.assertEqual(self.request("GET", "/api/status")[1]["maxFileBytes"], 25 * 1024 * 1024)
        self.assertEqual(self.request("GET", "/api/threads")[0], 200)

if __name__ == "__main__":
    unittest.main(verbosity=2)
