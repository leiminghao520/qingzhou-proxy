# VPS 与轻舟联动（0.10.0 候选版）

本轮在现有 macOS 客户端和 Hysteria HTTP 管理后台上实现七项联动。服务端源码从已有线上对应源码导入 `server/hy2-admin`，保留原认证、设备和订阅行为；新增逻辑的代码注释使用中文。初始隔离轮未安装或部署。随后按用户明确要求安装 App 并部署 VPS 服务端，见 [部署记录](deployment-vps-client.md)；未切换本机网络或自动连接。

## 实现范围

| 能力 | 行为与边界 |
| --- | --- |
| 服务端状态 | 展示 Hysteria、认证、Nginx 进程，证书到期、可用内存、磁盘与负载；150 秒后标为过期。进程在线不等于实际转发成功。 |
| 设备流量 | 今日、本月与留存归档；北京时间分日。保留采样不完整和未知值，不以零伪装采集失败。原始样本清理后每日归档保留。累计值是已观测归档，不承诺补齐安装前历史。 |
| 腾讯云账单/套餐 | 独立小时任务，区分 Lighthouse 与 CVM。轻量实例绑定自身流量包，保留原始字节值并以 GiB 展示；CVM 绑定实例及关联 EIP，共享套餐当前余量取套餐接口，不使用历史抵扣余量。服务端二次过滤资源；只读查询，无本月记录不解释为零费用，设备统计不冒充云厂商计费。 |
| 设备查看 | 只展示配对设备所属账户的设备；停用、轮换、添加仍走已有密码及 TOTP 管理后台，客户端不持有后台会话。 |
| 手动带宽 | 每方向最多 8 MiB、五秒，每设备每方向每分钟一次。显式走现有本地代理入口，核心连接表须确认经过绑定订阅节点；不能确认时不输出带宽。断开、切换、重规划或离开页面取消；已传输部分仍计费。 |
| 加密备份 | 在线 SQLite backup API，数据库完整性检查，再用 age 公钥加密。VPS 和 Mac 分别保留七份近期及四个不同周的备份。Mac 私钥在钥匙串，另导出口令保护的恢复密钥文件。VPS 只有公钥；应用运行时每五分钟尝试同步，不自动恢复。 |
| 联合诊断 | 组合本机配置、权限、路由、DNS、HTTPS 检查与新鲜服务端证据。管理通道失败显示未验证，不能推出代理失效；可导出脱敏结果。诊断不自动连接或修复。 |

配对必须由后台生成十分钟有效、仅一次使用的随机码；数据库只保存其摘要和访问令牌摘要。订阅响应只公布同源 `/api/client/v1` 能力路径，订阅密码不能调用联动 API。访问令牌独立存钥匙串；停用用户/设备、待踢下线、轮换或撤销授权均阻断访问。客户端拒绝重定向、限制响应大小，不记录订阅地址或令牌。

## 接口

所有联动接口位于 `/api/client/v1`，除配对外使用 Bearer 授权；普通用户不能读取所有者功能。

| 方法/路径 | 作用 | 权限 |
| --- | --- | --- |
| POST pair | 消耗一次性码，返回独立令牌 | 一次性码、IP 限流 |
| GET me / usage / devices | 设备身份、流量、同账户设备 | 配对设备 |
| GET status / billing | 状态、云账单缓存 | 所有者设备 |
| GET speed/download、POST speed/upload | 有上限的实际传输 | 配对设备、额外限流 |
| POST backup/recipient | 首次设置 age 公钥，不允许覆盖旧公钥 | 所有者设备 |
| GET backup、GET backup/download | 清单与加密文件 | 所有者设备 |

Web 端 `/client-access/<device_id>` 及其 `/revoke` 子路径只接受已有后台登录和 CSRF 校验。应用内解除配对仅删除本机访问令牌；服务器端撤销在后台执行。

## 后续生产配置

先完成验收门禁，再在维护窗口执行。此文档是部署步骤，不代表已部署。

1. 在线备份现有数据库、程序、Nginx 和 systemd 配置，并记录各服务 PID/启动时间；保持 Hysteria 与认证配置不变。旧 `deploy/release.py` 是历史认证切换工具，会停止或重启服务，本轮不能直接使用它发布联动能力。
2. 核对 `/opt/hy2-admin`、Python 环境及代码均由 root 管理、`hy2admin` 不可写。将新文件及两张模板加入对应目录；检查 `app.py`、`collect_stats.py` 差异后更新。API 要求 Flask 3.1 以上。在 `/opt/qingzhou-client-venv` 建立 root 管理的独立 venv，验证基础与 requirements-client.txt 依赖；Web 和采集应用新的 drop-in，认证继续用旧环境，不在线原位升级共享认证 venv。
3. 安装可信 age 工具，当前服务端默认 `/usr/bin/age`。新建 `/var/backups/qingzhou-client`，root:hy2admin、0750。父目录也必须由 root 控制；不能放回 Web 进程可写的 `/var/lib/hy2-admin` 下。备份单元通过 RuntimeDirectory 创建私有 `/run/qingzhou-backup`，原文只进入该受限临时目录。
4. 在现有 admin/sub 两个 HTTPS 主机中加入候选 `deploy/nginx.conf` 的 `/api/client/v1/` location 块；保留现有证书、其他路径和日志策略。8 MiB 请求体上限、禁用测速缓冲、读取超时 130 秒。先 `nginx -t`，通过后才 reload；无需替换整份现网配置。
5. Web worker 重新加载新程序，认证与 Hysteria 无须重启。新表均为增量创建，不重置现有账户、设备或用量。
6. 安装两个新增 service/timer；确认备份目录权限后再启用。手工运行一次云采集，确认缓存包含绑定资源、来源及采集时间；查询失败保留原采集时间，不生成零账单。
7. 用所有者设备配对；先导出并另存恢复密钥及口令，再启用公钥、运行备份服务，核验服务器清单、Mac 下载 SHA-256、隔离解密及数据库完整性。无公钥时任务跳过，不影响代理。
8. 全部检查完成后才安排真实 App 安装、配对与连续使用；本次已完成服务端配置；实际 App 配对及长期使用仍待验收，见部署记录。

当前 `hy2-admin` 与 `hy2-auth` 共用 Python venv。部署应给 Web/采集/备份使用新的、root 管理的独立 venv，调整对应 ExecStart；保留认证单元继续使用旧 venv。这样不会让正在运行的认证服务混用原位更换的依赖。候选 cloud/backup 单元及 admin/stats drop-in 已统一使用 `/opt/qingzhou-client-venv`，必须先建立并验证该环境。

### 腾讯云授权

优先实例角色；或将只读凭据保存在 VPS 的 `/etc/hy2-cloud.env`（root:root，0600），由 systemd 注入采集进程，不放入 App、数据库、仓库或聊天。

配置 `HY2_CLOUD_REGION`、`HY2_CLOUD_INSTANCE_ID`；可显式设置 `HY2_CLOUD_RESOURCE_TYPE=lighthouse` 或 `cvm`，未设置时按 `lhins-` 前缀识别轻量实例。`HY2_CLOUD_PACKAGE_IDS` 仅用于 CVM 的明确共享流量包 ID，逗号分隔；Lighthouse 从绑定实例查询，不配置共享包。静态凭据使用 SDK 支持的 `TENCENTCLOUD_SECRET_ID`、`TENCENTCLOUD_SECRET_KEY`，临时凭据还包括对应 token。无绑定实例时只返回未配置。

Lighthouse 调用 DescribeInstances、DescribeInstancesTrafficPackages、DescribeBillDetail；CVM 调用 DescribeInstances、DescribeAddresses、DescribeTrafficPackages、DescribeSpecificTrafficPackageUsedDetails、DescribeBillDetail。CAM 授权按腾讯云控制台当前支持粒度收敛。当前用户创建的子账号关联轻量只读与账单只读预设策略，账单授权包含账号范围。代码中的资源过滤不等于凭据天然只有单实例权限；客户端只能收到过滤后的结果，不能得到云凭据。

2026-10-22 已按用户授权读取本机私有 CSV，将只读凭据保存到 VPS `/etc/hy2-cloud.env`（已验证 root:root、0600），授权补验阶段未安装或启用定时器；后续已按部署记录启用。通过公网 IP 核实资源为新加坡 `lhins-qbi3vwvb`，不是底层元数据中的 CVM 资源。正式 `cloud_main` 使用固定版本 SDK、真实凭据和内存 SQLite 验证成功：实例套餐总量 1536 GiB、已用约 39.99 GiB、剩余约 1496.01 GiB，实例到期 2027-09-15；本月资源账单接口成功返回 0 条记录。该结果是采样时点值，不能当作持续更新或历史费用验收。真实配额提醒、App 配对及生产采集尚未验收。

接口依据：[实例流量包详情](https://cloud.tencent.com/document/product/1207/48681)、[字节字段定义](https://cloud.tencent.com/document/api/1207/47576)。Linux SDK 依赖仅加入隔离 venv，未升级线上认证或代理依赖。

### 恢复

备份包含一致性数据库、程序、运行依赖版本清单以及允许列表中的管理环境、Hysteria、Nginx、Helper、sudoers 和服务单元。云凭据不备份；证书私钥不包含，需要通过原证书管理流程恢复或重新签发。

恢复密钥文件使用 PBKDF2-HMAC-SHA256（600000 轮）与 AES-GCM，认证标签与普通轻舟配置备份隔离。恢复时先在私有临时目录解密 age 文件、检查归档路径和数据库 `PRAGMA integrity_check`；依照归档中的依赖清单在独立环境重建，人工核对配置再切换。禁止直接把 tar 解到系统根目录。恢复密钥和口令丢失后无法从 VPS 公钥恢复。

## 可重复验证

```sh
scripts/swift-local.sh build --product QingzhouChecks
.build/debug/QingzhouChecks vps-checks
scripts/coverage.sh
python3 scripts/vps-backup-checks.py
scripts/interface-checks.sh
```

服务端隔离检查需要预先准备 `/var/tmp/qz-client-test-venv`，安装基础、requirements-client.txt、pytest、coverage 依赖。Linux age 工具使用 `tools/agebuild` 同一固定源码交叉编译到 `.build/age-tools-linux`。`scripts/vps-isolated-checks.py` 仅将公开源码/检查工具暂存到 VPS 的独立 `/var/tmp/qingzhou-client-v1-isolated`，测试数据库全部在临时目录。

```sh
python3 scripts/vps-isolated-checks.py
# VPS 隔离目录中执行：
/var/tmp/qz-client-test-venv/bin/python /var/tmp/qingzhou-client-v1-isolated/tests/http_smoke.py
# 定向变异在副本执行，每个变异后恢复副本源码：
python3 scripts/vps-mutation-checks.py
python3 scripts/vps-mutation-checks.py --server
python3 scripts/package-vps-client.py
```

真实 HTTPS 隔离检查用临时自签证书、双 worker Gunicorn 和独立 Nginx，仅绑定回环随机高端口，不加载现网证书、不更换系统信任、不接触真实数据库。不能将它当成生产域名证书、真实代理路径或真实腾讯云权限的验收。
