#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# 覆盖率仅针对检查程序实际执行到的代码，不把界面或管理员服务标为已覆盖。
scripts/swift-local.sh build --build-path .build/coverage -Xswiftc -profile-generate -Xswiftc -profile-coverage-mapping --product QingzhouChecks
mkdir -p .build/coverage/profiles
LLVM_PROFILE_FILE="$PWD/.build/coverage/profiles/checks-%p.profraw" .build/coverage/debug/QingzhouChecks
xcrun llvm-profdata merge -sparse .build/coverage/profiles/*.profraw -o .build/coverage/checks.profdata
xcrun llvm-cov report .build/coverage/debug/QingzhouChecks -instr-profile=.build/coverage/checks.profdata -ignore-filename-regex='(Vendor/|QingzhouChecks/)' > .build/coverage/report.txt
cat .build/coverage/report.txt
