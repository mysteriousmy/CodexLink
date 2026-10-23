#!/usr/bin/env python3
"""Deterministic stdio peer. Never connects to a model or reads Codex state."""

import base64, json, os, sys, threading, time, uuid
from pathlib import Path

lock = threading.RLock()
threads, goals, approvals, projects, project_requests = {}, {}, {}, {}, {}
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
    if method == "thread/start":
        tid = str(uuid.uuid4())
        threads[tid] = {
            "id": tid,
            "cwd": p["cwd"],
            "projectId": p.get('projectId'),
            "preview": "Fixture task",
            "turns": [],
        }
        return {"thread": threads[tid]}
    if method == "thread/list":
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
    if method == "thread/unarchive":
        threads[tid]["archived"] = False
        return {"thread": threads[tid]}
    if method in ["thread/read", "thread/resume"]:
        if tid == "invalid-metadata":
            return {"thread": {"id": tid, "cwd": "relative/path"}}
        if tid == "outside" and tid not in threads:
            threads[tid] = {"id":tid, "cwd":str(Path(os.environ["CODEXLINK_DATA"]).parent), "preview":"External workspace", "turns":[]}
        if tid == "preexisting" and tid not in threads:
            threads[tid] = {"id":tid, "cwd":str(Path(os.environ["CODEXLINK_DATA"]).parent), "preview":"Already running", "turns":[{"id":"existing-turn", "status":"inProgress", "items":[]}]}
        if method == "thread/resume":
            assert set(p) == {"threadId", "excludeTurns"}, "resume must preserve configuration"
        return {"thread": threads[tid]}
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
        elif text not in ["hold", "hold disconnect"]:
            later(lambda: finish(tid), 0.4 if text == "delayed" else 0.05)
        return {"turn": t}
    if method == "turn/steer":
        if threads[tid]["turns"][0]["id"] != p["expectedTurnId"]:
            raise ValueError("turn changed")
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
