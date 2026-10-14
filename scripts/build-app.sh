#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output="${1:-$PWD/../../outputs}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
python3 scripts/fetch-core.py
python3 scripts/verify-yams.py
mkdir -p .build/httpcompat
(cd tools/httpcompat && go test -race ./... && go build -trimpath -o ../../.build/httpcompat/qzhttp .)
scripts/swift-local.sh build -c release --product Qingzhou
scripts/swift-local.sh build -c release --product QingzhouRunner
scripts/swift-local.sh build -c release --product QingzhouHelper
app="$output/轻舟代理.app"
if [ -e "$app" ]; then
    if [ -e "$output/轻舟代理.previous.app" ]; then rm -rf "$output/轻舟代理.previous.app"; fi
    mv "$app" "$output/轻舟代理.previous.app"
fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/Qingzhou "$app/Contents/MacOS/Qingzhou"
cp .build/httpcompat/qzhttp "$app/Contents/Resources/qzhttp"
cp Resources/shadowrocket-default.json "$app/Contents/Resources/shadowrocket-default.json"
cp .build/release/QingzhouHelper "$app/Contents/Resources/QingzhouHelper"
cp scripts/install-helper.sh scripts/uninstall-helper.sh scripts/recover-helper.sh "$app/Contents/Resources/"
cp .build/release/QingzhouRunner "$app/Contents/Resources/QingzhouRunner"
cp Vendor/Yams/LICENSE "$app/Contents/Resources/Yams.LICENSE"
cp Vendor/yams-lock.json "$app/Contents/Resources/"
cp Vendor/sing-box Vendor/sing-box.LICENSE Vendor/core-lock.json "$app/Contents/Resources/"
if [ -f Vendor/GPL-3.0.txt ]; then cp Vendor/GPL-3.0.txt "$app/Contents/Resources/"; fi
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Qingzhou</string>
<key>CFBundleIdentifier</key><string>cn.qingzhou.proxy</string>
<key>CFBundleName</key><string>轻舟代理</string>
<key>CFBundleDisplayName</key><string>轻舟代理</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.6.0</string>
<key>CFBundleVersion</key><string>6</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
if [ -f scripts/make-modern-icon.swift ]; then
    mkdir -p .build/icon-png
    swift scripts/make-modern-icon.swift .build/icon-png
    python3 scripts/make-icns.py .build/icon-png .build/AppIcon.icns
elif [ ! -f .build/AppIcon.icns ]; then
    mkdir -p .build/icon-png .build/AppIcon.iconset
    CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" swift -module-cache-path "$PWD/.build/module-cache" scripts/icon.swift .build/icon-png
    python3 scripts/make-icns.py .build/icon-png .build/AppIcon.icns
fi
cp .build/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app/Contents/Resources/qzhttp"
codesign --force --sign - "$app/Contents/Resources/sing-box"
codesign --force --sign - "$app/Contents/Resources/QingzhouRunner"
codesign --force --sign - "$app/Contents/Resources/QingzhouHelper"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
echo "APP_BUILD_OK"
