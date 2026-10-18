# 0.8.17 连接启动优化验收

日期：2026-10-18；版本：0.8.17（31）；基准：0.8.16（30）。

## 实现与行为边界

- 统一启动和 fallback 的双目标节点探测：任一成功即取消另一请求；两者均失败才沿用原有归因和控制接口核对。取消单次探测不关闭共享控制会话。
- TUN 节点域名去重，最多四个底层解析并发，单项三秒、整批六秒。跨重试共享工作池，未退出的系统解析继续占用原槽位；超时、取消后的结果不能提交。所有节点的绕过路由与出口保护均保留。
- 接管前后 DNS 基线最多四个解析器并发，保留转发器五秒单项预算及原有检查集合；网络写入仍在辅助服务串行事务内。
- 保留接管前后两轮完整验证，实际 TUN 路径通过后才显示已连接。保留企业 VPN、路由/DNS 所有权保护、重试退避及恢复策略。
- 显示准备网络与核心、检查代理通道、应用接管、验证实际网络，以及重试次数/等待时间。取消会失效连接代次并取消启动检测；旧结果不得覆盖当前会话。
- 使用单调时钟记录应用总耗时、尝试次数和各阶段耗时。辅助服务协议仍为 4，新增可选 stageTimings，成功/失败均可返回；旧响应缺失字段可解码。日志只包含固定阶段、耗时、次数和结果。

## 对照证据及限制

Shadowrocket 2.2.90 隧道启动入口经 REA/Hopper 静态反编译，观察到保存完成回调、启动接口监控、发送启动通知；未沿完整回调链验证成功标准，不能断言其没有联网验收。证据 ID：`ev_fc9d6115a1788209ffea549ca77e9c396ac4352a2bf559a8a722c2ac7ffa7dff`，目标 SHA-256：`75cf567840fdb74e8a6e472d31e82f999c887841bba201ccfc5cea1070f40d53`。

Clash Verge 2.4.7 的本机深度分析因 Hopper 桥接就绪超时未完成；仅以[该版本官方源码](https://github.com/clash-verge-rev/clash-verge-rev/blob/v2.4.7/src-tauri/src/core/manager/lifecycle.rs)辅助对照启动与测速的职责，未宣称本机动态行为已验证。

## 可复现检查

```sh
scripts/swift-local.sh build
.build/debug/QingzhouChecks
.build/debug/QingzhouChecks startup-checks
.build/debug/QingzhouChecks runtime-checks
.build/debug/QingzhouChecks startup-benchmark .build/startup-benchmark.json
bash scripts/network-monitor-checks.sh
bash scripts/network-resume-model-checks.sh
bash scripts/sleep-command-checks.sh
python3 scripts/integration.py
python3 scripts/features-integration.py
python3 scripts/traffic-recovery-integration.py
bash scripts/coverage.sh
python3 scripts/startup-optimization-mutations.py
python3 scripts/runtime-optimization-mutations.py
python3 scripts/mutation-check.py
bash scripts/build-app.sh "$PWD/outputs"
```

启动检查覆盖：一目标挂起另一成功、请求取消、共享会话内并发请求不受影响、父任务取消、域名去重、IPv4/IPv6 结果保留、并发上限、总/单项截止时间、晚到结果隔离、跨重试底层任务上限、取消和错误传播、可选协议字段及计时。恢复模型夹具使用正式 AppModel 验证阶段显示和手动取消后的旧代次拒绝。

十轮隔离基准复现旧等待方式（同时等待双目标）和新正式实现。目标延迟为 300/30 ms，DNS 为 12 个各 20 ms 的合成解析；输出明确标记 synthetic-only，不代表公网速度、真实 TUN 启动时间或吞吐量。

## 实网与交付边界

本机存在接管默认路由的现有隧道，本轮未停止它、未安装或启动新版辅助服务、未切换真实系统代理/TUN。真实 TUN/完整接管各十次对照、企业 VPN 共存、睡眠唤醒、网络切换及两小时稳定性仍未验证。

真实对照须保留旧包，确认其他公网接管已正常关闭且无待恢复记录；同一节点、配置、网络分别完成旧版/新版各十次连接。新版以 connectionTotal 和阶段日志统计总耗时中位数及最大值。每轮核对 HTTPS 及断开恢复，发生所有权冲突即停止并保留恢复证据。不同成功标准或网络环境的数字不能混为同一基准。

严格质量要求仍为适用行/分支覆盖率 100%、全项目变异检出率至少 80%。现有覆盖率脚本只覆盖检查程序执行到的代码，不覆盖完整界面/管理员路径；定向变异不能作为全项目指标。未达到/未取得的项目保持未通过或未验证，不用编译成功替代。

## 本轮最终结果

| 检查 | 结果 |
| --- | --- |
| 完整检查 | 通过：122 场景、1302 断言、0 失败 |
| 核心运行时 | 通过：runtime_failures=0 |
| 辅助服务网络监控 | 通过：41 条断言 |
| 恢复模型及取消代次 | 通过：43 条断言 |
| 睡眠命令预算 | 通过：14 条断言 |
| 协议转发集成 | 通过：14 个场景 |
| 规则/fallback 集成 | 通过：9 个场景、真实隔离核心 selector 检查通过 |
| 流量恢复 | 通过：2 个 WebSocket 场景 |
| 界面 | 通过：15 条断言、26 张隔离截图 |
| 启动优化定向变异 | 通过：6/6 检出，其中 2 项通过超时检出 |
| 原有运行优化定向变异 | 通过：15/15 检出，其中 1 项通过超时检出 |
| 原有六项定向变异 | 通过：6/6 检出 |
| 检查程序覆盖率 | 行 74.49%，区域 69.62%，函数 71.12%；未达到严格门禁 |
| 分支覆盖率/全项目变异指标 | 未取得完整证据，未验证 |
| Release/签名/组件摘要/源码摘要 | 通过 |
| 当前已安装及运行版本 | 仍为 0.8.16（30），本轮尚未替换 |
| 真实 TUN/完整接管前后各十次 | 未验证，未切换现有网络 |

原有运行优化变异脚本遇到“断线不通知”变异导致挂起时直接抛出 TimeoutExpired，丢失后续结果。本轮补齐 KILLED_TIMEOUT 分类，仅在正常基线已通过后将变异挂起计为检出；变异测试预算 30 秒，编译仍为原有预算。构建错误单独统计，未降低变异质量阈值。

隔离基准最终十轮结果（毫秒）：

| 项目 | 旧方式中位数 / 最大值 | 新方式中位数 / 最大值 |
| --- | --- | --- |
| 双目标探测 | 318.34 / 321.4 | 33.64 / 36.12 |
| 十二域名准备 | 286.64 / 291.63 | 74.08 / 75.82 |

这些是传输/解析夹具结果，不能换算成真实启动提升百分比。

本地保留产物：`outputs/qingzhou-0.8.17-20261018-121417.JNyGhx/轻舟代理.app`（构建输出未提交到 GitHub）。同目录包含 artifact-manifest.json、artifact-verification.json 和 validation/ 全部结果证据。签名会改变完整文件摘要；另逐段核对主程序、辅助服务和 Runner 的 Mach-O 全部节内容及 UUID 与 Release 编译产物一致。
