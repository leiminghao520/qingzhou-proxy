# 汐航 0.16.0 品牌与界面改版验证

本次将 macOS 客户端显示名称更新为汐航 / Xihang，交付帆与潮汐图标、青蓝主题、共用连接卡、线路卡、合并流量卡和节点卡。沿用简洁与专业模式；其他页面通过主题、标题、表单与卡片统一样式。

## 兼容与依赖

Bundle ID `cn.qingzhou.proxy`、数据目录 `Application Support/Qingzhou`、钥匙串 service `cn.qingzhou.proxy.credentials`、Helper 安装目录与标识、内部模块及二进制名保持不变。不迁移、不重写用户配置。

Pow 1.0.6 固定到 `1b4b1dda28c50b95f0872927ee2226fe8b58950e`，生产源码与 MIT 许可证原样随项目交付。仅调整其 Package.swift，删除未启用的 iOS 预览依赖；`Vendor/pow-lock.json` 记录每个文件哈希，`python3 scripts/verify-pow.py` 核验。Pow 只用于连接成功的短闪光和收藏反馈，减少动态效果时禁用。

图标生成入口为 `swift scripts/make-modern-icon.swift 输出目录`，不再依赖开发机上的历史图片。应用包包含 Pow 资源与许可证。图表沿用 Swift Charts，保留固定三十分钟窗口和稳定纵轴，增加选择读数。

## 检查入口

- `bash scripts/swift-local.sh build --product Qingzhou`
- `bash scripts/swift-local.sh build --product QingzhouChecks`，随后 `.build/debug/QingzhouChecks`
- `bash scripts/daily-experience-checks.sh`
- `bash scripts/connection-recovery-ui-checks.sh`
- `bash scripts/interface-checks.sh /绝对路径/截图目录 --brand`
- `bash scripts/build-app.sh /绝对路径/输出目录`

UI 检查使用独立偏好域、临时目录与虚构节点；不启动正式应用的恢复入口，不连接真实节点，不写系统代理。截图内连接与流量为隔离展示状态，不作为实网接管证据。具体本轮日志、断言数和截图见交付目录的验证记录。

## 交付与限制

本轮不覆盖 `/Applications`、不提交、不推送、不发布。预览与旧版共享技术身份，使用预览包前需正常退出旧版。正式替换时仍需单独验证登录启动、钥匙串访问、Helper 授权和真实连接；保留标识不等于操作系统不会再次授权。

主要变更为 UI 维护与品牌资产，不新增代理业务策略。现有隔离行为测试与渲染检查用于验收；未宣称 SwiftUI 视图达到 100% 行分支覆盖或完成变异测试。日常操作检查的覆盖率报告不包含实际执行视图闭包，不能代替截图和实机交互验收。
