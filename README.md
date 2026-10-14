# 轻舟代理 0.6.0 · 待验收开发版

macOS 14+、Apple Silicon、SwiftUI，固定 sing-box 1.14.3、Yams 6.2.2。默认系统代理；TUN、自动连接、登录启动及全局快捷键默认关闭。ad-hoc 签名，未做 Apple 公证。本版已完成源码和构建，管理员路径、真实 TUN 及严格质量门禁仍待验收。

## 0.6.0 开发更新与验证边界

- 新增兼容接管：系统代理与 TUN 共用规则，保留企业 VPN 的具体 IPv4/IPv6 路由和 DNS 作用域；支持补充内网域名。默认选择仍为系统代理，不自动启用接管。
- helper 协议升级为 3；更新应用后须重新安装随包的 helper，以更新固定客户端签名身份。启动、网络变化及恢复按本次所有权处理，不覆盖其他代理或企业 VPN。
- 应急恢复不再依赖当前模式；代理恢复失败仍尝试 helper 和本地核心清理，核对失败明确显示恢复未完成。
- 钥匙串读取允许系统原生授权，成功凭据仅缓存于当前进程；取消、缺失、交互不可用等错误分别提示。ad-hoc 签名更新后仍可能再次首次授权。
- 回归：76 场景、714 条断言通过；回环网络 3 场景、组合转发 8 场景通过；新增接管六项定向变异检出。定向变异不是 PIT 完整门禁。
- 尚未完成真实 TUN 三轮启停、企业 DNS/HTTPS/SSH 与三十分钟长连接验收；100% 行/分支覆盖率门禁未通过。本版不是已完成稳定性验收的正式发布。
- 源码仓库只包含通用默认规则，不预置公司域名，不包含用户节点、凭据、运行日志或应用二进制。

## 使用与新增功能

- 节点页支持链接、HTTPS 订阅、Base64、兼容 Clash/Mihomo YAML、文件拖入和本地二维码图片。输入转换成受限模型，不直接执行下载的配置。图片/文本上限 2 MiB，图片最多 2000 万像素、20 个二维码。
- 节点支持搜索、收藏、备注、最近使用、列表/紧凑卡片、多选、批量收藏/删除/测速。按唯一协议/服务器/端口保留更新节点的备注与收藏，歧义时不猜测。未变化节点保留 ID。
- 分享窗口需主动确认生成含凭据的链接/二维码；可复制链接或保存图片。应用不后台读取剪贴板。关闭分享窗口不清理用户已经复制的剪贴板内容。
- 配置页可新建、复制、改名、删除非当前配置；每份独立保存节点、订阅、策略、规则、选择。办公模板由用户填写内网域名，留空为通用模板，不预置公司域名。连接中切换采用校验、重连、提交；失败恢复上一运行配置。跨配置仍引用的凭据不清理。
- 更新预览显示新增、删除、参数/名称、证书验证、策略和规则变化。删除当前节点、证书验证降低或不兼容内容暂停自动应用。确认后才替换数据。
- fallback 仅接受节点成员，编辑器上下排列优先级；应用管理 selector，每 60 秒用 HTTPS 检测，超时 8 秒、最多 4 并发。当前节点连续失败两次切换，高优先级连续成功两次切回，切换间隔至少 60 秒；保留已有连接，无直连后备。全部节点或当前 fallback 组失败时停止接管并恢复原网络。
- 自动选择仍为核心 URLTest，每 5 分钟、50 ms 容差。测速是 HTTPS 请求延迟，不是下载带宽；断开测速使用普通用户受监护临时核心，不改系统代理。
- 规则解释页共用匹配模型，不查询实时 DNS；无法确定 IP 条件时明确显示限制。模拟结果与核心真实规则字段分开；连接详情可生成待确认规则。
- 最近 30 分钟速率图、按节点/目标聚合、连接排序/协议筛选仅保存在内存。聚合基于轮询观测，短连接可能未计入，不等同核心累计总量；重连清零。未提供的应用/规则字段不猜测。
- 诊断分开显示核心、端口、配置、权限、DNS、TLS、HTTPS、恢复及 TUN 路由/DNS。未连接不自动接管；无法独立归因的阶段显示未验证。导出默认脱敏。
- 菜单栏增加配置、实际节点、速率、暂停、诊断和恢复。快捷键默认关闭，可选择 P/D/R 与 ⌘⌥、⌘⌃、⌃⌥、⌘⌃⌥，注册时检查占用，冲突保留原设置。

导入协议为 HY2、SS（AES-128/256-GCM、ChaCha20-IETF-Poly1305）、Trojan TCP/TLS、VLESS TCP/WS/TLS/Reality/Vision。Reality/Vision 仅配置校验，尚无真实服务转发证据。策略 select/url-test/fallback，拒绝循环；fallback 不接受组、自动组或直连。规则 DOMAIN、DOMAIN-SUFFIX、DOMAIN-KEYWORD、IP-CIDR、IP-CIDR6、MATCH。外部端口/控制/TUN 不带入应用；脚本、覆写、proxy-providers 等列入不支持内容。未知节点参数拒绝。无解密、脚本、云同步、负载均衡或应用商店发布。

规则顺序：模式 → 本机/私网直连 → 用户规则 → 排列的远程规则源 → 默认策略。远程源动作统一覆盖，HTTPS 请求 15 秒、2 MiB、50,000 条限制。订阅/规则默认每 24 小时，仅应用运行时更新，失败保留旧数据，最多三次退避重试。隐藏窗口刷新降为每 5 秒。

## 数据、备份和回退

用户数据在 `~/Library/Application Support/Qingzhou/`。根 state.json schemaVersion=3，配置集合内沿用兼容 schema 2 的配置结构。元数据不含密码、完整订阅/规则地址或 API 密钥；凭据在 Keychain。文件 0600、目录 0700；敏感运行配置停止后清理。API 回环、每次随机 Bearer 密钥，无网页面板。日志脱敏，最多 500 行。

首次迁移先保存包含必要凭据的 `migration-v3.qzb` 加密快照，随机口令在 Keychain，`migration-v3.keyref` 只存引用；成功后才替换元数据。凭据缺失/保存失败不覆盖旧文件。保留旧节点 ID、收藏、规则、订阅和启动设置。

配置页支持 AES-GCM 完整备份、恢复预览、升级前快照。PBKDF2-SHA256 600,000 次、随机 16 字节盐和随机 nonce；口令不写入备份。明文最大 32 MiB、文件上限 48 MiB。错误口令、损坏、不支持版本先拒绝；恢复暂存新凭据，运行成功提交后清理旧凭据，失败回滚。

回退 0.2：先预览升级前快照，导出 0.2 回退数据并恢复必要旧 Keychain 引用；已有不同凭据引用时拒绝覆盖。退出 0.3，另存当前 state.json，将导出文件改名 state.json 放回用户数据目录，再启动历史版本-0.2。不要将 schema 3 文件交给旧版。含 fallback/TUN 的新快照不能给 0.2；升级后新增数据先另存完整加密备份。

## TUN 与管理员服务

设置页复制安装/修复、卸载或管理员恢复命令，由用户在终端完成 sudo：

```sh
sudo bash scripts/install-helper.sh '/绝对路径/轻舟代理.app'
sudo bash scripts/recover-helper.sh
sudo bash scripts/uninstall-helper.sh
```

root 目录 `/Library/PrivilegedHelperTools/cn.qingzhou.proxy`，launchd 标签 `cn.qingzhou.proxy.helper`。固定组件 SHA-256、版本、客户端 CDHash；LOCAL_PEERTOKEN audit UID 与 Security.framework 动态代码有效性/CDHash 校验。socket 0600，控制模型最大 4 MiB；仅 status/start/stop/recover，不接收 shell、任意程序路径或外部配置。变更核心/辅助服务/客户端后重新批准安装。

gVisor、MTU 1500、IPv4/IPv6；核心 auto_route 和内置 DNS 修改关闭，辅助服务记录和管理自己的四条半网接管路由、私网/用户 CIDR/直连规则/节点/引导 DNS 绕行及主服务 DNS，不替换现有同前缀路由。要求原 IPv4/IPv6 默认路由同一物理接口、可读取原 DNS；不满足明确拒绝。虚拟网段根据已有路由检查选择。

默认代理域名经代理请求 Cloudflare HTTPS DNS，节点和明确直连域名使用原 DNS；可选全部原系统解析，无 Fake-IP。更高优先级 VPN、应用内加密 DNS 不保证覆盖。系统代理与 TUN 不同时接管。

检测活动 VPN、非本机隧道路由、已有 HTTP/HTTPS/SOCKS/PAC；归属不明阻止启动，不能仅凭 utun 存在判断。本机预检已检测到活动 VPN，未启用 TUN，未改其配置。

root recovery.json/runtime.json 为 0600。写入前保存意图，清理时核对前缀、接口、网关和 DNS 当前值；外部修改冲突保留记录，不覆盖。正常断开先恢复网络后停核心；核心崩溃、应用 socket 中断、服务退出/重启执行恢复，不自动重新接管。SIGKILL 恢复、管理员批准/取消、卸载及真实 TCP/UDP/DNS/IPv6 仍待验收。失效恢复原网络，可能恢复直连，无持续断网保护。

外部冲突时使用管理员恢复命令重试，仍冲突由用户核对 scutil --dns、netstat -rn 与记录，保留原值，只处理确认仍归轻舟所有的设置；不要盲目清除其他 VPN、默认路由或 PAC。恢复记录未处理时安装/卸载拒绝删除组件。

## 构建和质量

```sh
scripts/build-app.sh /绝对路径/outputs
scripts/swift-local.sh run QingzhouChecks
.build/debug/QingzhouChecks runtime-checks
python3 scripts/integration.py
python3 scripts/features-integration.py
scripts/coverage.sh
python3 scripts/mutation-check.py
```

受限沙箱可能禁止 macOS DNS notification（status 9），受控核心测试需允许读取系统 DNS；不会修改系统代理或 TUN。隔离 SystemConfiguration 写入测试也需要管理员，不能替代真实用户授权与网络恢复验收。

适用代码门禁仍为 100% 行/分支覆盖及至少 80% 全项目变异检出率。当前未达到/未取得；六个定向变异不能代表全项目指标。详细状态见交付验收记录。

依赖：[sing-box 官方来源](https://github.com/SagerNet/sing-box)、[TUN 文档](https://sing-box.sagernet.org/configuration/inbound/tun/)、[Yams 6.2.2](https://github.com/jpsim/Yams/tree/6.2.2)。版本、下载哈希、许可证与源码获取说明随 Vendor 交付。固定源码参考 sing-tun bca4bf029237，参考归档 SHA-256：10310d412692015c8d2056af83db58c15728b56bf4db6c87a32dcdc9b8ecc071。
