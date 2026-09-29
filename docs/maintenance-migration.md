# 维护任务迁移、验证与回退

以下生产命令是迁移操作说明，本次没有在服务器执行。先确认所用提交的 Linux 集成验证通过，再选择维护窗口迁移；备份后更新，不重新安装现有服务。

## 已有行为与新接口

- 每日 01:00 仍重启 sing-box，按 `/run/systemd/system` 或 `/run/openrc` 选择正在使用的服务管理器；未知环境拒绝写入任务。服务命令从固定 PATH 解析为绝对路径。
- 每日 00:00 调用维护入口执行官方 ACME `--cron`，不强制续期。首次绑定和新申请沿用 ECC（现有脚本使用 ec-256）；不改变 CA、HTTP/DNS 验证方式或账户。
- 执行入口：`/usr/local/lib/sing-box-yg/maintenance.sh`。支持 `restart`、`renew`、`deploy`、`bind ID...`、`install-cron restart|renew`、`remove-cron restart|renew`；必须用 Bash 执行。
- 证书仍位于 `/root/ygkkkca/{cert.crt,private.key}`。`ca.log` 保存本次明确绑定的主标识；多 SAN/IP 证书在 `bind` 后逐项传入要保证的标识，通配符必须加引号。
- 官方 `--install-cert` 改为写入 `.maintenance/stage/<主标识的 SHA-256>`，并注册携带证书标识的更新后 `deploy` 钩子；校验成功才写入原有证书路径。更换域名后保留旧 ACME 记录，但旧记录只更新自己的暂存目录，不能部署当前证书。配置确实引用这对路径且服务运行中才重启。配置检查或重启失败保留旧证书备份和待重试状态。
- 如果试用过共享 `.maintenance/stage` 的旧版维护入口，更新后须对当前证书重新执行下文的 `bind ID...`，迁移其安装目标和钩子；不能只更新脚本而跳过绑定。旧共享目录不再作为部署来源，不会自动推断其中证书的归属。
- `.maintenance/backup` 是最近一次替换前的证书对，不是完整迁移备份。不存在旧证书时无法凭空回退；失败会返回非零且不显示成功。
- 绑定前通过官方 `--info` 确定域名配置文件并备份；安装或候选校验失败时恢复完整域名配置（含证书输出路径、重载命令）和原暂存文件。候选校验通过后才提交身份；后续服务加载失败则保留已验证的新配置供重试。恢复失败会保留私有事务备份并报错。
- 已停止的服务不会启动。若上次重启失败后仍停止，需要操作员诊断并恢复服务，然后再执行 `renew` 重试加载。
- 官方客户端本身不做 fork。新增功能依赖 Bash、OpenSSL、GNU date、jq、crontab 和常见 coreutils；Alpine 需安装 `bash coreutils openssl jq`（实际安装另行执行）。

## 隔离验证

```bash
python3 tests/check_integration.py
for file in sb.sh scripts/*.sh tests/*.sh; do bash -n "$file"; done
bash tests/maintenance.sh
bash tests/menu_flow.sh
bash tests/install_flow.sh
bash tests/update_flow.sh
SBYG_TEST_ACME=/absolute/path/to/acme-3.1.2.sh bash tests/acme_rollback.sh
SBYG_TEST_BINARY=/absolute/path/to/sing-box bash tests/live_tls.sh
```

前四套 Shell 回归使用临时目录、临时证书和替身服务/ACME/cron/更新下载，仅提取菜单及安装入口函数进行隔离测试。`acme_rollback.sh` 使用官方 3.1.2 源码（校验固定 SHA-256），仅用官方 `--info` 和 `--install-cert` 操作临时账户和证书，替身模拟 `--cron` 的调度；不申请证书、不运行客户端安装器、不调用官方 `--cron`。工作流下载该源码后执行离线回归。

真实 TLS 测试只在 Linux 执行：以真实 sing-box 监听随机回环端口，在 systemd/OpenRC **命令适配器替身**下验证新证书握手指纹以及无需续期时不重启；不代表已经验证了真实 OpenRC init 或每种发行版。

GitHub 工作流使用官方 sing-box 1.13.4，并固定发布资产 SHA-256。最新执行证据见 [验证记录](maintenance-validation.md)。Windows 本地不具备 WSL/Docker；生产迁移仍需逐机验证。

## 迁移步骤（未来执行）

在服务器已审核的仓库副本根目录，以 root 执行。先核对域名、实际证书有效期、证书 SAN、ACME 账户和服务状态，确认是本脚本原有的 ECC 证书。不要依据旧聊天记录代替当前检查。

1. 在服务器私有目录备份，禁止把包含账户密钥的备份提交 Git：

   ```bash
   umask 077
   backup="/root/sing-box-yg-backup-$(date +%Y%m%d-%H%M%S)"
   mkdir -p "$backup"
   crontab -l > "$backup/crontab.txt"  # 读取失败时停止迁移并检查原因
   tar -czf "$backup/state.tgz" -C / root/.acme.sh root/ygkkkca etc/s-box usr/bin/sb
   if [ -f /usr/local/lib/sing-box-yg/maintenance.sh ]; then
       cp /usr/local/lib/sing-box-yg/maintenance.sh "$backup/maintenance.sh"
   fi
   systemctl is-active sing-box > "$backup/service-before.txt" || true  # OpenRC 使用 rc-service sing-box status
   openssl x509 -in /root/ygkkkca/cert.crt -noout -dates -sha256 -fingerprint
   ```

2. 本地核对新脚本后部署，并移除明确属于该 ACME home 的旧自动任务；不会批量删除含 `--cron` 或 `sing-box` 的其他任务：

   ```bash
   bash -n sb.sh && bash -n scripts/acme.sh && bash -n scripts/maintenance.sh
   install -d -m 700 /usr/local/lib/sing-box-yg
   install -m 700 scripts/maintenance.sh /usr/local/lib/sing-box-yg/maintenance.sh
   bash /usr/local/lib/sing-box-yg/maintenance.sh remove-cron renew
   ```

   任务过滤支持旧版两个已知每日重启命令、旧版零点静默续期命令，以及官方客户端默认生成的、明确指向本 ACME home 的命令。自定义 shell 包装、`--config-home` 或其他时间安排不自动删除；检查 `crontab -l` 后单独确认其归属。

3. 绑定明确的现有证书（下面域名必须先经当前服务器核对）。这不申请新证书，但可能按需重启服务，安排短暂连接中断窗口：

   ```bash
   bash /usr/local/lib/sing-box-yg/maintenance.sh bind blog.fadeaway.ltd
   bash /usr/local/lib/sing-box-yg/maintenance.sh install-cron renew
   bash /usr/local/lib/sing-box-yg/maintenance.sh install-cron restart
   install -m 755 sb.sh /usr/bin/sb
   ```

   每一步非零立即停止，不继续覆盖配置。`bind` 可重复执行，证书相同且无待处理状态时不重复重启。在线证书菜单从本仓库 `main` 获取 `scripts/acme.sh`；主脚本与维护入口应使用同一发布版本。如果绑定失败且此前已移除旧续期任务，须恢复备份的 crontab，避免遗留无续期任务的状态。

4. 检查两条项目标记任务各仅一条、其他任务仍在；执行一次 `renew`（仅到期时会向原 CA 发起续期），核对退出状态和日志。检查服务状态、原监听端口与对外 TLS 证书 SHA-256 是否匹配磁盘证书；不要以“文件存在”或“进程运行”替代 TLS 握手验收。后续实际自动续期完成后，再核对日志和新指纹。

## 日志、故障处理与回退

- `/var/log/sing-box-yg/maintenance.log`：UTC 时间、操作及退出码、明确证书标识、到期时间、部署结果。超过 1 MiB 在下次写入时轮转，保留 5 份历史。
- 不保存 ACME 原始输出，避免 DNS 凭据泄漏。只归类记录端口占用、网络/DNS、授权/验证或限流线索；需要更详细证据时在受控终端排查，不能将包含密钥的调试内容上传。
- 普通证书剩余不足 14 天报警；总有效期不超过 10 天的短期证书剩余不足 24 小时报警。失败或临期输出标准错误，由已有 cron 邮件链路处理；本功能不安装或保证邮件投递服务。
- 维护命令使用同一目录锁。若进程被 SIGKILL 或机器断电遗留锁，先核对 `.maintenance/lock/pid` 与实际进程，确认没有维护任务运行后再移走锁；不盲目删除锁文件。
- 临时失败先修复根因并执行 `renew`，它会重试已暂存但尚未加载的证书，不要求强制申请。HTTP 验证仍要求公网 80 可达；新日志不能证明历史过期原因。
- 完整回退：停止本项目维护操作、移除两个带项目标记的任务；从私有迁移备份恢复原 `/root/.acme.sh`（含安装路径和 reload hook）、证书、`/etc/s-box` 和 `/usr/bin/sb`，恢复原 crontab。如迁移前已有维护入口则恢复其备份；否则移除本次新增入口和状态。先保存失败现场，避免覆盖未备份的诊断信息。
- 恢复后先执行原内核的 `check -c /etc/s-box/sb.json`；仅在迁移前服务运行时重启并验证 TLS 指纹，迁移前已停止则保持停止。回退会重新带回原 cron 缺陷，应在维护记录中标注。
