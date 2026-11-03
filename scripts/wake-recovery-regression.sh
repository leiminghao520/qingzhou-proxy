#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
stage="$PWD/.build/wake-recovery"
mkdir -p "$stage"
bash scripts/swift-local.sh run QingzhouChecks > "$stage/full.log" 2>&1
 tail -3 "$stage/full.log"
for name in wake-recovery-checks helper-recovery-offline network-monitor-checks native-route-checks quit-release-checks network-resume-model-checks protection-startup-checks bypass-helper-checks sleep-command-checks page-optimization-checks settings-scroll-checks diagnostics-history-events-checks core-api-readiness-checks; do
    if bash "scripts/$name.sh" > "$stage/$name.log" 2>&1; then
        echo "PASS $name"
        tail -2 "$stage/$name.log"
    else
        echo "FAIL $name"
        tail -30 "$stage/$name.log"
        exit 1
    fi
done
