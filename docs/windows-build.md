# Windows 本机构建与验证

本轮暂停 iOS，只推进 Android、Windows 并保留 macOS 兼容。Windows 完整客户端需要在 Windows 10/11 x64 上编译。本机 macOS 只完成服务交叉编译，不能代替 Windows 界面构建和安装验收。

## 准备环境

1. 安装 Flutter 3.47.7，将 `flutter/bin` 加入 PATH。SDK 可从 [Flutter 官方归档](https://docs.flutter.dev/install/archive)下载。
2. 安装 Go 1.26.5、Python 3.11 或更新版本，确保 `go` 和 `python` 命令可用。
3. 安装 Visual Studio，勾选“使用 C++ 的桌面开发”，包含 MSVC、Windows SDK 和 CMake 组件。Visual Studio Code 不能替代这些构建工具。配置依据：[Flutter Windows 官方说明](https://docs.flutter.dev/platform-integration/windows/setup)。
4. 安装后重新打开终端，检查以下命令：

```powershell
flutter --version
go version
python --version
flutter config --enable-windows-desktop
flutter doctor -v
flutter devices
```

`flutter doctor` 的 Windows 和 Visual Studio 检查应通过，`flutter devices` 应列出 windows。只构建 Windows 不需要 Android SDK、完整 Xcode、Apple 签名或 gomobile。

## 使用源码测试包

把 `qingzhou-windows-source.zip` 复制到 Windows 后解压到普通用户可写的目录，例如 `C:\Code\qingzhou-proxy`。包内保留本轮未提交修改，包含源码摘要清单；不依赖 Git 仓库，也不包含本机缓存、凭据或 SDK。

双击解压目录中的 `build-windows.cmd`。它会执行 `clients/qingzhou/tool/build_windows.ps1`，依次校验源码、同步版本、构建服务、检查依赖、执行 Flutter 静态分析和测试，再构建 Windows Release 界面。首次构建需要联网下载依赖，具体失败信息会保留在终端。

也可从源码仓库手动运行：

```powershell
cd clients\qingzhou
powershell -NoProfile -ExecutionPolicy Bypass -File tool\build_windows.ps1
```

成功后在根目录 `outputs` 中生成带时间和随机编号的 ZIP、构建说明、许可证、核心源码锁和 SHA-256 清单，不覆盖旧包。版本来自 `Sources/QingzhouKit/BuildVersion.swift`，当前为 0.8.10（24）。

## 安装测试

解压生成的客户端 ZIP，在该目录执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-windows.ps1
```

脚本会按需弹出 UAC，为发起安装的用户配置独立网络服务。界面以普通用户运行。安装完成后启动 `C:\Program Files\QingzhouProxy\qingzhou.exe`。

先使用一个测试节点验证系统代理模式：连接、当前出口 HTTPS 检查、托盘断开、关闭窗口后托盘保活、应用异常退出后的代理恢复，再验证 TUN 和组合模式。其他软件正在接管代理或 PAC 时，应显示冲突提示并保留原设置。

注册表读取失败或类型不支持时拒绝接管；恢复前逐字段核对所有权；外部修改、损坏记录及写入失败均保留恢复记录。旧开发版不带版本的恢复记录也会保留并阻止接管，不能手动删掉记录来冒充恢复成功。

卸载服务时从安装包目录执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-windows.ps1 -Uninstall
```

卸载会先停止并恢复代理；存在未恢复记录时拒绝继续。安装目录和用户数据保留，便于回退。

## 验收记录

请分别记录 Windows 版本、构建日志、安装结果、节点协议、DNS/TCP/UDP/IPv6、权限、休眠恢复及两小时稳定性。普通编译成功不等于这些运行检查通过。完整覆盖率和变异门禁仍未满足，详见 `verification-crossplatform.md`。
