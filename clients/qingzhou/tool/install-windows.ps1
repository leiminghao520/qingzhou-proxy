param([string]$OwnerSid = '', [switch]$Uninstall, [switch]$ServiceOnly)
$ErrorActionPreference = 'Stop'
$logDir = Join-Path $env:LOCALAPPDATA 'QingzhouProxy'
New-Item $logDir -ItemType Directory -Force | Out-Null
trap {
    $_ | Out-String | Out-File (Join-Path $logDir 'install.log') -Append -Encoding utf8
    exit 1
}
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (!$OwnerSid) { $OwnerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
if ($OwnerSid -notmatch '^S-1-5-21-\d+-\d+-\d+-\d+$') { throw '用户 SID 无效' }
if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'), '-OwnerSid', $OwnerSid)
    if ($Uninstall) { $arguments += '-Uninstall' }
    if ($ServiceOnly) { $arguments += '-ServiceOnly' }
    $process = Start-Process powershell.exe -Verb RunAs -ArgumentList $arguments -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw '管理员安装或恢复未完成' }
    exit
}
$destination = Join-Path $env:ProgramFiles 'QingzhouProxy'
$existing = Get-Service QingzhouProxy -ErrorAction SilentlyContinue
if ($existing) { Stop-Service QingzhouProxy -ErrorAction Stop; $existing.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(45)) }
if (Test-Path (Join-Path $destination 'recovery.json')) { throw '存在未恢复网络设置，请先在应用中恢复网络；未覆盖或删除旧组件' }
if ($Uninstall) {
    if ($existing) { & sc.exe delete QingzhouProxy; if ($LASTEXITCODE -ne 0) { throw '服务删除失败' } }
    Write-Output '服务已卸载；保留安装目录和用户数据，便于回退。'
    exit
}
$source = Split-Path $PSCommandPath -Parent
if ((!$ServiceOnly -and !(Test-Path (Join-Path $source 'qingzhou.exe'))) -or !(Test-Path (Join-Path $source 'qingzhou-service.exe'))) { throw '安装包不完整' }
New-Item $destination -ItemType Directory -Force | Out-Null
if ($ServiceOnly) {
    # 特权服务仅从管理员保护的目录运行，界面保留普通用户权限。
    Copy-Item (Join-Path $source 'qingzhou-service.exe') $destination -Force
    Copy-Item (Join-Path $source 'LICENSE') $destination -Force
} else {
    Copy-Item (Join-Path $source '*') $destination -Recurse -Force
}
& (Join-Path $destination 'qingzhou-service.exe') --configure-owner $OwnerSid
if ($LASTEXITCODE -ne 0) { throw '服务所有者配置失败' }
if (!$existing) { New-Service -Name QingzhouProxy -DisplayName '轻舟代理网络服务' -BinaryPathName ('"' + (Join-Path $destination 'qingzhou-service.exe') + '"') -StartupType Automatic | Out-Null }
Start-Service QingzhouProxy
Write-Output ('安装完成：' + (Join-Path $destination 'qingzhou.exe'))
