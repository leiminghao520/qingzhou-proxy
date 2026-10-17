$ErrorActionPreference = 'Stop'
$env:PYTHONUTF8 = '1'
Set-Location (Split-Path $PSScriptRoot -Parent)
python tool/verify_source_bundle.py
if ($LASTEXITCODE -ne 0) { throw '源码包校验失败' }
python tool/sync_version.py
if ($LASTEXITCODE -ne 0) { throw '版本生成失败' }
python tool/build_runtime.py windows
if ($LASTEXITCODE -ne 0) { throw '服务构建失败' }
flutter pub get --enforce-lockfile
if ($LASTEXITCODE -ne 0) { throw '依赖校验失败' }
flutter analyze
if ($LASTEXITCODE -ne 0) { throw '静态检查失败' }
flutter test
if ($LASTEXITCODE -ne 0) { throw '测试失败' }
flutter build windows --release
if ($LASTEXITCODE -ne 0) { throw 'Windows 构建失败' }
$release = 'build/windows/x64/runner/Release'
Copy-Item build/runtime/qingzhou-service.exe $release
Copy-Item tool/install-windows.ps1 $release
Copy-Item ../../LICENSE $release
$name = 'qingzhou-windows-x64-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
New-Item -Path ../../outputs -ItemType Directory -Force | Out-Null
$output = '../../outputs/' + $name + '.zip'
Compress-Archive -Path ($release + '/*') -DestinationPath $output
Get-FileHash $output -Algorithm SHA256

python tool/package_artifact.py windows $output
if ($LASTEXITCODE -ne 0) { throw '产物清单生成失败' }
