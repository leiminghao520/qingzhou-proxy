$ErrorActionPreference = 'Stop'
$env:PYTHONUTF8 = '1'
$root = Resolve-Path (Join-Path $PSScriptRoot '../../..')
$release = Join-Path $PSScriptRoot '../build/windows/x64/runner/Release'
$required = @('qingzhou.exe', 'qingzhou-service.exe', 'flutter_windows.dll', 'data/app.so', 'data/icudtl.dat', 'install-windows.ps1')
foreach ($file in $required) {
    if (!(Test-Path (Join-Path $release $file))) { throw "客户端文件缺失：$file" }
}
# 将微软运行库随应用分发，避免新系统因缺少 DLL 而退出。
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$crt = Get-ChildItem (Join-Path $vs 'VC/Redist/MSVC/*/x64/Microsoft.VC143.CRT') -Directory | Select-Object -Last 1
if (!$crt) { throw '未找到 MSVC x64 运行库' }
Copy-Item (Join-Path $crt.FullName '*.dll') $release -Force
$compiler = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6/ISCC.exe'
if (!(Test-Path $compiler)) { throw '未安装 Inno Setup 6' }
$versionSource = Get-Content (Join-Path $root 'Sources/QingzhouKit/BuildVersion.swift') -Raw
$version = [regex]::Match($versionSource, 'current\s*=\s*"([^"]+)"').Groups[1].Value
& $compiler "/DAppVersion=$version" (Join-Path $PSScriptRoot 'windows-installer.iss')
if ($LASTEXITCODE -ne 0) { throw '安装包生成失败' }
$installer = Join-Path $root "outputs/qingzhou-$version-windows-x64-setup.exe"
python (Join-Path $PSScriptRoot 'package_artifact.py') windows $installer
if ($LASTEXITCODE -ne 0) { throw '安装包清单生成失败' }
Get-FileHash $installer -Algorithm SHA256
