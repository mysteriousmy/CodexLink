import json, os, subprocess, sys, uuid
from websockets.sync.client import unix_connect
from test_gateway import GatewayFixture, ROOT

class SharedGatewayTests(GatewayFixture):
    def configure_runtime(self, config):
        self.socket = str(self.data / "shared.sock")
        self.owner_log = (self.data / "owner.log").open("w")
        self.owner = subprocess.Popen([sys.executable, str(ROOT / "tests/fake_shared_codex.py"), self.socket], env={**os.environ, "CODEXLINK_DATA":str(self.data)}, stdout=self.owner_log, stderr=subprocess.STDOUT)
        self.addCleanup(self.stop_owner)
        self.until(lambda: os.path.exists(self.socket))
        config["codexSocketPath"] = self.socket

    def stop_owner(self):
        self.owner.terminate()
        self.owner.wait(5)
        self.owner_log.close()

    def test_shared_attach_preserves_running_turn_and_owner_survives_gateway(self):
        self.assertEqual(self.request("GET", "/api/status")[1]["codexTransport"], "shared")
        code, snapshot, _ = self.request("GET", "/api/threads/preexisting")
        self.assertEqual(code, 200)
        self.assertEqual(snapshot["activeTurnId"], "existing-turn")
        self.assertTrue(snapshot["canControl"])
        self.assertEqual(self.calls("thread/resume")[-1]["params"], {"threadId":"preexisting", "excludeTurns":True})
        code, _, _ = self.request("POST", "/api/threads/preexisting/turns/existing-turn/steer", {"requestId":str(uuid.uuid4()), "text":"continue", "attachmentIds":[]})
        self.assertEqual(code, 200)
        self.proc.terminate()
        self.proc.wait(5)
        self.assertIsNone(self.owner.poll())
        with unix_connect(self.socket, uri="ws://localhost/rpc") as peer:
            peer.send(json.dumps({"id":99,"method":"initialize","params":{}}))
            response = json.loads(peer.recv(timeout=2))
            self.assertEqual(response["id"], 99)

    def test_new_shared_thread_snapshot_does_not_query_unmaterialized_turns(self):
        tid = self.create()
        self.assertEqual(self.request("GET", "/api/threads/"+tid)[0], 200)
        self.assertEqual(self.calls("thread/turns/list"), [])

    def test_other_client_approval_resolution_removes_pending_request(self):
        tid = self.create()
        self.send(tid, "approve")
        pending = self.until(lambda: self.request("GET", "/api/approvals")[1])
        with unix_connect(self.socket, uri="ws://localhost/rpc") as peer:
            peer.send(json.dumps({"id":pending[0]["rpcId"], "result":{"decision":"accept"}}))
            self.until(lambda: not self.request("GET", "/api/approvals")[1])
