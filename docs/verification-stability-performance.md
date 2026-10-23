# 轻舟稳定性与性能优化验收记录

基准为 Git `7507707`，实现为其上的本地源码修改。保留原有未跟踪的 `OPTIMIZATION_GUIDE.md` 和 `examples/`；未提交或推送，未安装候选、更新辅助服务或重连当前网络。配置格式、辅助服务协议和轮询周期保持兼容。

## 修改与判断依据

- 路由事件入口原来对任意报文安排检查。正式网络检查的隔离夹具证实：一次外部变化后，每轮查询产生的响应会继续触发下一轮；旧入口在限定的 20 轮中持续执行，新入口只有 1 次检查、1 次查询。这个对照验证反馈链存在，不能代替运行中辅助服务的堆栈诊断。
- 本机只读路由套接字检查核对当前检查进程的 PID，确认其原生 GET 响应会到达独立监听器。候选过滤到 1 条自身查询响应，安排 0 次变化检查，未发送 ADD、DELETE 或 CHANGE。
- 新入口仅忽略版本、声明长度和头部完整的 GET；路由、接口、地址、未知及异常通知均保守触发核验。每次回调最多接收 64 次，连续 EINTR 也计入预算。关闭或读取失败安排一次核验后停止该监听，保留每秒保护定时器。取消后不接收或提交迟到请求。
- 身份索引绑定单次不可变采样并按需构建；新采样生成独立索引。结构化快照不提前生成兼容路由文本。写前、写后采样、写入意图及恢复日志同步落盘均保留，没有跨写入复用旧表。
- 新增采样、解析、采样对象构建、身份索引、兼容文本、路由核验及审计落盘分项计时。`routeTableSample` 等总计时会包含子项，不能相加冒充总时间；既有 `routeJournalSave` 继续统计恢复日志。
- 相同连接、策略、累计计数和保护摘要不重复发布。连接计数、连接消失、节点延迟历史、实际出口、保护状态和首次重连仍及时更新；历史采样及前台 1 秒、后台 5 秒轮询保持原样，速率流更新频率保持原样。

## 检查结果

| 检查 | 结果 | 本地证据 |
| --- | --- | --- |
| Debug 全量构建 | 通过 | `.build/stability-debug-build.log` |
| 完整 QingzhouChecks | 144 场景、19,782 断言、0 失败 | `.build/stability-full-checks.log` |
| 新增稳定性与性能检查 | 154 断言、0 失败 | `.build/stability-performance-checks.log` |
| 正式网络监控夹具 | 100 断言、0 失败 | `.build/stability-monitor-checks.log` |
| 原生路由检查 | 2,142 断言通过 | `.build/stability-native-checks.log` |
| 路由写入与保护启动 | 144 断言通过 | `.build/stability-protection-checks.log` |
| 指定出口与拒绝保护 | 24 断言、0 失败 | `.build/stability-bypass-checks.log` |
| 退出释放检查 | 14 断言、0 失败 | `.build/stability-quit-checks.log` |
| 模型网络恢复检查 | 49 断言、0 失败 | `.build/stability-resume-model.log` |
| 页面、草稿及新增遥测发布检查 | 146 项通过 | `.build/stability-page-checks.log` |
| 设置页刷新隔离 | 基准与候选均为 24 次遥测、0 次正文重绘，配置和辅助状态变化正常渲染 | `.build/stability-settings-scroll.log` |
| 事件入口定向变异 | 8/8 检出，全部编译通过，无超时计入检出 | `.build/stability-event-mutations/report.json` |
| Release 全量构建 | 通过 | `.build/stability-release-build.log` |

变异覆盖纯查询触发、吞掉真实变化、取消失效、迟到请求、失去接收上限、异常报文忽略、读取失败空转和重复请求。它是本轮维护范围的定向证据，不代表全项目变异率或覆盖率；PIT 不适用于 Swift。没有降低既有质量阈值。

## 性能对照与限制

同一组合成数据为 600 条路由，取 48 条路径重复核验 3 次，共 144 次身份查询。原线性扫描算法耗时 **384.561 ms**，候选耗时 **2.383 ms**，包含候选采样对象及索引首次构建；逐项结果一致。该数据衡量身份核验计算成本，不代表真实启动、吞吐或耗电的改善比例。

相同遥测连续 20 轮没有发布更新；累计计数及策略历史变化仍发布。设置页候选主循环 p95 约 18.13 ms，滚动位置保留。

当前运行的仍是原安装版。本轮未对候选完成真实 TUN、企业 VPN、网卡切换或至少 10 分钟 CPU 验收，也未测候选真实连接启动时间，因此不宣称当前高 CPU 已在运行实例消失，或已将历史 7.07 秒连接降至某个值。

## 复现与后续验收

```sh
bash scripts/stability-performance-checks.sh
# 可选只读宿主路由通知验证；不发送路由写入。
bash scripts/stability-performance-checks.sh --read-only-events
bash scripts/network-monitor-checks.sh
bash scripts/native-route-checks.sh
bash scripts/protection-startup-checks.sh
bash scripts/bypass-helper-checks.sh
bash scripts/quit-release-checks.sh
bash scripts/network-resume-model-checks.sh
bash scripts/page-optimization-checks.sh
bash scripts/settings-scroll-checks.sh
/usr/bin/python3 scripts/stability-event-mutations.py
bash scripts/swift-local.sh build
.build/debug/QingzhouChecks
bash scripts/swift-local.sh build -c release
```

后续明确安排安装与真实网络窗口后，再安装同一源码候选并核对主程序、辅助服务及核心身份。保存原网络与恢复证据，分别在窗口显示和隐藏状态连续采样至少 10 分钟，记录辅助服务 CPU、检查次数和查询次数；核验企业域名、固定出口、外部路由改写、网络恢复及退出释放。以实际结果决定是否满足运行验收，不在本轮切换当前实例。
