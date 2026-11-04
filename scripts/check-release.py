#!/usr/bin/env python3
"""Audit the shipping binary and exercise Testing and Release lifecycles."""
import argparse
import contextlib
import json
import plistlib
import re
import subprocess
import sys
import time
from pathlib import Path

if not __debug__:
    raise SystemExit("Verification requires Python assertions. Disable optimization and retry.")

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--release", type=Path, required=True)
parser.add_argument("--testing", type=Path, required=True)
parser.add_argument("--link-map", type=Path, required=True, help="One link map from the Release build. Universal builds require its sibling maps.")
parser.add_argument("--settings", type=Path, required=True)
parser.add_argument("--cli", default=".build/debug/agentdevctl")
args = parser.parse_args()

def app_info(app):
    with (app / "Contents/Info.plist").open("rb") as info:
        return plistlib.load(info)

release_info = app_info(args.release)
release_id = release_info["CFBundleIdentifier"]
release = args.release / "Contents/MacOS" / release_info["CFBundleExecutable"]
testing = args.testing / "Contents/MacOS" / app_info(args.testing)["CFBundleExecutable"]
assert release_id != app_info(args.testing)["CFBundleIdentifier"]
assert not release_info.get("CFBundleURLTypes")
settings = json.loads(args.settings.read_text())
release_settings = next(entry["buildSettings"] for entry in settings if entry["target"] == "AgentLab")
assert release_settings["CONFIGURATION"] == "Release"
assert release_settings["PRODUCT_BUNDLE_IDENTIFIER"] == release_id
assert "AGENT_DEVKIT" not in release_settings.get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "").split()
def binary_uuids(binary):
    listing = subprocess.check_output(["xcrun", "dwarfdump", "--uuid", str(binary)], text=True)
    return {arch: uuid for uuid, arch in re.findall(r"^UUID: ([0-9A-Fa-f-]+) \(([^)]+)\)", listing, re.MULTILINE)}

architectures = subprocess.check_output(["lipo", "-archs", str(release)], text=True).split()
assert architectures, "Release binary has no architecture slices"
shipping_uuids = binary_uuids(release)
assert set(shipping_uuids) == set(architectures), "Release UUIDs do not cover every architecture"
symbols = subprocess.check_output(["nm", "-arch", "all", str(release)], text=True)
libraries = subprocess.check_output(["otool", "-arch", "all", "-L", str(release)], text=True)
link_maps = []
for architecture in architectures:
    path = args.link_map if len(architectures) == 1 else (
        args.link_map.parent / f"{release.name}-LinkMap-normal-{architecture}.txt"
    )
    assert path.is_file(), f"Release link map missing for {architecture}: {path}"
    contents = path.read_text()
    header = contents.splitlines()[:2]
    assert len(header) == 2 and header[0].startswith("# Path: "), f"Invalid link map: {path}"
    linked_binary = Path(header[0].removeprefix("# Path: "))
    assert linked_binary.name == release.name and linked_binary.is_file(), f"Missing or wrong linked binary: {path}"
    assert header[1] == f"# Arch: {architecture}", f"Wrong architecture in link map: {path}"
    assert binary_uuids(linked_binary).get(architecture) == shipping_uuids[architecture], (
        f"Release link map refers to a different {architecture} build: {path}"
    )
    link_maps.append(contents)

for evidence in [symbols, libraries, *link_maps, release.read_bytes().decode("latin1")]:
    assert not re.search(
        r"AgentDevKit(?:Core|Host|Transport)|LabRuntime|LabCommands|TestingSession|TestingWorkspace|"
        r"agentdevkit-legacy-overflow|enable-agentdevkit|allow-agentdevkit-mutations|long-node-names-v1",
        evidence,
    ), "Release contains Testing implementation or activation flags"

def cli(*arguments):
    return subprocess.run([args.cli, *arguments, "--json"], capture_output=True, text=True, timeout=4)

def discover():
    response = cli("session", "list")
    response.check_returncode()
    return json.loads(response.stdout)

def wait_for_session(process):
    deadline = time.monotonic() + 8
    while process.poll() is None and time.monotonic() < deadline:
        match = next((item for item in discover() if item["pid"] == process.pid), None)
        if match:
            return match["sessionId"]
        time.sleep(.1)
    raise AssertionError("Testing app did not publish its session")

def reject(selector):
    result = cli("--session", selector, "session", "ping")
    assert result.returncode == 3, result.stdout
    assert json.loads(result.stdout)["error"]["code"] == "SESSION_EXPIRED"

def stop(process):
    if process.poll() is None:
        process.kill()
    process.wait(timeout=4)

temp = Path(subprocess.check_output(["getconf", "DARWIN_USER_TEMP_DIR"], text=True).strip())
flags = ["--enable-agentdevkit", "--allow-agentdevkit-mutations", "--agentdevkit-legacy-overflow"]
bridge_flags = ["--enable-agentdevkit"]
with contextlib.ExitStack() as cleanup:
    def launch(executable, activation):
        process = subprocess.Popen([executable, *activation], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cleanup.callback(stop, process)
        return process

    def own_session(id, process):
        directory = temp / "adk" / id
        def clear():
            stop(process)
            for file in ["s", "session.json", "pending"]:
                (directory / file).unlink(missing_ok=True)
            directory.rmdir()
        cleanup.callback(clear)
        return directory

    control = launch(testing, bridge_flags)
    session = wait_for_session(control)
    stale = own_session(session, control)
    token = json.loads((stale / "session.json").read_text())["auth"]
    shipping = launch(release, flags)
    subprocess.run(
        [sys.executable, str(Path(__file__).with_name("check-live-bridge.py")), session, "--cli", args.cli],
        check=True,
    )
    assert shipping.poll() is None, "Release exited before runtime probe"
    assert all(item["pid"] != shipping.pid for item in discover())
    reject(release_id)

    # An abrupt exit leaves an actual stale socket and descriptor behind.
    stop(control)
    assert (stale / "session.json").is_file()
    reject(session)
    restarted = launch(testing, bridge_flags)
    new_id = wait_for_session(restarted)
    assert new_id != session
    new_directory = own_session(new_id, restarted)
    assert json.loads((new_directory / "session.json").read_text())["auth"] != token, "Session credential was reused"
    assert all(item["sessionId"] != session for item in discover())
    assert cli("--session", new_id, "session", "ping").returncode == 0

print(f"Release and lifecycle checks passed for {', '.join(architectures)}: build settings, link maps, binary, negative probe, crash, restart and credential rotation.")
