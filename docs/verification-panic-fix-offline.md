# 轻舟原生路由修复：离线验证报告

日期：2026-10-22。源码版本标识：0.12.2 / build 49。状态：修复已落地，所执行的离线检查通过；交付门禁未完成，尚无可供实机试连的候选应用。

## 当前结论

保留原生路由后端、捕获范围 CIDR 差集、4096 条预算、单份运行配置、资源缓存和原生接口就绪等待。没有恢复旧后端来掩盖问题，也没有迁移用户配置。

此次未安装、签名或交付候选应用，未替换 Applications 内容，未启用辅助服务，未运行真实路由 socket 查询或写入夹具。结束时只读核对：Shadowrocket 与 MacPacketTunnel 正在运行，`cn.qingzhou.proxy.helper` 为 disabled，未发现 QingzhouHelper 或测试 sing-box 残留。原先未提交改动保留；没有提交或推送。

仍不能证明 panic 的完整触发链已消除，不能承诺首次真实内核连接不会崩溃。超时、取消和进程隔离不构成内核安全保证。按用户“有未解决的崩溃关键疑点时不交候选试用”的要求，本轮只交源码修复及证据。

## panic 取证与判断边界

已核对用户 panic 与本机 `/System/Library/Kernels/kernel.release.t8132`：UUID 均为 `3F20A015-476B-35D8-A442-6ED70B7013D8`，panic 为 OS 25A362、xnu-12377.1.9，任务是 QingzhouHelper pid 56468。

通过两个 `__TEXT_EXEC` 基址求地址偏移，而非直接套用 Kernel slide：运行时 `0xfffffe004df30000`，镜像 `0xfffffe00072cc000`，偏移 `0x46c64000`。故障 PC `0xfffffe004e373a38` 对应镜像 `0xfffffe000770fa38`。指令先从 `[x21+8]` 读取 x8，再解引用 x8；panic 的 x8 和 FAR 为 0。上层返回地址对应的回调调用传入操作值 2（RTM_DELETE）。

这一形态与匹配 XNU 源码 `bsd/netinet/in_arp.c` 的 `arp_rtrequest` 删除分支 `LIST_REMOVE(la, la_le)`、随后清空前后指针的行为吻合。相邻的新增/解析分支在已有 la 时直接退出。它支持“ARP 路由回调链表状态异常”的判断，尚不能证明是哪条用户态请求或哪个并发事件首先造成状态异常。镜像只有稀疏导出符号，反汇编显示的最近符号 `_inet_arp_init_ifaddr`、`_ether_ioctl` 不能当作完整函数符号化结果。

原编码器在普通 ADD/DELETE 中强制附带空 `RTA_IFP`，且给全局路由设置接口索引。XNU 的 `rt_setif` 路径可调用旧接口地址的 DELETE 回调；Apple route 的普通新增并不默认注入该 IFP。已删除这种缺少独立依据的组合，但丢失的逐操作记录使我们无法确认它是唯一触发因素。

参考依据：

- [匹配版本 XNU rtsock.c](https://github.com/apple-oss-distributions/xnu/blob/xnu-12377.1.9/bsd/net/rtsock.c)：路由请求和接口重绑定。
- [匹配版本 XNU in_arp.c](https://github.com/apple-oss-distributions/xnu/blob/xnu-12377.1.9/bsd/netinet/in_arp.c)：ARP 路由回调。
- [Apple network_cmds route.c](https://github.com/apple-oss-distributions/network_cmds/blob/main/route.tproj/route.c)：地址排列、对齐及 IFP 用法。此文件取自 main 快照，有内容哈希，不声称它对应用户系统中的 route 可执行文件版本。

## 已实施的修复

| 范围 | 修改与依据 | 保留的约束 |
|---|---|---|
| 报文编码 | 全局头部索引为 0，仅作用域路由带索引；ADD/DELETE 不附带空 IFP；链路网关使用接口枚举得到的真实 AF_LINK 地址；修正无作用域 fe80 GET 错带接口编号 | IPv4/IPv6、链路网关、作用域及旧异常记录删除语义保留 |
| 独立协议验证 | 拆分编码、验证和传输；正式提交前验证地址顺序、边界、对齐、标志、掩码、前缀规范化及 IPv6 作用域；Python 参考编码器不调用待测编码器 | 畸形报文只进入内存模拟传输 |
| 原生传输 | socket 非阻塞；提交与接收共用单调截止时间；处理 EINTR、EAGAIN、短写、无关通知、错误 PID/sequence、内核拒绝和迟到响应 | 短写不补发尾部；提交结果未知时保留写前恢复意图；同一事务不切后端 |
| 控制通道 | 阻塞请求移出客户端 actor；进度与取消可并行处理，shutdown 唤醒等待；所有进度帧共享原有 60 秒总等待预算 | 不缩短原验证超时，最终成功仍等待实际路径检查 |
| 审计与恢复 | 每次操作先持久化事务号、序号、阶段及哈希身份，再记录结果和耗时；恢复记录 fsync 后原子替换并同步目录；日志两份轮转，每份约 1 MiB | 不记录凭据或原始路由身份；日志写前失败不执行操作 |
| 恢复失败 | 采样、查询、删除或核验失败后停止继续路由操作；即使异常也终止本次核心，保留恢复记录；删除前后重新采样核对所有权 | 外部改写不清理；恢复未完成禁止再次接管 |
| 动态企业网络 | 修复路径恢复后，DNS 转发器更新为新计划但服务仍持旧计划的问题，保持两端权威计划一致 | 原有企业分域 DNS、长连接及只暂停企业查询的行为保留 |
| 启动优化 | 结构化快照优先，文本表按需缓存；减少无必要的旧 IPv6 表渲染；核心配置检查使用已有有界命令预算 | 新保护、新捕获先建立并核验，再撤回旧自有路由；完整业务检查不省略 |

关键源码：`Sources/CQingzhouRoute/{QingzhouRoute.c,RouteRequestValidation.c,RouteTransport.c}`、`Sources/QingzhouKit/{RouteBackend.swift,HelperRequestChannel.swift,RouteAuditLog.swift,SecureFile.swift,TunSupport.swift}`、`Sources/QingzhouHelper/{main.swift,NativeRouteSupport.swift,RouteWriter.swift,NetworkMonitor.swift}`、`Sources/Qingzhou/AppModel.swift`。所有新增或修改的代码注释为中文。

## 已执行的离线检查

| 检查 | 结果 | 能证明的范围 |
|---|---|---|
| C 传输、独立验证器、ASan/UBSan、畸形语料及随机输入 | 通过，246 项断言，含 20,000 次随机输入 | 注入系统调用状态机及内存边界；真实 route socket 调用为 0 |
| 独立 Python Darwin ABI 编码对照 | 通过，18 种报文逐字节相同 | IPv4/IPv6、全局/作用域、IP/AF_LINK 网关、默认/主机路由、GET/ADD/DELETE、旧异常删除；不是内核接受性证明 |
| 原生后端、捕获及恢复记录检查 | 通过，2,136 项断言 | 使用独立 ACK、模拟传输、作用域和旧记录；不再把请求回显当成功响应 |
| 独立 CIDR 区间差集对照 | 通过，6 组 | 覆盖集合相等、捕获与排除不重叠、预算回退；不证明真实 VPN 出口 |
| 正式客户端控制通道与审计 | 通过，24 项断言 | 本地 socketpair 模拟激活卡住、进度、取消、总预算及审计故障 |
| 实际辅助服务恢复代码 | 通过，8 场景、33 项断言 | 成功、查询超时、未知写入、采样失败、外部改写、歧义、核验失败、保存记录重载；路由全为模拟，核心是受控 sleep 子进程 |
| 启动保护事务 | 通过，142 项断言 | 五个事务阶段各四个中断位置、大量保护项、部分写入及所有权恢复模型 |
| 监控/绕过/退出/代理激活/恢复模型 | 通过，98/24/14/16/49 项断言 | 链接正式相关业务实现，外部写入注入替代 |
| 本地 sing-box 业务 | 修复后通过，两组各 3 个动态接入序列 | 移除 TUN 入站，仅回环 HTTP/SOCKS/DNS；覆盖 VPN 启动前存在、热接入退出、多网卡、接口变化、DNS 故障恢复；每组公网失败 0、长连接重连 0、核心重启 0、夹具 DNS 泄漏 0 |
| 完整 QingzhouChecks | 通过，144 场景、19,782 项断言 | 项目功能检查；不能替代实机连接 |
| 定向变异 | 通过，13/13 被检出 | 针对提交、短写、取消、序列匹配、IFP、作用域、审计和 DNS 计划同步；不是 PIT 指标 |
| Release 编译及差异格式检查 | 通过 | App 与 Helper 可编译；没有打包、签名、安装或运行候选 |

本地业务首轮确实失败：VPN 预先存在的场景，在暂时丢路由后恢复，企业 DNS 持续 SERVFAIL。保留失败日志，修复权威计划同步后重新执行通过，并加入反向变异；没有把重试后偶然通过当成修复证据。

恢复模型仍不等于断电后真实内核残留恢复；普通用户 fixture 不验证 root 所有权、launchd、真实恢复启动或内核竞争。Windows 包只含标准库协议/差集参考工具与语料，本轮没有在 Windows 上实际运行。

## 覆盖率与未完成的质量门禁

来自 llvm-cov 的文件级结果（包含未运行的 OS 边界代码，未删掉它们以美化比例）：

| 文件 | 行覆盖 | 分支覆盖 |
|---|---:|---:|
| HelperRequestChannel.swift | 100% | Swift 工具未提供，0/0 不代表通过 |
| RouteAuditLog.swift | 98.25% | 未取得 |
| SecureFile.swift | 100% | 未取得 |
| CaptureRoutePlan.swift | 93.97% | 未取得 |
| RouteBackend.swift | 65.79% | 未取得 |
| RouteRequestValidation.c | 100% | 81.50% |
| RouteTransport.c | 76.27% | 76.27% |
| QingzhouRoute.c | 37.75% | 35.21% |

Swift 所选五个文件行覆盖 81.60%；C 所选三个文件行覆盖 61.29%、分支 58.64%。真实系统快照、socket 包装器及若干错误分支未执行。实际 helper 恢复 fixture 尚未纳入这份覆盖率汇总，因此不对它宣称覆盖率达标。

[delivery-quality-gate 技能](/Users/leiminghao/.codex/skills/delivery-quality-gate/SKILL.md) 的原文要求为 “100% applicable line and branch coverage and PIT mutation score of at least 80%”。交付质量门禁要求 100% 适用行/分支覆盖及至少 80% PIT；本项目 Swift/C 无可用 PIT 证据，Swift 分支指标未取得，已有行/分支也未满。**门禁未完成**。13 项定向变异不能替代 PIT，也不以断言数代替覆盖率。

## 耗时与操作次数

600 行合成路由、Debug、30 次内存快照样本：结构化采样中位数约 13.87 ms，p95 约 14.76 ms；按需文本渲染中位数约 1.70 ms。真实内核调用 0，外部命令 0。这是模拟输入处理开销，不是连接速度，也不是优化前后实机对照。

600 个已存在保护项的启动夹具仅需两次表采样、零目标查询、零写入。真实路由操作新增 begin/结果日志及分项计时；只有实网窗口才能取得总启动、保护阶段、接管应用、业务验证的真实耗时。

冷启动 10 次中位数 ≤5 秒、p95 ≤8 秒、保护 p95 ≤1 秒均为**未验证**。企业实际 DNS/VPN 出口、Antigravity 登录和模型请求、睡眠换网、真实退出恢复也未验证。

## 复现与交付内容

在项目目录普通用户执行：

```sh
bash scripts/panic-fix-offline.sh
bash scripts/panic-fix-coverage.sh
python3 scripts/panic-fix-mutations.py
bash scripts/swift-local.sh build -c release --product Qingzhou
bash scripts/swift-local.sh build -c release --product QingzhouHelper
```

离线入口拒绝 root；不要改成 `--read-only`、kernel-check 或恢复安装脚本。本轮所有可疑报文只经过模拟传输。Python 参考工具能在 Windows 标准 Python 中读取附带语料，不提供 Windows 上运行 Darwin 内核的能力。

证据目录含原始检查日志、失败与修复后的业务日志、协议及捕获语料、覆盖率 JSON/文本、变异结果、Apple 参考源码快照及哈希、故障指令、源码差异清单及本地 Release 组件哈希。Release 组件哈希仅用于标识本次编译，不表示已签名候选；不附带可安装应用。

当前没有修改运行环境，因此不需要执行回退。不要启用磁盘上旧的 0.12.1 helper 来尝试这些源码修复。后续若达到候选交付条件，首次单次真实内核连接、企业 VPN、Antigravity、取消和退出恢复必须分步验收；通过后才测冷启动与热重连，不能一开始循环压力测试。
