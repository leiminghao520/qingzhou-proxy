# HY2 Console · 设备订阅管理

## TCP 备用节点订阅（2026-10-28）

设置 `HY2_VLESS_PUBLIC_CONFIG` 指向 root 所有、hy2admin 可读的公开参数 JSON，字段为 `server`、`port`、`server_name`、`public_key`、`short_id`。不要放入服务器私钥或共享设备 UUID。未设置时保持原来的单 HY2 输出。

六种原订阅格式均追加 VLESS + TCP + REALITY + Vision，地址和令牌保持不变。轻舟在订阅更新预览中确认后同步节点，完整订阅的规则模板与 revision 保持原语义。sing-box 完整配置新增 selector，默认仍使用 HY2；Shadowrocket 完整配置保留原规则并扩展 PROXY 选择组。

`vless.py` 使用设备密码与 auth_id 派生稳定 UUID，密码轮换后 UUID 随之改变。`vless_sync.py` 由 root 运行，只读设备数据库；只允许启用用户下的启用设备。创建设备、启停设备或用户、轮换设备凭据后同步 TCP 授权列表；名称和备注修改不触发同步，有变化时重启 TCP 服务并断开旧连接。同步失败返回 503，数据库变更仍保留；读取、解密或重启失败会关闭 TCP 服务，避免旧授权继续有效。HY2 认证与连接不因此重启。

root 桥接器新增唯一固定操作 `sync-vless`，sudoers 必须单独允许此精确命令；它通过独立 systemd 任务加载 `/etc/hy2-admin.env` 并运行同步模块。模块使用文件锁串行读取和更新，避免并发变更丢失。部署还应配置每 30 秒运行的补偿 timer，恢复同步异常；服务文件见 `deploy/qz-vless-sync.*`。

新增节点流量目前不计入既有 HY2 的 `Subscription-Userinfo` 和设备 HY2 流量报表。客户端已下载的旧配置需要更新后才会获得轮换凭据。2026-10-28 最初单独发放的临时共享 TCP 链接已由设备专属凭据替代。

轻舟 0.10.0 联动增量、隔离验证和部署边界见 [联动说明](../../docs/vps-client-integration.md)。下方 v3 记录是导入前的历史基线，不能当成本轮变更范围。

Flask + Jinja + SQLite 的管理员专用后台。每台设备有独立凭据和私有订阅；代理认证运行在独立进程，日常用户与设备变更不重启 Hysteria。

## v3 本地改版（2026-10-02）

- 概览页收起用户预览至 8 条，增加最近 5 条管理操作，方便快速查看变化；完整记录仍在审计页。
- 用户列表每页显示 20 条，搜索与启停筛选会保留在翻页链接中；越界页码会回到有效页。
- 手机端加入可关闭的侧栏遮罩，支持 Escape 键、焦点约束和焦点返回；调整了卡片、表格、按钮与深色模式的布局。
- 设备页的订阅地址默认隐藏凭据，点击可临时显示；复制、下载、二维码功能继续使用原有地址。
- 图表补充文字说明与数据表，便于不依赖图形查看趋势。

本次没有修改数据库结构、认证逻辑或订阅接口。再次上线前仍需核对线上版本、备份并按下文的维护流程验证。

## 本地运行

使用 Python 3.12 或更新版本，安装 requirements.txt。配置 HY2_SECRET_KEY、HY2_ENCRYPTION_KEY（Fernet 密钥）、HY2_DATABASE、HY2_PUBLIC_BASE_URL、HY2_SERVER_NAME、HY2_SERVER_PORT；本机 HTTP 预览设 HY2_COOKIE_SECURE=0，生产必须为 1。不要将真实密钥写进代码、终端历史或测试数据。

通过安全环境变量提供后台初始密码后：

```sh
flask --app 'app:create_app()' bootstrap
flask --app 'app:create_app()' run --host 127.0.0.1 --port 8787
```

bootstrap 输出首次登录密码和 TOTP 绑定地址，必须按敏感凭据保管。首次登录强制修改密码。在“用户与设备”中创建唯一 owner，再登记实际设备。已有数据库无需重新 bootstrap。

运行回归测试：

```sh
python -m pytest -q
```

## 管理行为

- 后台登录密码 + TOTP 与 owner 代理身份相互独立。
- 用户显示名称、备注可编辑；账号标识固定。用户启停作用于全部设备，但重新启用用户不会恢复被单独停用的设备。
- 每台设备保存人工登记的平台、客户端和备注。凭据加密存储，订阅令牌使用 SHA-256 索引查找；不可将设备登记信息理解为网络自动探测结果。
- 每台设备的节点订阅、完整配置、二维码均独立。完整配置用于配置导入，通用 HY2 文件内是节点 URI；不是所有客户端都能直接扫描订阅 URL。
- 停用／轮换先提交失效状态，再断开已有连接。失败会进入持久化重试队列；队列中的设备不能重新认证，包括已轮换的新凭据，直到断开成功。
- owner 免限额，但可手动撤销；停用 owner 用户或停用／轮换其设备需要后台密码与 TOTP 二次校验。
- 没有用户自助门户、收费、自动限额或访问目的地采集。

## 接口与进程

- app:create_app()：管理页面、设备订阅、二维码及 /api/overview；Gunicorn 监听 127.0.0.1:8787。
- auth_service:create_auth_app()：独立 Gunicorn，监听 127.0.0.1:8788，仅提供 POST /auth。JSON 入参包含 auth: 设备标识:密码，成功返回 {ok:true,id:设备标识}。异常拒绝新连接，不返回数据库或凭据细节。
- /users/<user_id>/devices：创建设备；/users/<user_id>/devices/<device_id>：查看、编辑、启停、轮换。必须是后台会话，并对写操作验证 CSRF；校验设备所属用户。
- /s/<token>/<format>：以设备令牌获取指定格式；旧账号令牌不再受理。所有订阅禁止缓存、索引，不在日志记录完整请求路径。
- collect_stats.py：每分钟采集，并重试断开任务。统计 API 只监听本机，设置 HY2_STATS_URL 和 HY2_STATS_SECRET。
- privileged_helper.py：只允许读取服务状态和校验／重载 Nginx。后台没有写代理配置、重启代理或单独回滚代理配置的权限。
- deploy/release.py：root 在授权维护窗口手动执行的配套快照、切换和整体恢复工具；不加入后台 sudoers。

设备认证不可用时，新连接被拒绝；已建立连接由代理进程维持。后台页面进程重启不会重启认证进程。数据库不可用会阻止新认证。

## 统计口径

数据库时间使用 UTC，页面按北京时间展示。上传／下载以客户端视角显示；在线数是 Hysteria 客户端实例数，不是物理设备数。

每分钟记录累计计数和 systemd InvocationID，以同一运行代次的连续采样差值汇总。首次采样、计数回退、重启或超过 150 秒的采样间隔不推算丢失流量；图表和总量仅代表已观测数据。采样区间用量归入区间终点所在时段，因此跨小时／跨日边界有最多一个采样间隔的归属误差。

采集失败不是零用量；超过 150 秒的旧在线状态显示为未知。概览每 30 秒更新，隐藏标签页暂停刷新。旧账号采样独立保留，不分摊到新设备。审计与采样保留 180 天。

## 从账号订阅升级

以下步骤会改变线上状态，只能在获得上线授权后执行。先核对服务器程序、环境文件、数据库、Nginx 路径与本地版本，保留原有密钥。不要直接运行旧版单独回滚配置工具。

1. 将新发行版放到暂存目录。在替换 /opt/hy2-admin 前，使用新发行版的 deploy/release.py snapshot --nginx-config 实际HY2配置路径 创建配套快照。工具会暂时停止后台／采集／认证写入进程，使用 SQLite backup 保存数据库，保存程序（含原虚拟环境）、环境文件、代理配置、指定 Nginx 配置、helper、sudoers 和 systemd 单元，随后恢复原运行状态。快照根目录为 /var/backups/hy2-admin/releases，权限 0700。
2. 进入维护窗口，停止 hy2-admin 和 hy2-stats.timer/service；替换程序、安装 requirements.txt。以原 HY2_ENCRYPTION_KEY 启动应用，数据库会幂等新增设备和采样表，保留原用户、管理员、审计和旧采样。原登录密码和 TOTP 不变。
3. 安装本版 deploy/hy2-admin.service、hy2-auth.service、hy2-stats.service 和 hy2-stats.timer；安装 root 所有的 privileged_helper.py 到 /usr/local/sbin/hy2-admin-helper，并以 visudo 校验本版 sudoers。只允许 status 和 reload。保持认证端口与统计端口不对外开放。
4. 保留现有域名和 TLS 配置，核对 deploy/nginx.conf 的路由及脱敏访问日志；认证端口不经 Nginx 代理。以 nginx -t 验证。执行 systemctl daemon-reload，并启用、启动 hy2-auth 和 hy2-admin。此时设备认证已可独立探测，代理仍使用旧认证配置。
5. 在后台为每台真实设备登记并生成新订阅。至少准备一台启用的 owner 设备；用隔离的临时 Hysteria 实例和端口完成其客户端连通验证。程序升级后旧订阅下载停止，旧代理连接直到认证切换时才失效。
6. 在已安全加载现有环境变量的 root 会话中，执行 deploy/release.py activate --snapshot 快照绝对路径 --owner-device 实际设备ID。该命令先验证快照、设备状态及本机 HTTP 认证，再将现有代理配置的 auth 替换为本机 HTTP 认证并重启一次 Hysteria。同步废止全部旧账号密码，所有客户端重新导入设备订阅。切换失败会调用配套整体恢复。
7. 启用并启动 hy2-stats.timer。验证旧订阅 404、旧凭据认证失败、新 owner 和普通设备连通、单设备撤销隔离、至少两次连续采集，以及 Shadowrocket 和至少一个 Mihomo／sing-box 客户端的实际导入。
8. 恢复必须使用 deploy/release.py restore --snapshot 快照绝对路径。工具停止写入与代理进程，恢复配套程序、数据库和配置，再恢复原服务状态。被替换的新版本会另存于 replaced-* 目录，供检查；不直接递归删除。

快照包含私密配置及数据库，应仅由 root 访问。若服务目录、数据库或配置路径不符合上述默认值，先明确修改 release.py 中的路径常量，不要对未知路径尝试恢复。恢复会丢弃快照之后的线上变更，因此只适合配套的维护窗口。

## 验证边界

本地测试可覆盖页面、认证、权限、采样计算，以及模拟文件和 systemd 调用下的迁移／恢复编排。真实 Linux 服务管理、权限、TLS、线上历史数据迁移、跨设备客户端导入，必须在隔离环境或授权上线窗口进一步验证。不能用网页演示数据或配置语法校验替代真实连接验证。

本项目为 Python，不提供 Java/PIT 执行环境。PIT 变异门禁不能作为已完成项；需要该门禁时，先明确适用于 Python 的替代工具及验收口径。


## 订阅流量信息

所有设备订阅格式通过 `Subscription-Userinfo` 响应头返回该设备的已观测流量，单位为字节：`upload` 对应 Hysteria 的 `tx`，`download` 对应 `rx`。仅汇总当前数据库留存的有效采样增量（采样保留 180 天），并非 VPS 服务商账单或终身累计；采样缺口与重启丢失区间不估算。无有效采样时省略响应头，已观测零流量正常返回零。未配置真实配额及到期信息，因此不发送 `total`、`expire`。客户端更新订阅后刷新用量，订阅响应禁止缓存。
