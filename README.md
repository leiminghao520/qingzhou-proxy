# 轻舟代理 0.2.0

原生 SwiftUI macOS 客户端，最低 macOS 14，Apple Silicon，sing-box 1.14.3 普通用户子进程。源代码与开发构建可用，验收范围和待验收项目见交付验收记录。

## 使用

1. 打开应用，选择“链接导入”粘贴节点或 HTTPS 设备订阅，也可“文件导入”选择 UTF-8 YAML / 链接列表。
2. 在预览中选择“仅节点”或“节点、策略及规则”。完整范围有不支持项时禁止确认；仅节点须明确确认跳过不支持内容。跳过 TLS 验证的节点另需明确确认。
3. 在节点页选择节点，或策略页选择手动分组/自动选择，再连接。系统弹出授权窗口时由用户完成管理员授权。
4. 已连接代表核心与系统代理设置成功；远端 HTTPS 连通性独立显示。菜单栏可切模式、选策略、测速、更新或复制终端代理命令。
5. 断开和正常退出会恢复原代理；关闭主窗口后菜单栏继续运行。异常退出后重开应用可恢复残留。

设备链接从现有 HY2 admin 的 owner 设备页复制 `hy2.txt` 地址即可。应用和源码没有预置设备链接或 VPS 密钥。0.2 本轮已获授权只读提取现有 owner 设备订阅，完成多节点配置校验、原生 HTTPS 检测及 curl HTTPS 请求。临时凭据随后删除；真实系统代理路径仍待管理员验收。

## 日常功能

- 节点搜索、收藏、名称/协议/延迟排序；单节点、批量 HTTPS 延迟检测。超时 8 秒、最多并发 4 个、可取消。离线测速启动临时受监护核心，不改系统代理。测速不是带宽测速。
- 内置手动选择与自动选择，支持自定义 select/url-test 及组引用。核心 tag 使用稳定 UUID；循环和歧义引用拒绝。自动选择每 5 分钟检测、改善超过 50 ms 才切换；内置自动组只有节点，无直连后备。
- 规则、全部代理、全部直连通过控制 API 切换；选择只影响新连接。节点集合、规则结构改变采用校验后重连，失败保留原数据并尝试恢复原运行配置。
- 订阅改名、手动更新、自动更新开关、时间、失败原因、服务端用量/到期。默认每 24 小时、仅应用运行时，启动时补到期更新；失败后 60/300/1800 秒退避，最多 3 次，下个周期重试。新增不验证证书节点暂停更新，等待预览确认。
- 远程规则源支持 HTTPS 逐行域名/IP、Clash 文本、YAML payload、sing-box JSON 独立域名/IP规则集。默认 24 小时更新、可手动更新、拖序替代为上下移动；失败保留缓存。每次下载 15 秒、2 MiB、规则最多 50,000 条。
- 概览显示核心实时上传/下载速率、累计流量、连接数、实际节点。连接页可搜索、查看详情、关闭单条/全部连接。核心未提供的字段显示“未提供”，详情只保存在内存。每秒刷新，隐藏窗口时 5 秒；暂停刷新不停止代理。
- 登录启动和启动后自动连接独立，均默认关闭。登录启动需先将应用移入 `/Applications`，允许系统登录项。

## 导入兼容范围

- `hy2://`、`hysteria2://`、`ss://`、`trojan://`、`vless://`；HTTPS 链接列表、Base64 链接列表、兼容 Clash/Mihomo YAML。
- HY2 支持完整认证、SNI、TLS 验证开关、salamander 混淆、端口跳跃。SS 支持 AES-128-GCM、AES-256-GCM、ChaCha20-IETF-Poly1305。Trojan TCP/TLS；VLESS TCP/WS、TLS/Reality/Vision。Reality/Vision 本轮只做配置校验，未做真实服务转发。
- YAML 策略 select/url-test；规则 DOMAIN、DOMAIN-SUFFIX、DOMAIN-KEYWORD、IP-CIDR、IP-CIDR6、MATCH，动作 DIRECT、REJECT、兼容组。测速 URL/间隔/容差统一采用应用默认值，预览告知。
- 外部控制、端口等配置不带入应用；proxy-providers、脚本、DNS/Geo 数据和不兼容配置明确列出。禁止 YAML 锚点/别名，避免展开造成资源耗尽。未知节点参数不会静默忽略。
- 远程规则的动作由规则源设置统一覆盖，文本里的动作不决定执行动作。JSON 仅支持独立 domain/domain_suffix/domain_keyword/ip_cidr 条件，组合条件拒绝。
- 匹配顺序为模式 → 本机/私网直连 → 用户规则 → 排列的规则源 → 默认策略。远程 MATCH 会匹配之后所有目标，应放在末尾。

仅覆盖遵循 macOS 系统代理设置的应用。无 TUN、全机 UDP/DNS 接管、HTTPS 解密、脚本、云同步或自动后台守护更新。

## 数据、安全和恢复

数据目录 `~/Library/Application Support/Qingzhou/`：`state.json` schemaVersion 2，非敏感元数据和规则缓存；`proxy-recovery.json` 原代理/PAC 快照；临时 `runtime-*.json` 运行凭据及随机 API 密钥。文件 0600，目录 0700。普通元数据不含密码、订阅完整 URL 或 API 密钥；它们在 Keychain 或临时运行配置内。API 仅回环、Bearer 验证、没有网页面板。日志脱敏、最多 500 行、仅内存。

单实例锁防止并发覆盖。监护进程在主应用死亡时停止核心；残留代理下次启动恢复。恢复前比较本应用写入字段，外部冲突保留恢复记录，避免覆盖外部修改。若授权或恢复失败，用恢复入口；必要时根据恢复记录在系统网络设置内手动恢复，勿盲目清除原代理/PAC。

首次从 schema 1 迁移保存 `state-v1-backup.json`，0600；迁移失败不覆盖原文件。旧节点 ID、Keychain 引用、订阅和规则保留。首次迁移后、尚未编辑数据时，可退出应用，将当前 state.json 另存备份，再用 state-v1-backup.json 替换并启动旧版。**0.2 更新后不能直接恢复旧备份**：旧凭据可能已退休。需要先保留当前 schema 2 数据，并将当前节点与凭据引用转换为 schema 1；高级组/规则/远程源无法在旧版表达，须另存并明确取舍。建议使用交付目录的 0.1 归档仅做版本回退参考，不在旧版中覆盖 0.2 数据。

## 构建与测试

需要 macOS Command Line Tools / Swift 6.2、Python 3、codesign；集成测试使用 curl/openssl。不依赖完整 Xcode 的 XCTest。

```bash
scripts/build-app.sh /绝对路径/outputs
scripts/swift-local.sh build --enable-code-coverage
.build/debug/QingzhouChecks
.build/debug/QingzhouChecks runtime-checks
python3 scripts/integration.py
python3 scripts/features-integration.py
python3 scripts/supervisor-check.py
```

集成核心需要 macOS DNS 通知权限，沙箱内可能报 status 9，应从普通 Terminal 执行。`sudo .build/debug/QingzhouChecks system-proxy-checks` 使用隔离偏好文件测试，非默认系统配置；非管理员返回 77。本轮仍未取得真实系统代理授权验收。

构建验证固定核心及 Yams 归档/来源文件；应用、核心、监护程序仅 ad-hoc 签名，未 Apple 公证。代码测试通过不等于管理员路径或严格质量门禁通过。覆盖率和变异证据见验收记录。

## 来源和许可

界面和管理逻辑独立实现；Shadowrocket 2.2.90 仅用作本机静态结构参考，没有复制代码/资源或读取其账号。

sing-box [官方 v1.14.3](https://github.com/SagerNet/sing-box/releases/tag/v1.14.3)，对应源码归档和 GPL 许可在 Vendor。固定归档 SHA-256 `0360ce634a04c26a6b4fd957517987bb4f6c8950f63435ce3c5af2fcae5860c5`，未重新签名核心 `28b7200074d6380006acc4f035a404c8af3dceb65dd92d7386ed92c9224e08a2`。

Yams [官方 6.2.2](https://github.com/jpsim/Yams/tree/6.2.2)，MIT 许可、固定源码和官方归档保留；SHA-256 `c18b63003173ff886eb781e0cbb2cba612fb5c68485b0cd4e66ad06b686091e8`。各依赖保留原版权。项目源码 GPL-3.0-or-later。
