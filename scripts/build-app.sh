#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output="${1:-$PWD/../../outputs}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
version=$(/usr/bin/sed -n 's/.*current="\([^"]*\)".*/\1/p' Sources/QingzhouKit/BuildVersion.swift)
build=$(/usr/bin/sed -n 's/.*build=\([0-9]*\).*/\1/p' Sources/QingzhouKit/BuildVersion.swift)
test -n "$version"; test -n "$build"
output="$(/usr/bin/mktemp -d "$output/qingzhou-$version-$(date +%Y%m%d-%H%M%S).XXXXXX")"
bash scripts/build-age.sh
/usr/bin/python3 scripts/fetch-core.py
/usr/bin/python3 scripts/verify-yams.py
/usr/bin/python3 scripts/helper-script-tests.py
/usr/bin/python3 scripts/verify-domestic.py
mkdir -p .build/httpcompat
(cd tools/httpcompat && go test -race ./... && go build -trimpath -o ../../.build/httpcompat/qzhttp .)
scripts/swift-local.sh build -c release --product Qingzhou
scripts/swift-local.sh build -c release --product QingzhouRunner
scripts/swift-local.sh build -c release --product QingzhouHelper
app="$output/轻舟代理.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/Qingzhou "$app/Contents/MacOS/Qingzhou"
cp .build/httpcompat/qzhttp "$app/Contents/Resources/qzhttp"
cp .build/age-tools/age .build/age-tools/age-keygen "$app/Contents/Resources/"
cp Vendor/age.LICENSE "$app/Contents/Resources/age.LICENSE"
cp Resources/shadowrocket-default.json "$app/Contents/Resources/shadowrocket-default.json"
cp Resources/domestic-rules.json Resources/domestic-rules-lock.json Resources/domestic-domain.LICENSE "$app/Contents/Resources/"
cp .build/release/QingzhouHelper "$app/Contents/Resources/QingzhouHelper"
cp scripts/install-helper.sh scripts/uninstall-helper.sh scripts/recover-helper.sh "$app/Contents/Resources/"
cp .build/release/QingzhouRunner "$app/Contents/Resources/QingzhouRunner"
cp Vendor/Yams/LICENSE "$app/Contents/Resources/Yams.LICENSE"
cp Vendor/yams-lock.json "$app/Contents/Resources/"
cp Vendor/sing-box Vendor/sing-box.LICENSE Vendor/core-lock.json "$app/Contents/Resources/"
if [ -f Vendor/GPL-3.0.txt ]; then cp Vendor/GPL-3.0.txt "$app/Contents/Resources/"; fi
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Qingzhou</string>
<key>CFBundleIdentifier</key><string>cn.qingzhou.proxy</string>
<key>CFBundleName</key><string>轻舟代理</string>
<key>CFBundleDisplayName</key><string>轻舟代理</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$build</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
if [ -f scripts/make-modern-icon.swift ]; then
    mkdir -p .build/icon-png
    swift scripts/make-modern-icon.swift .build/icon-png
    /usr/bin/python3 scripts/make-icns.py .build/icon-png .build/AppIcon.icns
elif [ ! -f .build/AppIcon.icns ]; then
    mkdir -p .build/icon-png .build/AppIcon.iconset
    CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" swift -module-cache-path "$PWD/.build/module-cache" scripts/icon.swift .build/icon-png
    /usr/bin/python3 scripts/make-icns.py .build/icon-png .build/AppIcon.icns
fi
cp .build/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign "${QZ_SIGNING_IDENTITY:--}" "$app/Contents/Resources/qzhttp"
codesign --force --sign "${QZ_SIGNING_IDENTITY:--}" "$app/Contents/Resources/sing-box"
codesign --force --sign "${QZ_SIGNING_IDENTITY:--}" "$app/Contents/Resources/QingzhouRunner"
codesign --force --sign "${QZ_SIGNING_IDENTITY:--}" "$app/Contents/Resources/age"
codesign --force --sign "${QZ_SIGNING_IDENTITY:--}" "$app/Contents/Resources/age-keygen"
codesign --force --sign "${QZ_SIGNING_IDENTITY:--}" "$app/Contents/Resources/QingzhouHelper"
codesign --force --sign "${QZ_SIGNING_IDENTITY:--}" "$app"
codesign --verify --deep --strict "$app"
/usr/bin/python3 - "$app" "$version" <<'PYTHON'
import pathlib,hashlib,json,sys,subprocess
app=pathlib.Path(sys.argv[1]);files=['Contents/Resources/age','Contents/Resources/age-keygen','Contents/Resources/age.LICENSE','Contents/MacOS/Qingzhou','Contents/Resources/sing-box','Contents/Resources/QingzhouRunner','Contents/Resources/QingzhouHelper','Contents/Resources/qzhttp','Contents/Resources/shadowrocket-default.json','Contents/Resources/domestic-rules.json','Contents/Resources/domestic-rules-lock.json','Contents/Resources/domestic-domain.LICENSE']
source=pathlib.Path.cwd()
source_files=sorted([path for folder in ['Sources','scripts','Resources','tools','server'] for path in (source/folder).rglob('*') if path.is_file() and not any(part.startswith('.') or part=='__pycache__' for part in path.relative_to(source).parts)]+[source/'Package.swift'])
source_digest=hashlib.sha256()
for path in source_files:source_digest.update(str(path.relative_to(source)).encode());source_digest.update(hashlib.sha256(path.read_bytes()).digest())
manifest={'version':sys.argv[2],'gitHead':subprocess.run(['git','rev-parse','HEAD'],capture_output=True,text=True,check=True).stdout.strip(),'sourceTreeSHA256':source_digest.hexdigest(),'includesUncommittedChanges':True,'components':{f:{'size':(app/f).stat().st_size,'sha256':hashlib.sha256((app/f).read_bytes()).hexdigest()} for f in files}}
(app.parent/'artifact-manifest.json').write_text(json.dumps(manifest,indent=2))
PYTHON
echo "APP_BUILD_OK $app"
