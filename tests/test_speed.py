import json
from test_gateway import GatewayFixture
import test_shared_gateway as shared
from websockets.sync.client import unix_connect


class SpeedTests(GatewayFixture):
    def test_fast_mode_changes_only_service_tier_and_survives_reload(self):
        tid = self.create()
        before = self.request('GET', f'/api/threads/{tid}')[1]
        self.assertTrue(before['serviceTierKnown'])
        self.assertIsNone(before['serviceTier'])
        for mode, tier in [('fast', 'priority'), ('standard', 'default')]:
            with self.subTest(mode=mode):
                code, speed, _ = self.request('PUT', f'/api/threads/{tid}/speed', {'mode':mode})
                self.assertEqual(code, 200)
                self.assertEqual(speed, {'serviceTier':tier, 'serviceTierKnown':True})
                self.assertEqual(self.calls('thread/settings/update')[-1]['params'], {'threadId':tid, 'serviceTier':tier})
                snapshot = self.request('GET', f'/api/threads/{tid}')[1]
                self.assertEqual(snapshot['serviceTier'], tier)
                self.assertEqual(snapshot['permissions'], before['permissions'])
                self.assertIsNone(snapshot['activeTurnId'])
        self.assertEqual(self.calls('thread/resume'), [])
        self.assertEqual(self.calls('turn/start'), [])

    def test_existing_session_speed_is_read_without_writes(self):
        for tid, tier, known in [('existing-fast', 'priority', True), ('existing-standard', None, True), ('existing-unknown', None, False)]:
            with self.subTest(thread=tid):
                code, snapshot, _ = self.request('GET', f'/api/threads/{tid}')
                self.assertEqual(code, 200)
                self.assertEqual((snapshot['serviceTier'], snapshot['serviceTierKnown']), (tier, known))
                self.assertEqual(self.calls('thread/resume')[-1]['params'], {'threadId':tid, 'excludeTurns':True})
        self.assertEqual(self.calls('thread/settings/update'), [])

    def test_speed_validation_auth_and_rpc_rejection_preserve_state(self):
        tid = self.create()
        path = f'/api/threads/{tid}/speed'
        self.assertEqual(self.request('PUT', path, {'mode':'turbo'})[0], 400)
        self.assertEqual(self.request('PUT', path, {'mode':'fast'}, headers={'Origin':self.base}, auth=False)[0], 401)
        self.assertEqual(self.calls('thread/settings/update'), [])
        (self.data / 'reject-speed').touch()
        code, problem, _ = self.request('PUT', path, {'mode':'fast'})
        self.assertEqual(code, 409)
        self.assertEqual(problem['code'], 'codex_rpc_error')
        snapshot = self.request('GET', f'/api/threads/{tid}')[1]
        self.assertIsNone(snapshot['serviceTier'])
        self.assertTrue(snapshot['serviceTierKnown'])

    def test_speed_changes_during_active_turn_do_not_interrupt_or_resend(self):
        tid = self.create()
        self.send(tid, 'hold')
        turn = self.request('GET', f'/api/threads/{tid}')[1]['activeTurnId']
        self.assertEqual(self.request('PUT', f'/api/threads/{tid}/speed', {'mode':'fast'})[0], 200)
        snapshot = self.request('GET', f'/api/threads/{tid}')[1]
        self.assertEqual(snapshot['activeTurnId'], turn)
        self.assertEqual(snapshot['serviceTier'], 'priority')
        self.assertEqual(len(self.calls('turn/start')), 1)
        self.assertEqual(self.calls('turn/interrupt'), [])
        self.assertEqual(self.calls('turn/steer'), [])

    def test_profile_name_does_not_override_effective_sandbox(self):
        snapshot = self.request('GET', '/api/threads/existing-custom')[1]
        self.assertIsNone(snapshot['permissions']['preset'])
        self.assertEqual(snapshot['permissions']['label'], '自定义权限')
        self.assertTrue(snapshot['permissions']['sandboxPolicy']['networkAccess'])
        self.assertEqual(self.calls('thread/settings/update'), [])


class SharedSettingsTests(GatewayFixture):
    configure_runtime = shared.SharedGatewayTests.configure_runtime
    stop_owner = shared.SharedGatewayTests.stop_owner

    def test_external_speed_change_updates_snapshot_and_events(self):
        tid = self.create()
        with self.ws() as events, unix_connect(self.socket, uri='ws://localhost/rpc') as peer:
            peer.send(json.dumps({'id':91, 'method':'thread/settings/update', 'params':{'threadId':tid, 'serviceTier':'priority'}}))
            self.until(lambda: self.request('GET', f'/api/threads/{tid}')[1]['serviceTier'] == 'priority')
            while True:
                message = json.loads(events.recv(timeout=3))
                if message.get('method') == 'thread/settings/updated': break
            self.assertEqual(message['params']['threadSettings']['serviceTier'], 'priority')
            self.assertEqual(message['params']['permissions']['preset'], 'default')

    def test_refresh_repairs_missed_speed_and_permission_events_without_writes(self):
        tid = self.create()
        self.send(tid, 'hold')
        self.assertEqual(self.request('GET', f'/api/threads/{tid}')[1]['permissions']['preset'], 'default')
        (self.data / 'suppress-settings-event').touch()
        with unix_connect(self.socket, uri='ws://localhost/rpc') as peer:
            peer.send(json.dumps({'id':92, 'method':'thread/settings/update', 'params':{'threadId':tid, 'serviceTier':'priority', 'permissions':':danger-full-access', 'approvalPolicy':'never', 'approvalsReviewer':'user'}}))
            self.assertEqual(json.loads(peer.recv(timeout=3))['id'], 92)
        writes = len(self.calls('thread/settings/update'))
        snapshot = self.request('GET', f'/api/threads/{tid}')[1]
        self.assertEqual(snapshot['permissions']['preset'], 'full-access')
        self.assertEqual(snapshot['serviceTier'], 'priority')
        self.assertTrue(snapshot['serviceTierKnown'])
        self.assertEqual(self.request('GET', f'/api/threads/{tid}/permissions')[1]['current']['preset'], 'full-access')
        self.assertEqual(len(self.calls('thread/settings/update')), writes)
        self.assertTrue(all(c['params'] == {'threadId':tid, 'excludeTurns':True} for c in self.calls('thread/resume')))
