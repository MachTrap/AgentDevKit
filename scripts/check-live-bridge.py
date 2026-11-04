#!/usr/bin/env python3
"""Check an explicitly selected, running AgentLab-AgentTesting session."""
import argparse
import base64
import contextlib
import hashlib
from concurrent.futures import ThreadPoolExecutor
import json
import os
import socket
import ssl
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
source = parser.add_mutually_exclusive_group()
source.add_argument("--app-group")
source.add_argument("--pairing-dir", type=Path)
args = parser.parse_args()
session_id = str(args.session_id).upper()
flags = []
if args.app_group:
    flags = ["--app-group", args.app_group]
elif args.pairing_dir:
    flags = ["--pairing-dir", str(args.pairing_dir)]
cli = [args.cli, *flags, "--session", session_id]
identity = json.loads(subprocess.check_output(cli + ["session", "ping", "--json"]))["result"]
bundle = "dev.agentdevkit.AgentTesting"
if args.app_group:
    bundle = "dev.agentdevkit.AgentLab.AppGroupTesting"
elif args.pairing_dir:
    bundle = "dev.agentdevkit.AgentLab.LoopbackTesting"
assert identity["bundleId"] == bundle
capabilities = json.loads(subprocess.check_output(cli + ["capabilities", "--json"]))["result"]
assert capabilities["app"] == identity
assert capabilities["readOnly"]
assert set(capabilities["methods"]) == {
    "system.hello", "system.capabilities", "state.snapshot", "state.observe", "actions.list",
    "diagnostics.recent", "events.since", "runtime.wait",
}
assert capabilities["fixtures"] == [] and capabilities["routes"] == [] and capabilities["actions"] == []

if args.app_group:
    directory = Path.home() / "Library" / "Group Containers" / args.app_group / "a" / session_id.replace("-", "")[:16]
elif args.pairing_dir:
    directory = args.pairing_dir / "adk" / session_id
else:
    temp = Path(subprocess.check_output(["getconf", "DARWIN_USER_TEMP_DIR"], text=True).strip())
    directory = temp / "adk" / session_id
descriptor = directory / "session.json"
mode_checks = [(directory, 0o700), (descriptor, 0o600)]
if not args.pairing_dir:
    mode_checks.append((directory / "s", 0o600))
for path, mode in mode_checks:
    stat = path.lstat()
    assert stat.st_uid == os.geteuid() and stat.st_mode & 0o777 == mode
descriptor_bytes = descriptor.read_bytes()
credentials = json.loads(descriptor_bytes)
credential = credentials["auth"]

if args.pairing_dir:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.minimum_version = ssl.TLSVersion.TLSv1_3
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE  # The exact leaf is verified before a request is written.
    expected_pin = base64.b64decode(credentials["certificatePin"])

def connect():
    if args.pairing_dir:
        with contextlib.ExitStack() as stack:
            raw = stack.enter_context(socket.create_connection(("127.0.0.1", credentials["port"]), timeout=3))
            secure = stack.enter_context(context.wrap_socket(raw))
            assert hashlib.sha256(secure.getpeercert(binary_form=True)).digest() == expected_pin
            assert secure.version() == "TLSv1.3"
            stack.pop_all()
            return secure
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.settimeout(3)
        sock.connect(str(directory / "s"))
        return sock
    except BaseException:
        sock.close()
        raise

def probe(payload, length=None):
    with connect() as sock:
        sock.sendall(struct.pack(">I", len(payload) if length is None else length) + payload)
        with sock.makefile("rb") as stream:
            size = struct.unpack(">I", stream.read(4))[0]
            return json.loads(stream.read(size))

if args.pairing_dir:
    # Change only the pin in this selected Testing descriptor. The real CLI
    # must reject the real listener and recover after the pin is restored.
    wrong = {**credentials, "certificatePin": base64.b64encode(bytes(32)).decode()}
    staged = directory / "verification-pending"
    def replace_descriptor(data):
        fd = os.open(staged, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as output:
            output.write(data)
        os.replace(staged, descriptor)
    try:
        replace_descriptor(json.dumps(wrong).encode())
        failed = subprocess.run(cli + ["session", "ping", "--json"], capture_output=True)
        assert failed.returncode != 0 and b"SESSION_EXPIRED" in failed.stdout, failed
    finally:
        replace_descriptor(descriptor_bytes)

    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as route:
        route.connect(("192.0.2.1", 1))
        address = route.getsockname()[0]
    try:
        remote = socket.create_connection((address, credentials["port"]), timeout=1)
    except OSError:
        pass
    else:
        remote.close()
        raise AssertionError("Loopback port accepted a connection on a non-loopback address")

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
with connect() as abandoned:
    abandoned.sendall(struct.pack(">I", 300) + b"{")
with ThreadPoolExecutor(max_workers=4) as pool:
    replies = pool.map(lambda _: request(), range(4))
    assert all(reply["result"] == identity for reply in replies)
# Fill the bounded workers with waits that cannot succeed, then disconnect.
waiters = []
try:
    for _ in range(4):
        connection = connect()
        waiters.append(connection)
        payload = payload_for(
            method="runtime.wait",
            params={"condition": "state.field_equals", "scope": "app", "field": "projectCount", "value": -1},
        )
        connection.sendall(struct.pack(">I", len(payload)) + payload)
    time.sleep(0.2)
    started = time.monotonic()
    for connection in waiters:
        connection.close()
    while True:
        try:
            assert request()["result"] == identity
            break
        except (OSError, struct.error):
            if time.monotonic() - started >= 1.2:
                raise
            time.sleep(0.05)
    assert time.monotonic() - started < 1.2, "Disconnected waits held all request slots"
finally:
    for connection in waiters:
        connection.close()

print("Live checks passed: identity, capabilities, permissions, authentication, version, allowlist, schema, malformed and oversized frames, replay, interrupted peer, four concurrent requests, disconnected wait cancellation.")
