param(
    [ValidateRange(1024,65535)][int]$ListenPort = 7890,
    [ValidateSet('systemProxy','tun','compatible')][string]$CaptureMode = 'systemProxy'
)
$ErrorActionPreference = 'Stop'

# 此脚本只读取状态和发起测试请求，不连接、断开、安装服务或修改网络设置。
function Invoke-RuntimeRead([string]$Method, [string]$Arguments = '') {
    $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', 'cn.qingzhou.proxy.v1', [IO.Pipes.PipeDirection]::InOut, [IO.Pipes.PipeOptions]::Asynchronous)
    try {
        $pipe.Connect(3000)
        $writer = [IO.BinaryWriter]::new($pipe)
        $bytes = [Text.Encoding]::UTF8.GetBytes((@{method=$Method; arguments=$Arguments} | ConvertTo-Json -Compress))
        $writer.Write([uint32]$bytes.Length)
        $writer.Write($bytes)
        $writer.Flush()
        function Read-Exact([int]$Count) {
            $buffer = New-Object byte[] $Count
            $offset = 0
            while ($offset -lt $Count) {
                $pending = $pipe.ReadAsync($buffer, $offset, $Count-$offset)
                if (!$pending.Wait(12000)) { throw '服务读取超时' }
                if ($pending.Result -eq 0) { throw '服务响应不完整' }
                $offset += $pending.Result
            }
            return ,$buffer
        }
        $header = Read-Exact 4
        $length = [BitConverter]::ToUInt32($header, 0)
        if ($length -gt 1048576) { throw '诊断响应过大' }
        $response = [Text.Encoding]::UTF8.GetString((Read-Exact $length)) | ConvertFrom-Json
        if ($response.error) { throw '服务拒绝诊断请求' }
        return ($response.value | ConvertFrom-Json)
    } finally { $pipe.Dispose() }
}

function Test-Https([string]$Name, [string[]]$Options) {
    # 只保存固定目标的 HTTP 状态和 curl 数值错误码，不记录请求、节点或订阅。
    $response = & curl.exe --silent --output NUL --write-out '%{http_code}' --max-time 10 @Options 'https://www.gstatic.com/generate_204' 2>$null
    $exitCode = $LASTEXITCODE
    return @{ name=$Name; passed=($exitCode -eq 0 -and $response -eq '204'); curlExit=$exitCode; httpStatus=$response }
}

$report = [ordered]@{
    checkedAt=(Get-Date).ToUniversalTime().ToString('o')
    service='unverified'
    captureMode=$CaptureMode
    listenPort=$ListenPort
    tunRouting='unverified'
    tunDNS='unverified'
}
try {
    $status = Invoke-RuntimeRead 'status'
    $report.service = $status.state
    if ($status.listenPort) { $ListenPort = [int]$status.listenPort }
    if ($status.captureMode) { $CaptureMode = [string]$status.captureMode }
    $report.captureMode = $CaptureMode
    $report.listenPort = $ListenPort
    $capabilities = Invoke-RuntimeRead 'capabilities'
    $report.coreVersion = $capabilities.coreVersion
    $report.serviceBuild = $capabilities.serviceBuild
    if ($capabilities.diagnostics -eq $true -and $status.coreRunning -eq $true) {
        $diagnostic = Invoke-RuntimeRead 'query' '/diagnostics'
        $report.diagnostics = $diagnostic.diagnostics
    }
} catch {
    $report.service = 'unavailable'
    $report.serviceError = '服务查询失败；请使用安装客户端的同一 Windows 账户运行，并确认服务已启动'
}

try {
    $values = Get-ItemProperty -LiteralPath 'HKCU:/Software/Microsoft/Windows/CurrentVersion/Internet Settings'
    $report.registryProxyMatches = ($values.ProxyEnable -eq 1 -and $values.ProxyServer -eq ('127.0.0.1:' + $ListenPort) -and !$values.AutoConfigURL)
} catch { $report.registryProxyMatches = 'unverified' }

$report.requests = @(Test-Https 'explicitLocalProxy' @('--proxy', ('http://127.0.0.1:' + $ListenPort)))
if ($CaptureMode -ne 'systemProxy') {
    # 绕过 HTTP 代理只检查当前网络路径；成功也不能单独证明经过了 TUN。
    $report.requests += Test-Https 'networkPathIPv4' @('--noproxy','*','--ipv4')
    $report.requests += Test-Https 'networkPathIPv6' @('--noproxy','*','--ipv6')
}
$report | ConvertTo-Json -Depth 8
