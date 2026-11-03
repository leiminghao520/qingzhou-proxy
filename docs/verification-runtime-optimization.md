# 首批运行优化验收记录

基准：Git `3d9eb03`；本次为其上的未提交源码修改。未修改配置格式、辅助服务协议、核心版本或现有质量阈值，未替换已安装应用、安装辅助服务或接管当前系统网络。

## 实现

- `TrafficMonitor` 在连接任务内消费流，断线或流正常结束均触发退避重连；有效样本重置退避。AppModel 以连接代次和任务取消阻止旧结果发布，断开请求立即取消监控，网络清理开始前停止所有监控。流量、连接列表、节点健康独立记录，菜单栏、简洁首页和专业首页统一使用速率可用状态。
- `FallbackBootstrap` 从当前配置引用计算组闭包，双目标探测沿用核心超时，四节点并发且同一节点只检测一次。按照成员顺序等待结果；未知高优先级阻断向下选择。所有相关组确定结果后取消多余任务，已决定组的尾部不再入队。相关组无法确认可用节点时启动失败，不增加直连后备。
- `NetworkCheckScheduler` 合并串行队列上的待处理通知，检查中新增请求只补查一次；每秒定时器保留。正式监控实现每轮生成一个 `NetworkRouteSample`，分别供包含瞬态路由的所有权检查及原过滤策略的网络快照使用。DNS、代理和路由每轮重新核验，快照重试退避不跳过所有权检查。
- 网络采样、时钟、DNS 和快照读取可注入；生产默认仍使用真实系统读取。测试夹具链接正式 `NetworkMonitor.swift`，模拟管理员服务输入与写操作，明确禁止写入真实路由。

## 检查与证据

全部日志、覆盖率和截图位于本仓库 `.build/`，属于可重新生成的本地证据。

| 检查 | 结果 | 证据 |
| --- | --- | --- |
| Debug 客户端、辅助服务和检查程序 | 通过 | `.build/app-build.log`、`.build/helper-monitor-checks.log`、`.build/optimization-build.log` |
| Release 构建 | 通过 | `.build/release-build.log` |
| 完整检查 | 121 个场景、1258 条断言，0 失败 | `.build/coverage-run.log` |
| 实际回环 WebSocket | 2 个场景、3 条客户端断言，0 失败 | `.build/traffic-recovery-run.log` |
| 正式网络监控实现的隔离夹具 | 13 条断言，0 失败 | `.build/helper-monitor-checks.log` |
| 核心协议与转发集成 | 14 个场景，0 失败 | `.build/integration-run.log` |
| 策略和 fallback 核心集成 | 9 个路由场景，API 检查 0 失败 | `.build/features-integration-run.log` |
| DNS 与地址族隔离 | 6 个场景，0 失败 | `.build/network-policy-run.log` |
| 安装/恢复/卸载脚本夹具 | 8 个场景，0 失败 | `.build/helper-scripts-run.log` |
| 界面 | 15 条断言、26 张截图 | `.build/interface-run.log`、`.build/ui-evidence/` |
| HTTP 兼容层竞态检查 | Go race 检查通过 | `.build/httpcompat-checks.log` |
| 组合入口隔离转发 | 9 个场景，0 失败 | `.build/combined-isolation-run.log` |
| 完整接管配置的隔离转发 | 19 个场景，0 失败 | `.build/full-capture-isolation-run.log` |
| 首批优化定向变异 | 15/15 检出，0 存活、0 编译错误 | `.build/runtime-optimization-mutations.json` |
| 既有定向变异 | 6/6 检出，0 存活、0 编译错误 | `.build/mutation-results.json` |

WebSocket 夹具使用合成密钥校验实际 URLSession 连接，首条连接发送有效样本后异常断开，第二次验证鉴权、数据恢复及主动取消关闭连接。单元检查还覆盖退避封顶、恢复后重置、等待/收流时取消、旧流迟到数据、不同通道状态独立、回退组引用范围、并发完成顺序、未知结果、共享节点去重和提前结束。

网络监控夹具证实稳定状态两轮仅采集两次路由表，而原实现每轮核验及快照各采一次；保护计划保持一致。另覆盖 DNS 消失、路由网关被改写、代理所有权冲突、快照退避、采样重试耗尽、变化稳定一秒后重规划和事件批次之间的冲突重新核验。恢复期间额外路由命令不计入稳定轮次。

## 质量门禁与实测限制

- **严格门禁未通过**：现有检查程序的 QingzhouKit 行覆盖率为 74.54%，未达到项目要求的 100%。三个新增 QingzhouKit 文件行覆盖率均为 100%，区域覆盖率仍有缺口；LLVM 输出未提供可据以验收的 Swift 分支覆盖率。
- 检查程序的覆盖率不包含 AppModel、SwiftUI 界面及真实管理员服务；隔离夹具结果不能补写为这些代码的全量覆盖。
- 十五项定向变异只覆盖列出的优化行为，不能证明全项目变异检出率达到 80%。未降低门槛，未把定向检出率冒充项目指标。
- 本机原有 Homebrew Python 的 `plistlib` 因动态库符号缺失无法运行脚本夹具；改用项目文档指定的 `/usr/bin/python3` 执行通过，未修改 Python 安装。
- 核心从本地已有副本补齐，SHA-256 与 `Vendor/core-lock.json` 的 `binarySHA256` 一致，`scripts/fetch-core.py` 验证通过；版本仍为 1.14.3。
- 未测真实 TUN/企业 VPN、真实休眠换网、两小时稳定性、空闲 CPU、进程唤醒和耗电。没有宣称吞吐、耗电或启动时间的百分比提升。验收真实管理员路径前应使用独立环境，先保存原网络与恢复证据。

## 重跑命令

```sh
python3 scripts/fetch-core.py
bash scripts/swift-local.sh build --product QingzhouChecks
.build/debug/QingzhouChecks
python3 scripts/traffic-recovery-integration.py
bash scripts/network-monitor-checks.sh
python3 scripts/integration.py
python3 scripts/features-integration.py
python3 scripts/network-policy-integration.py
/usr/bin/python3 scripts/helper-script-tests.py
bash scripts/interface-checks.sh
bash scripts/coverage.sh
python3 scripts/runtime-optimization-mutations.py
python3 scripts/mutation-check.py
bash scripts/swift-local.sh build -c release
```
