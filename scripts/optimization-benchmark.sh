#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/swift-local.sh build --product QingzhouChecks
stage="$PWD/.build/optimization-benchmark"
mkdir -p "$stage"
# 从 Git 基线读取旧算法，只在构建目录生成对照程序，不修改工作区源文件。
python3 - "$stage" <<'PY'
from pathlib import Path
import subprocess,sys
stage=Path(sys.argv[1])
log=subprocess.check_output(['git','show','HEAD:Sources/QingzhouKit/NetworkSafety.swift'],text=True)
log=log[log.index('public final class DiagnosticLog'):].replace('DiagnosticLog','BaselineDiagnosticLog')
log=log.replace('    private let url:URL','    public var writtenBytes=0\n    private let url:URL').replace('        try SecureFile.write(data,to:url)','        writtenBytes+=data.count\n        try SecureFile.write(data,to:url)')
download=subprocess.check_output(['git','show','HEAD:Sources/QingzhouKit/ImportService.swift'],text=True)
download=download[download.index('public final class BoundedDownload'):].replace('BoundedDownload','BaselineBoundedDownload')
(stage/'Baseline.swift').write_text('import Foundation\nimport Darwin\nimport QingzhouKit\n'+log+'\n'+download)
PY
sources=(.build/debug/QingzhouKit.build/*.o .build/debug/CQingzhouRoute.build/*.o .build/debug/Yams.build/*.o .build/debug/CYaml.build/src/*.o)
swiftc -parse-as-library -Onone -g -I .build/debug/Modules -I Vendor/Yams/Sources/CYaml/include -Xcc -fmodule-map-file=.build/debug/CQingzhouRoute.build/module.modulemap \
    -module-cache-path .build/module-cache "$stage/Baseline.swift" scripts/optimization-benchmark.swift \
    "${sources[@]}" -o "$stage/check"
"$stage/check" "${1:-$stage/result.json}"
