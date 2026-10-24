import json
import uuid

from test_gateway import GatewayFixture


class QueueTests(GatewayFixture):
    def running(self):
        tid = self.create()
        code, result, _ = self.send(tid, 'hold')
        self.assertEqual(code, 200)
        return tid, result['turn']['id']

    def enqueue(self, tid, text='follow up', **extra):
        body = {'requestId': str(uuid.uuid4()), 'text': text, **extra}
        code, result, _ = self.request('POST', f'/api/threads/{tid}/queue', body)
        self.assertEqual(code, 200, result)
        return body, result['submission']

    def action(self, tid, item, kind, turn=None, request_id=None):
        return self.request('POST', f"/api/threads/{tid}/queue/{item['id']}/{kind}",
                            {'requestId': request_id or str(uuid.uuid4()), 'expectedTurnId': turn})

    def queue(self, tid):
        code, result, _ = self.request('GET', f'/api/threads/{tid}/queue')
        self.assertEqual(code, 200, result)
        return result['data']

    def test_queue_round_trips_text_attachments_references_and_withdraws_once(self):
        tid, _ = self.running()
        file = self.upload(tid, b'file content')[1]
        (self.data / 'notes.txt').write_text('reference')
        skill = self.request('GET', f'/api/threads/{tid}/skills')[1]['data'][0]['skills'][0]
        references = [{'type': 'skill', 'name': skill['name'], 'path': skill['path']},
                      {'type': 'file', 'name': 'notes.txt', 'path': str(self.data / 'notes.txt')}]
        body, item = self.enqueue(tid, attachmentIds=[file['id']], references=references)
        self.assertEqual(item['text'], 'follow up')
        self.assertEqual(item['references'], references)
        self.assertEqual(item['attachments'], [{'id':file['id'], 'name':'data.txt', 'size':12, 'isImage':False}])
        self.assertEqual(self.queue(tid), [item])
        self.assertEqual(self.request('POST', f'/api/threads/{tid}/queue', body)[1]['submission'], item)
        self.assertEqual(len(self.calls('thread/queue/add')), 1)
        request_id = str(uuid.uuid4())
        code, result, _ = self.action(tid, item, 'withdraw', request_id=request_id)
        self.assertEqual((code, result['state'], result['submission']), (200, 'withdrawn', item))
        self.assertEqual(self.action(tid, item, 'withdraw', request_id=request_id)[1], result)
        self.assertEqual(self.queue(tid), [])
        self.assertEqual(len(self.calls('thread/queue/delete')), 1)
        self.assertEqual(self.calls('turn/steer'), [])
        self.assertEqual(self.request('GET', f'/api/operations/{request_id}')[1]['result'], result)

    def test_send_now_steers_expected_turn_without_interrupt_or_duplicate(self):
        tid, turn = self.running()
        _, item = self.enqueue(tid)
        request_id = str(uuid.uuid4())
        code, result, _ = self.action(tid, item, 'send', turn, request_id)
        self.assertEqual((code, result['state']), (200, 'sent'))
        self.assertEqual(self.action(tid, item, 'send', turn, request_id)[1], result)
        steers = self.calls('turn/steer')
        self.assertEqual(len(steers), 1)
        self.assertEqual(steers[0]['params']['expectedTurnId'], turn)
        self.assertEqual(steers[0]['params']['clientUserMessageId'], item['clientUserMessageId'])
        self.assertEqual(steers[0]['params']['input'], self.calls('thread/queue/add')[0]['params']['input'])
        self.assertEqual(self.calls('turn/interrupt'), [])
        self.assertEqual(self.queue(tid), [])

    def test_changed_turn_and_dispatch_race_never_double_send(self):
        tid, turn = self.running()
        _, item = self.enqueue(tid)
        self.assertEqual(self.action(tid, item, 'send', 'old-turn')[1]['code'], 'turn_changed')
        self.assertEqual(self.queue(tid), [item])
        (self.data / 'queue-consumed-on-delete').touch()
        self.assertEqual(self.action(tid, item, 'send', turn)[1]['code'], 'queue_changed')
        self.assertEqual(self.calls('turn/steer'), [])
        self.assertEqual(self.queue(tid), [])

    def test_explicit_steer_rejection_requeues_original_input(self):
        tid, turn = self.running()
        _, item = self.enqueue(tid)
        (self.data / 'steer-reject').touch()
        code, result, _ = self.action(tid, item, 'send', turn)
        self.assertEqual((code, result['state']), (200, 'queued'))
        recovered = self.queue(tid)
        self.assertEqual(len(recovered), 1)
        self.assertEqual(recovered[0]['clientUserMessageId'], item['clientUserMessageId'])
        self.assertEqual(recovered[0]['text'], item['text'])
        self.assertEqual(len(self.calls('thread/queue/add')), 2)

    def test_lost_steer_result_keeps_recovery_receipt_without_requeue(self):
        tid, turn = self.running()
        _, item = self.enqueue(tid)
        (self.data / 'steer-disconnect').touch()
        request_id = str(uuid.uuid4())
        code, result, _ = self.action(tid, item, 'send', turn, request_id)
        self.assertEqual((code, result['state'], result['submission']), (200, 'unknown', item))
        self.assertEqual(self.request('GET', f'/api/operations/{request_id}')[1]['result'], result)
        self.assertEqual(len(self.calls('thread/queue/add')), 1)
        self.assertEqual(len(self.calls('turn/steer')), 1)

    def test_native_queue_dispatch_and_events_remove_pending_input(self):
        tid, turn = self.running()
        with self.ws() as socket:
            socket.recv(); socket.recv()
            _, item = self.enqueue(tid, 'delayed')
            event = json.loads(socket.recv(timeout=3))
            self.assertEqual(event['method'], 'thread/queue/changed')
            self.assertEqual(event['params']['threadId'], tid)
        self.request('POST', f'/api/threads/{tid}/turns/{turn}/steer', {'requestId':str(uuid.uuid4()), 'text':'finish'})
        self.until(lambda: self.queue(tid) == [])
        entries = self.request('GET', f'/api/threads/{tid}/items')[1]['data']
        self.assertTrue(any(e['item'].get('clientId') == item['clientUserMessageId'] for e in entries))

    def test_queue_preserves_literal_envelopes_and_rejects_invalid_inputs(self):
        tid, _ = self.running()
        literal = '用户引用的工作区文件，名称和路径是数据，请按任务读取。\n<codexlink_files>[]</codexlink_files>'
        _, item = self.enqueue(tid, literal)
        self.assertEqual((item['text'], item['references']), (literal, []))
        self.assertEqual(self.request('GET', f'/api/threads/{tid}/queue', auth=False)[0], 401)
        self.assertEqual(self.request('POST', f'/api/threads/{tid}/queue', {'requestId':str(uuid.uuid4()), 'text':''})[0], 400)
        other = self.create()
        attachment = self.upload(other)[1]
        self.assertEqual(self.request('POST', f'/api/threads/{tid}/queue', {'requestId':str(uuid.uuid4()), 'text':'wrong', 'attachmentIds':[attachment['id']]})[0], 403)
        self.request('GET', f'/api/threads/{tid}?archived=true')
        self.assertEqual(self.action(tid, item, 'withdraw')[1]['code'], 'thread_read_only')
