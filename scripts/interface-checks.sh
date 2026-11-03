#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/swift-local.sh build --product Qingzhou
stage="$PWD/.build/interface-checks"
mkdir -p "$stage/InterfaceChecks.app/Contents/MacOS" "$stage/InterfaceChecks.app/Contents/Resources"
if [ -d .build/debug/Pow_Pow.bundle ]; then cp -R .build/debug/Pow_Pow.bundle "$stage/InterfaceChecks.app/Contents/Resources/"; fi
if [ -f .build/AppIcon.icns ]; then cp .build/AppIcon.icns "$stage/InterfaceChecks.app/Contents/Resources/AppIcon.icns"; fi
cat > "$stage/InterfaceChecks.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>InterfaceChecks</string>
<key>CFBundleIdentifier</key><string>cn.qingzhou.interfacechecks</string>
<key>CFBundleName</key><string>汐航界面检查</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
# 测试入口单独链接，正式应用不携带模拟状态或截图开关。
/usr/bin/python3 - "$stage" <<'PY'
from pathlib import Path
import sys
source = Path('Sources/Qingzhou/QingzhouApp.swift').read_text()
Path(sys.argv[1], 'QingzhouApp.swift').write_text(source.replace('@main struct QingzhouApp', 'struct QingzhouApp', 1))
PY
sources=()
for source in Sources/Qingzhou/*.swift; do
    if [[ "$source" != "Sources/Qingzhou/QingzhouApp.swift" ]]; then sources+=("$source"); fi
done
objects=(.build/debug/Pow.build/*.o .build/debug/QingzhouKit.build/*.o .build/debug/CQingzhouRoute.build/*.o .build/debug/Yams.build/*.o .build/debug/CYaml.build/src/*.o)
swiftc -parse-as-library -swift-version 5 -I .build/debug/Modules -I Vendor/Yams/Sources/CYaml/include -Xcc -fmodule-map-file=.build/debug/CQingzhouRoute.build/module.modulemap \
    -module-cache-path .build/module-cache "${sources[@]}" "$stage/QingzhouApp.swift" \
    scripts/interface-checks.swift "${objects[@]}" -o "$stage/InterfaceChecks.app/Contents/MacOS/InterfaceChecks"
# 每次使用新目录和独立偏好域，不读取日常配置，不调用连接或恢复操作。
fixture="$(mktemp -d "$stage/state.XXXXXX")"
"$stage/InterfaceChecks.app/Contents/MacOS/InterfaceChecks" --test-directory "$fixture" --output "${1:-$PWD/.build/ui-evidence}" "${@:2}"
