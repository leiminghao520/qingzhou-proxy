# Windows 已连接但代理不通：实现和验证记录

日期：2026-10-17（Asia/Shanghai）。本次代码改善连接状态的可验证性、错误归因和恢复核验，尚未确定用户此前实网故障的根因，不能将此开发版本称为已完成实网验收的修复版。

## 版本核对

- 检查分支：`codex/android-windows-preview`；本地基线为 `445b5e2aa3f9e3e1d6d5154fa64d5059feb1ff6d`。
- 发布标签 `v0.8.11-windows-preview.1` 对应 `7f766bd382e7a1d171d9007c3ea7ece439c8f5ce`。该标签到分支基线的差异限于 CI、界面预览测试及文档，运行时源码一致。
- 已安装服务的内嵌 Go 构建信息记录该发布提交、`go1.26.5`、sing-box `v1.14.3`，但 `vcs.modified=true`，因此不能声称安装二进制与标签源码逐字一致。
- 轻舟服务 SHA-256：`58a98615fbe7767149ebe754c5a8280d1ab0b2cd35d13b7a37036a168fec828e`；REA 证据：`ev_00665e9f9eb73a435d07da9b54ea8ad7a6649315cb2c828d9a465bdd9a7d1a99`。
- 对照的本机 Clash Verge 版本为 2.5.8；其 `verge-mihomo.exe` 内嵌模块为 Mihomo，构建提交 `88dcbf7f1614a67c3b36b848ee3592dfa92ada36`，同样标记有未提交修改。REA 证据：`ev_e59388b53d574db51aa95680a01bf4a1760d74873d4235fc360b1f4b25ef18fb`。
- 上述 REA 证据只证明嵌入的元数据与文件身份，不证明依赖真实性、实际运行行为或代理连通性。源码对照参考 [Clash sysproxy-rs Windows 实现](https://github.com/clash-verge-rev/sysproxy-rs/blob/main/src/windows.rs)，不把当前上游源码等同于本机安装版本。

## 代码变化

- 保留 `state` 协议，新增 `coreRunning`、`captureMode`、`listenPort`、`diagnostics` 和可选 `checkedAt`。能力响应增加 `diagnostics:true` 与服务构建标识。通过既有 `query('/diagnostics')` 请求检查，无需更改 Runtime 接口。
- 主动诊断从当前混合代理入口发送 HTTPS 请求，依次记录端口、TLS 和 HTTPS 结果。目标固定为现有测速使用的 `https://www.gstatic.com/generate_204`，禁止重定向，超时 8 秒，不接受调用方指定 URL。单一目标失败只说明该检查失败，不能证明所有目标都不可达。
- Windows 桥接在登录用户进程查询 WinINET 的连接级代理状态，仅返回固定说明和错误码。PAC／自动检测启用时明确标记未验证，不把注册表值匹配等同于浏览器实际接管。
- DNS 无法独立归因时维持未验证；本地代理 HTTPS 成功不代表 TUN 路由或 TUN DNS 已验证。TUN 路由／DNS 检查仍未实现实机证据采集。
- 核心错误保留阶段、类别与数值系统错误码；错误链在进程内保留，界面不输出底层错误中可能存在的节点地址、口令或订阅 URL。实际端口占用测试发现 Windows Winsock 的 10048 与可移植 errno 常量不同，已补充对应分类。
- 系统代理写入和恢复后均重新读取核验；核验失败保留恢复记录。外部修改仍拒绝覆盖。
- 兼容入口异常退出时清理残留核心；主动诊断完成后重新读取核心状态，避免后台健康管理器已停止核心却返回连接成功。
- 界面分别显示内核运行和检测结果；诊断失败保留连接操作能力，不自动切换接管模式。变更配置后使旧结果失效，并防止延迟响应覆盖新状态。其他平台通过能力标识保留原行为。
- Windows 构建脚本增加 Go 转发、恢复与服务诊断回归门禁。

未替换系统代理写入机制：本机当前注册表与 WinINET 查询一致，尚无证据证明直接写注册表就是用户故障根因。保留 sing-box，未迁移至 Mihomo。

## 已执行验证

使用隔离在工作目录中的 Go 1.26.9（与项目 CI 固定的 1.26.5 不同）：

```powershell
go test -count=1 -tags 'with_gvisor,with_quic,with_utls,with_clash_api' -ldflags=-checklinkname=0 ./systemproxy ./engine ./config ./health ./cmd/qingzhou-service
```

- 五个包通过，含子测试共 37 个测试场景，零失败。
- 真实 sing-box 混合入口向受控回环 HTTPS 服务转发，在 HTTP 兼容入口开／关两种情况下通过；不是用户真实远程节点测试。
- 不可信 TLS 证书、HTTP 代理错误、关闭入口、实际端口占用、DNS／拒绝连接／超时分类、敏感错误隐藏、接管写入未生效、恢复重试与外部修改保护通过。
- Windows 服务 `go build` 成功；开发产物 `qingzhou-service-diagnostics.exe` 不是完整安装包，不应单独替换现有客户端服务。
- Dart 静态检查通过，无问题。Flutter 3.47.7 / Dart 3.13.5 下完整 `flutter test --no-pub --dart-define=QINGZHOU_PREVIEW=true` 通过，共 47 个测试。首次测试发现侧栏残留“连接已建立”提示，已修正并通过回归。
- 使用官方 pub.dev 成功解析锁定依赖，`pubspec.lock` 未修改。`pub get --enforce-lockfile` 在依赖解析完成后因系统未启用插件符号链接支持而以失败退出；分析和测试使用已解析依赖、跳过该构建准备步骤。
- 只读诊断脚本通过 Windows PowerShell 语法解析并运行。早期沙箱拒绝服务访问；当前环境访问已恢复，已安装服务返回 `disconnected`、核心 1.14.3，默认 7890 端口未接受连接。这是当前环境观察，不是此前用户故障复现。
- `git diff --check` 通过。

## 未完成的验收

- 未连接或断开轻舟／Clash，未修改用户系统代理、DNS、路由或已安装服务。
- 同一真实节点下轻舟／Clash 依次对照、系统代理与 TUN 的实网 HTTPS、IPv4／IPv6、DNS 及生命周期恢复验收均未完成。
- 后续已安装 Visual Studio Build Tools 2022、Windows SDK 和 ATL，使用目录联接及临时短路径完成原生 Release 编译。完整安装器打包、卸载和真实节点网络验收仍未完成。

## 在正常 Windows 用户环境完成验证

按原有 Windows CI 流程构建完整客户端。`tool/build_windows.ps1` 会执行新增 Go 回归、Flutter 分析和测试，然后构建客户端。通过前不要发布稳定版本。

分别使用同一节点运行轻舟系统代理、轻舟 TUN 与 Clash；每次只启用一个应用。新客户端的设置页可运行“分阶段网络诊断”。另外可从安装客户端的同一 Windows 账户运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File clients/qingzhou/tool/diagnose_windows.ps1 -ListenPort 7890 -CaptureMode systemProxy
```

监听端口和接管模式按实际设置填写。支持新增接口的服务会自动返回实际值。脚本只查询服务和配置并发送固定目标的测试请求，不启动、停止或修改代理；TUN 模式会补充绕过 HTTP 代理的 IPv4／IPv6 请求，但不会将请求成功独立认定为 TUN 接管成功。脚本 JSON 不含节点凭据。

若显式本地代理 HTTPS 成功、系统代理检查失败，继续定位登录用户的代理应用；若本地代理请求失败，结合阶段和错误码定位端口、TLS、节点或网络。得到证据后再修改对应转发／接管层。

## 后续退出故障处理

用户报告客户端无法退出，截图显示“网络恢复尚未完成”。现场调用已安装服务的 `stop` 成功返回，随后结束轻舟界面进程；当前系统代理 `127.0.0.1:7897` 保持不变。此时没有取得原始退出失败异常，不能认定是恢复冲突、通知失败还是窗口插件失败。

源码确认右上角关闭按钮只隐藏窗口；托盘退出把停止、托盘销毁和窗口销毁的异常一律归为网络恢复失败，无法准确显示阶段。新增退出准备流程：停止响应失败时重试幂等恢复，查询确认服务断开且核心未运行才销毁窗口；恢复失败保留可显示的具体原因，桌面销毁失败单独提示，并防止重复退出并发。补充五项退出准备回归测试，完整 Flutter 回归 47 项通过。

## 新版桌面入口部署

按用户要求，以 `--build-name=0.8.11 --build-number=26` 完成 Windows Release 编译，生成诊断开发版客户端。客户端独立放在 `%LOCALAPPDATA%/Programs/QingzhouProxyDiagnostics`，保留旧客户端目录；桌面“轻舟代理”快捷方式已切换至新版。

已使用原服务安装脚本的 `-ServiceOnly` 更新受管理员保护目录中的服务，安装成功，已验证服务文件 SHA-256 与交付包一致；服务返回 `diagnostics:true`、`state:disconnected`、`coreRunning:false`。完整运行目录及文件摘要位于 `qingzhou-windows-0.8.11-diagnostics-26`，服务验证记录位于 `installed-version-verification.json`。未自动连接节点，用户当前外部系统代理 `127.0.0.1:7897` 保持不变。

## GitHub 发布准备

发布前快进合入远端 `5e15dba664b4b073c3f552a7d99cd419b18cf22a` 的 macOS 网络恢复改动，未覆盖该修改。Windows 客户端显式构建版本仍为 `0.8.11+26`，独立诊断预发布不变更 macOS 的 `0.8.14` 版本。

使用 Inno Setup 6.7.3 和仓库原有安装脚本生成 `qingzhou-0.8.11.26-windows-x64-setup.exe`，包含完整界面、配套服务、Flutter 引擎、资源和微软 C++ 运行库。安装包 SHA-256 为 `6bb3396b7a3d0ab217bcaecf56760a2d283dec01113652b7c6e3f2ab9e2f9d9f`。安装器编译通过，尚未完成完整安装器升级／卸载回归；已有完整客户端启动与配套服务更新验证。此版本仍不代表原始代理故障已通过真实节点验收。
