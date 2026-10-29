#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/swift-local.sh build --product Qingzhou
stage="$PWD/.build/chart-legend-checks"
mkdir -p "$stage"
/usr/bin/python3 - "$stage" "${2:-}" <<'PY'
from pathlib import Path
import sys
stage=Path(sys.argv[1])
s=Path('Sources/Qingzhou/DailyViews.swift').read_text()
start=s.index('struct RateChart: View {');end=s.index('\n// MARK: - Rule Draft Modal',start)
chart=Path(sys.argv[2]).read_text().replace('struct RateChartBefore: View','struct RateChart: View',1) if sys.argv[2] else s[start:end]
s=Path('Sources/Qingzhou/UIComponents.swift').read_text();theme=s[s.index('enum Theme {'):s.index('// MARK: - 协议标签')]
s=Path('Sources/Qingzhou/QingzhouApp.swift').read_text();formatters=s[s.index('func bytes('):s.index('@MainActor func latency')]
(stage/'ChartSource.swift').write_text('import SwiftUI\nimport AppKit\nimport Charts\nimport QingzhouKit\n'+theme+'\n'+formatters+'\n'+chart)
PY
objects=(.build/debug/QingzhouKit.build/*.o .build/debug/CQingzhouRoute.build/*.o .build/debug/Yams.build/*.o .build/debug/CYaml.build/src/*.o)
swiftc -parse-as-library -swift-version 5 -I .build/debug/Modules -I Vendor/Yams/Sources/CYaml/include -Xcc -fmodule-map-file=.build/debug/CQingzhouRoute.build/module.modulemap -module-cache-path .build/module-cache "$stage/ChartSource.swift" scripts/chart-legend-checks.swift "${objects[@]}" -o "$stage/checks"
"$stage/checks" "${1:?请指定输出目录}"
