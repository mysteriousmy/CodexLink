import json
from test_gateway import GatewayFixture
import test_shared_gateway as shared
from websockets.sync.client import unix_connect


class PermissionTests(GatewayFixture):
    def test_four_permission_presets_confirm_actual_settings_and_persist_for_turns(self):
        tid = self.create()
        path = f'/api/threads/{tid}/permissions'
        code, choices, _ = self.request('GET', path)
        self.assertEqual(code, 200)
        self.assertEqual(choices['current']['preset'], 'default')
        self.assertEqual([o['id'] for o in choices['options']], ['read-only', 'default', 'auto-review', 'full-access'])
        self.assertTrue(all(o['allowed'] for o in choices['options']))
        modes = [('read-only', ':read-only', 'on-request', 'user', 'readOnly'), ('default', ':workspace', 'on-request', 'user', 'workspaceWrite'), ('auto-review', ':workspace', 'on-request', 'auto_review', 'workspaceWrite'), ('full-access', ':danger-full-access', 'never', 'user', 'dangerFullAccess')]
        for preset, profile, policy, reviewer, sandbox in modes:
            with self.subTest(preset=preset):
                code, actual, _ = self.request('PUT', path, {'preset':preset})
                self.assertEqual(code, 200)
                self.assertEqual(actual['preset'], preset)
                self.assertEqual(actual['sandboxPolicy']['type'], sandbox)
                self.assertEqual(actual['approvalPolicy'], policy)
                self.assertEqual(actual['approvalsReviewer'], reviewer)
                self.assertEqual(self.calls('thread/settings/update')[-1]['params'], {'threadId':tid, 'permissions':profile, 'approvalPolicy':policy, 'approvalsReviewer':reviewer})
                self.assertEqual(self.request('GET', f'/api/threads/{tid}')[1]['permissions'], actual)
        self.assertEqual(self.calls('thread/resume'), [])  # empty threads cannot resume
        self.assertEqual(self.send(tid, 'hello')[0], 200)
        self.assertNotIn('permissions', self.calls('turn/start')[-1]['params'])
        self.assertNotIn('approvalPolicy', self.calls('turn/start')[-1]['params'])

    def test_custom_existing_permissions_are_displayed_and_never_overwritten_on_resume(self):
        code, snapshot, _ = self.request('GET', '/api/threads/outside')
        self.assertEqual(code, 200)
        current = snapshot['permissions']
        self.assertIsNone(current['preset'])
        self.assertEqual(current['label'], '自定义权限')
        self.assertEqual(current['activePermissionProfile']['id'], 'custom-profile')
        self.assertTrue(current['sandboxPolicy']['networkAccess'])
        self.assertEqual(self.request('GET', '/api/threads/outside/permissions')[1]['current'], current)
        self.assertEqual(self.calls('thread/resume')[-1]['params'], {'threadId':'outside', 'excludeTurns':True})
        self.assertEqual(self.calls('thread/settings/update'), [])

    def test_permission_changes_reject_active_turn_and_active_goal(self):
        tid = self.create()
        self.send(tid, 'hold')
        path = f'/api/threads/{tid}/permissions'
        self.assertEqual(self.request('PUT', path, {'preset':'full-access'})[0], 409)
        turn = self.request('GET', f'/api/threads/{tid}')[1]['activeTurnId']
        self.request('POST', f'/api/threads/{tid}/turns/{turn}/interrupt')
        self.request('PUT', f'/api/threads/{tid}/goal', {'objective':'fixture goal'})
        self.assertEqual(self.request('PUT', path, {'preset':'default'})[0], 409)
        self.assertEqual(self.calls('thread/settings/update'), [])

    def test_permissions_respect_managed_profiles_reviewers_and_authentication(self):
        tid = self.create()
        path = f'/api/threads/{tid}/permissions'
        (self.data / 'requirements.json').write_text(json.dumps({'allowedPermissionProfiles':{':workspace':True}, 'allowedApprovalsReviewers':['user']}))
        options = self.request('GET', path)[1]['options']
        self.assertEqual({o['id']:o['allowed'] for o in options}, {'read-only':False, 'default':True, 'auto-review':False, 'full-access':False})
        for preset in ['read-only', 'auto-review', 'full-access']:
            self.assertEqual(self.request('PUT', path, {'preset':preset})[0], 403)
        self.assertEqual(self.request('PUT', path, {'preset':'unknown'})[0], 400)
        self.assertEqual(self.request('PUT', path, {'preset':'default'}, headers={'Origin':self.base}, auth=False)[0], 401)
        self.assertEqual(self.calls('thread/settings/update'), [])
        self.assertEqual(self.request('PUT', path, {'preset':'default'})[0], 200)


class SharedPermissionTests(GatewayFixture):
    configure_runtime = shared.SharedGatewayTests.configure_runtime
    stop_owner = shared.SharedGatewayTests.stop_owner

    def test_external_permission_change_updates_snapshot_and_live_clients(self):
        tid = self.create()
        with self.ws() as events, unix_connect(self.socket, uri='ws://localhost/rpc') as peer:
            peer.send(json.dumps({'id':91, 'method':'thread/settings/update', 'params':{'threadId':tid, 'permissions':':workspace', 'approvalPolicy':'on-request', 'approvalsReviewer':'auto_review'}}))
            self.until(lambda: self.request('GET', f'/api/threads/{tid}')[1]['permissions']['preset'] == 'auto-review')
            while True:
                message = json.loads(events.recv(timeout=3))
                if message.get('method') == 'thread/settings/updated': break
            self.assertEqual(message['params']['permissions']['preset'], 'auto-review')
            self.assertEqual(message['params']['threadSettings']['approvalsReviewer'], 'auto_review')
