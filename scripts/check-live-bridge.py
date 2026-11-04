#!/usr/bin/env python3
"""Check an explicitly selected, running AgentLab-AgentTesting session."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
import socket
import struct
import subprocess
import time
import uuid
from pathlib import Path

if not __debug__:
    raise SystemExit("Verification requires Python assertions. Disable optimization and retry.")

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("session_id", type=uuid.UUID)
parser.add_argument("--cli", default=".build/debug/agentdevctl")
args = parser.parse_args()
session_id = str(args.session_id).upper()
cli = [args.cli, "--session", session_id]
identity = json.loads(subprocess.check_output(cli + ["session", "ping", "--json"]))["result"]
assert identity["bundleId"] == "dev.agentdevkit.AgentTesting"
capabilities = json.loads(subprocess.check_output(cli + ["capabilities", "--json"]))["result"]
assert capabilities["app"] == identity
assert capabilities["readOnly"]
assert set(capabilities["methods"]) == {
    "system.hello", "system.capabilities", "state.snapshot", "state.observe", "actions.list",
    "diagnostics.recent", "events.since", "runtime.wait",
}
assert capabilities["fixtures"] == [] and capabilities["routes"] == [] and capabilities["actions"] == []

temp = Path(subprocess.check_output(["getconf", "DARWIN_USER_TEMP_DIR"], text=True).strip())
directory = temp / "adk" / session_id
descriptor = directory / "session.json"
for path, mode in [(directory, 0o700), (descriptor, 0o600), (directory / "s", 0o600)]:
    stat = path.lstat()
    assert stat.st_uid == os.geteuid() and stat.st_mode & 0o777 == mode
credential = json.loads(descriptor.read_text())["auth"]

def probe(payload, length=None):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(3)
        sock.connect(str(directory / "s"))
        sock.sendall(struct.pack(">I", len(payload) if length is None else length) + payload)
        with sock.makefile("rb") as stream:
            size = struct.unpack(">I", stream.read(4))[0]
            return json.loads(stream.read(size))

def payload_for(**overrides):
    envelope = {
        "protocol": "agentdevkit/1", "requestId": str(uuid.uuid4()), "sessionId": session_id,
        "auth": credential, "method": "system.hello", "params": {}, "timeoutMs": 2000,
    }
    envelope.update(overrides)
    return json.dumps(envelope).encode()

def request(**overrides):
    return probe(payload_for(**overrides))

def rejected(reply, code):
    assert reply["ok"] is False and reply["error"]["code"] == code
    assert "result" not in reply and credential not in json.dumps(reply)

rejected(request(auth="X" * 44), "AUTH_REQUIRED")
rejected(request(sessionId=str(uuid.uuid4())), "AUTH_REQUIRED")
rejected(request(protocol="agentdevkit/999"), "UNSUPPORTED_VERSION")
rejected(request(method="unregistered.method"), "UNKNOWN_METHOD")
rejected(request(method="fixtures.load", params={"fixture": "basic-project-v1"}), "PERMISSION_DENIED")
rejected(request(method="actions.invoke", params={"actionId": "inspector.save", "arguments": {"name": "Rejected"}}), "PERMISSION_DENIED")
rejected(request(params={"unexpected": True}), "INVALID_PARAMS")
rejected(probe(b"{"), "INVALID_PARAMS")
rejected(probe(b"", length=4097), "FRAME_TOO_LARGE")
request_id = str(uuid.uuid4())
assert request(requestId=request_id)["result"] == identity
rejected(request(requestId=request_id), "CONFLICT")
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as abandoned:
    abandoned.connect(str(directory / "s"))
    abandoned.sendall(struct.pack(">I", 300) + b"{")
with ThreadPoolExecutor(max_workers=4) as pool:
    replies = pool.map(lambda _: request(), range(4))
    assert all(reply["result"] == identity for reply in replies)
# Fill the bounded workers with waits that cannot succeed, then disconnect.
waiters = []
try:
    for _ in range(4):
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        waiters.append(connection)
        connection.connect(str(directory / "s"))
        payload = payload_for(
            method="runtime.wait",
            params={"condition": "state.field_equals", "scope": "app", "field": "projectCount", "value": -1},
        )
        connection.sendall(struct.pack(">I", len(payload)) + payload)
    time.sleep(0.2)
    started = time.monotonic()
    for connection in waiters:
        connection.close()
    assert request()["result"] == identity
    assert time.monotonic() - started < 1.2, "Disconnected waits held all request slots"
finally:
    for connection in waiters:
        connection.close()

print("Live checks passed: identity, capabilities, permissions, authentication, version, allowlist, schema, malformed and oversized frames, replay, interrupted peer, four concurrent requests, disconnected wait cancellation.")
