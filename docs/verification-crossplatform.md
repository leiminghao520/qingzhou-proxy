# 跨平台开发验证记录

日期：2026-10-17（Asia/Shanghai）。本记录区分源码、构建、自动化和实际平台验证，尚未完成原计划的三端可安装测试版交付。

最新范围：用户已暂停 iOS 开发，保留源码，当前只推进 Android、Windows。Windows 完整构建和实机检查由用户稍后在 Windows 电脑执行，本机交叉编译不替代该证据。

## 实现

新增 clients/qingzhou Flutter 工程和原生运行层，保留 macOS 工程。共享受限模型、协议校验及配置生成；iOS Packet Tunnel、Android VpnService 和 Windows 服务分别管理平台生命周期。现有 HTTP 兼容代码迁入 tools/httpcompat/gateway 库，原 CLI 保留同一行为和测试。

实现订阅/节点导入、更新预览、前台更新与退避、二维码图片、收藏/备注、分享、策略组、规则、远程规则、多配置、备份恢复及基础监控。支持离线与连接中单节点测速、当前出口 HTTPS 检查。原生回退调度不依赖 Flutter。包含平台不支持的企业保护或排除路由时拒绝运行并保留原配置。

## 已执行

- macOS 原有 QingzhouChecks：121 场景、1258 断言、0 失败。
- HTTP 兼容层原有 Go 测试在迁移后通过，使用 race 检查。
- 新增 Go 配置校验、可达回退组、迟滞切换与移动运行库隔离测速生命周期测试通过，使用 race 检查。移动运行库测试使用 macOS SDK，没有打开 VPN。
- 内嵌核心普通模式与 HTTP 兼容模式的隔离回环 HTTPS 转发和启停检查通过；没有修改当前机器的系统代理、DNS 或 TUN。
- Flutter 已执行导入、二维码、远程规则、备份完整性、配置回滚、手机/桌面导航、批量操作、忙碌时心跳、长时间系统授权及 Windows RPC 封装测试：最终 23 项通过，静态分析无问题。RPC 使用模拟通道，不等于 Windows C++ 和服务实机验证。
- Android ARM64 原生 AAR 与调试 APK 构建通过；APK v2 签名校验通过，版本 0.8.10+24、minSdk 29、targetSdk 36。Windows x64 服务交叉编译通过。完整 Windows 界面尚未编译。
- iOS 扩展语法和与生成的 Objective-C 接口的局部类型检查已执行；局部检查使用 macOS SDK，不能代替 iOS SDK 编译与签名。

## 尚未验收

- iOS 完整 Xcode/iOS SDK 构建、开发团队、签名、安装和 Packet Tunnel 实机运行。
- Windows Flutter 界面编译、ZIP 安装脚本、服务 ACL/UAC、DPAPI、系统代理广播、TUN 及异常退出恢复。
- Android 真机授权、通知、VPN 转发、撤销权限、进程退出、后台运行及 Wi-Fi/蜂窝切换。
- 三端真实 TCP/UDP、IPv6、DNS、真实节点协议矩阵、睡眠唤醒、其他 VPN 冲突及两小时稳定性。
- 适用代码 100% 行/分支覆盖与至少 80% 完整变异检出率：未通过/未取得完整证据；不以定向测试代替。

## 当前功能差距

企业 VPN 组合保护、自定义排除路由、全局快捷键、登录启动、批量测速、完整流量聚合与规则解释仍未完成跨平台对齐。Windows 的 TUN 和组合接管只能作为待实机验收的实现，不应作为已验证的日常模式。没有提交、推送、上传、商店发布或修改当前系统的代理接管设置。

## 质量数据与环境

- Flutter 使用 `flutter test --branch-coverage`：行 982/1791（54.83%），分支 268/655（40.92%）。低于 100%，不通过既定门禁。
- Go 使用 `go test -race -coverprofile=../build/go-coverage.out -tags with_gvisor,with_quic,with_utls,with_clash_api ./...`：config 50.5%、engine 48.9%、health 83.6%、mobile 41.3%（语句覆盖，不等于分支覆盖）。Windows 专用文件不在宿主测试范围内。
- 新增可移植 systemproxy 模块：Go race 测试通过，语句覆盖 98.4%。覆盖正常恢复、部分写入失败、外部修改、读写错误、记录损坏及文件持久化；注册表 API 本身仍需 Windows 验证。
- 完整变异测试未执行，不能宣称达到 80%。Kotlin、Swift iOS、C++、Windows Go 的目标系统覆盖证据缺失。
- `xcrun --sdk iphoneos --show-sdk-path` 失败，缺少 iOS SDK；`adb devices` 无设备。没有取得真实节点凭据，真实四协议网络和两小时稳定性均未验证。
- 环境：Flutter 3.47.7、Dart 3.13.5、Go 1.26.5、JDK 17、SDK 35/36、NDK 28.2.13676358、CMake 3.22.1。依赖下载使用本机临时镜像配置，未修改仓库标准仓库地址。AGP 9 的插件迁移弃用提示仍存在。

## 互通范围

实际 Swift BackupService 成功解密 Dart 导出的含 Trojan 节点、凭据和选中策略的备份；Flutter 成功读取 Swift CryptoKit 生成的固定备份。该样例不等于完整 Swift/Dart 导入、规则顺序和核心配置矩阵对照，后者仍需补齐。

## 本轮继续开发

- 解决操作或确认框持续超过二十秒时，Windows 心跳暂停而导致服务误断开的问题。
- 系统代理读取错误和不支持的注册表类型不再当作缺失值；恢复记录先持久化，恢复时逐字段核对所有权。引入版本化记录，旧开发版无版本记录会保留并阻止接管。
- 新增批量选择、收藏、删除；删除预览明确受影响的空策略组、规则及远程规则源；清理递归引用并保留其他配置使用的凭据。连接中的更新仍走保存失败回滚事务。
- Android 请求通知权限，拒绝后保留界面断开入口并提示限制；VPN 授权等待不再受 Dart 四十五秒超时限制；清理隧道时分别处理核心和文件描述符错误。权限操作仅编译验证，仍未取得真机运行证据。
- 提供不含 Git 元数据的 Windows 源码构建包，解压后源码摘要、版本生成和本地 Go 模块替换检查通过；Windows PowerShell 完整构建仍未执行。
