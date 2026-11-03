$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '../../..')
$evidence = Join-Path $root 'outputs/windows-evidence'
New-Item $evidence -ItemType Directory -Force | Out-Null
$installer = Get-ChildItem (Join-Path $root 'outputs/*-windows-x64-setup.exe') | Select-Object -Last 1
$log = Join-Path $evidence 'setup.log'
$setup = Start-Process $installer.FullName -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', ('/LOG="' + $log + '"')) -PassThru -Wait
if ($setup.ExitCode -ne 0) { throw "安装失败：$($setup.ExitCode)" }
$service = Get-Service QingzhouProxy
if ($service.Status -ne 'Running') { throw '安装后网络服务未启动' }

function Invoke-Runtime([string]$Method) {
    $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', 'cn.qingzhou.proxy.v1', [IO.Pipes.PipeDirection]::InOut)
    try {
        $pipe.Connect(5000)
        $writer = [IO.BinaryWriter]::new($pipe)
        $reader = [IO.BinaryReader]::new($pipe)
        $bytes = [Text.Encoding]::UTF8.GetBytes((@{method=$Method; arguments=''} | ConvertTo-Json -Compress))
        $writer.Write([uint32]$bytes.Length)
        $writer.Write($bytes)
        $writer.Flush()
        $length = $reader.ReadUInt32()
        if ($length -gt 4194304) { throw '服务响应过大' }
        $reply = [Text.Encoding]::UTF8.GetString($reader.ReadBytes($length)) | ConvertFrom-Json
        if ($reply.error) { throw $reply.error }
        return ($reply.value | ConvertFrom-Json)
    } finally { $pipe.Dispose() }
}
$capabilities = Invoke-Runtime 'capabilities'
if ($capabilities.coreVersion -ne '1.14.3') { throw '核心版本错误' }
$status = Invoke-Runtime 'status'
if ($status.state -ne 'disconnected') { throw '新安装不得自动连接' }
$ui = Join-Path $env:LOCALAPPDATA 'Programs/QingzhouProxy/qingzhou.exe'
$process = Start-Process $ui -WorkingDirectory (Split-Path $ui) -PassThru
try {
    Start-Sleep -Seconds 20
    $process.Refresh()
    if ($process.HasExited -or $process.MainWindowHandle -eq 0) { throw '客户端退出或未显示窗口' }
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $bounds = [Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bitmap = [Drawing.Bitmap]::new($bounds.Width, $bounds.Height)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen($bounds.Location, [Drawing.Point]::Empty, $bounds.Size)
    $bitmap.Save((Join-Path $evidence 'installed-desktop.png'))
    $graphics.Dispose()
    $bitmap.Dispose()
    @{service='Running'; core=$capabilities.coreVersion; state=$status.state; windowTitle=$process.MainWindowTitle; survivedSeconds=20; realNetwork='未验证'; stability2h='未验证'} |
        ConvertTo-Json | Set-Content (Join-Path $evidence 'smoke.json') -Encoding utf8
} finally {
    if (!$process.HasExited) { Stop-Process -Id $process.Id -Force }
}
$uninstaller = Join-Path (Split-Path $ui) 'unins000.exe'
$uninstall = Start-Process $uninstaller -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') -PassThru -Wait
if ($uninstall.ExitCode -ne 0) { throw '卸载失败' }
if (Get-Service QingzhouProxy -ErrorAction SilentlyContinue) { throw '卸载后服务仍然存在' }
Write-Output 'WINDOWS_INSTALL_UI_SERVICE_UNINSTALL_PASS'
