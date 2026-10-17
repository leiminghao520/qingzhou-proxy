#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 tool/sync_version.py
python3 tool/build_runtime.py ios
ruby tool/configure_ios.rb
flutter pub get --enforce-lockfile
flutter analyze
flutter test
flutter build ipa --release "$@"
for artifact in build/ios/ipa/*.ipa; do
  if [ -f "$artifact" ]; then
    python3 tool/package_artifact.py ios "$artifact"
  fi
done
