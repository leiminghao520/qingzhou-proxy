#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/swift-local.sh build --product Qingzhou
stage="$PWD/.build/settings-scroll-checks"
mkdir -p "$stage"
# 探针只加入独立检查程序，正式应用不包含重绘计数器。
/usr/bin/python3 - "$stage" "${1:-HEAD}" <<'PY'
from pathlib import Path
import subprocess,sys
stage=Path(sys.argv[1]);app=Path('Sources/Qingzhou/QingzhouApp.swift').read_text().replace('@main struct QingzhouApp','struct QingzhouApp',1)
(stage/'QingzhouApp.swift').write_text(app)
legacy=subprocess.check_output(['git','show',sys.argv[2]+':Sources/Qingzhou/SettingsView.swift'],text=True)
# 历史版本的保存参数已移到统一绕过页；此夹具只测展示，不执行保存。
legacy=legacy.replace(',domains:protectedDomains,exclusions:exclusions','').replace('DomesticRouting.','BaselineDomesticRouting.')
marker='private struct SettingsContent:'
index=legacy.find(marker)
if index>=0:
    legacy=legacy[:index]+legacy[index:].replace('    var body: some View {','    var body: some View {\n        let _=SettingsBenchmarkProbe.record()',1)
else:
    legacy=legacy.replace('    var body: some View {','    var body: some View {\n        let _=SettingsBenchmarkProbe.record()',1)
(stage/'SettingsView-baseline.swift').write_text(legacy)
current=Path('Sources/Qingzhou/SettingsView.swift').read_text()
marker='private struct SettingsContent:'
index=current.index(marker)
current=current[:index]+current[index:].replace('    var body: some View {','    var body: some View {\n        let _=SettingsBenchmarkProbe.record()',1)
(stage/'SettingsView-candidate.swift').write_text(current)
PY
sources=()
for source in Sources/Qingzhou/*.swift; do
    if [[ "$source" != "Sources/Qingzhou/QingzhouApp.swift" && "$source" != "Sources/Qingzhou/SettingsView.swift" ]]; then sources+=("$source"); fi
done
objects=(.build/debug/QingzhouKit.build/*.o .build/debug/CQingzhouRoute.build/*.o .build/debug/Yams.build/*.o .build/debug/CYaml.build/src/*.o)
for variant in baseline candidate; do
    swiftc -parse-as-library -swift-version 5 -I .build/debug/Modules -I Vendor/Yams/Sources/CYaml/include -Xcc -fmodule-map-file=.build/debug/CQingzhouRoute.build/module.modulemap \
        -module-cache-path .build/module-cache "${sources[@]}" "$stage/QingzhouApp.swift" \
        "$stage/SettingsView-$variant.swift" scripts/settings-scroll-checks.swift "${objects[@]}" -o "$stage/$variant"
    fixture="$(mktemp -d "$stage/state.XXXXXX")"
    "$stage/$variant" --test-directory "$fixture" --result "$stage/$variant.json" --variant "$variant"
done
