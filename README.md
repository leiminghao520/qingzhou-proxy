# 轻舟代理 · 待真实网络验收开发版

版本唯一来源为 `Sources/QingzhouKit/BuildVersion.swift`，应用包和辅助服务使用同一版本。

macOS 14+、Apple Silicon、SwiftUI，固定 sing-box 1.14.3、Yams 6.2.2。默认系统代理，由 sing-box mixed 入站直接承接 HTTP/HTTPS/SOCKS；HTTP 兼容模式默认关闭，User-Agent 与 URL 重写保留但只在开启兼容模式后生效。TUN、自动连接、登录启动及全局快捷键默认关闭。ad-hoc 签名，未做 Apple 公证。本版已完成源码和构建，管理员路径、真实 TUN 及严格质量门禁仍待验收。

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

用户数据在 `~/Library/Application Support/Qingzhou/`。根 state.json schemaVersion=3，配置集合内沿用兼容 schema 2 的配置结构。新增 httpCompatibilityEnabled 缺省为 false，旧配置升级不会自动启用兼容入口。元数据不含密码、完整订阅/规则地址或 API 密钥；凭据在 Keychain。文件 0600、目录 0700；敏感运行配置停止后清理。API 回环、每次随机 Bearer 密钥，无网页面板。日志脱敏，最多 500 行。

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

构建版本唯一来源为 `Sources/QingzhouKit/BuildVersion.swift`。每次打包在输出目录中新建带版本、时间和随机后缀的目录，并输出 `artifact-manifest.json`，不覆盖旧包。启动前检测本地入口与当前节点，成功后才接管系统代理；界面分别显示运行状态与连通性。模式切换事务重建 DNS 策略。核心 DNS API 承担兼容模式目的解析，A/AAAA 独立查询，失败不回退直连。真实节点、两小时稳定性与 TUN 恢复需单独记录。

附加验证：`/usr/bin/python3 scripts/helper-script-tests.py` 在临时目录模拟安装/恢复/卸载失败，不能替代真实管理员验收。`QingzhouChecks network-acceptance state.json sing-box qzhttp result.json 7200` 只使用临时回环入口，读取现有凭据，对普通/兼容模式执行两小时 HTTPS、节点和 SOCKS 观察，不接管系统网络；结果只含固定阶段和状态。新包清单包含源码树摘要和 Git 基准，明确含未提交变更。


完整接管（0.8.0，待实网验收）：设置中选择“完整接管（TUN＋系统代理）”并明确应用后，规则模式按本机、企业保护、用户规则、国内域名、国内 IP、最终策略依次处理；国内兜底使用随包固定资产，版本和摘要见 `Resources/domestic-rules-lock.json`。企业域名优先使用原作用域 DNS，DNS 回答返回前确认原 VPN 路由，不能确认时拒绝请求。HTTP 兼容开关独立，默认关闭。网络设置先编辑草稿，再一次应用；完整接管期间切换运行模式需确认重连。

辅助服务协议为 4，需要通过应用的安装入口更新；发现未恢复记录时拒绝覆盖旧服务。当前默认接管方式不迁移。构建和回环隔离转发通过不等于管理员 TUN、企业 VPN、Dock 启动软件、休眠唤醒、网络切换或两小时稳定性验收通过，完成这些检查前不要作为默认日常模式。固定国内规则随独立版本包更新，摘要不匹配拒绝完整接管，旧包保留作回退，不进行后台清空或替换。


## 简洁与专业界面

未保存界面偏好时默认使用简洁模式，侧栏提供连接、线路、订阅和设置。侧栏底部及简洁设置页可切换简洁/专业，选择会单独保存在应用偏好中；切换不会修改配置、代理运行模式、接管方式或当前连接。专业模式保留完整节点、策略组、规则、监控和配置管理。

简洁首页提供添加订阅或节点、线路选择和连接操作，分别显示代理运行状态与 HTTPS 检测结果。网络待恢复及订阅待确认提示保留；高级设置和网络诊断可直接打开，无需切换专业模式。高级网络设置仍使用原有草稿及应用流程。

界面检查：`bash scripts/interface-checks.sh`。检查程序单独链接，不加入正式应用；使用新建的独立测试目录和偏好域，生成浅色/深色及窄窗口状态截图，并检查模式切换与偏好持久化。不会调用连接、接管或恢复网络。窗口截图依赖本机已有屏幕录制权限；需要交互检查时可运行 `bash scripts/interface-checks.sh "$PWD/.build/ui-evidence" --interactive`，只使用模拟数据，不要操作真实接管或管理员安装。


## 液态玻璃界面（0.8.9）

macOS 26 使用系统原生 Liquid Glass 导航选中态、连接按钮及界面切换，配合磨砂内容卡片和柔和背景渐变。macOS 14/15 使用兼容材质；开启减少透明度或提高对比度时使用实色表面，开启减少动态效果时取消应用添加的弹簧过渡。界面检查另外生成辅助功能状态截图；旧系统材质仅通过编译兼容检查，未在 macOS 14/15 实机验收。

重新构建会改变客户端代码身份。使用 TUN 或完整接管时，切换新版后需要在设置中的“安装 / 更新辅助服务”完成 macOS 管理员授权，沿用现有安全校验。


## 白天、夜间和跟随系统（0.8.10）

侧栏底部的外观菜单及两种模式的设置页均可选择白天、夜间或跟随系统。默认跟随系统，手动选择立即作用于应用窗口与弹窗，并独立保存偏好，不修改代理配置或触发重连。

## 监控恢复与启动调度优化

流量通道断线后，在当前连接内按 1、2、4、8、16、30 秒退避重连，收到有效样本后重置退避。断开、切配置或退出时取消旧监控；流量、连接列表与节点健康状态分别保存，失效或暂停时速率显示“不可用”。

启动仅初始化当前策略可达的回退组；规则模式同时包含最终策略、用户规则和远程规则引用，选择组按全部可选成员计算可达闭包。节点检测在本次初始化内共享，最多四个节点并发；不越过未知的高优先级节点，相关组无法确认可用成员时拒绝启动。组已确定结果后不再启动其尾部探测。

TUN 每秒保护核验保留，一轮所有权检查和重规划共用一次路由表采样；事件批量合并，执行中新增请求补查。每轮重新读取 DNS、代理所有权及路由，不跨轮缓存。网络恢复、外部冲突保护和辅助服务协议不变。

新增隔离检查：

```sh
.build/debug/QingzhouChecks optimization-checks
python3 scripts/traffic-recovery-integration.py
bash scripts/network-monitor-checks.sh
python3 scripts/runtime-optimization-mutations.py
```

这些检查不安装管理员服务或接管当前系统网络。源码与独立检查通过不代表已安装应用已更新，也不能替代真实 TUN/VPN、耗电及两小时稳定性验收。结果与质量门禁限制见 [首批运行优化验收记录](docs/verification-runtime-optimization.md)。
