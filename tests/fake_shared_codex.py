"""Independent Unix-WebSocket peer; stopping a gateway must not stop this owner."""
import json, sys, threading
from websockets.sync.server import unix_serve
import fake_codex as fake

peers = set()
gate = threading.RLock()

def broadcast(value):
    with gate:
        for peer in list(peers):
            try:
                text = json.dumps(value)
                peer.send([text[:len(text)//2], text[len(text)//2:]])
            except Exception:
                peers.discard(peer)

def handle(peer):
    with gate: peers.add(peer)
    try:
        for raw in peer:
            response = fake.handle(json.loads(raw))
            if response is not None:
                text = json.dumps(response)
                peer.send([text[:len(text)//2], text[len(text)//2:]])
    finally:
        with gate: peers.discard(peer)

fake.emit = broadcast
with unix_serve(handle, path=sys.argv[1]) as server:
    server.serve_forever()
