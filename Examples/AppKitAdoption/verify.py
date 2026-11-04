#!/usr/bin/env python3
"""Compare the existing AppKit controls with read-only state and audit Release."""
import argparse
import contextlib
import json
from pathlib import Path
import subprocess
import time

if not __debug__:
    raise SystemExit("Verification requires Python assertions. Disable optimization and retry.")

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--derived-data", type=Path, default=Path(".build/AppKitAdoption"))
parser.add_argument("--cli", default=".build/debug/agentdevctl")
args = parser.parse_args()

products = args.derived_data / "Build/Products"
testing = products / "Debug/AppKitDocuments-AgentTesting.app/Contents/MacOS/AppKitDocuments-AgentTesting"
shipping = products / "Release/AppKitDocuments.app/Contents/MacOS/AppKitDocuments"
ax = Path(__file__).with_name("VerifyAccessibility.swift")
temp = Path(subprocess.check_output(["getconf", "DARWIN_USER_TEMP_DIR"], text=True).strip())

def sessions():
    return json.loads(subprocess.check_output([args.cli, "session", "list", "--json"], timeout=4))

@contextlib.contextmanager
def launch(app, *flags):
    process = subprocess.Popen([app, *flags])
    try:
        yield process
    finally:
        if process.poll() is None:
            process.kill()
        process.wait(timeout=4)

def verify_ui(process, action, value):
    subprocess.run(["swift", ax, str(process.pid), action, value], check=True, timeout=15)

for command in [["nm", "-arch", "all", shipping], ["otool", "-arch", "all", "-L", shipping]]:
    listing = subprocess.check_output(command, text=True)
    assert "AgentDevKit" not in listing and "TestingBridge" not in listing
assert b"--enable-agentdevkit" not in shipping.read_bytes()

for app, flags in [(shipping, ["--enable-agentdevkit"]), (testing, [])]:
    with launch(app, *flags) as process:
        verify_ui(process, "selected", "Draft")
        verify_ui(process, "press", "documents.review")
        verify_ui(process, "selected", "Review")
        assert all(session["pid"] != process.pid for session in sessions())
        verify_ui(process, "press", "documents.close")
        assert process.wait(timeout=5) == 0

with launch(testing, "--enable-agentdevkit") as process:
    verify_ui(process, "selected", "Draft")
    deadline = time.monotonic() + 5
    session = None
    while session is None and time.monotonic() < deadline:
        session = next((item for item in sessions() if item["pid"] == process.pid), None)
        if session is None:
            time.sleep(0.1)
    assert session is not None, "Testing app did not publish its endpoint"
    session_id = session["sessionId"]
    endpoint = temp / "adk" / session_id
    prefix = [args.cli, "--session", session_id]
    capability = json.loads(subprocess.check_output(prefix + ["capabilities", "--json"], timeout=4))["result"]
    assert capability["readOnly"] and capability["scopes"] == ["selected-document"]
    assert capability["app"]["pid"] == process.pid

    def state():
        result = subprocess.check_output(prefix + ["state", "--scope", "selected-document", "--json"], timeout=4)
        return json.loads(result)["result"]

    initial = state()
    assert initial["ready"] and initial["fields"] == {"selectedDocumentId": "draft"}
    assert initial["revision"] == 0
    verify_ui(process, "press", "documents.review")
    verify_ui(process, "selected", "Review")
    selected = state()
    assert selected["ready"] and selected["fields"] == {"selectedDocumentId": "review"}
    assert selected["revision"] == 1
    rejected = subprocess.run(
        prefix + ["fixtures", "load", "--fixture", "unregistered", "--json"],
        capture_output=True, text=True, timeout=4,
    )
    assert rejected.returncode == 4 and json.loads(rejected.stdout)["error"]["code"] == "UNKNOWN_METHOD"
    verify_ui(process, "press", "documents.close")
    assert process.wait(timeout=5) == 0
    assert not endpoint.exists() and all(item["sessionId"] != session_id for item in sessions())

print("AppKit adoption passed: AX selection, live read-only state, opt-in, graceful cleanup and shipping exclusion.")
print("Testing build fingerprint:", session["buildFingerprint"])
