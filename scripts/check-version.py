#!/usr/bin/env python3
"""Check that every published version string matches Sources/AgentDevKitCore/Version.swift."""
import argparse
import re
import subprocess
from pathlib import Path

if not __debug__:
    raise SystemExit("Verification requires Python assertions. Disable optimization and retry.")

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--cli", help="Built agentdevctl to compare with --version.")
parser.add_argument("--release", action="store_true",
                    help="Also require the vX.Y.Z tag on origin, so versioned doc links and Exact Version resolve.")
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent

version = re.search(r'current = "([0-9]+\.[0-9]+\.[0-9]+)"', (root / "Sources/AgentDevKitCore/Version.swift").read_text()).group(1)
problems = []

skill = (root / ".agents/skills/macos-agent-native/SKILL.md").read_text()
if f'version: "{version}"' not in skill:
    problems.append("SKILL.md metadata.version")

# Release links and install commands must name the current tag only.
for path in [root / "README.md", *sorted((root / ".agents/skills/macos-agent-native").rglob("*.md")), root / "Examples/AgentLab/README.md"]:
    for tag in set(re.findall(r"(?:tree/|blob/|--branch |Exact Version |tag )v?([0-9]+\.[0-9]+\.[0-9]+)", path.read_text())):
        if tag != version:
            problems.append(f"{path.relative_to(root)} names {tag}")

for project in sorted(root.glob("Examples/*/*.xcodeproj/project.pbxproj")):
    for marketing in set(re.findall(r"MARKETING_VERSION = ([0-9.]+);", project.read_text())):
        if marketing != version:
            problems.append(f"{project.relative_to(root)} MARKETING_VERSION {marketing}")

if args.cli:
    built = subprocess.check_output([args.cli, "--version"], text=True).strip()
    if built != version:
        problems.append(f"{args.cli} reports {built}")

if args.release:
    tags = subprocess.run(["git", "-C", str(root), "ls-remote", "--tags", "origin", f"refs/tags/v{version}"],
                          capture_output=True, text=True)
    if tags.returncode != 0 or not tags.stdout.strip():
        problems.append(f"tag v{version} is not on origin; docs link to it and Xcode resolves Exact Version from it")

assert not problems, f"Version {version} mismatches: " + "; ".join(problems)
print(f"Version {version} is consistent.")
