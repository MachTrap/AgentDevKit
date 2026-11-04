#!/usr/bin/env python3
"""Measure composed Inspector setup on a mutation-enabled AgentLab session."""
import argparse
import json
import statistics
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("session_id")
parser.add_argument("--cli", default=".build/debug/agentdevctl")
args = parser.parse_args()

def invoke(*arguments):
    return subprocess.check_output([args.cli, "--session", args.session_id, *arguments, "--json"], timeout=6)

def prepare(route):
    return invoke("scenario", "prepare", "--fixture", "long-node-names-v1", "--route", route)

samples = []
for _ in range(3):
    home = json.loads(prepare("home"))["result"]["screen"]
    assert home["screenId"] == "home" and home["ready"]
    start = time.perf_counter()
    response = prepare("projects.editor.inspector")
    elapsed = (time.perf_counter() - start) * 1_000
    screen = json.loads(response)["result"]["screen"]
    assert screen["screenId"] == "projects.editor.inspector" and screen["ready"]
    assert screen["fields"]["nodeId"] == "node-1"
    samples.append({"milliseconds": round(elapsed, 1), "responseBytes": len(response)})

print(json.dumps({
    "fixture": "long-node-names-v1",
    "destination": "projects.editor.inspector",
    "commandsPerRun": 1,
    "screenshotsPerRun": 0,
    "samples": samples,
    "medianMilliseconds": statistics.median(sample["milliseconds"] for sample in samples),
    "failures": 0,
}, indent=2))
