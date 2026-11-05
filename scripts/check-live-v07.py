#!/usr/bin/env python3
"""Verify the v0.6–v0.7 features on one mutation-enabled AgentLab session, through the real CLI.

Launch first, for example:
  .build/debug/agentdevctl launch PATH/AgentLab-AgentTesting.app --mutations --replace --background --wait screen.ready
"""
import argparse
import json
import os
import subprocess
import tempfile
import threading
import time
from pathlib import Path

if not __debug__:
    raise SystemExit("Verification requires Python assertions. Disable optimization and retry.")

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("session_id")
parser.add_argument("--cli", default=".build/debug/agentdevctl")
parser.add_argument("--recipes", default="Examples/AgentLab/recipes")
args = parser.parse_args()
cli = [args.cli, "--session", args.session_id]


def run(*arguments, exit_code=0, raw=False):
    result = subprocess.run(cli + list(arguments) + ([] if raw else ["--json"]), check=False, capture_output=True, text=True)
    assert result.returncode == exit_code, (arguments, result.returncode, result.stdout, result.stderr)
    return result.stdout if raw else json.loads(result.stdout)


def state():
    return run("state")["result"]


checks = []

# 1 · Discoverable errors
typo = run("wait", "--condition", "state.feild_equals", "--field", "density", "--value", "regular", exit_code=2)["error"]
assert typo["details"]["closest"] == "state.field_equals", typo
example = typo["details"]["example"].split()
assert example[:2] == ["agentdevctl", "wait"], example
run("navigation", "open", "--route", "settings.controls")
assert run(*example[1:])["result"]["satisfied"], "The suggested example runs."
alias = run("wait", "--condition", "state.fieldEquals", "--field", "density", "--value", "regular")["result"]
assert alias["condition"] == "state.field_equals"
for command, code, closest in [
    (["navigation", "open", "--route", "settings.control"], "ROUTE_NOT_FOUND", "settings.controls"),
    (["fixtures", "load", "--fixture", "basic-projct"], "FIXTURE_NOT_FOUND", "basic-project-v1"),
    (["action", "invoke", "--id", "queue.toggel"], "ACTION_NOT_FOUND", "queue.toggle"),
    (["state", "--scope", "windo:main"], "INVALID_PARAMS", "window:main"),
]:
    error = run(*command, exit_code=2 if code == "INVALID_PARAMS" else 4)["error"]
    assert error["code"] == code and error["details"]["closest"] == closest, error
checks.append("errors name the closest ID and a runnable example")

# 2 · Shell-friendly CLI
environment = dict(os.environ, AGENTDEVKIT_SESSION=args.session_id)
for shell in ["zsh", "bash"]:
    out = subprocess.run([shell, "-c", f'S="--session {args.session_id}"; {args.cli} $S state --field density'],
                         check=True, capture_output=True, text=True).stdout.strip()
    assert out == "regular", (shell, out)
with tempfile.TemporaryDirectory() as folder:
    Path(folder, ".agentdevkit.json").write_text(json.dumps({"session": args.session_id}))
    nested = Path(folder, "a", "b")
    nested.mkdir(parents=True)
    plain = subprocess.run([str(Path(args.cli).resolve()), "state", "--fields", "density,queued,revision"], cwd=nested,
                           check=True, capture_output=True, text=True, env={k: v for k, v in os.environ.items() if k != "AGENTDEVKIT_SESSION"})
    assert set(json.loads(plain.stdout)) == {"density", "queued", "revision"}
missing = subprocess.run([args.cli, "state", "--field", "nope"], env=environment, capture_output=True, text=True)
assert missing.returncode == 4
assert run("wait", "--until", "density=regular")["result"]["condition"] == "state.field_equals"
usage = subprocess.run([args.cli, "state", "--bogus"], env=environment, capture_output=True, text=True)
assert usage.returncode == 2 and "Usage: agentdevctl [--session ID_OR_BUNDLE] state" in usage.stderr and "scenario" not in usage.stderr
checks.append("default sessions, zsh/bash splitting, --field/--fields, --until and per-command usage")

# 3 · Tracked operations
started = time.monotonic()
accepted = run("fixtures", "load", "--fixture", "slow-fixture-v1")
assert time.monotonic() - started < 3 and accepted["status"] == "accepted"
operation = accepted["result"]["operationId"]
busy = run("action", "invoke", "--id", "queue.toggle", "--args", '{"names":["Desktop"]}', exit_code=4)["error"]
assert busy["code"] == "CONFLICT" and busy["details"]["operationId"] == operation
assert run("wait", "--operation", operation, "--timeout-ms", "10000")["result"]["satisfied"]
status = run("operations", "status", "--operation", operation)["result"]
assert status["state"] == "completed" and status["result"]["fixture"] == "slow-fixture-v1"
followed = run("fixtures", "load", "--fixture", "slow-fixture-v1", "--wait")
assert followed["status"] == "completed" and "operationId" not in followed["result"]
run("navigation", "open", "--route", "settings.controls")
panel = run("action", "invoke", "--id", "controls.import")["result"]
assert panel["outcome"] == "accepted"
time.sleep(1)
listed = [item for item in run("operations", "list")["result"] if item["id"] == panel["operationId"]]
assert listed and listed[0]["awaitingUser"], listed
run("ui", "dismiss")
run("wait", "--condition", "lifecycle.ended", "--operation", panel["operationId"])
cancelled = run("operations", "status", "--operation", panel["operationId"])["result"]
assert cancelled["state"] == "cancelled", cancelled
checks.append("slow fixture accepted then completed, --wait, open panel awaitingUser then dismissed")

# 4 · Whole active UI
run("ui", "press", "--id", "controls.display")
time.sleep(0.4)
surfaces = run("ui", "surfaces")["result"]["surfaces"]
popover = next(item for item in surfaces if item["kind"] == "popover")
assert popover["parentId"] == "main"
capture = run("ui", "capture")["result"]
assert capture["mode"] == "active" and capture["surfaces"] == ["main", popover["id"]], capture
assert "popoverChrome" in capture["approximations"]
revision = state()["revision"]
assert run("ui", "capture", "--revision", str(revision))["ok"]
snapshot = run("ui", "snapshot", "--only-identified")["result"]
assert snapshot["revision"] == snapshot["tree"]["revision"] == snapshot["capture"]["revision"]
checks.append("surfaces list the popover; active capture composites it; revision-bound capture and snapshot")

# 5 · Targeting and typed operations
tree = run("ui", "tree", "--window", popover["id"])["result"]["elements"]
slider = next(item for item in tree if item.get("identifier") == "controls.detail")
assert slider["numericValue"] == 2 and slider["valueDescription"] == "Standard" and slider["maxValue"] == 4
assert run("ui", "set", "--id", "controls.detail", "--value", "4")["result"]["numericValue"] == 4
assert state()["fields"]["detailName"] == "Complete"
run("ui", "dismiss")
run("ui", "choose", "--id", "controls.density", "--item", "Compact")
assert state()["fields"]["density"] == "compact"
run("ui", "expand", "--role", "disclosuretriangle", "--label", "Advanced")
assert state()["fields"]["advancedExpanded"] is True
lint = run("ui", "tree", "--lint", "--prefix", "queue")["result"]["lint"]
assert any(item["kind"] == "copiedDown" and item["identifier"] == "queueRow" for item in lint), lint
ambiguous = run("ui", "press", "--id", "queueRow", exit_code=4)["error"]
assert ambiguous["code"] == "AMBIGUOUS_ELEMENT" and len(ambiguous["details"]["paths"]) == 6
desktop = next(path for path in ambiguous["details"]["paths"] if path.endswith("queueRow[2]"))
run("ui", "press", "--path", desktop)
assert state()["fields"]["queued"] == ["Desktop"]
run("ui", "set", "--role", "checkbox", "--label", "Desktop", "--value", "false")
assert state()["fields"]["queued"] == []
checks.append("slider set, menu choose, disclosure expand, copy-down lint, ambiguity, press by path and role")

# 7 · In-process input
run("fixtures", "load", "--fixture", "basic-project-v1")
run("navigation", "open", "--route", "settings.controls")
run("ui", "key", "--keys", "Down Space")
assert state()["fields"]["queued"] == ["Desktop"]
run("ui", "hover", "--role", "checkbox", "--label", "Documents")
assert state()["fields"]["hovered"] == "Documents"
assert any(item.get("identifier") == "controls.hover-card" for item in run("ui", "tree", "--prefix", "controls.hover")["result"]["elements"])
checks.append("arrow keys move and toggle the queue; hover shows the hover card")

# 9 · Invariants
start = state()["revision"]
run("action", "invoke", "--id", "controls.seedMapBug", "--args", '{"enabled": true}')
run("action", "invoke", "--id", "queue.toggle", "--args", '{"names":["Downloads"]}')
report = run("invariants")["result"]
assert not report["invariants"][0]["holds"]
observed = run("observe", "--since", str(start))["result"]["violations"]
assert observed[0]["id"] == "queue.mapConsistent" and observed[0]["revision"] > start
run("wait", "--until", "invariants.hold", "--timeout-ms", "500", exit_code=5)
run("action", "invoke", "--id", "controls.seedMapBug", "--args", '{"enabled": false}')
assert run("wait", "--until", "invariants.hold")["result"]["satisfied"]
checks.append("invariant violation reported with its revision and resolved")

# 8 · Recipes
passing = subprocess.run(cli + ["recipe", "run", f"{args.recipes}/queue-map.json", "--json"], capture_output=True, text=True)
report = json.loads(passing.stdout)
assert passing.returncode == 0 and report["passed"] and report["rounds"] == 5, report
assert all(burst["revisionAfter"] - burst["revisionBefore"] == 3 for burst in report["bursts"])
with tempfile.TemporaryDirectory() as output:
    seeded = subprocess.run(cli + ["recipe", "run", f"{args.recipes}/queue-map-seeded-failure.json", "--out", output, "--json"],
                            capture_output=True, text=True)
    report = json.loads(seeded.stdout)
    assert seeded.returncode == 4 and report["failure"]["step"] == "6", report
    assert report["failure"]["observed"] == ["Downloads", "Desktop"]
    assert Path(report["failure"]["snapshot"], "capture.png").exists()
run("action", "invoke", "--id", "controls.seedMapBug", "--args", '{"enabled": false}')
checks.append("recipe passes five rounds with back-to-back bursts; seeded failure names step, values and snapshot")

# 10 · Operator prompts, answered by a scripted press on the panel
ticket = run("operator", "ask", "--question", "Did a dialog appear?", "--options", "Yes,No")["result"]
time.sleep(0.5)
panel = next(item for item in run("ui", "surfaces")["result"]["surfaces"] if item["id"].startswith("agentdevkit.operator"))
assert panel["title"] == "Agent question (Testing build)"
run("ui", "press", "--window", panel["id"], "--id", "operator.option.0")
run("wait", "--operation", ticket["operationId"])
assert run("operator", "answer", "--operation", ticket["operationId"])["result"]["answer"] == "Yes"
late = run("operator", "ask", "--question", "Anyone?", "--answer-timeout-ms", "1000", "--wait")["result"]
assert late["status"] == "unanswered"
checks.append("operator question answered in the labelled panel; timeout reports unanswered")

# 12 and 14 · File fixture, experiments, privacy probe
loaded = run("fixtures", "load", "--fixture", "files-v1")["result"]["fields"]
assert loaded["root"].startswith("/private/") and loaded["duplicateGroups"] == 1
probe = run("experiment", "run", "--id", "probe.stat", "--args", '{"path":"Downloads/installer.dmg"}')["result"]["fields"]
assert probe["bytes"] == 2_097_152
assert run("diagnostics", "recent", "--category", "experiment", "--limit", "1")["result"][0]["message"].startswith('inputs={"path"')
assert set(run("tcc", "status")["result"]) >= {"fullDiskAccess", "accessibility", "screenRecording"}
refused = subprocess.run([args.cli, "tcc", "reset", "--bundle", "com.apple.Safari"], capture_output=True, text=True)
assert refused.returncode == 4 and "not a Testing bundle" in refused.stderr
checks.append("canonical file fixture, recorded experiment, privacy probe, TCC refusal of a shipping bundle")

# 13 · Visual baselines
with tempfile.TemporaryDirectory() as folder:
    run("scenario", "prepare", "--fixture", "basic-project-v1", "--route", "settings.controls")
    template = f"{folder}/controls-{{locale}}-{{appearance}}.png"
    first = run("ui", "capture", "--mode", "window", "--baseline", template)["result"]["baseline"]
    assert first["created"]
    assert run("ui", "capture", "--mode", "window", "--baseline", template)["result"]["baseline"]["matched"]
    run("action", "invoke", "--id", "queue.toggle", "--args", '{"names":["Desktop"]}')
    moved = run("ui", "capture", "--mode", "window", "--baseline", template, "--threshold", "0.0001", exit_code=4)["result"]["baseline"]
    assert not moved["matched"] and Path(moved["diff"]).exists()
checks.append("baseline created, matched, then mismatched with a diff image")

for line in checks:
    print("ok  " + line)
print(f"Live v0.7 checks passed: {len(checks)} groups.")
