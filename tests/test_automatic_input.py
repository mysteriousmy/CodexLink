import uuid

from test_gateway import GatewayFixture


class AutomaticInputTests(GatewayFixture):
    def submit(self, tid, text, **extra):
        body = {'requestId':str(uuid.uuid4()), 'text':text, **extra}
        return body, self.request('POST', f'/api/threads/{tid}/input', body)

    def test_automatic_input_starts_idle_and_steers_active_turn_once(self):
        tid = self.create()
        body, (code, result, _) = self.submit(tid, 'hold')
        self.assertEqual(code, 200)
        turn = result['turn']['id']
        self.assertEqual(self.request('POST', f'/api/threads/{tid}/input', body)[1], result)
        self.assertEqual(len(self.calls('turn/start')), 1)
        file = self.upload(tid, b'followup attachment')[1]
        body, (code, result, _) = self.submit(tid, 'use this file', attachmentIds=[file['id']])
        self.assertEqual((code, result['turnId']), (200, turn))
        self.assertEqual(self.request('POST', f'/api/threads/{tid}/input', body)[1], result)
        steer = self.calls('turn/steer')
        self.assertEqual(len(steer), 1)
        self.assertEqual(steer[0]['params']['expectedTurnId'], turn)
        self.assertEqual(steer[0]['params']['clientUserMessageId'], body['requestId'])
        self.assertIn('followup attachment', (self.data / 'attachments' / (file['id'] + '.bin')).read_text())
        self.assertGreater(len(steer[0]['params']['input']), 1)
        self.assertEqual(self.calls('thread/queue/add'), [])
        self.assertEqual(self.calls('turn/interrupt'), [])
        self.assertEqual(self.calls('thread/goal/set'), [])
        self.until(lambda: self.request('GET', f'/api/threads/{tid}')[1]['activeTurnId'] is None)
        self.assertEqual(self.submit(tid, 'hold')[1][0], 200)
        self.assertEqual(len(self.calls('turn/start')), 2)

    def test_automatic_input_ignores_unrelated_old_turn_completion(self):
        tid = self.create()
        self.send(tid, 'questions overlap')
        self.until(lambda: self.request('GET', '/api/approvals')[1])
        _, (code, result, _) = self.submit(tid, 'clarification')
        self.assertEqual(code, 200)
        self.assertIn('turnId', result)
        self.assertEqual(len(self.calls('turn/start')), 1)
        self.assertEqual(len(self.calls('turn/steer')), 1)

    def test_automatic_input_unknown_acceptance_never_queues_or_retries(self):
        tid = self.create()
        self.submit(tid, 'hold')
        (self.data / 'steer-disconnect').touch()
        body, (code, _, _) = self.submit(tid, 'do not duplicate')
        self.assertGreaterEqual(code, 500)
        self.request('POST', f'/api/threads/{tid}/input', body)
        self.assertEqual(len(self.calls('turn/steer')), 1)
        self.assertEqual(self.calls('thread/queue/add'), [])
        self.assertEqual(len(self.calls('turn/start')), 1)

    def test_automatic_input_authentication_and_read_only_boundaries(self):
        tid = self.create()
        path = f'/api/threads/{tid}/input'
        self.assertEqual(self.request('POST', path, {'requestId':str(uuid.uuid4()), 'text':'hold'}, auth=False, headers={'Origin':self.base})[0], 401)
        self.assertEqual(self.request('POST', path, {'requestId':str(uuid.uuid4()), 'text':''})[0], 400)
        self.request('POST', f'/api/threads/{tid}/archive', {'requestId':str(uuid.uuid4())})
        self.assertEqual(self.submit(tid, 'hold')[1][0], 409)
        self.assertEqual(self.calls('turn/start'), [])
