# Claude 优先整机保护 v2（0.16.15 / 98 候选）

本版本使用现有管理员辅助服务、TUN 和 PF，不需要 Developer ID 或 Network Extension。它不激活此前的应用过滤原型。需要更新管理员辅助服务；旧服务缺少 v2 能力时，在停止当前连接或修改配置之前拒绝开启。

## 操作行为

- 开启：持久保存原设置和恢复点，固定 TLS 节点、全部代理、完整接管及严格代理 DNS，建立并核验屏障后连接。
- 关闭开关：仅停止代理；恢复点和整机 PF 屏障保留。再次开启继续原固定节点，不覆盖最初快照。
- 手动断开、正常退出和应用内应急清理：保留断网保护。退出前核验核心停止、接管已清理和 v2 屏障有效。
- 解除保护并恢复直连：首页和菜单栏独立入口，明确确认后清理本应用规则、恢复原设置及原连接状态。此后 Claude 允许直连。
- 核心/GUI/辅助服务退出：不通过故障恢复或回滚隐式解除保护。辅助服务下次启动重新加载本应用规则；不承诺系统重启空窗保护。

开关表示代理是否开启；保护持有状态独立保存，暂停后仍禁止修改会改变出口的配置。失败时不走普通事务自动恢复直连。绿色要求实际 PF 证据有效、核心保持运行且适用的连通性检查通过；未知、过期及旧记录不提供绿色证明。

## 网络约束

- 固定 VPS 的 IP、端口和传输协议：Hysteria2 使用 UDP，VLESS/Trojan 使用 TCP。暂不支持 Shadowsocks，避免误判 TCP/UDP 出口组合。
- 物理/其他 VPN 出口不放行整段私网、公司网段、云枢公网 IP、局域网代理或本地 DNS。IPv6 同样拒绝公网回退。
- 基础例外仅含回环、IPv4 广播 DHCP 客户端请求、IPv6 链路本地邻居/路由发现。IPv4 DHCP 单播续租受阻时可能需要重新获取地址，不为此开放整个网关。
- 只生成拒绝规则，基础例外仍受其他防火墙规则约束。协议列表按 PF 支持的编号展开；原始 IP 和特权程序主动改写网络不在普通应用故障保障范围。
- TUN 配置只保留代理 DNS，不创建企业直连出口或动态企业规则；开启首次清理已有 IPv4/IPv6 PF 连接状态。
- 云枢共存暂不验收。未知企业防火墙结构或外部规则冲突拒绝接管，不自动关闭企业安全软件，不覆盖无法确认所有权的规则。

## 验证与部署边界

本机 `pfctl -n -f` 仅检查语法，不加载、清空或替换系统规则。离线回归使用内存凭据、模拟管理员命令和临时配置；不能替代抓包及实际断网行为。

发布前仍须验证 VPS 不可达、核心/GUI/helper 退出、正常断开/退出、休眠、网络切换、接口复用、IPv4/IPv6/DNS/UDP 和已有连接。若公司特权组件移除 PF，界面应失去确认，不能靠状态轮询保证期间没有泄漏。

尚未完成实机验收时只交付候选包，不自动替换正在工作的应用。安装需要管理员授权更新 helper，临时签名每个新包都要重新批准客户端哈希。

若应用无法打开，明确解除本应用保护的管理员恢复命令为：

```bash
sudo bash '/Applications/汐航.app/Contents/Resources/recover-helper.sh' '/Applications/汐航.app'
```

此命令会恢复普通网络并允许 Claude 直连。仅在希望解除保护时执行；脚本按本应用恢复记录清理，不使用全局 `pfctl -F all`。随后重新打开应用，通过明确解除入口核对和恢复用户设置记录。

## 复现

```bash
bash scripts/swift-local.sh build --product QingzhouChecks
QZ_PF_RULE_FIXTURE="$PWD/.build/claude-pf-rules.conf" .build/debug/QingzhouChecks disconnect-protection-checks
/sbin/pfctl -nf .build/claude-pf-rules.conf
/sbin/pfctl -nf .build/claude-pf-rules.conf.udp
/sbin/pfctl -nf .build/claude-pf-rules.conf.ipv6
bash scripts/claude-safety-checks.sh
bash scripts/quit-release-checks.sh
```

应串行执行构建和检查，避免 Swift 对象在链接过程中被另一次构建覆盖。所有实机状态必须以当次观察为准，不引用先前版本的成功结果冒充验收。
