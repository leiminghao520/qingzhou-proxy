#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/module-cache .build/pm-cache .build/pm-config .build/pm-security
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
operation="${1:-build}"
if [ "$#" -gt 0 ]; then shift; fi
exec swift "$operation" --disable-sandbox --cache-path "$PWD/.build/pm-cache" --config-path "$PWD/.build/pm-config" --security-path "$PWD/.build/pm-security" -Xswiftc -module-cache-path -Xswiftc "$PWD/.build/module-cache" "$@"
