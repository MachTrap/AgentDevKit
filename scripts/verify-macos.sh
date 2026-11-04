#!/usr/bin/env bash
# The same release gate runs locally and in GitHub Actions.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

project=Examples/AgentLab/AgentLab.xcodeproj
destination="platform=macOS,arch=$(uname -m)"
root=${ADK_VERIFICATION_BUILD_ROOT:-.build/macos-verification}
run_swift() {
  if [[ ${ADK_SWIFT_DISABLE_SANDBOX:-0} == 1 ]]; then
    swift "$@" --disable-sandbox
  else
    swift "$@"
  fi
}
run_swift test
run_swift build -c release --product agentdevctl
test "$(.build/release/agentdevctl --version)" = 0.2.0
run_swift build --package-path Tools/MCP --force-resolved-versions -c release --product agentdevkit-mcp

xcodebuild -project "$project" -scheme AgentLab-AgentTesting -destination "$destination" \
  -derivedDataPath "$root/testing" build
xcodebuild -project "$project" -scheme AgentLab-Release -destination "$destination" \
  -derivedDataPath "$root/release" LD_GENERATE_MAP_FILE=YES build
xcodebuild -project "$project" -scheme AgentLab-Release -destination "$destination" \
  -derivedDataPath "$root/release" -showBuildSettings -json > "$root/release/settings.json"

log="$root/release/testing-release.log"
if xcodebuild -project "$project" -scheme AgentLab-AgentTesting -configuration Release \
  -destination "$destination" -derivedDataPath "$root/rejected" build > "$log" 2>&1; then
  cat "$log"
  exit 1
fi
grep -F 'AgentLab-AgentTesting can only build in Debug configuration' "$log"
test ! -e "$root/rejected/Build/Products/Release/AgentLab-AgentTesting.app/Contents/MacOS/AgentLab-AgentTesting"

python3 scripts/check-release.py \
  --release "$root/release/Build/Products/Release/AgentLab.app" \
  --testing "$root/testing/Build/Products/Debug/AgentLab-AgentTesting.app" \
  --link-map "$root/release/Build/Intermediates.noindex/AgentLab.build/Release/AgentLab.build/AgentLab-LinkMap-normal-$(uname -m).txt" \
  --settings "$root/release/settings.json"
