#!/usr/bin/env python3
"""Verify tracked work and semantic saves on one mutation-enabled AgentLab session."""
import argparse
import json
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("session_id")
parser.add_argument("--cli", default=".build/debug/agentdevctl")
args = parser.parse_args()

def run(*arguments, exit_code=0):
    result = subprocess.run(
        [args.cli, "--session", args.session_id, *arguments, "--json"],
        check=False, capture_output=True, text=True,
    )
    reply = json.loads(result.stdout)
    assert result.returncode == exit_code, reply
    return reply

capabilities = run("capabilities")["result"]
assert set(capabilities["actions"]) == {"inspector.save", "settings.appearance.save"}
unknown = run("action", "invoke", "--id", "unregistered.save", "--args", "{}", exit_code=4)
assert unknown["error"]["code"] == "UNKNOWN_METHOD"

scenario = ("scenario", "prepare", "--fixture")
route = ("--route", "projects.editor.inspector")
pending = run(*scenario, "slow-project-v1", *route, "--no-wait")
assert pending["status"] == "accepted"
screen = pending["result"]["screen"]
assert screen["blockers"] == ["document.load"]
timeout = run("wait", "--condition", "screen.ready", "--timeout-ms", "400", exit_code=5)
assert timeout["error"]["details"] == {"blockers": "document.load"}
finished = run("wait", "--condition", "operation.completed", "--operation", screen["operationId"])["result"]
assert finished["satisfied"]
assert run("wait", "--condition", "screen.ready")["result"]["screen"]["ready"]

failed = run(*scenario, "network-error-v1", *route, exit_code=4)
assert failed["error"]["code"] == "NOT_READY"
diagnostic = run("diagnostics", "recent", "--category", "document", "--severity", "error", "--limit", "1")["result"][0]
assert diagnostic["code"] == "DOCUMENT_LOAD_FAILED" and diagnostic["correlationId"] == failed["requestId"]

before = run("navigation", "open", *route)["result"]
save = ("action", "invoke", "--id", "inspector.save", "--args", '{"name":"Saved through the action"}')
updated = run(*save, "--revision", str(before["revision"]))
after = updated["result"]
assert after["fields"]["nodeName"] == "Saved through the action"
assert run(*save, "--revision", str(before["revision"]), exit_code=3)["error"]["code"] == "CONFLICT"
assert run("state")["result"] == after
events = run("events", "since", "--revision", str(before["revision"]), "--limit", "3")["result"]
assert [event["type"] for event in events["events"]] == ["work.started", "work.finished", "node.saved"]
started, finished, _ = events["events"]
assert started["lifecycle"]["name"] == "workspace.save"
assert started["lifecycle"]["id"] == finished["lifecycle"]["id"]
assert finished["lifecycle"]["outcome"] == "completed"
assert "Saved through the action" not in json.dumps(events)
assert all(event["correlationId"] == updated["requestId"] for event in events["events"])
assert events["nextRevision"] == after["revision"] and not events["hasMore"]
observation = run("observe", "--since", str(before["revision"]), "--limit", "3")["result"]
assert observation == {"screen": after, "delta": events, "resynced": False}
assert run("wait", "--condition", "state.field_equals", "--field", "nodeName", "--value", '"Saved through the action"')["result"]["satisfied"]
print("Live runtime passed: timeout blocker, completion, fault diagnostic, correlated save event and stale-save rejection.")
