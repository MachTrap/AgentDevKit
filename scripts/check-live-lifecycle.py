#!/usr/bin/env python3
"""Verify paired and correlated lifecycle events against a running Testing app."""
import argparse
import json
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("session_id")
parser.add_argument("--cli", default=".build/debug/agentdevctl")
args = parser.parse_args()

def run(*arguments):
    raw = subprocess.check_output([args.cli, "--session", args.session_id, *arguments, "--json"], timeout=5)
    return json.loads(raw)

capabilities = run("capabilities")["result"]
inspector = next(route for route in capabilities["routes"] if route["id"] == "projects.editor.inspector")
assert inspector["windowId"] == "main" and inspector["accessibilityId"] == "screen.editor.inspector"
assert inspector["readinessGates"] == ["screen.appearance", "document.load"]
catalog = capabilities["lifecycle"]
assert {"kind": "screen", "name": "projects.editor.inspector"} in catalog
assert {"kind": "work", "name": "document.load"} in catalog
assert {"kind": "scenario", "name": "scenario.prepare"} in catalog

assert run("fixtures", "load", "--fixture", "basic-project-v1")["result"]["fixture"] == "basic-project-v1"
baseline = run("state")["result"]["revision"]
prepared = run("scenario", "prepare", "--fixture", "basic-project-v1", "--route", "projects.editor.inspector")
scenario_id = prepared["requestId"]
operation_id = prepared["result"]["screen"]["operationId"]
run("navigation", "open", "--route", "home")
slow = run("scenario", "prepare", "--fixture", "slow-project-v1", "--route", "projects.editor.inspector", "--no-wait")
run("navigation", "open", "--route", "home")
cancelled = run("wait", "--condition", "lifecycle.ended", "--operation", slow["result"]["screen"]["operationId"])["result"]
assert cancelled["satisfied"] and cancelled["lifecycle"]["outcome"] == "cancelled"
assert cancelled["screen"]["screenId"] == "home"
failed = subprocess.run(
    [args.cli, "--session", args.session_id, "scenario", "prepare", "--fixture", "network-error-v1",
     "--route", "projects.editor", "--json"],
    capture_output=True, text=True, timeout=5,
)
assert failed.returncode == 4
failure = json.loads(failed.stdout)
assert failure["error"]["code"] == "NOT_READY"
events = run("observe", "--since", str(baseline), "--limit", "100")["result"]["delta"]["events"]
traces = [event["lifecycle"] for event in events if "lifecycle" in event]

def pair(id, kind, outcome, parent=None):
    matches = [event for event in traces if event["id"] == id]
    assert [event["phase"] for event in matches] == ["began", "ended"], matches
    assert all(event["kind"] == kind and event.get("parentId") == parent for event in matches)
    assert matches[-1]["outcome"] == outcome
    assert matches[-1]["durationMs"] >= 0
    return matches

pair(scenario_id, "scenario", "completed")
pair(operation_id, "work", "completed", scenario_id)
fixture_save = next(event for event in traces if event["name"] == "workspace.save" and
                    event["phase"] == "began" and event.get("parentId") == scenario_id)
pair(fixture_save["id"], "work", "completed", scenario_id)
screen = next(event for event in traces if event["kind"] == "screen" and
              event["phase"] == "began" and event.get("parentId") == scenario_id)
pair(screen["id"], "screen", "superseded", scenario_id)
pair(slow["requestId"], "scenario", "accepted")
pair(slow["result"]["screen"]["operationId"], "work", "cancelled", slow["requestId"])
pair(failure["requestId"], "scenario", "failed")
failed_work = next(event for event in traces if event["name"] == "document.load" and
                   event["phase"] == "began" and event.get("parentId") == failure["requestId"])
pair(failed_work["id"], "work", "failed", failure["requestId"])
print("Live lifecycle passed: paired screen, scenario and work spans for completion, cancellation and failure.")
