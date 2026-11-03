#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/swift-local.sh build --product QingzhouHelper
objects=(.build/debug/QingzhouKit.build/*.o .build/debug/CQingzhouRoute.build/*.o .build/debug/Yams.build/*.o .build/debug/CYaml.build/src/*.o)
python3 - <<'PYFIXTURE'
from pathlib import Path
source=Path('Sources/QingzhouHelper/main.swift').read_text()
source=source.split('#if !QZ_HELPER_FIXTURE\n')[0]
Path('.build/helper-recovery-service.swift').write_text(source)
PYFIXTURE
sources=()
for source in Sources/QingzhouHelper/*.swift; do
    if [[ "$source" != "Sources/QingzhouHelper/main.swift" ]]; then sources+=("$source"); fi
done
swiftc -D QZ_HELPER_FIXTURE -parse-as-library -swift-version 5 \
    -I .build/debug/Modules -I Vendor/Yams/Sources/CYaml/include \
    -Xcc -fmodule-map-file=.build/debug/CQingzhouRoute.build/module.modulemap \
    -module-cache-path .build/module-cache "${sources[@]}" .build/helper-recovery-service.swift \
    scripts/helper-recovery-offline.swift "${objects[@]}" -o .build/helper-recovery-offline
.build/helper-recovery-offline
