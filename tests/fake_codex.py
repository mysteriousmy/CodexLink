#!/usr/bin/env python3
"""Deterministic stdio peer. Never connects to a model or reads Codex state."""

import base64, json, os, sys, threading, time, uuid
from pathlib import Path

lock = threading.RLock()
threads, goals, approvals, projects, project_requests = {}, {}, {}, {}, {}
settings = {}
queues = {}
loaded, subscribed = set(), set()
usage = {
    "total": {"totalTokens": 1200, "inputTokens": 1000, "outputTokens": 200},
    "last": {"totalTokens": 300},
    "modelContextWindow": 1000,
}


def emit(value):
    with lock:
        print(json.dumps(value), flush=True)


def event(method, **params):
    emit({"method": method, "params": params})


def finish(tid):
    t = threads[tid]["turns"][0]
    if t["status"] != "inProgress":
        return
    item = {"id": "agent-" + t["id"], "type": "agentMessage", "text": ""}
    event("item/started", threadId=tid, turnId=t["id"], item=item)
    for delta in ["Hello ", "世界"]:
        event(
            "item/agentMessage/delta",
            threadId=tid,
            turnId=t["id"],
            itemId=item["id"],
            delta=delta,
        )
        item["text"] += delta
    t["items"].append(item)
    event("item/completed", threadId=tid, turnId=t["id"], item=item)
    event("thread/tokenUsage/updated", threadId=tid, tokenUsage=usage)
    t["status"] = "completed"
    event("turn/completed", threadId=tid, turn=t)
    dispatch_queue(tid)
    if tid not in subscribed:
        unload(tid)


def thread_status(tid):
    if tid not in loaded:
        return {'type':'notLoaded'}
    return {'type':'active' if any(t['status'] == 'inProgress' for t in threads[tid]['turns']) else 'idle'}


def unload(tid):
    if tid in subscribed or thread_status(tid)['type'] == 'active':
        return
    loaded.discard(tid)
    event('thread/status/changed', threadId=tid, status={'type':'notLoaded'})
    event('thread/closed', threadId=tid)


def dispatch_queue(tid):
    with lock:
        if not queues.get(tid) or any(t['status'] == 'inProgress' for t in threads[tid]['turns']):
            return
        item = queues[tid].pop(0)
        event('thread/queue/changed', threadId=tid)
        call('turn/start', {'threadId':tid, 'input':item['input'], 'clientUserMessageId':item['clientUserMessageId']})


def later(action, delay=0.05):
    timer = threading.Timer(delay, action)
    timer.daemon = True
    timer.start()


def call(method, p):
    tid = p.get("threadId")
    if method == "initialize":
        assert p['capabilities']['experimentalApi'] is True
        projects['codex-project'] = {'id':'codex-project', 'name':'Codex fixture project', 'roots':[{'path':os.environ['CODEXLINK_DATA']}], 'metadata':{}}
        return {"userAgent": "fake-codex/1"}
    if method == 'project/list':
        data = list(projects.values()); offset = int(p.get('cursor') or 0)
        return {'data':data[offset:offset+2], 'nextCursor':str(offset+2) if offset+2 < len(data) else None}
    if method == 'project/read':
        return {'project': projects.get(p['projectId'])}
    if method == 'project/create':
        if p['idempotencyKey'] in project_requests: return {'project':projects[project_requests[p['idempotencyKey']]]}
        pid = str(uuid.uuid4())
        projects[pid] = {'id':pid, 'name':p['name'], 'roots':p['roots'], 'metadata':{}}
        project_requests[p['idempotencyKey']] = pid
        event('project/changed', projectId=pid, changeType='created')
        return {'project':projects[pid]}
    if method == "account/read":
        return {"account": {"type": "chatgpt", "email": "fixture@example.test"}}
    if method == "account/usage/read":
        if Path(os.environ["CODEXLINK_DATA"], "usage-error").exists():
            raise ValueError("usage temporarily unavailable")
        return {
            "summary": {"lifetimeTokens": 123456},
            "dailyUsageBuckets": [
                {"startDate": time.strftime("%Y-%m-%d"), "tokens": 100}
            ],
        }
    if method == "account/rateLimits/read":
        return {
            "rateLimits": {
                "primary": None,
                "secondary": {
                    "windowDurationMins": 10080,
                    "usedPercent": 23,
                    "resetsAt": 1900000000,
                },
            }
        }
    if method == "model/list":
        return {
            "data": [
                {
                    "id": "fixture",
                    "model": "fixture",
                    "displayName": "Fixture",
                    "supportedReasoningEfforts": [{"reasoningEffort": "low"}],
                    "defaultReasoningEffort": "low",
                }
            ]
        }
    if method == 'configRequirements/read':
        path = Path(os.environ['CODEXLINK_DATA'], 'requirements.json')
        return {'requirements':json.loads(path.read_text()) if path.exists() else {}}
    if method == 'permissionProfile/list':
        requirements = call('configRequirements/read', {})['requirements']
        allowed = requirements.get('allowedPermissionProfiles')
        return {'data':[{'id':x, 'description':x, 'allowed':allowed is None or allowed.get(x, False)} for x in [':read-only', ':workspace', ':danger-full-access']], 'nextCursor':None}
    if method == 'thread/settings/update':
        current = dict(settings[tid])
        profile = p['permissions']
        current.update(approvalPolicy=p['approvalPolicy'], approvalsReviewer=p['approvalsReviewer'], activePermissionProfile={'id':profile, 'extends':None})
        current['sandboxPolicy'] = {':read-only':{'type':'readOnly', 'networkAccess':False}, ':workspace':{'type':'workspaceWrite', 'writableRoots':[], 'networkAccess':False}, ':danger-full-access':{'type':'dangerFullAccess'}}[profile]
        settings[tid] = current
        # Real app-server sends confirmation after the empty RPC response.
        later(lambda: event('thread/settings/updated', threadId=tid, threadSettings=current))
        return {}
    if method == "thread/start":
        tid = str(uuid.uuid4())
        threads[tid] = {
            "id": tid,
            "cwd": p["cwd"],
            "projectId": p.get('projectId'),
            "preview": "Fixture task",
            "turns": [],
        }
        settings[tid] = {'approvalPolicy':p['approvalPolicy'], 'approvalsReviewer':p['approvalsReviewer'], 'sandboxPolicy':{'type':'workspaceWrite', 'writableRoots':[], 'networkAccess':False}, 'activePermissionProfile':{'id':p['permissions'], 'extends':None}}
        loaded.add(tid)
        subscribed.add(tid)
        return {"thread": threads[tid], **settings[tid]}
    if method == "thread/list":
        if Path(os.environ['CODEXLINK_DATA'], 'close-finish').exists():
            for pending in list(loaded - subscribed):
                if thread_status(pending)['type'] == 'active': finish(pending)
        for thread_id, thread in threads.items(): thread['status'] = thread_status(thread_id)
        data = [t for t in threads.values() if bool(t.get("archived")) == bool(p.get("archived"))]
        if p.get("cwd"): data = [t for t in data if t["cwd"] == p["cwd"]]
        if p.get('projectId'): data = [t for t in data if t.get('projectId') == p['projectId']]
        if p.get("searchTerm"): data = [t for t in data if p["searchTerm"].lower() in t.get("preview", "").lower()]
        offset = int(p.get("cursor") or 0)
        limit = min(p.get("limit", 30), 2)
        return {"data": data[offset:offset+limit], "nextCursor": str(offset+limit) if offset+limit < len(data) else None}
    if method == "skills/list":
        return {"data":[{"cwd": p["cwds"][0], "errors":[], "skills":[{"name":"fixture-skill", "path":str(Path(p["cwds"][0], "SKILL.md")), "description":"Fixture skill", "enabled":True, "scope":"repo"}]}]}
    if method == "fuzzyFileSearch":
        return {"files":[{"path":"notes.txt", "root":p["roots"][0], "file_name":"notes.txt", "match_type":"file", "score":10}]}
    if method == "mcpServerStatus/list":
        return {"data":[{"name":"fixture-mcp", "authStatus":"unsupported", "runtimeStatus":"connected", "tools":{"read_note":{"name":"read_note", "description":"Reads a fixture note"}}, "resources":[{"name":"note", "uri":"fixture://note"}], "resourceTemplates":[]}], "nextCursor":None}
    if method == 'thread/archive':
        if Path(os.environ['CODEXLINK_DATA'], 'archive-error').exists(): raise ValueError('archive rejected')
        threads[tid]['archived'] = True
        for turn in threads[tid]['turns']:
            if turn['status'] == 'inProgress': turn['status'] = 'interrupted'
        subscribed.discard(tid)
        unload(tid)
        event('thread/archived', threadId=tid)
        return {}
    if method == 'thread/unsubscribe':
        override = Path(os.environ['CODEXLINK_DATA'], 'close-result')
        if override.exists(): return {'status':override.read_text().strip()}
        if tid not in loaded: return {'status':'notLoaded'}
        if tid not in subscribed: return {'status':'notSubscribed'}
        subscribed.discard(tid)
        if Path(os.environ['CODEXLINK_DATA'], 'close-disconnect').exists(): os._exit(7)
        if Path(os.environ['CODEXLINK_DATA'], 'close-before-response').exists(): unload(tid)
        else: later(lambda: unload(tid))
        return {'status':'unsubscribed'}
    if method == "thread/unarchive":
        threads[tid]["archived"] = False
        event('thread/unarchived', threadId=tid)
        return {"thread": threads[tid]}
    if method in ["thread/read", "thread/resume"]:
        if tid == "invalid-metadata":
            return {"thread": {"id": tid, "cwd": "relative/path"}}
        if tid == "outside" and tid not in threads:
            threads[tid] = {"id":tid, "cwd":str(Path(os.environ["CODEXLINK_DATA"]).parent), "preview":"External workspace", "turns":[]}
            settings[tid] = {'approvalPolicy':{'granular':{'sandbox_approval':True}}, 'approvalsReviewer':'user', 'sandboxPolicy':{'type':'workspaceWrite', 'writableRoots':['/custom'], 'networkAccess':True}, 'activePermissionProfile':{'id':'custom-profile', 'extends':':workspace'}}
        if tid == "preexisting" and tid not in threads:
            threads[tid] = {"id":tid, "cwd":str(Path(os.environ["CODEXLINK_DATA"]).parent), "preview":"Already running", "turns":[{"id":"existing-turn", "status":"inProgress", "items":[]}]}
        if method == "thread/resume":
            assert set(p) == {"threadId", "excludeTurns"}, "resume must preserve configuration"
            if threads[tid].get('archived'): raise ValueError('thread archived')
            loaded.add(tid)
            subscribed.add(tid)
        threads[tid]['status'] = thread_status(tid)
        return {"thread": threads[tid], **settings.get(tid, {})}
    if method == "thread/turns/list":
        return {"data": threads[tid]["turns"], "nextCursor": None}
    if method == "thread/items/list":
        return {
            "data": [
                {"turnId": t["id"], "item": i}
                for t in threads[tid]["turns"]
                for i in reversed(t["items"])
            ],
            "nextCursor": None,
        }
    if method == "thread/goal/get":
        return {"goal": goals.get(tid)}
    if method == "thread/goal/clear":
        goals.pop(tid, None)
        event("thread/goal/cleared", threadId=tid)
        return {}
    if method == "thread/goal/set":
        g = goals.get(
            tid,
            {
                "threadId": tid,
                "tokensUsed": 0,
                "timeUsedSeconds": 0,
                "status": "active",
                "tokenBudget": None,
            },
        )
        g.update(
            {k: v for k, v in p.items() if k in ["objective", "status", "tokenBudget"]}
        )
        goals[tid] = g
        event("thread/goal/updated", threadId=tid, goal=g)
        return {"goal": g}
    if method == 'thread/queue/list':
        return {'data':queues.get(tid, []), 'nextCursor':None}
    if method == 'thread/queue/add':
        item = {'id':str(uuid.uuid4()), 'input':p['input'], 'clientUserMessageId':p['clientUserMessageId']}
        queues.setdefault(tid, []).append(item)
        event('thread/queue/changed', threadId=tid)
        later(lambda: dispatch_queue(tid))
        return {'queuedSubmission':item}
    if method == 'thread/queue/delete':
        with lock:
            item = next((q for q in queues.get(tid, []) if q['id'] == p['queuedSubmissionId']), None)
            if item is not None:
                queues[tid].remove(item)
                event('thread/queue/changed', threadId=tid)
            consumed = Path(os.environ['CODEXLINK_DATA'], 'queue-consumed-on-delete').exists()
            return {'deleted':item is not None and not consumed}
    if method == 'thread/queue/start':
        if any(t['status'] == 'inProgress' for t in threads[tid]['turns']): raise ValueError('thread already has an active or pending turn')
        item = next(q for q in queues[tid] if q['id'] == p['queuedSubmissionId'])
        queues[tid].remove(item)
        event('thread/queue/changed', threadId=tid)
        return call('turn/start', {'threadId':tid, 'input':item['input'], 'clientUserMessageId':item['clientUserMessageId']})
    if method == "turn/start":
        text = " ".join(i.get("text", "") for i in p["input"])
        if text == "crash":
            os._exit(7)
        t = {
            "id": str(uuid.uuid4()),
            "status": "inProgress",
            "items": [
                {
                    "id": p.get("clientUserMessageId", str(uuid.uuid4())),
                    "type": "userMessage",
                    "clientId": p.get("clientUserMessageId"),
                    "content": p["input"],
                }
            ],
        }
        threads[tid]["turns"].insert(0, t)
        event("turn/started", threadId=tid, turn=t)
        event("item/started", threadId=tid, turnId=t["id"], item=t["items"][0])
        if text == "approve":
            rid = "approval-" + t["id"]
            approvals[rid] = tid
            later(
                lambda: emit(
                    {
                        "id": rid,
                        "method": "item/commandExecution/requestApproval",
                        "params": {
                            "threadId": tid,
                            "turnId": t["id"],
                            "itemId": "cmd",
                            "command": "fixture command",
                        },
                    }
                )
            )
        elif text in ['questions', 'questions nonblocking', 'questions overlap', 'questions long preview']:
            rid = 'question-' + t['id']
            approvals[rid] = tid
            questions = [
                {'id':'mode', 'header':'方案', 'question':'选择实现方式？', 'isOther':False, 'isSecret':False, 'options':[
                    {'label':'分步完成（推荐）', 'description':'先验证核心流程，再发布。'},
                    {'label':'一次完成', 'description':'直接提交完整实现。'}]},
                {'id':'scope', 'header':'范围', 'question':'先支持哪个平台？', 'isOther':True, 'isSecret':False, 'options':[
                    {'label':'手机', 'description':'优先验证移动端。'}, {'label':'网页', 'description':'优先验证浏览器。'}]},
                {'id':'secret', 'header':'私密输入', 'question':'输入测试用私密回答', 'isOther':False, 'isSecret':True, 'options':None},
            ]
            if text == 'questions long preview': questions[0]['question'] = '很长的问题' * 100
            def ask():
                emit({'id':rid, 'method':'item/tool/requestUserInput', 'params':{'threadId':tid, 'turnId':t['id'], 'itemId':'questions', 'questions':questions, 'isBlocking':text != 'questions nonblocking', 'autoResolutionMs':None}})
                if text == 'questions overlap': event('turn/completed', threadId=tid, turn={'id':'older-turn', 'status':'completed'})
            later(ask)
        elif text in ['async questions', 'async questions duplicate']:
            item = {'id':'async-' + t['id'], 'type':'agentMessage', 'text':'', 'phase':'commentary', 'delivery':'async', 'questions':[
                {'title':'需要哪种界面风格？', 'options':['简洁（推荐）', '信息丰富']},
                {'title':'还有什么要求？', 'options':None}]}
            t['items'].append(item)
            def async_ask():
                event('item/completed', threadId=tid, turnId=t['id'], item=item)
                if text.endswith('duplicate'): event('item/completed', threadId=tid, turnId=t['id'], item=item)
            later(async_ask)
        elif text == "flood":

            def flood():
                for n in range(200):
                    event("turn/diff/updated", threadId=tid, diff="x" * 65536)
                finish(tid)

            later(flood)
        elif text == "benchmark":

            def benchmark():
                for n in range(1000):
                    event(
                        "turn/diff/updated",
                        threadId=tid,
                        diff="x" * 256,
                        sentAtNs=time.time_ns(),
                    )
                    time.sleep(0.001)
                finish(tid)

            later(benchmark)
        elif text == "burst":

            def burst():
                for n in range(550):
                    event("turn/diff/updated", threadId=tid, diff=str(n))
                finish(tid)

            later(burst)
        elif text == "rich":
            def rich():
                png = "iVBORw0KGgoAAAANSUhEUgAAAUAAAAC0CAIAAABqhmJGAAACKElEQVR4nO3TQQ3AIADAQJgz5CAbJ/PAhzS5U9BP59pnAE3f6wDgnoEhzMAQZmAIMzCEGRjCDAxhBoYwA0OYgSHMwBBmYAgzMIQZGMIMDGEGhjADQ5iBIczAEGZgCDMwhBkYwgwMYQaGMANDmIEhzMAQZmAIMzCEGRjCDAxhBoYwA0OYgSHMwBBmYAgzMIQZGMIMDGEGhjADQ5iBIczAEGZgCDMwhBkYwgwMYQaGMANDmIEhzMAQZmAIMzCEGRjCDAxhBoYwA0OYgSHMwBBmYAgzMIQZGMIMDGEGhjADQ5iBIczAEGZgCDMwhBkYwgwMYQaGMANDmIEhzMAQZmAIMzCEGRjCDAxhBoYwA0OYgSHMwBBmYAgzMIQZGMIMDGEGhjADQ5iBIczAEGZgCDMwhBkYwgwMYQaGMANDmIEhzMAQZmAIMzCEGRjCDAxhBoYwA0OYgSHMwBBmYAgzMIQZGMIMDGEGhjADQ5iBIczAEGZgCDMwhBkYwgwMYQaGMANDmIEhzMAQZmAIMzCEGRjCDAxhBoYwA0OYgSHMwBBmYAgzMIQZGMIMDGEGhjADQ5iBIczAEGZgCDMwhBkYwgwMYQaGMANDmIEhzMAQZmAIMzCEGRjCDAxhBoYwA0OYgSHMwBBmYAgzMIQZGMIMDGEGhjADQ5iBIczAEGZgCDMwhBkYwgwMYQaGMANDmIEhzMAQZmAIMzCEGRjCDAxhBoYwA0OYgSHMwDC6fqpaAvNW1JPlAAAAAElFTkSuQmCC"
                svg = Path(threads[tid]["cwd"], "motion.svg")
                svg.write_text('<svg xmlns="http://www.w3.org/2000/svg" width="200" height="100"><circle cx="20" cy="50" r="16" fill="royalblue"><animate attributeName="cx" values="20;180;20" dur="2s" repeatCount="indefinite"/></circle></svg>')
                for item in [
                    {"id":"progress-"+t["id"], "type":"agentMessage", "phase":"commentary", "text":"Intermediate progress is visible. 🐈 ✅ 🚀 🎨"},
                    {"id":"files-"+t["id"], "type":"fileChange", "status":"completed", "changes":[{"path":"lib/example.dart", "kind":{"type":"update"}, "diff":"@@ -1,2 +1,3 @@\n void main() {\n-  print('before');\n+  print('Hello, CodexLink');\n+  // 文件修改可以清晰阅读\n"}]},
                    {"id":"view-"+t["id"], "type":"imageView", "path":str(svg)},
                    {"id":"image-"+t["id"], "type":"imageGeneration", "status":"completed", "result":png},
                    {"id":"mcp-"+t["id"], "type":"mcpToolCall", "server":"fixture", "tool":"picture", "status":"completed", "result":{"content":[{"type":"image", "data":png, "mimeType":"image/png"}]}},
                    {"id":"link-"+t["id"], "type":"agentMessage", "phase":"final_answer", "text":"[打开动画 SVG](motion.svg)"},
                ]:
                    t["items"].append(item)
                    event("item/completed", threadId=tid, turnId=t["id"], item=item)
                finish(tid)
            later(rich)
        elif text == "notification-duplicate":
            def duplicate():
                finish(tid)
                event("turn/completed", threadId=tid, turn=t)
            later(duplicate)
        elif text == "notification-burst":
            def completions():
                for i in range(270):
                    event("turn/completed", threadId=tid, turn={"id": f"notice-{i}", "status": "completed", "items": []})
                finish(tid)
            later(completions)
        elif text in ["notification-failed", "notification-interrupted"]:
            def terminal():
                t["status"] = "failed" if text.endswith("failed") else "interrupted"
                event("turn/completed", threadId=tid, turn=t)
            later(terminal)
        elif text not in ["hold", "hold disconnect"]:
            later(lambda: finish(tid), 0.4 if text == "delayed" else 0.05)
        return {"turn": t}
    if method == "turn/steer":
        if Path(os.environ['CODEXLINK_DATA'], 'steer-reject').exists(): raise ValueError('fixture steer rejection')
        if Path(os.environ['CODEXLINK_DATA'], 'steer-disconnect').exists(): os._exit(7)
        if threads[tid]["turns"][0]["id"] != p["expectedTurnId"]:
            raise ValueError("turn changed")
        item = {"id": str(uuid.uuid4()), "clientId":p.get('clientUserMessageId'), "type": "userMessage", "content": p["input"]}
        threads[tid]["turns"][0]["items"].append(item)
        event("item/started", threadId=tid, turnId=p["expectedTurnId"], item=item)
        event("item/completed", threadId=tid, turnId=p["expectedTurnId"], item=item)
        later(lambda: finish(tid))
        return {"turnId": p["expectedTurnId"]}
    if method == "turn/interrupt":
        t = threads[tid]["turns"][0]
        t["status"] = "interrupted"
        event("turn/completed", threadId=tid, turn=t)
        return {}
    raise ValueError("Unsupported fixture method: " + method)


def handle(msg):
    with lock:
        with Path(os.environ["CODEXLINK_DATA"], "rpc-calls.jsonl").open("a") as log:
            log.write(json.dumps(msg) + "\n")
    if "method" not in msg:
        if msg.get("id") in approvals:
            event("serverRequest/resolved", requestId=msg["id"])
            later(lambda tid=approvals.pop(msg["id"]): finish(tid))
        return None
    if "id" not in msg:
        return None
    try:
        return {"id": msg["id"], "result": call(msg["method"], msg.get("params") or {})}
    except Exception as error:
        return {"id": msg["id"], "error": {"code": -32000, "message": str(error)}}

if __name__ == "__main__":
    for line in sys.stdin:
        response = handle(json.loads(line))
        if response is not None: emit(response)
