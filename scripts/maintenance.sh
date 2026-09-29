#!/bin/bash
# GPL-3.0; non-interactive maintenance for sing-box-yg. Safe to source.
SBYG_RUNTIME=${SBYG_RUNTIME:-/usr/local/lib/sing-box-yg/maintenance.sh}
SBYG_CERT_DIR=${SBYG_CERT_DIR:-/root/ygkkkca}
SBYG_STATE=${SBYG_STATE:-/root/ygkkkca/.maintenance}
SBYG_ACME=${SBYG_ACME:-/root/.acme.sh/acme.sh}
SBYG_CONFIG=${SBYG_CONFIG:-/etc/s-box/sb.json}
SBYG_BINARY=${SBYG_BINARY:-/etc/s-box/sing-box}
SBYG_RUN_DIR=${SBYG_RUN_DIR:-/run}
SBYG_LOG_DIR=${SBYG_LOG_DIR:-/var/log/sing-box-yg}
SBYG_BASH=${SBYG_BASH:-/bin/bash}
export PATH=${SBYG_PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}

sbyg_error() { printf 'sing-box-yg: %s\n' "$*" >&2; return 1; }
sbyg_init() {
    umask 077
    mkdir -p "$SBYG_STATE" "$SBYG_LOG_DIR" || return 1
    chmod 700 "$SBYG_STATE" "$SBYG_LOG_DIR" || return 1
}
sbyg_log() {
    local log="$SBYG_LOG_DIR/maintenance.log" n
    if [[ -f $log ]] && [[ $(wc -c < "$log") -gt 1048576 ]]; then
        for n in 4 3 2 1; do
            [[ ! -f $log.$n ]] || mv -f "$log.$n" "$log.$((n+1))" || return 1
        done
        mv -f "$log" "$log.1" || return 1
    fi
    printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$log"
}
sbyg_service() {
    if [[ -d $SBYG_RUN_DIR/systemd/system ]] && command -v systemctl >/dev/null; then
        SBYG_MANAGER=systemd; SBYG_SERVICE=$(command -v systemctl)
    elif [[ -d $SBYG_RUN_DIR/openrc ]] && command -v rc-service >/dev/null; then
        SBYG_MANAGER=openrc; SBYG_SERVICE=$(command -v rc-service)
    else
        sbyg_error '无法识别正在运行的 systemd/OpenRC'; return 1
    fi
}
sbyg_active() {
    if [[ $SBYG_MANAGER == systemd ]]; then "$SBYG_SERVICE" is-active --quiet sing-box
    else "$SBYG_SERVICE" sing-box status >/dev/null 2>&1; fi
}
sbyg_restart() {
    sbyg_service || return 1
    if [[ $SBYG_MANAGER == systemd ]]; then "$SBYG_SERVICE" restart sing-box
    else "$SBYG_SERVICE" sing-box restart; fi || return 1
    sbyg_active
}

# Replace only our markers and exact historical schedules, never arbitrary --cron jobs.
sbyg_cron() (
    local kind=$1 action=$2 tmp rc cmd marker user
    umask 077
    tmp=$(mktemp -d) || exit 1
    trap 'rm -rf -- "$tmp"' EXIT
    LC_ALL=C crontab -l > "$tmp/old" 2> "$tmp/error"; rc=$?
    if (( rc != 0 )); then
        user=$(id -un) || exit 1
        # BusyBox uses bb_cat(username), unlike Vixie/Cronie. Only ENOENT for
        # this user with no partial stdout is an empty table, never EACCES.
        if ! { (( rc == 1 )) && [[ ! -s $tmp/old ]] && {
            grep -Fxq "no crontab for $user" "$tmp/error" ||
            grep -Fxq "crontab: can't open '$user': No such file or directory" "$tmp/error"
        }; }; then
            sbyg_error '读取 crontab 失败，未修改任务'; exit 1
        fi
    fi
    marker="# sing-box-yg:$kind"
    if [[ $kind == restart ]]; then
        [[ $action != install ]] || sbyg_service || exit 1
        cmd="0 1 * * * $SBYG_BASH $SBYG_RUNTIME restart $marker"
    elif [[ $kind == renew ]]; then
        cmd="0 0 * * * $SBYG_BASH $SBYG_RUNTIME renew $marker"
    elif [[ $kind == auxiliary && $action == remove ]]; then
        cmd=
    else exit 1; fi
    awk -v kind="$kind" -v marker="$marker" -v client="$SBYG_ACME" -v home="$(dirname "$SBYG_ACME")" '
      $0 ~ (" " marker "$") {next}
      kind == "restart" && ($0 == "0 1 * * * systemctl restart sing-box;rc-service sing-box restart" || $0 == "0 1 * * * /usr/bin/systemctl restart sing-box") {next}
      kind == "renew" && $0 == "0 0 * * * bash ~/.acme.sh/acme.sh --cron >/dev/null 2>&1" {next}
      kind == "auxiliary" && $0 == "@reboot sleep 10 && /bin/bash -c \"busybox httpd -f -p $(cat /etc/s-box/subport.log 2>/dev/null) -h /root/websbox > /dev/null 2>&1 &\"" {next}
      kind == "auxiliary" && $0 == "@reboot sleep 10 && /bin/bash -c \"nohup $(cat /etc/s-box/sbwpph.log 2>/dev/null) &\"" {next}
      kind == "auxiliary" && index($0, "@reboot sleep 10 && /bin/bash -c \"nohup /etc/s-box/cloudflared tunnel --url http://localhost:") == 1 && index($0, " > /etc/s-box/argo.log 2>&1 &") > 0 {next}
      # Official client default: only remove its exact command for this ACME home.
      kind == "renew" && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 == "*" && $4 == "*" && $5 == "*" {
        command=$0; sub(/^[^ ]+ +[^ ]+ +\* +\* +\* +/, "", command)
        expected="\"" client "\" --cron --home \"" home "\" > /dev/null"
        if (command == expected || command == expected " 2>&1") next
        expected="\"" home "\"/acme.sh --cron --home \"" home "\" > /dev/null"
        if (command == expected || command == expected " 2>&1") next
      }
      {print}
    ' "$tmp/old" > "$tmp/new" || exit 1
    [[ $action != install ]] || printf '%s\n' "$cmd" >> "$tmp/new"
    crontab "$tmp/new" || { sbyg_error '写入 crontab 失败'; exit 1; }
)
sbyg_install_runtime() {
    local source=${BASH_SOURCE[0]} tmp
    [[ $SBYG_RUNTIME == /* && $SBYG_RUNTIME != *[[:space:]]* ]] || return 1
    mkdir -p "$(dirname "$SBYG_RUNTIME")" || return 1
    [[ $source != "$SBYG_RUNTIME" ]] || return 0
    tmp=$(mktemp "${SBYG_RUNTIME}.XXXXXX") || return 1
    if cp "$source" "$tmp" && "$SBYG_BASH" -n "$tmp" && chmod 700 "$tmp" && mv -f "$tmp" "$SBYG_RUNTIME"; then return 0; fi
    rm -f "$tmp"; return 1
}
sbyg_identity() {
    [[ -n $1 && $1 != -* && $1 != *[!a-zA-Z0-9.*:_-]* ]]
}
sbyg_stage() {
    local digest
    sbyg_identity "$1" || return 1
    digest=$(printf '%s' "$1" | openssl dgst -sha256) || return 1
    digest=${digest##* }
    [[ $digest =~ ^[a-fA-F0-9]{64}$ ]] || return 1
    printf '%s/stage/%s\n' "$SBYG_STATE" "$digest"
}
sbyg_validate() {
    local cert=$1 key=$2 identity pubcert pubkey start now match
    shift 2
    (($#)) || return 1
    openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1 || return 1
    start=$(openssl x509 -in "$cert" -noout -startdate) || return 1
    start=$(date -u -d "${start#notBefore=}" +%s) || return 1
    now=$(date -u +%s); (( start <= now )) || return 1
    pubcert=$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null) || return 1
    pubkey=$(openssl pkey -in "$key" -pubout 2>/dev/null) || return 1
    [[ -n $pubkey && $pubcert == "$pubkey" ]] || return 1
    for identity in "$@"; do
        sbyg_identity "$identity" || return 1
        if [[ $identity == *:* || $identity =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            # Older OpenSSL releases return zero even for an identity mismatch.
            match=$(LC_ALL=C openssl x509 -in "$cert" -noout -checkip "$identity" 2>/dev/null) || return 1
            [[ $match == "IP $identity does match certificate" ]] || return 1
        elif [[ $identity == '*.'* ]]; then
            # A concrete host match alone would incorrectly accept a single-host certificate.
            openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null | tr ',' '\n' | sed 's/^[[:space:]]*//' | grep -Fxi "DNS:$identity" >/dev/null || return 1
        else
            match=$(LC_ALL=C openssl x509 -in "$cert" -noout -checkhost "$identity" 2>/dev/null) || return 1
            [[ $match == "Hostname $identity does match certificate" ]] || return 1
        fi
    done
}
sbyg_fingerprint() { openssl x509 -in "$1" -noout -sha256 -fingerprint 2>/dev/null; }
sbyg_ids() {
    [[ -s $SBYG_STATE/identities ]] || { sbyg_error '缺少托管证书标识，请先执行 bind'; return 1; }
    mapfile -t SBYG_IDS < "$SBYG_STATE/identities"
    local id
    for id in "${SBYG_IDS[@]}"; do sbyg_identity "$id" || return 1; done
}
sbyg_expiry() {
    local cert=$SBYG_CERT_DIR/cert.crt begin end threshold=1209600
    begin=$(openssl x509 -in "$cert" -noout -startdate); end=$(openssl x509 -in "$cert" -noout -enddate)
    begin=$(date -u -d "${begin#notBefore=}" +%s) || return 1
    end=$(date -u -d "${end#notAfter=}" +%s) || return 1
    (( end - begin > 864000 )) || threshold=86400
    sbyg_log "certificate=${SBYG_IDS[0]} expires_epoch=$end" || return 1
    if ! openssl x509 -in "$cert" -noout -checkend "$threshold" >/dev/null; then
        sbyg_error "证书 ${SBYG_IDS[0]} 已进入临期窗口，请检查续期日志"; return 1
    fi
}
sbyg_uses_cert() {
    [[ -f $SBYG_CONFIG ]] || return 1
    jq -e --arg cert "$SBYG_CERT_DIR/cert.crt" --arg key "$SBYG_CERT_DIR/private.key" \
        '[.. | objects | select(.certificate_path? == $cert and .key_path? == $key)] | length > 0' "$SBYG_CONFIG" >/dev/null
}
sbyg_copy_pair() (
    local source=$1 target=$2 tmp
    umask 077
    tmp=$(mktemp -d "$target/.certificate.XXXXXX") || exit 1
    trap 'rm -rf -- "$tmp"' EXIT
    cp "$source/cert.crt" "$tmp/cert.crt" && cp "$source/private.key" "$tmp/private.key" &&
        chmod 600 "$tmp/cert.crt" "$tmp/private.key" || exit 1
    # Rename complete files on the same filesystem; never truncate a live PEM.
    mv -f "$tmp/private.key" "$target/private.key" && mv -f "$tmp/cert.crt" "$target/cert.crt"
)
sbyg_restore() {
    [[ -s $SBYG_STATE/backup/cert.crt && -s $SBYG_STATE/backup/private.key ]] || return 1
    sbyg_copy_pair "$SBYG_STATE/backup" "$SBYG_CERT_DIR"
}
sbyg_deploy() {
    sbyg_ids || return 1
    # Retained ACME records may still renew; only the selected record may deploy.
    [[ $# == 0 || $1 == "${SBYG_IDS[0]}" ]] || return 0
    local stage old new active=0
    stage=$(sbyg_stage "${SBYG_IDS[0]}") || return 1
    sbyg_validate "$stage/cert.crt" "$stage/private.key" "${SBYG_IDS[@]}" || { sbyg_error '暂存证书校验失败，保留现有证书'; return 1; }
    new=$(sbyg_fingerprint "$stage/cert.crt") || return 1
    old=$(sbyg_fingerprint "$SBYG_CERT_DIR/cert.crt") || old=
    if [[ $new == "$old" && ! -f $SBYG_STATE/pending ]]; then return 0; fi
    if [[ -f $SBYG_CONFIG ]]; then
        command -v jq >/dev/null && jq empty "$SBYG_CONFIG" || return 1
    fi
    if sbyg_uses_cert; then
        sbyg_service || return 1
        if sbyg_active; then active=1; fi
    fi
    mkdir -p "$SBYG_STATE/backup" || return 1
    if [[ $new != "$old" && -s $SBYG_CERT_DIR/cert.crt && -s $SBYG_CERT_DIR/private.key ]]; then
        sbyg_copy_pair "$SBYG_CERT_DIR" "$SBYG_STATE/backup" || return 1
    fi
    touch "$SBYG_STATE/pending" || return 1
    sbyg_copy_pair "$stage" "$SBYG_CERT_DIR" || { sbyg_restore; return 1; }
    if (( active )); then
        if ! "$SBYG_BINARY" check -c "$SBYG_CONFIG" >/dev/null 2>&1; then
            sbyg_restore; sbyg_error '配置校验失败，已尝试恢复旧证书'; return 1
        fi
        if ! sbyg_restart >/dev/null 2>&1; then
            touch "$SBYG_STATE/restart-failed"
            sbyg_restore && sbyg_restart >/dev/null 2>&1
            sbyg_error '证书加载失败，保留待重试状态并尝试恢复旧证书服务'; return 1
        fi
        sbyg_log "certificate=${SBYG_IDS[0]} service=loaded" || return 1
    else
        sbyg_log "certificate=${SBYG_IDS[0]} service=stopped-or-unrelated (not started)" || return 1
        if [[ -f $SBYG_STATE/restart-failed ]]; then
            sbyg_error '上次加载失败且服务仍停止，请先检查服务；未擅自启动'; return 1
        fi
    fi
    rm -f "$SBYG_STATE/pending" "$SBYG_STATE/restart-failed" || return 1
    printf '%s\n' "${SBYG_IDS[0]}" > "$SBYG_CERT_DIR/ca.log" || return 1
    sbyg_log "certificate=${SBYG_IDS[0]} deployment=success fingerprint=$new"
}

# Do not persist raw ACME output: providers can print DNS credentials in errors.
sbyg_acme_call() {
    local operation=$1 rc codes
    shift
    # Record only fixed diagnostic categories, never arbitrary provider output.
    SBYG_DEFER_DEPLOY=1 "$SBYG_BASH" "$SBYG_ACME" "$@" 2>&1 | awk '
      {line=tolower($0)}
      line ~ /address already in use|port.*(occupied|used)/ {seen["port-in-use"]=1}
      line ~ /timed out|timeout|connection refused|could not resolve/ {seen["network-or-dns"]=1}
      line ~ /unauthorized|authorization.*fail|invalid.*(token|key)|invalid response/ {seen["authorization-or-challenge"]=1}
      line ~ /rate.?limit|too many/ {seen["ca-rate-limit"]=1}
      END {for (category in seen) print "acme_diagnostic=" category}
    ' >> "$SBYG_LOG_DIR/maintenance.log"
    codes=("${PIPESTATUS[@]}"); rc=${codes[0]}
    (( codes[1] == 0 )) || return 1
    sbyg_log "acme_operation=$operation exit=$rc" || return 1
    return "$rc"
}
sbyg_bind() (
    (($#)) || return 1
    local id rc snapshot file domain_conf restore_tmp stage hook_id committed=0
    for id in "$@"; do sbyg_identity "$id" || return 1; done
    stage=$(sbyg_stage "$1") || return 1
    printf -v hook_id '%q' "$1"
    # Ask the client for the actual config path (also handles --home wrappers
    # and custom certificate homes). Never eval or log its configuration output.
    domain_conf=$(set -o pipefail; "$SBYG_BASH" "$SBYG_ACME" --info -d "$1" --ecc 2>/dev/null |
        sed -n 's/^DOMAIN_CONF=//p' | tr -d '\r') || {
        sbyg_error '无法确定ACME域名配置，未修改安装目标'; return 1
    }
    [[ $domain_conf == /* && $domain_conf != *$'\n'* && -f $domain_conf ]] || {
        sbyg_error 'ACME域名配置路径无效，未修改安装目标'; return 1
    }
    mkdir -p "$stage" || return 1
    snapshot=$(mktemp -d "$SBYG_STATE/bind.XXXXXX") || return 1
    cp -p "$domain_conf" "$snapshot/domain.conf" || { rm -rf -- "$snapshot"; return 1; }
    for file in cert.crt private.key; do
        if [[ -f $stage/$file ]]; then
            cp -p "$stage/$file" "$snapshot/$file" || { rm -rf -- "$snapshot"; return 1; }
        fi
    done
    trap '
        rc=$?
        if (( ! committed )); then
            # --install-cert persists its targets/hook before copying any PEM.
            # Restore in the config filesystem, preserving all other settings.
            restore_tmp=$(mktemp "${domain_conf}.sbyg.XXXXXX") &&
                cp -p "$snapshot/domain.conf" "$restore_tmp" &&
                mv -f "$restore_tmp" "$domain_conf" || {
                    [[ -z ${restore_tmp:-} ]] || rm -f -- "$restore_tmp"
                    sbyg_error "ACME配置恢复失败，备份保留在 $snapshot"; exit 1
                }
            for file in cert.crt private.key; do
                if [[ -f $snapshot/$file ]]; then
                    cp -p "$snapshot/$file" "$stage/$file"
                else
                    rm -f "$stage/$file"
                fi || { sbyg_error "暂存证书恢复失败，备份保留在 $snapshot"; exit 1; }
            done
        fi
        rm -rf -- "$snapshot"
        exit "$rc"
    ' EXIT
    sbyg_acme_call install --install-cert -d "$1" --ecc \
        --key-file "$stage/private.key" --fullchain-file "$stage/cert.crt" \
        --reloadcmd "$SBYG_BASH $SBYG_RUNTIME deploy $hook_id"; rc=$?
    (( rc == 0 )) || { sbyg_error "安装证书失败 (exit=$rc)，保留现有证书"; return 1; }
    sbyg_validate "$stage/cert.crt" "$stage/private.key" "$@" || {
        sbyg_error '候选证书身份或密钥校验失败，保留原托管状态'; return 1
    }
    printf '%s\n' "$@" > "$snapshot/identities" &&
        mv -f "$snapshot/identities" "$SBYG_STATE/identities" || return 1
    committed=1
    sbyg_deploy || return 1
    printf '%s\n' "$1" > "$SBYG_CERT_DIR/ca.log"
)
sbyg_issue_locked() {
    local args=("$@") ids=() rc
    while (($#)); do
        if [[ $1 == -d ]]; then (($# >= 2)) || return 1; sbyg_identity "$2" || return 1; ids+=("$2"); shift; fi
        shift
    done
    ((${#ids[@]})) || return 1
    sbyg_acme_call issue "${args[@]}"; rc=$?
    # Official acme.sh uses 2 for an issuance skipped because the cert is not due.
    (( rc == 0 || rc == 2 )) || { sbyg_error "申请失败 (exit=$rc)，保留账户和原证书"; return 1; }
    sbyg_bind "${ids[@]}" || return 1
    sbyg_log "issue_result=$([[ $rc == 2 ]] && echo unchanged || echo updated) certificate=${ids[0]}"
}
sbyg_renew() {
    local before after rc failed=0
    sbyg_ids || return 1
    before=$(sbyg_fingerprint "$SBYG_CERT_DIR/cert.crt") || before=
    sbyg_acme_call cron --cron; rc=$?
    if (( rc != 0 )); then sbyg_error "自动续期失败 (exit=$rc)，详见 $SBYG_LOG_DIR/maintenance.log"; failed=1; fi
    # Retry a previous hook failure even if ACME now considers the certificate fresh.
    if ! sbyg_deploy; then failed=1; fi
    sbyg_validate "$SBYG_CERT_DIR/cert.crt" "$SBYG_CERT_DIR/private.key" "${SBYG_IDS[@]}" || { sbyg_error '现有证书无效'; failed=1; }
    sbyg_expiry || failed=1
    after=$(sbyg_fingerprint "$SBYG_CERT_DIR/cert.crt") || after=
    sbyg_log "renew_result=$([[ $failed == 1 ]] && echo failed || { [[ $before == "$after" ]] && echo unchanged || echo updated; }) certificate=${SBYG_IDS[0]}" || return 1
    return "$failed"
}
sbyg_locked() (
    sbyg_init || exit 1
    if ! mkdir "$SBYG_STATE/lock" 2>/dev/null; then sbyg_error '维护任务已在运行（或遗留锁，需核对进程后处理）'; exit 1; fi
    trap 'rm -rf -- "$SBYG_STATE/lock"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    printf '%s\n' "$BASHPID" > "$SBYG_STATE/lock/pid"
    "$@"
)
sbyg_issue() { sbyg_install_runtime && sbyg_locked sbyg_issue_locked "$@"; }
sbyg_main() {
    local action=${1:-}; shift || return 1
    case "$action" in
        restart) sbyg_locked sbyg_restart >/dev/null || { sbyg_error '定时重启失败'; return 1; };;
        renew) sbyg_locked sbyg_renew;;
        deploy)
            if [[ ${SBYG_DEFER_DEPLOY:-0} == 1 ]]; then return 0; fi
            sbyg_locked sbyg_deploy "$@";;
        bind) sbyg_install_runtime && sbyg_locked sbyg_bind "$@";;
        issue) sbyg_issue "$@";;
        install-cron) sbyg_install_runtime && sbyg_locked sbyg_cron "$1" install;;
        remove-cron) sbyg_locked sbyg_cron "$1" remove;;
        *) sbyg_error '用法: maintenance.sh {restart|renew|deploy|bind ID...|issue ARGS...|install-cron restart/renew|remove-cron restart/renew}';;
    esac
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then sbyg_main "$@"; exit $?; fi
