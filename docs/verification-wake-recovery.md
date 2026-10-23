# 睡眠唤醒与网络恢复候选验收

候选版本：0.13.4（58），macOS。源码保留此前诊断、配置历史、时间线及性能优化的未提交修改，未提交或推送。

## 已实现行为

- `WakeRecoveryCoordinator` 统一管理等待、确认、重建与取消。只有系统睡眠前已有连接才保留内存恢复意图，单独熄屏、锁屏不新建意图；系统与屏幕均唤醒后等待 15 秒。
- 控制接口、实际出站节点、当前规则 HTTPS 和适用的路由、DNS、系统代理所有权分别核验。实际节点未知、取消及单次超时不计入节点失效证据，不用节点列表首项代替实际节点。
- 两轮明确失败间隔 3 秒确认；写入前再检查一次。最多实际重建 3 次，退避 1、3、10 秒；辅助服务让行不消耗实际重建次数。每次启动沿用原有启动预算。
- 辅助服务已有重建时客户端等待，恢复请求在辅助服务串行队列内再次原子核对，防止状态读取与写入之间出现第二次重建。辅助服务等待最多 60 轮，总确认最多 120 轮；连续两轮无法确认转为手动处理。
- 用户断开、退出、切配置、换节点、再次睡眠和连接代次变化撤销旧任务。屏幕再次睡眠时取消本轮探测，重新亮屏后仍保留原系统睡眠意图。时间线任务 ID 与内部执行代次分离，旧任务收尾不能清除新任务或发布迟到成功。
- 恢复期间暂停原健康检查的自动断开判断。鉴权、真实归属冲突、指定出口未就绪、配置或恢复失败转为手动处理；不放宽指定出口保护。
- 首页显示等待稳定、复查、重连次数、恢复及停止原因。时间线记录睡眠、正式唤醒、失败、等待、成功与停止，包含原会话、恢复任务和实际重连次数。

## 路由恢复边界

原生路由采样保留标志和独立的链路地址证据。只针对 `239.255.255.250/32`，在同接口、同作用域、组播克隆父项与对应组播邻居缓存同时存在、没有独立竞争出口时排除缓存干扰。普通单播、独立静态主机、其他接口及缺失原始证据的旧文本快照保持保守判断。

删除前、后重新采样并核对事务记录、前缀、网关、接口及作用域。原生删除沿用采样的 HOST/网络身份：满长 `/32` 网络父项携带完整掩码，不能编码为主机缓存删除。父项消失后单独留下的同 link# 缓存不被重新认领为父项。

单项冲突、查询失败、删除失败不再阻断其他独立自有项的清理；最后重新核验整表，汇总未完成项并保留恢复记录。外部替换项不删除。恢复和退出共用结构化索引分类，存在自有或未确认项不报告恢复成功。

恢复记录格式不变。新增采样字段只在内存中使用；协议仍为 5，新请求、响应及事件元数据均使用可选字段。旧辅助服务缺少原子唤醒恢复能力时停止自动处理，待安装窗口更新后验收，不悄悄退回有竞争窗口的恢复操作。

## 隔离验证

结果与构建路径见文末自动生成的交付记录。主要入口：

```sh
bash scripts/wake-recovery-regression.sh
bash scripts/wake-recovery-coverage.sh
python3 scripts/wake-recovery-mutations.py
bash scripts/wake-route-snapshot.sh --replay .build/wake-recovery/current-routes.bin
```

- 新增协调器、真实 CoreAPI/URLProtocol 适配器、原生路由报文和恢复实现故障注入，覆盖取消、迟到结果、重复唤醒、后台唤醒、共享控制会话、三次上限、辅助重建竞争、配置代次和不同接口竞争。
- 实际 `Service.stop` 的非管理员夹具覆盖组播共存、静态主机、外部替换、删除竞争、局部失败、重启读取和恢复中断，所有路由写入均进入内存后端。
- 当前机器完整只读原生快照为 363 条，现场同时观察到组播父项和缓存。回放以整表为背景构造共存、其他接口竞争和静态主机三种目标状态，路由写入 0 次。原始快照保存在 `.build` 的 0600 文件中；它是本次采样，不冒充此前故障发生时的原始整表或管理员恢复记录。
- 运行完整 QingzhouChecks，及网络监控、原生路由、保护、恢复退出、恢复模型、页面草稿、设置刷新、诊断历史时间线和核心就绪检查。

## 覆盖率和适用范围

覆盖率采用 LLVM 实际计数，报告同时包含新文件和复用文件的原有代码。Swift 的 `Branches=0` 表示该工具链未提供可用的 Swift 分支指标，不能解释为分支覆盖 100%。C 的分支覆盖单独由 clang 插桩统计。辅助服务入口使用正式源码的隔离副本，编译时去掉顶层运行入口，未构造管理员 Service 实例。

严格的适用代码行、分支覆盖 100% 门禁未通过；报告中的定向变异率不等于全量变异率。PIT 是 JVM 工具，本 Swift/C 工程不适用，采用可编译并实际执行的定向故障变异。编译失败或运行超时不计入检出。

## 故障处理与后续安装窗口

- “未验证”或连续超时：保留证据并转为手动处理，不把未知结果当作节点失效重建。
- “网络所有权冲突”：保留其他 VPN 的路由、DNS 和代理；恢复记录继续保留，不自动争抢网络。
- “指定出口未就绪”：保留拒绝保护，不通过通用恢复撤销保护来尝试其他网卡。
- 恢复失败或删除竞争：继续清理其他明确自有项，保留未完成记录和具体错误。下次恢复按当时真实身份重新核对，不使用旧快照猜测所有权。
- 旧辅助服务能力不符：需要单独安装窗口更新辅助服务，再验证实际睡眠和网络变化。

本轮只交付隔离候选。没有安装到 Applications、更新运行中的辅助服务、启动候选或触发真实重连。真实合盖睡眠、反复开合盖、Wi-Fi 切换、企业 VPN 共存及至少十分钟持续运行仍未验收。未覆盖的真实环境路径不能由离线通过替代。

## 最终交付记录


| 检查 | 结果 |
|---|---|
| 完整 QingzhouChecks | 144 场景 / 19,782 断言 / 0 失败 |
| 唤醒、CoreAPI 与原生报文 | 98 断言 / 0 失败 |
| 正式 AppModel 恢复模型 | 89 断言 / 0 失败 |
| 实际辅助服务恢复夹具 | 54 断言 / 0 失败，管理员调用与真实路由写入为 0 |
| 退出释放 | 17 断言 / 0 失败 |
| 网络监控 / 原生路由 | 100 / 2,142 断言，均通过 |
| 保护 / 绕过 / 睡眠命令 | 144 / 24 / 14 断言，均通过 |
| 页面草稿 / 设置刷新 | 146 检查通过；baseline 与 candidate telemetryBodies 均为 0 |
| 诊断历史时间线 / 界面 / 核心就绪 | 76 / 22 / 11 断言，均通过 |
| 完整当前路由回放 | 363 条，观察到真实父项与缓存；3 项回放通过 |
| 定向变异 | 12/12 可编译变异检出，包括原生 HOST 删除编码和链路地址丢失 |

覆盖率原始报告（10 个选定文件，包含复用文件的既有代码；完整功能检查未全部合入这份插桩统计）：

```text
Filename                                              Regions    Missed Regions     Cover   Functions  Missed Functions  Executed       Lines      Missed Lines     Cover    Branches   Missed Branches     Cover
-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
Sources/QingzhouKit/WakeRecoveryCoordinator.swift         125                 7    94.40%          29                 1    96.55%         162                 1    99.38%           0                 0         -
Sources/QingzhouKit/RouteIdentityIndex.swift              113                47    58.41%          46                 8    82.61%         121                45    62.81%           0                 0         -
Sources/QingzhouKit/ConnectivityProbe.swift               139                78    43.88%          36                19    47.22%         126                67    46.83%           0                 0         -
Sources/QingzhouKit/CaptureController.swift               187                97    48.13%          38                20    47.37%         190                55    71.05%           0                 0         -
Sources/Qingzhou/AppModel+WakeRecovery.swift              182                75    58.79%          28                 6    78.57%         196                47    76.02%           0                 0         -
Sources/QingzhouKit/RouteBackend.swift                    309               245    20.71%          84                49    41.67%         305               197    35.41%           0                 0         -
Sources/QingzhouHelper/NativeRouteSupport.swift            37                14    62.16%          16                 9    43.75%          45                27    40.00%           0                 0         -
Sources/QingzhouHelper/QuitRelease.swift                   31                29     6.45%           4                 3    25.00%          31                29     6.45%           0                 0         -
.build/wake-recovery-coverage/HelperService.swift         659               492    25.34%         155               101    34.84%         665               476    28.42%           0                 0         -
Sources/CQingzhouRoute/QingzhouRoute.c                    605               294    51.40%          12                 4    66.67%         167                53    68.26%         306               185    39.54%
-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
TOTAL                                                    2387              1378    42.27%         448               220    50.89%        2008               997    50.35%         306               185    39.54%
```

严格覆盖率门禁：**未通过**。协调器行覆盖率 **99.38%**，模型衔接 **76.02%**；整体行覆盖率及 C 分支覆盖率见上表。Swift 分支指标不可得，未将其标记为通过。未覆盖部分包括真实核心启动、管理员网络恢复、实际电源通知及若干故障路径。

故障与事件采用结构化类别；辅助服务 IPC 占用单独作为等待状态，不累积为未知节点失败。原会话筛选可关联重建后的事件，文本及 JSON 导出均包含恢复原因与任务信息。

候选构建为本地临时签名，Debug 和 Release 均通过 `codesign --verify --deep --strict`。每份候选核对版本 0.13.4（58）及全部 12 个组件的大小和 SHA-256；两份清单的源码树摘要与最终工作区一致。未对候选进行真实网络安装验收。

- [Release 候选](</Users/leiminghao/Documents/Codex/2026-10-12/new-chat/work/GitHub/qingzhou-proxy/.build/wake-recovery/candidates/qingzhou-0.13.4-20261023-133659.R82vU3/轻舟代理.app>)
- [Release 组件清单](</Users/leiminghao/Documents/Codex/2026-10-12/new-chat/work/GitHub/qingzhou-proxy/.build/wake-recovery/candidates/qingzhou-0.13.4-20261023-133659.R82vU3/artifact-manifest.json>)

- [Debug 候选](</Users/leiminghao/Documents/Codex/2026-10-12/new-chat/work/GitHub/qingzhou-proxy/.build/wake-recovery/candidates/debug-0.13.4.IrkApM/轻舟代理.app>)
- [Debug 组件清单](</Users/leiminghao/Documents/Codex/2026-10-12/new-chat/work/GitHub/qingzhou-proxy/.build/wake-recovery/candidates/debug-0.13.4.IrkApM/artifact-manifest.json>)

源码树 SHA-256：`0b3577a206033063bbc592b3b3f052b19d1a2ffcba692cfe45abd5e9c559b080`。分支 `codex/android-windows-preview`，HEAD `7507707`，包含现有未提交修改。

- [候选独立校验回执](</Users/leiminghao/Documents/Codex/2026-10-12/new-chat/work/GitHub/qingzhou-proxy/.build/wake-recovery/candidate-verification.json>)
- [完整回归日志](</Users/leiminghao/Documents/Codex/2026-10-12/new-chat/work/GitHub/qingzhou-proxy/.build/wake-recovery/regression-final.log>)
- [最终核心检查日志](</Users/leiminghao/Documents/Codex/2026-10-12/new-chat/work/GitHub/qingzhou-proxy/.build/wake-recovery/full-final.log>)
- [最终模型检查日志](</Users/leiminghao/Documents/Codex/2026-10-12/new-chat/work/GitHub/qingzhou-proxy/.build/wake-recovery/model-final.log>)
- [覆盖率报告](</Users/leiminghao/Documents/Codex/2026-10-12/new-chat/work/GitHub/qingzhou-proxy/.build/wake-recovery-coverage/report.txt>)
- [定向变异结果](</Users/leiminghao/Documents/Codex/2026-10-12/new-chat/work/GitHub/qingzhou-proxy/.build/wake-recovery-mutations/report.json>)
