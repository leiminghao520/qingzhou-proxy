#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 tool/sync_version.py
python3 tool/build_runtime.py android
flutter pub get --enforce-lockfile
flutter analyze
flutter test
flutter build apk --debug --target-platform android-arm64
python3 tool/package_artifact.py android build/app/outputs/flutter-apk/app-debug.apk
