"""Local fixture benchmark; excludes model latency and mobile rendering."""

import json, statistics, time
from pathlib import Path
from test_gateway import GatewayTests

case = GatewayTests()
started = time.perf_counter()
case.setUp()
startup_ms = (time.perf_counter() - started) * 1000
try:

    def rss():
        for line in Path(f"/proc/{case.proc.pid}/status").read_text().splitlines():
            if line.startswith("VmRSS:"):
                return int(line.split()[1])

    before = rss()
    latencies = []
    tid = case.create()
    with case.ws() as ws:
        ws.recv()
        ws.recv()
        case.send(tid, "benchmark")
        while True:
            event = json.loads(ws.recv(timeout=5))
            p = event.get("params", {})
            if "sentAtNs" in p:
                latencies.append((time.time_ns() - p["sentAtNs"]) / 1e6)
            if event["method"] == "turn/completed":
                break
    after = rss()
    latencies.sort()
    result = {
        "sampleCount": len(latencies),
        "producerIntervalMs": 1,
        "payloadCharacters": 256,
        "forwardingP50Ms": round(statistics.median(latencies), 3),
        "forwardingP95Ms": round(latencies[int(len(latencies) * 0.95) - 1], 3),
        "forwardingMaxMs": round(max(latencies), 3),
        "gatewayRssBeforeKiB": before,
        "gatewayRssAfterKiB": after,
        "fixtureStartupReadyMs": round(startup_ms, 1),
        "scope": "local Linux HTTP/WS, deterministic Codex peer, includes JSON and scheduling; not model or phone performance",
    }
    print(json.dumps(result, indent=2))
    Path("artifacts/benchmark.json").write_text(json.dumps(result, indent=2))
finally:
    case.doCleanups()
