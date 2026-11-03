# VPS 联动 0.10.0 候选版验收记录

日期：2026-10-21；腾讯云只读授权与轻量适配补验：2026-10-22。Git 基准：`51ed13f`，分支 `codex/android-windows-preview`；本轮源码未提交/推送。保留原有无关的 `OPTIMIZATION_GUIDE.md`、`examples/`。App 为 0.10.0、build 41，ad-hoc 签名。

**当前状态：2026-10-22 按用户要求安装 build 41 后，用户已自行启动新版；随后按“继续”指令部署 VPS 联动服务。公网发现、一次性配对、状态与套餐查询检查通过，代理核心与认证进程未重启，本机代理 HTTPS 请求返回 200。实际 App 配对尚未完成，严格覆盖率和全范围变异门禁仍未通过，不能标记完整验收完成。详见 [部署记录](deployment-vps-client.md)。**

## 已执行

| 检查 | 结果与范围 |
| --- | --- |
| Swift 编译/发布打包 | 通过。App、Runner、Helper 构建；包内包含 age/age-keygen 1.2.1、许可证和组件摘要。签名及所有清单组件 SHA-256 再核验通过。 |
| 客户端检查 | 通过。136 场景、19597 断言、0 失败，其中独立联动检查 44 断言。覆盖同源发现、授权错误、响应限额、取消、备份损坏/中断、原文件保留、恢复口令与测速路径证据。 |
| 服务端回归 | 2026-10-22 通过 91 项（包含既有认证/设备/订阅回归，以及轻量实例选择、字节换算、账单资源过滤、身份歧义拒绝、SDK 采集），0 失败；一个既有测试时间 API 弃用警告。 |
| 真实 HTTPS 隔离链路 | 通过。临时证书、真实 Nginx、双 Gunicorn worker、仅回环随机端口。并发兑换只允许一次成功；8 MiB 上传及下载、413/429、无采样时保持未知。未使用现网证书或数据库。 |
| 加密与恢复 | 通过。Mac 和 VPS 隔离环境使用真实 age 工具；数据库一致性/完整性、云凭据过滤、依赖清单、留存、失败不覆盖清单、损坏拒绝。同名配置文件保留路径层级，避免 Nginx/sudoers 冲突。 |
| UI | 本次通过烟雾检查。23 断言、41 张截图；新增轻量实例套餐浅色/深色场景。独立目录和偏好域，未创建接管恢复记录。不能替代完整交互覆盖率。 |
| 定向变异 | 通过所选场景。此前客户端 4/4，本次服务端 9/9 检出；补充轻量套餐字节换算错误、实例套餐误标共享。客户端未修改底层 HTTP/加密逻辑，保留原结果。**不是全代码变异得分。** |
| 源码格式 | `git diff --check` 通过；新 Python 模块编译检查通过。 |

## 严格门禁与未验证部分

| 项目 | 状态 |
| --- | --- |
| 新服务端三模块 | 本次 367 条语句中覆盖 347 条（94.55%），分支覆盖 85/98（86.73%），合并 92.90%；覆盖汇总见 `.build/vps-verification/server-cloud-coverage.json`，未达到 100%。`client_api.py` 行覆盖 179/179，仍有分支缺口。缺口包括定时任务入口、采集异常、分页边界与生成器分支。未排除代码来制造 100%。 |
| 新 Swift 联动 HTTP 库 | `VPSClient.swift` 行覆盖 100%；区域覆盖 90.51%。Swift 当前报告分支数量为 0，不解释为分支 100%。 |
| 联合诊断、App 界面/状态模型 | 诊断文件报告行覆盖 96.97%；App 的 VPSCenter/VPSView 未纳入 CLI 覆盖目标。完整 Mac 钥匙串配对、恢复文件面板交互未验收。 |
| 全范围变异门禁 | 未验证。11 个定向变异不足以代表全部新增代码；PIT 本身不适用于本仓库的 Swift/Python。 |
| 真实腾讯云只读查询 | 本次通过。用户创建的子账号凭据已保存到 VPS `/etc/hy2-cloud.env`，权限 root:root 0600。正式 SDK/`cloud_main` 对新加坡轻量实例 `lhins-qbi3vwvb` 查询成功，数据只写入内存数据库。套餐总量 1536 GiB，剩余约 1496.01 GiB；本月账单接口成功但无该资源记录，不能声称真实费用为零。未启用生产采集、未验证历史费用及实际结算延迟。 |
| 生产端配对、备份定时器与长期运行 | 生产接口已用短期检查授权验证，检查后精确撤回；两项定时器已启用，无公钥时备份任务成功跳过。实际 App 配对、公钥导出、钥匙串流程和连续使用验收仍未完成。 |

沿用 [delivery-quality-gate](/Users/leiminghao/.codex/skills/delivery-quality-gate/SKILL.md) 的要求：`100% applicable line and branch coverage and PIT mutation score of at least 80%`。该门禁仍未完整满足；本次按用户后续明确要求完成安装和服务端部署，不把已部署等同门禁通过或全部功能验收完成。隔离结果、真实公网接口结果与 App 实际使用结果分别记录。

## 产物

- [最新 App 候选包](/Users/leiminghao/Documents/Codex/2026-10-12/new-chat/work/GitHub/qingzhou-proxy/outputs/qingzhou-0.10.0-20261022-000654.c1oLZQ/轻舟代理.app)，同目录 `artifact-manifest.json` 记录源树及组件摘要。旧候选包已移入废纸篓，只保留最新 App 候选包。build 41 签名、组件及源树摘要复核通过，App 与服务端归档扫描未包含本次云凭据。
- [服务端候选包](/Users/leiminghao/Documents/Codex/2026-10-12/new-chat/work/GitHub/qingzhou-proxy/outputs/vps-client-0.10.0-candidate/hy2-client-source.tar.gz) 与 [清单](/Users/leiminghao/Documents/Codex/2026-10-12/new-chat/work/GitHub/qingzhou-proxy/outputs/vps-client-0.10.0-candidate/server-manifest.json)，已按部署记录安装到 VPS，原有认证及代理核心保持运行。
- [实现、配置与恢复说明](/Users/leiminghao/Documents/Codex/2026-10-12/new-chat/work/GitHub/qingzhou-proxy/docs/vps-client-integration.md)。服务端采用新的独立 venv 及 admin/stats drop-in，认证继续使用旧 venv；不得原位升级认证共享依赖。备份目录采用 root 管理的 `/var/backups/qingzhou-client`，公钥未配置时跳过。
- 复现日志与覆盖率报告在 `.build/vps-verification/`，界面截图在 `.build/ui-evidence/`。都未进入服务端源码包。


配对修正补验：2026-10-22 已安装 build 42，服务端 92 项、联动客户端 53 断言、真实 Swift HTTPS 配对链路通过。旧进程未强退，需重开加载；用户实际持久配对尚未确认，详见部署记录。完整覆盖率与全范围变异门禁仍未完成。
