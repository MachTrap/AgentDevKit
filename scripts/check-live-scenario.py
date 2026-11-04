#!/usr/bin/env python3
"""Exercise the real AgentLab Inspector using a mutation-enabled test session."""
import argparse
import json
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("session_id")
parser.add_argument("--cli", default=".build/debug/agentdevctl")
args = parser.parse_args()

def run(*arguments, exit_code=0):
    command = [args.cli, "--session", args.session_id, *arguments, "--json"]
    response = subprocess.run(command, check=False, capture_output=True, text=True)
    result = json.loads(response.stdout)
    if response.returncode != exit_code:
        raise AssertionError(result)
    return result

capabilities = run("capabilities")["result"]
assert not capabilities["readOnly"]
assert "large-project-v1" in capabilities["fixtures"]

prepare = (
    "scenario", "prepare", "--fixture", "large-project-v1", "--route", "projects.editor.inspector",
    "--context", '{"nodeId":"node-42"}', "--wait-ready",
)
for _ in range(3):
    reply = run(*prepare)
    assert reply["status"] == "completed"
    result = reply["result"]
    assert result["fixture"]["fields"] == {"projectId": "fixture:large-project", "nodeId": "node-1"}
    screen = result["screen"]
    assert screen["ready"] is True
    assert screen["screenId"] == "projects.editor.inspector"
    assert screen["fields"]["nodeCount"] == 200
    assert screen["fields"]["nodeId"] == "node-42"
    assert screen["fields"]["nodeName"] == "Node 42"
    assert "notes" not in screen["fields"]
    assert run("state", "--scope", "current-screen")["result"] == screen

error = run(
    "scenario", "prepare", "--fixture", "empty-projects-v1", "--route", "projects.editor.inspector",
    exit_code=2,
)["error"]
assert error["details"]["phase"] == "navigation"
unchanged = run("state", "--scope", "current-screen")["result"]
assert unchanged["revision"] > screen["revision"]
assert {**unchanged, "revision": screen["revision"]} == screen
assert run("state", "--scope", "app")["result"]["fields"] == {"projectCount": 1}
print("Live scenario passed: three fixture/route runs, Inspector readiness, scoped state and failed-scenario preflight.")
