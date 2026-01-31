#!/bin/bash
# SPDX-License-Identifier: MIT
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd -P)"
test_root="${MOBILELLM_TEST_OUTPUT:-}"
if [[ -z "$test_root" ]]; then test_root="$(mktemp -d "${TMPDIR:-/tmp}/mobilellm-behavior.XXXXXX")"; fi
mkdir -p "$test_root"
for package in AppUI AppRuntime LLMCore AgentContracts AgentRuntime AgentSandboxAPI MobileLLMUI LLMEngineApple; do
    swift test --package-path "$repo_root/Packages/$package" --scratch-path "$test_root/$package" \
        2>&1 | tee "$test_root/$package.log"
done
swift test --package-path "$repo_root/Tools/AgentHarnessVerification" --scratch-path "$test_root/verification" \
    2>&1 | tee "$test_root/verification.log"
swift run --package-path "$repo_root/Tools/AgentHarnessVerification" --scratch-path "$test_root/verification" \
    agent-harness-verify static --repo-root "$repo_root"
echo "Behavior test logs: $test_root"
