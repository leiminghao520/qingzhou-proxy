# 轻舟代理 0.1.0

原生 macOS 系统代理客户端，SwiftUI 界面与 sing-box 1.14.3 独立子进程。优先支持 Hysteria2 VPS 的设备专用链接导入。最低 macOS 14，交付版本为 Apple Silicon。

## 使用

1. 打开 `轻舟代理.app`，点击“链接导入”。
2. 从现有 HY2 admin 的设备页复制该设备的通用 Hysteria2 订阅（`hy2.txt`），或粘贴 `hy2://` / `hysteria2://` 单节点链接。
3. 查看节点预览并“确认导入”。如果链接要求跳过证书验证，预览会要求明确确认。
4. 选中节点后点击“连接”。如系统请求管理员授权，请由你完成本机授权。
5. “已连接”表示本地核心就绪且系统代理设置完成；“HTTPS 连通性正常”表示应用通过该代理请求 Apple 检测页成功。
6. “断开”会恢复原代理。关闭主窗口后菜单栏继续运行；从菜单栏或应用菜单退出会恢复原设置。

本次实际 VPS 订阅导入及 HTTPS 转发验收通过。应用中没有预置设备订阅、密码、账号或密钥；验收使用的临时凭据已删除。

## 功能与范围

- 节点手动添加、编辑、删除、选择；连接时切换节点会断开后重连。
- HTTPS 节点列表订阅导入、预览、手动更新、删除。更新全部校验成功才替换；失败保留旧节点。不支持定时更新。
- SS：AES-128-GCM / AES-256-GCM / ChaCha20-IETF-Poly1305。
- Trojan：TCP/TLS。
- VLESS：TCP / WebSocket，TLS / Reality / Vision。Reality、Vision 的配置已校验；本次实际转发测试覆盖 TCP/TLS 与 WebSocket/TLS。
- Hysteria2：完整认证字符串、SNI、证书验证开关、salamander 混淆、端口跳跃范围、带宽参数。
- 全部代理或规则模式；规则支持域名、域名后缀、IP/CIDR → 直连、代理、拒绝。
- 规则模式中本机及私网优先直连，用户规则按列表顺序匹配，其余代理；规则修改在下次连接生效。
- 核心仅监听 `127.0.0.1`，默认端口 7890，可在设置中更改。
- 运行日志最多 500 行，完整链接、UUID、密码及令牌脱敏；日志只保存在内存。
- 独立核心监护进程在主应用异常结束后停止核心。遗留系统代理在下次启动恢复。

仅接管遵循 macOS 系统代理设置的应用。没有 TUN、全机 UDP/DNS 接管、脚本、HTTPS 解密、策略组或云同步。Hysteria2 到服务器的传输使用 QUIC/UDP，这与接管全机 UDP 是两回事。

只接受节点链接和返回逐行节点链接的 HTTPS 订阅。完整 Shadowrocket 配置、Mihomo YAML、sing-box JSON 不会被执行。未知参数直接报错，避免导入后悄悄丢失设置。

## 数据与恢复

- `~/Library/Application Support/Qingzhou/state.json`：节点元数据、规则、选择和监听端口，权限 0600。
- `~/Library/Application Support/Qingzhou/proxy-recovery.json`：原代理恢复记录，权限 0600。原系统 PAC 设置若含敏感值，也只保存在此受保护记录中。
- `~/Library/Application Support/Qingzhou/runtime-*.json`：运行时临时配置，权限 0600；正常停止清理，异常遗留在下次启动清理。
- 凭据和完整订阅地址位于 macOS 钥匙串的 `cn.qingzhou.proxy.credentials` 服务。
- 同时只运行一个应用实例；第二个实例不会覆盖第一个实例的配置。

连接前保存快照，再修改当前网络位置内启用服务的 HTTP/HTTPS/SOCKS 及自动代理启用项。断开时只恢复仍属于本应用的字段，保留其他字段的后续修改。发生冲突时不强行覆盖，保留恢复记录并提示处理。

如果异常退出后网络受影响，重新打开应用使用“恢复原代理”。若系统授权失败或存在外部修改冲突：打开“系统设置 → 网络 → 对应网络服务 → 详细信息 → 代理”，检查本应用写入的 `127.0.0.1` 及监听端口，并参考恢复记录恢复原有设置。不要在未检查原记录时把原来就存在的代理/PAC 一并清除。恢复确认完成前应用不会正常退出并丢弃记录。

## 构建

依赖：macOS Command Line Tools / Swift 6.2、Python 3、系统 codesign。不需要完整 Xcode；集成测试另需 curl 和 openssl。

```bash
scripts/build-app.sh /绝对路径/outputs
```

`Vendor/core-lock.json` 固定核心版本、压缩包与二进制 SHA-256。构建前校验；缺失或被改变时从官方 release 下载，必须通过固定哈希检查。应用、核心和监护程序使用本机 ad-hoc 签名。本次未做 Developer ID 签名或 Apple 公证，属于本机开发构建。

## 测试

```bash
scripts/swift-local.sh build --enable-code-coverage
.build/debug/QingzhouChecks
.build/debug/QingzhouChecks runtime-checks
python3 scripts/integration.py
python3 scripts/supervisor-check.py
```

测试采用可执行 Swift 行为检查器，不依赖当前环境缺失的 XCTest；错误断言返回非零退出码。

隔离网络偏好文件的持久化 API 测试需要管理员权限，测试不会使用默认系统偏好文件：

```bash
sudo .build/debug/QingzhouChecks system-proxy-checks
```

普通权限下该命令返回 77，明确标记跳过。本次未完成这一管理员路径，也未在用户真实系统设置上完成切换/恢复。逻辑测试、真实代理核心转发和 VPS 转发不能替代该验收。

## 来源和许可

界面和管理逻辑独立实现；本机 Shadowrocket 2.2.90 仅用于静态包结构参考，没有复制其代码、图片或配置，也没有读取其保存的账号。

sing-box 官方 release：[1.14.3](https://github.com/SagerNet/sing-box/releases/tag/v1.14.3)

核心归档 SHA-256：`0360ce634a04c26a6b4fd957517987bb4f6c8950f63435ce3c5af2fcae5860c5`

未重新签名前核心 SHA-256：`28b7200074d6380006acc4f035a404c8af3dceb65dd92d7386ed92c9224e08a2`

官方对应源码：[v1.14.3](https://github.com/SagerNet/sing-box/tree/v1.14.3)

`Vendor/` 中保留核心许可、GPL 全文和对应官方源码归档。本项目源码按 GPL-3.0-or-later 提供；上游组件保留其各自版权和许可。应用名与图标为本项目自有，不表示与 Shadowrocket 或 sing-box 官方有关联。
