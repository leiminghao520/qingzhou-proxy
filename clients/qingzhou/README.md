# 轻舟代理跨平台客户端

本目录新增 iOS、Android、Windows 客户端，原有 macOS SwiftUI 工程继续由仓库根目录构建。当前属于开发测试版本，尚未完成三端安装、真实 VPN/TUN 和两小时稳定性验收；不能把共享层测试或 AAR 编译通过视为三端交付完成。

按 2026-10-17 的最新约定，iOS 开发和验收暂停，保留已有工程；当前只推进 Android 与 Windows。Windows 本机的环境准备、源码包使用及安装命令见 [Windows 构建说明](../../docs/windows-build.md)。

## 支持范围

- iOS 16+，Swift Packet Tunnel 扩展；Android 10+ ARM64，Kotlin VpnService；Windows 10/11 x64，Flutter 界面与独立 Windows 服务。
- Flutter 3.47.7 / Dart 3.13.5，Go 1.26.5，sing-box 1.14.3，SagerNet gomobile v0.1.12。依赖分别锁定在 pubspec.lock、runtime/go.mod 与 runtime/go.sum。
- 节点链接、Base64、受限 Clash YAML、轻舟完整订阅与二维码图片导入；订阅更新预览、收藏与备注、分享链接和二维码；批量选择、收藏和删除；多配置、选择/自动测速/优先回退策略组、规则编辑与远程规则源；加密备份、连接观测和外观设置。
- 默认关闭自动连接、登录启动与 HTTP 兼容模式。移动端仅提供 VPN 接管；Windows 提供系统代理、TUN、组合接管。其他平台的接管设置在恢复时明确预览转换。
- 不包含账号或云同步。企业保护域名、自定义 TUN 排除路由尚未迁移，包含这些设置的配置保留原数据并拒绝运行；请复制配置后调整。支持离线与连接中单节点 HTTPS 测速；登录启动、全局快捷键、批量测速及监控聚合仍待补齐。远程规则源支持自动更新，完整订阅中的提供器与脚本不支持。

## 工具链与构建

安装 Flutter 3.47.7、Go 1.26.5。Android 需要 JDK 17、Android SDK 36、Build Tools 36.0.0、NDK 28.2.13676358。Windows 界面需要在安装了 Visual Studio C++ 桌面开发组件的 Windows 上构建。iOS 的旧构建说明保留供后续恢复开发时使用，本轮无需准备其工具链。

```sh
cd clients/qingzhou
flutter pub get --enforce-lockfile
go install github.com/sagernet/gomobile/cmd/gomobile@v0.1.12
go install github.com/sagernet/gomobile/cmd/gobind@v0.1.12
export PATH="$(go env GOPATH)/bin:$PATH"
python3 tool/sync_version.py
```

版本唯一来源仍为根目录 Sources/QingzhouKit/BuildVersion.swift。版本生成脚本更新 Flutter 与 Xcode 的构建值。核心源码锁定提交 `7054cac5124465ffdb145870d7c01885566711b1`，构建前核对 module 摘要与提交。原生核心包含 QUIC、uTLS、gVisor 和 Clash API，遵循上游的 `-checklinkname=0` 链接设置；不调用下载配置中的 shell 或程序路径。GPL-3.0-or-later 许可证随测试包提供。

Android：设置 ANDROID_HOME、ANDROID_NDK_HOME 与 JAVA_HOME 后执行 `bash tool/build_android.sh`。输出 ARM64 调试签名 APK，明确属于测试包；脚本将产物复制到根目录 outputs 下独立目录并记录摘要，不覆盖旧包。

iOS：执行 `bash tool/build_ios.sh`；可附加 Flutter 支持的签名或导出参数。`tool/configure_ios.rb` 需要 Ruby xcodeproj 1.27.0，会维护 Runner、PacketTunnel 两个 target、共享源码和扩展嵌入关系。两个 target 均需设置开发团队，启用 Network Extension、App Group `group.cn.qingzhou.qingzhou` 和共享 Keychain。无法签名时不生成声称可安装的 IPA。

Windows：在 PowerShell 中执行 `tool/build_windows.ps1`，得到包含界面、服务与安装脚本的 ZIP。解压后运行 `install-windows.ps1`；脚本按需请求 UAC，保留发起安装的用户 SID，安装到 Program Files 并启动服务。卸载服务执行 `install-windows.ps1 -Uninstall`，保留用户数据和安装目录；存在未恢复记录时拒绝覆盖组件。尚未在 Windows 上执行此完整流程。

## 运行边界

共享业务层只向原生层提交受限模型。原生层校验协议参数、策略循环及规则引用，生成核心配置。控制 API 仅监听回环地址，随机认证密钥不返回界面。Windows 命名管道同时限制 ACL，并核对服务端 PID 与 SCM 登记的服务进程。

移动端的代理与优先回退定时器在原生服务或扩展内运行，不依赖 Flutter 后台计时。优先回退先在未接管网络的核心中按优先级探测，四并发、八秒单次预算、二十五秒初始化总预算；运行期间每六十秒检查，连续两次失败/恢复后切换，切换至少间隔六十秒。全部失败时关闭核心，由宿主结束隧道或恢复系统代理。

HTTP 兼容层从 tools/httpcompat/gateway 共享源码直接嵌入，根目录原有 qzhttp CLI 继续调用同一实现。仅对采用本地 HTTP 代理入口的流量提供 User-Agent 与重写；不解密 HTTPS，也不承诺所有移动应用遵循系统提供的 HTTP 代理设置。

本地目录独立于 macOS 旧数据，快照使用随机 AES-GCM 密钥加密；密钥由 flutter_secure_storage 交给平台安全存储管理。Windows 使用当前用户 DPAPI 包装快照密钥，再由凭据管理器保护；该路径仍待 Windows 编译与实机验证。`.qzb` 延续 Swift 版 PBKDF2-SHA256 600,000 次、AES-256-GCM、相同 AAD 及 nonce/ciphertext/tag 布局。新凭据和配置整体写入加密快照后，才切换安全存储中的活动引用。恢复不会开启自动连接。

## 验证

```sh
flutter analyze
flutter test --branch-coverage
(cd runtime && go test -race -tags 'with_gvisor,with_quic,with_utls,with_clash_api' ./...)
(cd ../../tools/httpcompat && go test -race ./...)
python3 tool/verify_interop.py
```

互通检查需要先在仓库根目录运行 `scripts/swift-local.sh run QingzhouChecks`，再将 Flutter 的 dart 加入 PATH。它用实际 QingzhouKit.BackupService 读取 Dart 导出的备份。Flutter 测试还会读取 Swift CryptoKit 生成的固定测试备份；所有样例均为虚构凭据。

质量要求保持适用代码行/分支覆盖率 100%、变异检出率至少 80%。当前尚未达到此门禁，原生平台、后台运行、断网恢复和真实网络检查仍需独立验收。详细结果见仓库 docs/verification-crossplatform.md。
