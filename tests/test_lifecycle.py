import uuid

from test_gateway import GatewayFixture


class ThreadLifecycleTests(GatewayFixture):
    def action(self, tid, action, request_id=None, **kwargs):
        return self.request('POST', f'/api/threads/{tid}/{action}',
                            {'requestId': request_id or str(uuid.uuid4())}, **kwargs)

    def row(self, tid, archived=False):
        rows = self.request('GET', f'/api/threads?archived={str(archived).lower()}')[1]['data']
        return next((row for row in rows if row['id'] == tid), None)

    def test_archive_restore_preserves_history_and_is_idempotent(self):
        tid = self.create()
        self.send(tid, 'hold')
        other = self.create()
        history = self.request('GET', f'/api/threads/{tid}/items')[1]
        rid = str(uuid.uuid4())
        result = self.action(tid, 'archive', rid)
        self.assertEqual(result[:2], (200, {'threadId':tid, 'state':'archived'}))
        self.assertEqual(self.action(tid, 'archive', rid)[:2], result[:2])
        self.assertEqual(len(self.calls('thread/archive')), 1)
        self.assertIsNone(self.row(tid))
        self.assertEqual(self.row(tid, archived=True)['status']['type'], 'notLoaded')
        self.assertEqual(self.row(other)['status']['type'], 'idle')
        self.assertEqual(self.request('GET', f'/api/threads/{tid}/items')[1], history)
        self.assertFalse(self.request('GET', f'/api/threads/{tid}?reopen=true')[1]['canControl'])
        self.assertEqual(self.calls('thread/resume'), [])
        self.assertEqual(self.send(tid)[1]['code'], 'thread_archived')
        self.assertEqual(self.action(tid, 'unarchive')[0], 200)
        self.assertFalse(self.row(tid)['archived'])
        self.assertTrue(self.request('GET', f'/api/threads/{tid}?reopen=true')[1]['canControl'])
        self.assertEqual(self.calls('thread/resume')[-1]['params'], {'threadId':tid, 'excludeTurns':True})

    def test_active_close_waits_for_native_unload_and_requires_explicit_reopen(self):
        tid = self.create()
        self.send(tid, 'hold')
        self.assertEqual(self.row(tid)['status']['type'], 'active')
        rid = str(uuid.uuid4())
        code, result, _ = self.action(tid, 'close', rid)
        self.assertEqual((code, result['state']), (200, 'closing'))
        self.assertEqual(self.action(tid, 'close', rid)[1], result)
        self.assertEqual(len(self.calls('thread/unsubscribe')), 1)
        self.assertEqual(self.calls('thread/archive'), [])
        self.assertEqual(self.calls('turn/interrupt'), [])
        self.assertEqual(self.request('GET', f'/api/operations/{rid}')[1]['result'], result)
        row = self.row(tid)
        self.assertTrue(row['closePending'])
        self.assertEqual(row['status']['type'], 'active')
        snapshot = self.request('GET', f'/api/threads/{tid}')[1]
        self.assertTrue(snapshot['closed'])
        self.assertFalse(snapshot['canControl'])
        self.assertEqual(self.calls('thread/resume'), [])
        self.assertEqual(self.send(tid)[1]['code'], 'thread_closed')
        (self.data / 'close-finish').touch()
        self.until(lambda: not self.row(tid)['closePending'])
        self.assertEqual(self.row(tid)['status']['type'], 'notLoaded')
        self.assertGreater(len(self.request('GET', f'/api/threads/{tid}/items')[1]['data']), 1)
        snapshot = self.request('GET', f'/api/threads/{tid}?reopen=true')[1]
        self.assertFalse(snapshot['closed'])
        self.assertTrue(snapshot['canControl'])
        self.assertEqual(len(self.calls('thread/resume')), 1)
        self.assertEqual(self.row(tid)['status']['type'], 'idle')

    def test_closed_notification_before_unsubscribe_response_stays_closed(self):
        tid = self.create()
        (self.data / 'close-before-response').touch()
        self.assertEqual(self.action(tid, 'close')[1]['state'], 'closed')
        self.assertFalse(self.row(tid)['closePending'])
        self.assertEqual(self.row(tid)['status']['type'], 'notLoaded')
        self.assertEqual(self.action(tid, 'close')[1]['state'], 'closed')
        self.assertFalse(self.request('GET', f'/api/threads/{tid}')[1]['canControl'])

    def test_lifecycle_auth_invalid_request_and_conflicting_retry_do_not_mutate(self):
        tid = self.create()
        for action in ['archive', 'close']:
            self.assertEqual(self.action(tid, action, auth=False, headers={'Origin':self.base})[0], 401)
            self.assertEqual(self.action(tid, action, 'invalid')[0], 400)
        self.assertEqual(self.calls('thread/archive'), [])
        self.assertEqual(self.calls('thread/unsubscribe'), [])
        rid = str(uuid.uuid4())
        self.assertEqual(self.action(tid, 'archive', rid)[0], 200)
        self.assertEqual(self.action(tid, 'close', rid)[1]['code'], 'request_id_conflict')
        self.assertEqual(self.calls('thread/unsubscribe'), [])

    def test_native_rejections_preserve_session_and_do_not_claim_unload(self):
        tid = self.create()
        (self.data / 'archive-error').touch()
        self.assertEqual(self.action(tid, 'archive')[0], 409)
        self.assertIsNotNone(self.row(tid))
        for result, code in [('notSubscribed', 'thread_not_subscribed'), ('unexpected', 'invalid_close_result')]:
            (self.data / 'close-result').write_text(result)
            self.assertEqual(self.action(tid, 'close')[1]['code'], code)
            self.assertFalse(self.row(tid)['closedByClient'])
            self.assertTrue(self.request('GET', f'/api/threads/{tid}')[1]['canControl'])

    def test_archived_or_unloaded_goal_does_not_block_another_project_task(self):
        for action in ['archive', 'close']:
            with self.subTest(action=action):
                tid = self.create()
                self.assertEqual(self.request('PUT', f'/api/threads/{tid}/goal', {'objective':'retained goal', 'status':'active'})[0], 200)
                (self.data / 'close-before-response').touch()
                self.assertEqual(self.action(tid, action)[0], 200)
                # Reading saved Goal metadata must not reserve an absent runtime.
                self.assertEqual(self.request('GET', f'/api/threads/{tid}/goal')[1]['goal']['objective'], 'retained goal')
                other = self.create()
                code, result, _ = self.send(other, 'hold')
                self.assertEqual(code, 200, result)
                self.assertEqual(self.action(other, 'archive')[0], 200)

    def test_lost_close_response_does_not_resubscribe_or_repeat_on_refresh(self):
        tid = self.create()
        (self.data / 'close-disconnect').touch()
        rid = str(uuid.uuid4())
        self.assertEqual(self.action(tid, 'close', rid)[1]['code'], 'codex_disconnected')
        self.until(lambda: self.request('GET', '/api/status')[1]['codex'] == 'ready')
        self.assertEqual(self.request('GET', f'/api/operations/{rid}')[1]['state'], 'unknown')
        # The replacement fixture has no history, but a refresh must still not resume it.
        self.assertNotEqual(self.request('GET', f'/api/threads/{tid}')[0], 200)
        self.assertEqual(self.calls('thread/resume'), [])
        self.assertEqual(self.action(tid, 'close', rid)[1]['code'], 'codex_disconnected')
        self.assertEqual(len(self.calls('thread/unsubscribe')), 1)
