# 验证记录

日期：2026-09-30。分支：`codex/fix-renewal-cron`。

Linux CI 已通过：[运行 36604855285](https://github.com/fadeawaylove/sing-box-yg/actions/runs/36604855285)，代码提交 `e6f6f0f40eace6b377a8be45397a1281bfa666dc`，Ubuntu 24.04。后续发布文档变更不改变该测试代码。

自动迁移入口及完整回归也已通过 Linux CI：[运行 36606241442](https://github.com/fadeawaylove/sing-box-yg/actions/runs/36606241442)，提交 `eac247ec0fa8df9f27dcbd02118a87bf8cf4919f`。`tests/migration.sh` 覆盖运行/停止状态、重复执行、SAN 保留、错误旧记录、安装/任务写入失败恢复、忙碌 ACME、配置/读取失败、记录歧义、无效密钥和过期证书。迁移使用替身服务与临时文件，逐字节确认原配置和证书不变，并拒绝任何服务修改命令。

| 验证 | 结果 |
| --- | --- |
| Bash 语法：主脚本、证书脚本、维护入口及测试脚本 | 通过 |
| `python tests/check_integration.py` | 通过；12 个自有资源路径、主脚本与维护入口成对更新、官方客户端来源、当前证书脚本哈希 |
| `bash tests/maintenance.sh` | 45 个场景在 Linux 通过，含 BusyBox 空表／权限／不完整读取、绑定失败回滚、OpenSSL 零退出码身份不匹配、日志权限 |
| `bash tests/menu_flow.sh` | 21 条菜单成功/失败路径通过；复用现有 ACME 客户端 |
| `bash tests/install_flow.sh` | 2 项通过：证书失败中止安装；选择自签证书后正常初始化 TLS 并继续 |
| `bash tests/update_flow.sh` | 下载失败、安装失败、成对更新、临时文件清理后的维护入口可用性，共 4 项通过 |
| `SBYG_TEST_ACME=… bash tests/acme_rollback.sh` | 官方 ACME 3.1.2 的 8 项离线回归通过：原有 4 项绑定／回滚测试，以及双域名的两种续期安装顺序、旧域名单独更新钩子／无需续期、旧共享暂存目录隔离；对完整域名配置及证书逐字节比较 |
| `git diff --check` | 通过 |
| `bash tests/live_tls.sh` | GitHub Ubuntu 上通过：真实 sing-box 1.13.4 返回新 TLS 指纹，未更新不重复重启；本地 Windows 跳过 |
| GitHub Linux 工作流 | 上述运行全部通过，包含官方 ACME 离线回归和真实内核 TLS 验证 |
| 生产服务器 | 未连接、未修改、未执行证书申请 |

本地使用 Git for Windows Bash、OpenSSL、jq 和 Python。服务管理器、ACME、crontab、下载与安装均为临时替身。证书是本地生成的测试证书，不接触生产 CA。Windows 不验证 Linux 文件权限语义；700/600 权限断言仅在 Linux 测试运行时执行。

审查后的三项修复：安装入口显式传播证书失败；精确识别当前用户的 BusyBox 无任务错误，拒绝权限、其他缺失路径及不完整读取；候选证书校验通过后原子提交身份记录，校验/安装失败恢复原暂存证书。以上均有回归覆盖。

再次审查后，绑定回滚增加官方 ACME 域名配置的备份与恢复；配置路径从客户端 `--info` 获取，避免假定默认账户目录。官方客户端回归在临时账户中执行真实 `--install-cert`，验证 `Le_Real*` 路径、`Le_ReloadCmd` 及其他域名设置均能完整恢复，没有发起证书申请或网络验证。

本次修复将暂存目录按主证书标识隔离，部署钩子携带标识并忽略非当前记录。新增测试通过替身模拟 `--cron` 调度，按各记录持久化的路径及钩子调用官方客户端真实 `--install-cert`，再执行维护部署，验证任一安装顺序均加载当前证书。调度与签发仍属模拟，不代表真实 CA 续期或 Linux TLS 验收。试用旧共享暂存版本后须重新绑定当前证书，详见迁移文档。

已只读核对官方 acme.sh 3.1.2 的默认 crontab 格式与 `RENEW_SKIP=2`，并从官方 GitHub v1.13.4 发布资产 API 核对 Linux amd64 包 SHA-256；未下载或执行生产安装器。

Linux 首次执行揭示旧版 OpenSSL 在身份不匹配时仍可能返回零，现检查明确的匹配输出，并补充 DNS/IP 回归；日志写入与轮转自身设置私有权限，不依赖调用方 umask。这两项修复后全部 CI 通过。

真实 systemd/OpenRC init 的发行版级测试不包含在命令适配器替身结论中；生产迁移仍需核对实际配置、服务与 TLS 指纹。历史自动续期失败的具体原因仍未确证。
