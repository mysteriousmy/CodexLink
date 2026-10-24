"""Completion delivery contracts against the real HTTP/SSE gateway."""
import contextlib
import datetime
import http.client
import json
import os
import subprocess
import urllib.parse

from test_gateway import COMMAND, GatewayFixture


class NotificationTests(GatewayFixture):
    def batch(self, baseline=None):
        path = "/api/notifications"
        if baseline is not None:
            path += "?" + urllib.parse.urlencode({"epoch": baseline["epoch"], "after": baseline["cursor"]})
        code, data, _ = self.request("GET", path)
        self.assertEqual(code, 200)
        return data

    @contextlib.contextmanager
    def stream(self, baseline=None, last_id=None):
        path = "/api/notifications/events"
        if baseline is not None:
            path += "?" + urllib.parse.urlencode({"epoch": baseline["epoch"], "after": baseline["cursor"]})
        headers = {"Authorization": "Bearer " + self.token}
        if last_id is not None:
            headers["Last-Event-ID"] = last_id
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        connection.request("GET", path, headers=headers)
        response = connection.getresponse()
        self.assertEqual(response.status, 200)
        self.assertTrue(response.getheader("Content-Type").startswith("text/event-stream"))

        def event():
            result = {}
            while True:
                line = response.readline().decode().rstrip("\r\n")
                if not line:
                    if result:
                        result["data"] = json.loads(result["data"])
                        return result
                    self.fail("Notification stream ended before an event")
                key, value = line.split(":", 1)
                result[key] = value.strip()
        try:
            yield event
        finally:
            response.close()
            connection.close()

    def restart(self):
        self.proc.terminate()
        self.proc.wait(5)
        self.proc = subprocess.Popen(COMMAND, env={**os.environ, "CODEXLINK_DATA": str(self.data)}, stdout=self.log, stderr=subprocess.STDOUT)
        self.until(lambda: self.request("GET", "/api/status")[1].get("codex") == "ready")

    def test_notification_baseline_live_delivery_and_replay_are_private(self):
        baseline = self.batch()
        self.assertEqual(baseline["items"], [])
        self.assertTrue(baseline["reset"])
        with self.stream() as event:
            ready = event()
            self.assertEqual(ready["event"], "ready")
            tid = self.create()
            self.send(tid)
            notice = event()
            self.assertEqual(notice["event"], "task")
            self.assertEqual(notice["data"]["threadId"], tid)
            self.assertEqual(notice["data"]["status"], "completed")
            self.assertEqual(set(notice["data"]), {"sequence", "id", "threadId", "turnId", "status", "completedAt"})
            completed = event()
            self.assertEqual(completed["event"], "ready")
        self.assertEqual(self.batch()["items"], [])  # first enable never floods old completions
        with self.stream(last_id=ready["id"]) as event:
            self.assertEqual(event()["data"]["id"], notice["data"]["id"])
            self.assertEqual(event()["event"], "ready")
        self.assertEqual(self.batch(completed["data"])["items"], [])

    def test_notification_duplicate_and_interrupted_turns_do_not_alert_twice(self):
        baseline = self.batch()
        tid = self.create()
        self.send(tid, "notification-duplicate")
        self.until(lambda: self.batch(baseline)["cursor"] == 1)
        self.send(tid, "notification-interrupted")
        self.until(lambda: self.request("GET", f"/api/threads/{tid}")[1].get("activeTurnId") is None)
        self.send(tid, "notification-failed")
        self.until(lambda: self.batch(baseline)["cursor"] == 2)
        rows = self.batch(baseline)["items"]
        self.assertEqual([n["status"] for n in rows], ["completed", "failed"])
        self.assertEqual(len({n["id"] for n in rows}), 2)

    def test_notification_cursor_and_history_survive_gateway_restart(self):
        baseline = self.batch()
        self.send(self.create())
        self.until(lambda: self.batch(baseline)["cursor"] == 1)
        self.restart()
        restored = self.batch(baseline)
        self.assertEqual(restored["epoch"], baseline["epoch"])
        self.assertEqual(restored["cursor"], 1)
        self.assertEqual(len(restored["items"]), 1)
        self.assertTrue(restored["durable"])
        self.assertEqual(self.batch(restored)["items"], [])

    def test_notification_retention_is_bounded_and_reports_delivery_gap(self):
        baseline = self.batch()
        self.send(self.create(), "notification-burst")
        self.until(lambda: self.batch(baseline)["cursor"] == 271)
        batch = self.batch(baseline)
        self.assertEqual(len(batch["items"]), 256)
        self.assertTrue(batch["gap"])
        self.assertEqual(batch["items"][0]["sequence"], 16)
        self.assertEqual(batch["items"][-1]["sequence"], 271)

    def test_notification_expired_history_and_changed_epoch_are_explicit(self):
        baseline = self.batch()
        self.send(self.create())
        self.until(lambda: self.batch(baseline)["cursor"] == 1)
        self.proc.terminate()
        self.proc.wait(5)
        journal = json.loads((self.data / "notifications.json").read_text())
        journal["items"][0]["completedAt"] = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=8)).isoformat()
        (self.data / "notifications.json").write_text(json.dumps(journal))
        self.restart()
        expired = self.batch(baseline)
        self.assertTrue(expired["gap"])
        self.assertEqual(expired["items"], [])
        changed = self.batch({"epoch": "previous-server", "cursor": 1})
        self.assertTrue(changed["reset"])
        self.assertTrue(changed["gap"])
        self.assertEqual(changed["items"], [])

    def test_notification_corrupt_journal_resets_epoch_without_breaking_startup(self):
        baseline = self.batch()
        self.send(self.create())
        self.until(lambda: self.batch(baseline)["cursor"] == 1)
        old = self.batch(baseline)
        self.proc.terminate()
        self.proc.wait(5)
        (self.data / "notifications.json").write_text(json.dumps({"epoch": old["epoch"], "cursor": 1, "items": None}))
        self.restart()
        restored = self.batch(old)
        self.assertNotEqual(restored["epoch"], old["epoch"])
        self.assertTrue(restored["gap"])
        self.assertTrue(restored["reset"])
        self.assertFalse(restored["durable"])
        self.send(self.create())
        self.until(lambda: self.batch()["durable"])
        self.assertEqual(self.batch()["cursor"], 1)

    def test_notification_endpoints_require_authentication_and_valid_cursor(self):
        for path in ["/api/notifications", "/api/notifications/events"]:
            self.assertEqual(self.request("GET", path, auth=False)[0], 401)
            self.assertEqual(self.request("GET", path, headers={"Origin": "https://wrong.example"})[0], 403)
            self.assertEqual(self.request("GET", path + "?after=-1")[0], 400)
            self.assertEqual(self.request("GET", path + "?after=broken")[0], 400)
        self.assertEqual(self.request("GET", "/api/notifications/events", headers={"Last-Event-ID": "invalid"})[0], 400)
