#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
stage="$PWD/.build/claude-filter-checks"
mkdir -p "$stage"
bash scripts/swift-local.sh build --enable-code-coverage --product ClaudeSafetyPolicyChecks > "$stage/build.log" 2>&1
LLVM_PROFILE_FILE="$stage/policy.profraw" .build/debug/ClaudeSafetyPolicyChecks | tee "$stage/policy-checks.txt"
xcrun llvm-profdata merge -sparse "$stage/policy.profraw" -o "$stage/policy.profdata"
xcrun llvm-cov report .build/debug/ClaudeSafetyPolicyChecks -instr-profile="$stage/policy.profdata" \
    Sources/QingzhouKit/ClaudeApplicationPolicy.swift Sources/QingzhouKit/ClaudeSafetyStateMachine.swift \
    Sources/QingzhouKit/ClaudeNetworkFilterClient.swift | tee "$stage/coverage.txt"
bash scripts/swift-local.sh build --product ClaudeFilterPrototype > "$stage/prototype-build.log" 2>&1
for plist in Resources/ClaudeFilter/Info.plist Resources/ClaudeFilter/Filter.entitlements Resources/ClaudeFilter/Host.entitlements; do
    plutil -lint "$plist"
done
set +e
.build/debug/ClaudeFilterPrototype --preflight --bundle /Applications/汐航.app > "$stage/deployment-preflight.txt"
status=$?
set -e
cat "$stage/deployment-preflight.txt"
if [ "$status" -ne 2 ]; then
    echo "FAIL 原型必须明确返回未通过发布门槛"
    exit 1
fi
echo "PASS 策略检查和编译完成；实机发布门槛未通过，未安装、未激活、未写入网络配置"
