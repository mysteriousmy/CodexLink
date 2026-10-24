import concurrent.futures
import json
import uuid
from test_gateway import GatewayFixture
import test_shared_gateway as shared
from websockets.sync.client import unix_connect


class QuestionTests(GatewayFixture):
    def test_structured_async_replies_preserve_ids_and_echo_into_history(self):
        for active in [False, True]:
            with self.subTest(active=active):
                tid = self.create()
                self.assertEqual(self.send(tid, 'async questions')[0], 200)
                history = lambda: self.request('GET', f'/api/threads/{tid}/items')[1]['data']
                question = self.until(lambda: [v['item'] for v in history() if v['item'].get('questions')])[0]
                turn = self.request('GET', f'/api/threads/{tid}')[1]['activeTurnId']
                if not active:
                    self.assertEqual(self.request('POST', f'/api/threads/{tid}/turns/{turn}/interrupt')[0], 200)
                answer = {'questionItemId': json.dumps(['request_user_input_async', question['id'], 1], separators=(',', ':')),
                          'question': '还有什么要求？', 'answer': '保留草稿\n"手机和网页" 😀'}
                text = '<send_user_message_question_reply>' + json.dumps([answer], ensure_ascii=False) + '</send_user_message_question_reply>'
                path = f'/api/threads/{tid}/turns' + (f'/{turn}/steer' if active else '')
                self.assertEqual(self.request('POST', path, {'requestId':str(uuid.uuid4()), 'text':text})[0], 200)
                method = 'turn/steer' if active else 'turn/start'
                params = self.calls(method)[-1]['params']
                self.assertEqual(params['input'], [{'type':'text', 'text':text}])
                if active:
                    self.assertEqual(params['expectedTurnId'], turn)
                echoed = self.until(lambda: [v['item'] for v in history() if v['item'].get('content') == params['input']])
                self.assertEqual(len(echoed), 1)
                self.until(lambda: self.request('GET', f'/api/threads/{tid}')[1]['activeTurnId'] is None)

    def pending(self, tid):
        return self.request('GET', f'/api/threads/{tid}')[1]['approvals']

    def ask(self, text='questions'):
        tid = self.create()
        self.assertEqual(self.send(tid, text)[0], 200)
        request = self.until(lambda: self.pending(tid))[0]
        return tid, request

    def result(self):
        return {'answers': {'mode': {'answers': ['分步完成（推荐）']},
                            'scope': {'answers': ['手机和网页']},
                            'secret': {'answers': ['fixture-only-secret']}}}

    def test_native_questions_reconnect_and_exact_reply_once(self):
        tid, request = self.ask()
        with self.ws():
            pass
        self.assertEqual(self.pending(tid), [request])
        self.assertEqual(request['params']['questions'][0]['options'][0]['description'], '先验证核心流程，再发布。')
        path = '/api/approvals/' + request['id']
        with concurrent.futures.ThreadPoolExecutor(2) as pool:
            results = list(pool.map(lambda _: self.request('POST', path, {'result': self.result()})[0], range(2)))
        self.assertEqual(sorted(results), [204, 409])
        self.until(lambda: not self.pending(tid))
        replies = [v for v in map(json.loads, (self.data/'rpc-calls.jsonl').read_text().splitlines()) if v.get('id') == request['rpcId']]
        self.assertEqual(replies, [{'id': request['rpcId'], 'result': self.result()}])

    def test_invalid_answers_and_unauthorized_requests_preserve_pending_question(self):
        tid, request = self.ask()
        path = '/api/approvals/' + request['id']
        cases = [({}, 'missing'), ({'answers': []}, 'wrong-container')]
        for key, value, label in [('mode', None, 'null'), ('mode', 'bad', 'scalar'), ('mode', {'answers': []}, 'empty'),
                                  ('mode', {'answers': ['']}, 'blank'), ('mode', {'answers': [1]}, 'number'),
                                  ('mode', {'answers': ['not-an-option']}, 'unknown-option'),
                                  ('mode', {'answers': ['一次完成', '分步完成（推荐）']}, 'multiple'),
                                  ('secret', {'answers': ['x' * 20001]}, 'too-long')]:
            value_result = self.result()
            value_result['answers'][key] = value
            cases.append((value_result, label))
        extra = self.result(); extra['answers']['unknown'] = {'answers':['extra']}
        cases.append((extra, 'unknown-question'))
        replaced = self.result(); replaced['answers']['unknown'] = replaced['answers'].pop('mode')
        cases.append((replaced, 'replaced-question-id'))
        for result, label in cases:
            with self.subTest(case=label):
                self.assertEqual(self.request('POST', path, {'result':result})[0], 400)
                self.assertEqual(self.pending(tid), [request])
        self.assertEqual(self.request('POST', path, {'result':self.result()}, headers={'Origin':self.base}, auth=False)[0], 401)
        valid = self.result(); valid['answers']['secret'] = {'answers':['x'*20000]}
        self.assertEqual(self.request('POST', path, {'result':valid})[0], 204)

    def test_only_matching_turn_completion_expires_question(self):
        tid, request = self.ask('questions overlap')
        self.assertEqual(self.pending(tid), [request])
        turn = request['params']['turnId']
        self.assertEqual(self.request('POST', f'/api/threads/{tid}/turns/{turn}/interrupt')[0], 200)
        self.until(lambda: not self.pending(tid))
        self.assertEqual(self.request('POST', '/api/approvals/' + request['id'], {'result':self.result()})[0], 409)

    def test_async_questions_survive_history_and_nonblocking_flag_survives_snapshot(self):
        tid, request = self.ask('questions nonblocking')
        self.assertFalse(request['params']['isBlocking'])
        self.request('POST', f"/api/threads/{tid}/turns/{request['params']['turnId']}/interrupt")
        other = self.create()
        self.assertEqual(self.send(other, 'async questions')[0], 200)
        def questions():
            return [v['item'] for v in self.request('GET', f'/api/threads/{other}/items')[1]['data'] if v['item'].get('questions')]
        item = self.until(questions)[0]
        self.assertEqual(item['text'], '')
        self.assertEqual(item['delivery'], 'async')
        self.assertEqual(item['questions'], [{'title':'需要哪种界面风格？', 'options':['简洁（推荐）','信息丰富']}, {'title':'还有什么要求？', 'options':None}])


class SharedQuestionTests(GatewayFixture):
    configure_runtime = shared.SharedGatewayTests.configure_runtime
    stop_owner = shared.SharedGatewayTests.stop_owner

    def test_other_client_answer_resolves_pending_native_question(self):
        tid = self.create()
        self.send(tid, 'questions')
        request = self.until(lambda: self.request('GET', f'/api/threads/{tid}')[1]['approvals'])[0]
        with self.ws() as events, unix_connect(self.socket, uri='ws://localhost/rpc') as peer:
            peer.send(json.dumps({'id': request['rpcId'], 'result': {'answers': {}}}))
            while True:
                event = json.loads(events.recv(timeout=3))
                if event.get('method') == 'approval/resolved': break
            self.assertEqual(event['params']['id'], request['id'])
        self.assertEqual(self.request('GET', f'/api/threads/{tid}')[1]['approvals'], [])
