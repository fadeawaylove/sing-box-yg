#!/bin/bash
# Isolated regression tests. All files/services/ACME/crontab are test doubles.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
export MSYS2_ARG_CONV_EXCL='/CN='
export TEST_ROOT="$WORK"
export SBYG_PATH="$WORK/bin:$PATH"
export SBYG_RUNTIME="$WORK/runtime/maintenance.sh"
export SBYG_CERT_DIR="$WORK/cert"
export SBYG_STATE="$WORK/state"
export SBYG_LOG_DIR="$WORK/log"
export SBYG_ACME="$WORK/acme"
export SBYG_CONFIG="$WORK/sb.json"
export SBYG_BINARY="$WORK/bin/sing-box"
export SBYG_RUN_DIR="$WORK/run"
export SBYG_BASH=$(command -v bash)
mkdir -p "$WORK/bin" "$SBYG_CERT_DIR" "$SBYG_STATE" "$SBYG_RUN_DIR/systemd/system"
printf 'original domain configuration\n' > "$WORK/domain.conf"
source "$ROOT/scripts/maintenance.sh"
export STAGE=$(sbyg_stage test.example)
mkdir -p "$STAGE"
# The production helpers explicitly handle return codes rather than relying on errexit.
set +e
total=0
ok() { total=$((total+1)); printf 'ok %s - %s\n' "$total" "$1"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect_ok() { local label=$1; shift; "$@" > "$WORK/out" 2> "$WORK/err" || { cat "$WORK/err"; fail "$label"; }; ok "$label"; }
expect_fail() { local label=$1; shift; if "$@" > "$WORK/out" 2> "$WORK/err"; then fail "$label accepted invalid operation"; fi; ok "$label"; }
same() { cmp -s "$1" "$2" || fail "files differ: $1 $2"; }
cat > "$WORK/bin/crontab" <<'SH'
#!/bin/bash
if [[ $1 == -l ]]; then
    [[ ! -f $TEST_ROOT/read-fail ]] || { echo 'permission denied' >&2; exit 1; }
    if [[ ! -f $TEST_ROOT/cron ]]; then
        user=$(id -un)
        if [[ -f $TEST_ROOT/busybox-permission ]]; then
            printf "crontab: can't open '%s': Permission denied\n" "$user" >&2
        elif [[ -f $TEST_ROOT/other-missing ]]; then
            echo "crontab: can't open '/missing/spool': No such file or directory" >&2
        elif [[ -f $TEST_ROOT/busybox-empty ]]; then
            [[ ! -f $TEST_ROOT/partial-read ]] || echo '0 * * * * keep-me'
            printf "crontab: can't open '%s': No such file or directory\n" "$user" >&2
        else
            printf 'no crontab for %s\n' "$user" >&2
        fi
        exit 1
    fi
    cat "$TEST_ROOT/cron"
else
    [[ ! -f $TEST_ROOT/write-fail ]] || exit 1
    cp "$1" "$TEST_ROOT/cron"
fi
SH
cat > "$WORK/bin/systemctl" <<'SH'
#!/bin/bash
if [[ $1 == is-active ]]; then [[ -f $TEST_ROOT/active ]]; exit; fi
[[ $1 == restart ]] || exit 90
echo systemd >> "$TEST_ROOT/restarts"
[[ ! -f $TEST_ROOT/restart-fail ]] || exit 1
touch "$TEST_ROOT/active"
SH
cat > "$WORK/bin/rc-service" <<'SH'
#!/bin/bash
[[ $1 == sing-box ]] || exit 90
if [[ $2 == status ]]; then [[ -f $TEST_ROOT/active ]]; exit; fi
[[ $2 == restart ]] || exit 90
echo openrc >> "$TEST_ROOT/restarts"
[[ ! -f $TEST_ROOT/restart-fail ]] || exit 1
touch "$TEST_ROOT/active"
SH
cat > "$WORK/bin/sing-box" <<'SH'
#!/bin/bash
[[ $1 == check && $2 == -c ]] || exit 90
[[ ! -f $TEST_ROOT/config-fail ]]
SH
cat > "$WORK/acme" <<'SH'
#!/bin/bash
if [[ $1 == --info ]]; then printf 'DOMAIN_CONF=%s/domain.conf\n' "$TEST_ROOT"; exit 0; fi
[[ ! -f $TEST_ROOT/acme-fail ]] || { echo 'DNS token=SUPER_SECRET authorization failed' >&2; exit 1; }
echo "$1" >> "$TEST_ROOT/acme-calls"
if [[ $1 == --issue ]]; then exit "${ISSUE_RC:-0}"; fi
if [[ $1 == --install-cert ]]; then printf 'installation attempted\n' >> "$TEST_ROOT/domain.conf"; fi
if [[ $1 == --install-cert && -f $TEST_ROOT/install-fail ]]; then exit 1; fi
if [[ $1 == --install-cert || -f $TEST_ROOT/update ]]; then
    cert="$STAGE/cert.crt"; key="$STAGE/private.key"
    args=("$@")
    while (($#)); do
        case "$1" in
            --fullchain-file) cert=$2; shift;;
            --key-file) key=$2; shift;;
        esac
        shift
    done
    set -- "${args[@]}"
    cp "$TEST_ROOT/${BIND_SOURCE:-new}.crt" "$cert"
    cp "$TEST_ROOT/${BIND_SOURCE:-new}.key" "$key"
    if [[ $1 == --install-cert ]]; then
        while (($#)); do
            if [[ $1 == --reloadcmd ]]; then shift; bash -c "$1"; exit $?; fi
            shift
        done
        exit 90
    fi
fi
exit 0
SH
chmod +x "$WORK/bin/"* "$WORK/acme"
make_cert() {
    local name=$1 days=$2 identity=${3:-test.example}
    openssl req -new -newkey rsa:2048 -nodes -keyout "$WORK/$name.key" -out "$WORK/$name.csr" -subj "/CN=$identity" >/dev/null 2>&1 || fail 'key generation'
    printf 'subjectAltName=DNS:%s,DNS:*.wild.example,IP:127.0.0.1,IP:::1\n' "$identity" > "$WORK/ext"
    openssl x509 -req -in "$WORK/$name.csr" -signkey "$WORK/$name.key" -out "$WORK/$name.crt" -days "$days" -extfile "$WORK/ext" >/dev/null 2>&1 || fail 'cert generation'
}
make_cert old 90
make_cert new 90
make_cert expired 0
make_cert short 1
make_cert near 12
cp "$WORK/old.crt" "$SBYG_CERT_DIR/cert.crt"
cp "$WORK/old.key" "$SBYG_CERT_DIR/private.key"
printf 'test.example\n' > "$SBYG_STATE/identities"
jq -n --arg cert "$SBYG_CERT_DIR/cert.crt" --arg key "$SBYG_CERT_DIR/private.key" '{inbounds:[{tls:{certificate_path:$cert,key_path:$key}}]}' > "$SBYG_CONFIG"
expect_ok 'valid certificate + DNS, wildcard, IPv4, IPv6 identities' sbyg_validate "$WORK/old.crt" "$WORK/old.key" test.example '*.wild.example' 127.0.0.1 ::1
expect_fail 'wrong identity rejected' sbyg_validate "$WORK/old.crt" "$WORK/old.key" other.example
expect_fail 'expired certificate rejected' sbyg_validate "$WORK/expired.crt" "$WORK/expired.key" test.example
expect_fail 'wrong key rejected' sbyg_validate "$WORK/old.crt" "$WORK/new.key" test.example
expect_fail 'corrupt cert rejected' sbyg_validate "$WORK/ext" "$WORK/old.key" test.example
expect_fail 'missing identity rejected' sbyg_validate "$WORK/old.crt" "$WORK/old.key"
touch "$WORK/busybox-empty"
expect_ok 'BusyBox absent user crontab permits initial task' sbyg_main install-cron renew
[[ $(wc -l < "$WORK/cron") == 1 ]] || fail 'missing initial BusyBox cron'
rm "$WORK/cron"
touch "$WORK/busybox-permission"
expect_fail 'BusyBox permission failure is not an empty table' sbyg_main install-cron renew
[[ ! -f $WORK/cron ]] || fail 'installed cron despite permission failure'
rm "$WORK/busybox-permission"; touch "$WORK/other-missing"
expect_fail 'unrelated missing path is not an empty table' sbyg_main install-cron renew
[[ ! -f $WORK/cron ]] || fail 'installed cron despite missing spool'
rm "$WORK/other-missing"; touch "$WORK/partial-read"
expect_fail 'partial crontab read is not an empty table' sbyg_main install-cron renew
[[ ! -f $WORK/cron ]] || fail 'replaced partially read cron'
rm "$WORK/partial-read" "$WORK/busybox-empty"
expect_ok 'first restart task' sbyg_main install-cron restart
expect_ok 'repeated restart task' sbyg_main install-cron restart
[[ $(wc -l < "$WORK/cron") == 1 ]] || fail 'duplicate cron'
cat >> "$WORK/cron" <<'CRON'
0 1 * * * systemctl restart sing-box;rc-service sing-box restart
0 0 * * * bash ~/.acme.sh/acme.sh --cron >/dev/null 2>&1
5 0 * * * /other/acme.sh --cron
5 1 * * * echo sing-box
CRON
printf '33 4 * * * "%s"/acme.sh --cron --home "%s" > /dev/null\n' "$(dirname "$SBYG_ACME")" "$(dirname "$SBYG_ACME")" >> "$WORK/cron"
expect_ok 'legacy restart migration' sbyg_main install-cron restart
expect_ok 'legacy renewal migration' sbyg_main install-cron renew
[[ $(wc -l < "$WORK/cron") == 4 ]] || fail 'cron migration removed unrelated jobs'
cp "$WORK/cron" "$WORK/saved-cron"
touch "$WORK/write-fail"
expect_fail 'crontab write failure propagated' sbyg_main install-cron restart
same "$WORK/cron" "$WORK/saved-cron"
rm "$WORK/write-fail"; touch "$WORK/read-fail"
expect_fail 'crontab read failure preserves jobs' sbyg_main install-cron renew
same "$WORK/cron" "$WORK/saved-cron"
rm "$WORK/read-fail"
expect_ok 'systemd restart' sbyg_main restart
[[ $(tail -1 "$WORK/restarts") == systemd ]] || fail 'wrong service manager'
rm -rf "$SBYG_RUN_DIR/systemd"; mkdir "$SBYG_RUN_DIR/openrc"
expect_ok 'OpenRC restart' sbyg_main restart
[[ $(tail -1 "$WORK/restarts") == openrc ]] || fail 'wrong OpenRC command'
touch "$WORK/restart-fail"
expect_fail 'OpenRC restart failure' sbyg_main restart
rm "$WORK/restart-fail"; rm -rf "$SBYG_RUN_DIR/openrc"
expect_fail 'unknown service manager refuses cron' sbyg_main install-cron restart
same "$WORK/cron" "$WORK/saved-cron"
mkdir -p "$SBYG_RUN_DIR/systemd/system"
touch "$WORK/restart-fail"
expect_fail 'systemd restart failure' sbyg_main restart
rm "$WORK/restart-fail"
expect_ok 'bind stages cert and loads once' sbyg_main bind test.example
same "$WORK/new.crt" "$SBYG_CERT_DIR/cert.crt"
same "$WORK/old.crt" "$SBYG_STATE/backup/cert.crt"
touch "$WORK/install-fail"
cp "$WORK/domain.conf" "$WORK/expected-domain.conf"
expect_fail 'install failure preserves current cert and identity' sbyg_main bind other.example
same "$WORK/domain.conf" "$WORK/expected-domain.conf"
same "$WORK/new.crt" "$SBYG_CERT_DIR/cert.crt"
[[ $(cat "$SBYG_STATE/identities") == test.example ]] || fail 'failed bind changed identity'
rm "$WORK/install-fail"
make_cert candidate 90
export BIND_SOURCE=candidate
expect_fail 'invalid extra SAN preserves original managed identity and stage' sbyg_main bind test.example missing.example
same "$WORK/domain.conf" "$WORK/expected-domain.conf"
[[ $(cat "$SBYG_STATE/identities") == test.example ]] || fail 'validation failure poisoned identity'
same "$WORK/new.crt" "$STAGE/cert.crt"
same "$WORK/new.key" "$STAGE/private.key"
same "$WORK/new.crt" "$SBYG_CERT_DIR/cert.crt"
[[ $(cat "$SBYG_CERT_DIR/ca.log") == test.example ]] || fail 'validation failure changed active identity'
unset BIND_SOURCE
expect_ok 'renewal still succeeds after rejected bind' sbyg_main renew
count=$(wc -l < "$WORK/restarts")
expect_ok 'not due renewal is quiet and does not restart' sbyg_main renew
[[ ! -s $WORK/out && ! -s $WORK/err ]] || fail 'normal cron emits output'
[[ $(wc -l < "$WORK/restarts") == "$count" ]] || fail 'unnecessary restart'
grep -q 'renew_result=unchanged' "$SBYG_LOG_DIR/maintenance.log" || fail 'missing skip result'
touch "$WORK/acme-fail"
expect_fail 'ACME failure despite valid old cert' sbyg_main renew
same "$WORK/new.crt" "$SBYG_CERT_DIR/cert.crt"
grep -R 'SUPER_SECRET' "$SBYG_LOG_DIR" && fail 'credential leakage'
grep -q 'acme_diagnostic=authorization-or-challenge' "$SBYG_LOG_DIR/maintenance.log" || fail 'missing sanitized diagnostic'
expect_fail 'issue failure does not install or remove existing cert' sbyg_main issue --issue -d test.example
same "$WORK/new.crt" "$SBYG_CERT_DIR/cert.crt"
rm "$WORK/acme-fail"
export ISSUE_RC=2
expect_ok 'official issuance skip status accepted and verified' sbyg_main issue --issue -d test.example
unset ISSUE_RC
mkdir "$SBYG_STATE/lock"
expect_fail 'concurrent operation rejected' sbyg_main renew
rmdir "$SBYG_STATE/lock"
make_cert new 90
touch "$WORK/update" "$WORK/config-fail"
cp "$SBYG_CERT_DIR/cert.crt" "$WORK/before-failure"
expect_fail 'config failure restores old certificate' sbyg_main renew
same "$WORK/before-failure" "$SBYG_CERT_DIR/cert.crt"
[[ $(wc -l < "$WORK/restarts") == "$count" ]] || fail 'restarted invalid config'
rm "$WORK/config-fail" "$WORK/update"
expect_ok 'pending deployment retries when ACME is not due' sbyg_main renew
same "$WORK/new.crt" "$SBYG_CERT_DIR/cert.crt"
make_cert new 90
touch "$WORK/update" "$WORK/restart-fail"
cp "$SBYG_CERT_DIR/cert.crt" "$WORK/before-failure"
expect_fail 'reload failure retains pending and restores backup' sbyg_main renew
same "$WORK/before-failure" "$SBYG_CERT_DIR/cert.crt"
[[ -f $SBYG_STATE/pending ]] || fail 'no retry state'
rm "$WORK/restart-fail" "$WORK/update"
expect_ok 'failed service load can retry' sbyg_main renew
cp "$STAGE/cert.crt" "$WORK/good-stage"
printf 'broken\n' > "$STAGE/cert.crt"
cp "$SBYG_CERT_DIR/cert.crt" "$WORK/before-failure"
expect_fail 'invalid staged certificate leaves live certificate intact' sbyg_main renew
same "$WORK/before-failure" "$SBYG_CERT_DIR/cert.crt"
cp "$WORK/good-stage" "$STAGE/cert.crt"
count=$(wc -l < "$WORK/restarts")
rm "$WORK/active"; make_cert new 90; touch "$WORK/update"
expect_ok 'stopped service is not started' sbyg_main renew
[[ $(wc -l < "$WORK/restarts") == "$count" ]] || fail 'started stopped service'
touch "$WORK/active"; printf '{}\n' > "$SBYG_CONFIG"; make_cert new 90
expect_ok 'unrelated service not restarted' sbyg_main renew
[[ $(wc -l < "$WORK/restarts") == "$count" ]] || fail 'restarted unrelated service'
rm "$WORK/update"
cp "$WORK/near.crt" "$SBYG_CERT_DIR/cert.crt"; cp "$WORK/near.key" "$SBYG_CERT_DIR/private.key"
sbyg_ids
expect_fail 'ordinary certificate 14 day alert' sbyg_expiry
cp "$WORK/short.crt" "$SBYG_CERT_DIR/cert.crt"; cp "$WORK/short.key" "$SBYG_CERT_DIR/private.key"
sleep 1
expect_fail 'short-lived certificate 24 hour alert' sbyg_expiry
head -c 1048577 /dev/zero > "$SBYG_LOG_DIR/maintenance.log"
expect_ok 'bounded log rotation' sbyg_log 'rotation test'
[[ -f $SBYG_LOG_DIR/maintenance.log.1 ]] || fail 'rotation missing'
expect_ok 'remove only managed renew cron' sbyg_main remove-cron renew
grep -q '/other/acme.sh --cron' "$WORK/cron" || fail 'removed foreign ACME job'
cat >> "$WORK/cron" <<'CRON'
@reboot sleep 10 && /bin/bash -c "nohup $(cat /etc/s-box/sbwpph.log 2>/dev/null) &"
@reboot sleep 10 && /bin/bash -c "busybox httpd -f -p $(cat /etc/s-box/subport.log 2>/dev/null) -h /root/websbox > /dev/null 2>&1 &"
@reboot echo unrelated-sbwpph-websbox
CRON
expect_ok 'uninstall auxiliary cleanup preserves unrelated entries' sbyg_main remove-cron auxiliary
grep -q '^@reboot echo unrelated' "$WORK/cron" || fail 'removed unrelated auxiliary task'
grep -q 'cat /etc/s-box/sbwpph.log' "$WORK/cron" && fail 'left auxiliary startup task'
if [[ $(uname -s) == Linux ]]; then
    [[ $(stat -c %a "$SBYG_STATE") == 700 && $(stat -c %a "$SBYG_LOG_DIR/maintenance.log") == 600 ]] || fail 'private permissions'
fi
printf 'PASS: %s regression scenarios\n' "$total"
