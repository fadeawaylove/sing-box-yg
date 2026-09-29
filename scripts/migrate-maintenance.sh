#!/bin/bash
# Conservative migration: never write live PEM/config files or restart a service.
# The downloaded runtime/menu are pinned to the Linux-tested release.
sbyg_migrate() (
    set -o pipefail
    umask 077
    local source_root=$1 backup= dirty=0 locked=0 active=0 rc i candidate id conf stage fingerprint hook
    local paths=() ids=() matches=() sans=()
    source "$source_root/scripts/maintenance.sh" || exit 1
    local menu=${SBYG_SB_SCRIPT:-/usr/bin/sb}
    local backup_root=${SBYG_BACKUP_ROOT:-/root}
    local account=${SBYG_ACCOUNT_HOME:-$(dirname "$SBYG_ACME")}
    local config_dir=${SBYG_CONFIG%/*}
    for candidate in openssl jq date crontab tar cp mv chmod mktemp pgrep cmp; do
        command -v "$candidate" >/dev/null || { sbyg_error "缺少依赖 $candidate，未迁移"; exit 1; }
    done
    [[ -f $SBYG_CONFIG && -x $SBYG_BINARY && -f $SBYG_ACME && -f $menu ]] || {
        sbyg_error '未找到完整的现有服务和 ACME 安装，未迁移'; exit 1;
    }
    [[ ! -e $SBYG_STATE/pending && ! -e $SBYG_STATE/restart-failed ]] || {
        sbyg_error '存在未完成的证书加载，请先处理原维护错误'; exit 1;
    }
    "$SBYG_BASH" -n "$source_root/sb.sh" && "$SBYG_BASH" -n "$source_root/scripts/maintenance.sh" || exit 1
    "$SBYG_BINARY" check -c "$SBYG_CONFIG" >/dev/null 2>&1 || {
        sbyg_error '现有 sing-box 配置检查失败，未迁移'; exit 1;
    }
    sbyg_service || exit 1
    if sbyg_active; then active=1; fi
    fingerprint=$(sbyg_fingerprint "$SBYG_CERT_DIR/cert.crt") || exit 1
    # Identify by certificate fingerprint, never by ca.log or the last list row.
    for candidate in "$account"/*_ecc/fullchain.cer; do
        [[ -f $candidate ]] || continue
        [[ $(sbyg_fingerprint "$candidate") == "$fingerprint" ]] || continue
        matches+=("${candidate%/fullchain.cer}")
    done
    [[ ${#matches[@]} == 1 ]] || {
        sbyg_error '无法唯一匹配当前证书的 ECC 账户记录，未迁移'; exit 1;
    }
    id=${matches[0]##*/}; id=${id%_ecc}
    sbyg_identity "$id" || exit 1
    mapfile -t sans < <(openssl x509 -in "$SBYG_CERT_DIR/cert.crt" -noout -ext subjectAltName |
        tr ',' '\n' | sed -n -e 's/^[[:space:]]*DNS://p' -e 's/^[[:space:]]*IP Address://p')
    ((${#sans[@]})) || { sbyg_error '证书没有可识别的 SAN，未迁移'; exit 1; }
    ids=("$id")
    for candidate in "${sans[@]}"; do [[ $candidate == "$id" ]] || ids+=("$candidate"); done
    sbyg_validate "$SBYG_CERT_DIR/cert.crt" "$SBYG_CERT_DIR/private.key" "${ids[@]}" &&
        sbyg_validate "${matches[0]}/fullchain.cer" "${matches[0]}/$id.key" "${ids[@]}" || {
        sbyg_error '现有证书已过期、身份不符或密钥不匹配，未迁移'; exit 1;
    }
    conf=$("$SBYG_BASH" "$SBYG_ACME" --info -d "$id" --ecc 2>/dev/null |
        sed -n 's/^DOMAIN_CONF=//p' | tr -d '\r') || exit 1
    [[ $conf == "${matches[0]}/$id.conf" && -f $conf ]] || {
        sbyg_error '账户使用非标准配置路径，未自动迁移'; exit 1;
    }
    stage=$(sbyg_stage "$id") || exit 1
    paths=("$conf" "$SBYG_RUNTIME" "$menu" "$SBYG_STATE/identities"
        "$SBYG_CERT_DIR/ca.log" "$stage/cert.crt" "$stage/private.key")
    for candidate in "${paths[@]}"; do
        [[ ! -L $candidate && ( ! -e $candidate || -f $candidate ) ]] || {
            sbyg_error '待更新路径是符号链接或特殊文件，未迁移'; exit 1;
        }
    done
    sbyg_init || exit 1
    mkdir "$SBYG_STATE/lock" 2>/dev/null || { sbyg_error '维护正在执行或存在遗留锁，未迁移'; exit 1; }
    locked=1
    migration_finish() {
        rc=$?
        trap - EXIT INT TERM
        if (( dirty )); then
            local restored=1 temp
            for i in "${!paths[@]}"; do
                if [[ -f $backup/files/$i ]]; then
                    temp=$(mktemp "${paths[i]}.restore.XXXXXX") &&
                        cp -p "$backup/files/$i" "$temp" && mv -f "$temp" "${paths[i]}" || restored=0
                else
                    rm -f -- "${paths[i]}" || restored=0
                fi
            done
            crontab "$backup/crontab.txt" || restored=0
            if (( restored )); then
                echo "迁移失败，已恢复原脚本、证书安装配置和定时任务。备份：$backup" >&2
            else
                echo "迁移失败，自动恢复未完全成功。保留备份：$backup；请勿重新安装服务。" >&2
            fi
            rc=1
        fi
        (( ! locked )) || rm -rf -- "$SBYG_STATE/lock"
        exit "$rc"
    }
    trap migration_finish EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    printf '%s\n' "$BASHPID" > "$SBYG_STATE/lock/pid" || exit 1
    backup=$(mktemp -d "$backup_root/sing-box-yg-backup.XXXXXX") || exit 1
    echo "备份目录：$backup"
    mkdir "$backup/files" || exit 1
    # Existing installations have cron jobs. A read error is never treated as empty.
    crontab -l > "$backup/crontab.txt" || { sbyg_error '无法备份 crontab，未迁移'; exit 1; }
    tar -czf "$backup/state.tgz" -C / "${account#/}" "${SBYG_CERT_DIR#/}" \
        "${config_dir#/}" "${menu#/}" || exit 1
    for i in "${!paths[@]}"; do
        [[ ! -f ${paths[i]} ]] || cp -p "${paths[i]}" "$backup/files/$i" || exit 1
        printf '%s\n' "${paths[i]}" >> "$backup/paths.txt" || exit 1
    done
    cp -p "$SBYG_CONFIG" "$backup/live-config" &&
        cp -p "$SBYG_CERT_DIR/cert.crt" "$backup/live-cert" &&
        cp -p "$SBYG_CERT_DIR/private.key" "$backup/live-key" || exit 1
    dirty=1
    sbyg_cron renew remove || exit 1
    rc=0
    pgrep -f "$SBYG_ACME" >/dev/null || rc=$?
    (( rc == 1 )) || { sbyg_error 'ACME 正在运行或无法检查进程，停止迁移'; exit 1; }
    mkdir -p "$stage" || exit 1
    sbyg_install_runtime || exit 1
    printf -v hook '%q' "$id"
    sbyg_acme_call install --install-cert -d "$id" --ecc \
        --key-file "$stage/private.key" --fullchain-file "$stage/cert.crt" \
        --reloadcmd "$SBYG_BASH $SBYG_RUNTIME deploy $hook" || exit 1
    sbyg_validate "$stage/cert.crt" "$stage/private.key" "${ids[@]}" || exit 1
    [[ $(sbyg_fingerprint "$stage/cert.crt") == "$fingerprint" ]] || {
        sbyg_error '操作期间候选证书发生变化，停止迁移'; exit 1;
    }
    printf '%s\n' "${ids[@]}" > "$SBYG_STATE/identities" &&
        printf '%s\n' "$id" > "$SBYG_CERT_DIR/ca.log" || exit 1
    # Replace the management script atomically; never run its installer/menu.
    candidate=$(mktemp "${menu}.XXXXXX") || exit 1
    if ! { cp "$source_root/sb.sh" "$candidate" && chmod 755 "$candidate" && mv -f "$candidate" "$menu"; }; then
        rm -f -- "$candidate"; exit 1
    fi
    sbyg_cron restart install && sbyg_cron renew install || exit 1
    cmp -s "$backup/live-config" "$SBYG_CONFIG" &&
        cmp -s "$backup/live-cert" "$SBYG_CERT_DIR/cert.crt" &&
        cmp -s "$backup/live-key" "$SBYG_CERT_DIR/private.key" || {
        sbyg_error '检测到现有配置或证书被其他进程修改，请检查；未覆盖该变化'; exit 1;
    }
    if sbyg_active; then rc=1; else rc=0; fi
    [[ $rc == "$active" ]] || { sbyg_error '服务状态发生变化，请检查；未自动启动或重启'; exit 1; }
    dirty=0
    echo "迁移完成：证书 $id；未重启服务，原配置和证书未变。"
    echo "已设置每日 00:00 续期检查和 01:00 重启；备份保留在 $backup"
)

sbyg_migration_main() (
    [[ $EUID == 0 ]] || { echo '请使用 root 执行' >&2; exit 1; }
    local work revision=d179a120db25737ccf304c98cc5825b5231cbb61
    work=$(mktemp -d) || exit 1
    trap 'rm -rf -- "$work"' EXIT
    mkdir "$work/scripts" || exit 1
    curl -fsSL --retry 2 "https://raw.githubusercontent.com/fadeawaylove/sing-box-yg/$revision/scripts/maintenance.sh" \
        -o "$work/scripts/maintenance.sh" &&
    curl -fsSL --retry 2 "https://raw.githubusercontent.com/fadeawaylove/sing-box-yg/$revision/sb.sh" \
        -o "$work/sb.sh" || exit 1
    sbyg_migrate "$work"
)
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then sbyg_migration_main "$@"; exit $?; fi
