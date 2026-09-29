#!/bin/bash
# No root/server access: all paths, services, crontab and ACME are disposable.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
export MSYS2_ARG_CONV_EXCL='/CN='
source "$ROOT/scripts/migrate-maintenance.sh"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 90 \
    -subj '/CN=test.example' -addext 'subjectAltName=DNS:test.example,DNS:alt.example,IP:127.0.0.1' \
    -keyout "$WORK/key" -out "$WORK/cert" >/dev/null 2>&1
export SBYG_BASH=$(command -v bash)
setup() {
    export TEST_ROOT="$WORK/$1"
    export SBYG_PATH="$TEST_ROOT/bin:$PATH"
    export SBYG_RUNTIME="$TEST_ROOT/runtime/maintenance.sh"
    export SBYG_CERT_DIR="$TEST_ROOT/live" SBYG_STATE="$TEST_ROOT/state"
    export SBYG_LOG_DIR="$TEST_ROOT/log" SBYG_CONFIG="$TEST_ROOT/service/sb.json"
    export SBYG_BINARY="$TEST_ROOT/bin/sing-box" SBYG_RUN_DIR="$TEST_ROOT/run"
    export SBYG_ACCOUNT_HOME="$TEST_ROOT/account" SBYG_ACME="$TEST_ROOT/account/acme.sh"
    export SBYG_SB_SCRIPT="$TEST_ROOT/menu" SBYG_BACKUP_ROOT="$TEST_ROOT/backups"
    mkdir -p "$TEST_ROOT/bin" "$SBYG_CERT_DIR" "$TEST_ROOT/service" "$SBYG_RUN_DIR/systemd/system" \
        "$SBYG_ACCOUNT_HOME/test.example_ecc" "$SBYG_BACKUP_ROOT" "$TEST_ROOT/runtime"
    cp "$WORK/cert" "$SBYG_CERT_DIR/cert.crt"
    cp "$WORK/cert" "$TEST_ROOT/expected-cert"
    cp "$WORK/key" "$SBYG_CERT_DIR/private.key"
    cp "$WORK/cert" "$SBYG_ACCOUNT_HOME/test.example_ecc/fullchain.cer"
    cp "$WORK/key" "$SBYG_ACCOUNT_HOME/test.example_ecc/test.example.key"
    echo original-domain > "$SBYG_ACCOUNT_HOME/test.example_ecc/test.example.conf"
    echo old-menu > "$SBYG_SB_SCRIPT"
    echo old-runtime > "$SBYG_RUNTIME"
    echo wrong-old-list-tail.example > "$SBYG_CERT_DIR/ca.log"
    echo '{"inbounds":[]}' > "$SBYG_CONFIG"
    printf '%s\n' '0 0 * * * bash ~/.acme.sh/acme.sh --cron >/dev/null 2>&1' \
        '0 1 * * * systemctl restart sing-box;rc-service sing-box restart' \
        '5 * * * * unrelated-job' > "$TEST_ROOT/cron"
    cp "$TEST_ROOT/cron" "$TEST_ROOT/cron-before"
    touch "$TEST_ROOT/active"
    cat > "$TEST_ROOT/bin/systemctl" <<'SH'
#!/bin/bash
if [[ $1 == is-active ]]; then [[ -f $TEST_ROOT/active ]]; exit; fi
echo unexpected-service-mutation >> "$TEST_ROOT/mutations"
exit 99
SH
    cat > "$TEST_ROOT/bin/sing-box" <<'SH'
#!/bin/bash
[[ $1 == check && ! -f $TEST_ROOT/bad-config ]]
SH
    cat > "$TEST_ROOT/bin/pgrep" <<'SH'
#!/bin/bash
[[ -f $TEST_ROOT/busy ]]
SH
    cat > "$TEST_ROOT/bin/crontab" <<'SH'
#!/bin/bash
if [[ $1 == -l ]]; then
    [[ ! -f $TEST_ROOT/read-fail ]] || exit 1
    cat "$TEST_ROOT/cron"
else
    if [[ -f $TEST_ROOT/write-fail && $(cat "$1") == *'sing-box-yg:restart'* ]]; then
        rm "$TEST_ROOT/write-fail"; exit 1
    fi
    cp "$1" "$TEST_ROOT/cron"
fi
SH
    cat > "$SBYG_ACME" <<'SH'
#!/bin/bash
if [[ $1 == --info ]]; then echo "DOMAIN_CONF=$SBYG_ACCOUNT_HOME/test.example_ecc/test.example.conf"; exit; fi
[[ $1 == --install-cert ]] || { echo unexpected-acme-command >> "$TEST_ROOT/mutations"; exit 99; }
while (($#)); do
    case "$1" in
        --key-file) key=$2; shift;;
        --fullchain-file) cert=$2; shift;;
        --reloadcmd) hook=$2; shift;;
    esac
    shift
done
echo new-install-targets > "$SBYG_ACCOUNT_HOME/test.example_ecc/test.example.conf"
cp "$SBYG_ACCOUNT_HOME/test.example_ecc/fullchain.cer" "$cert"
cp "$SBYG_ACCOUNT_HOME/test.example_ecc/test.example.key" "$key"
[[ ! -f $TEST_ROOT/install-fail ]] || exit 1
bash -c "$hook"
SH
    chmod +x "$TEST_ROOT/bin/"* "$SBYG_ACME"
}
unchanged_live() {
    cmp "$TEST_ROOT/expected-cert" "$SBYG_CERT_DIR/cert.crt"
    cmp "$WORK/key" "$SBYG_CERT_DIR/private.key"
    [[ $(cat "$SBYG_CONFIG") == '{"inbounds":[]}' && ! -f $TEST_ROOT/mutations ]]
}
expect_failure() {
    if sbyg_migrate "$ROOT" > "$WORK/out" 2> "$WORK/err"; then
        echo 'FAIL: migration unexpectedly succeeded' >&2; exit 1
    fi
    unchanged_live
    cmp "$TEST_ROOT/cron-before" "$TEST_ROOT/cron"
    [[ $(cat "$SBYG_SB_SCRIPT") == old-menu && $(cat "$SBYG_RUNTIME") == old-runtime ]]
    [[ $(cat "$SBYG_ACCOUNT_HOME/test.example_ecc/test.example.conf") == original-domain ]]
    [[ $(cat "$SBYG_CERT_DIR/ca.log") == wrong-old-list-tail.example ]]
    [[ ! -e $SBYG_STATE/identities && ! -e $SBYG_STATE/lock ]]
}
setup success
sbyg_migrate "$ROOT"
unchanged_live
[[ -f $TEST_ROOT/active ]]
cmp "$ROOT/sb.sh" "$SBYG_SB_SCRIPT"
grep -Fx alt.example "$SBYG_STATE/identities" >/dev/null
grep -Fx 127.0.0.1 "$SBYG_STATE/identities" >/dev/null
[[ $(head -1 "$SBYG_STATE/identities") == test.example ]]
[[ $(grep -c 'sing-box-yg:' "$TEST_ROOT/cron") == 2 ]]
grep -Fx '5 * * * * unrelated-job' "$TEST_ROOT/cron" >/dev/null
sbyg_migrate "$ROOT"
[[ $(grep -c 'sing-box-yg:' "$TEST_ROOT/cron") == 2 ]]
unchanged_live
echo 'PASS: active service, SAN preservation, misleading ca.log and repeat migration'

setup stopped
rm "$TEST_ROOT/active"
sbyg_migrate "$ROOT"
[[ ! -f $TEST_ROOT/active ]]
unchanged_live
echo 'PASS: stopped service is never started'

for scenario in install-fail write-fail busy bad-config read-fail; do
    setup "$scenario"
    touch "$TEST_ROOT/$scenario"
    expect_failure
    echo "PASS: $scenario leaves original files/tasks/service intact"
done
setup ambiguous
cp -a "$SBYG_ACCOUNT_HOME/test.example_ecc" "$SBYG_ACCOUNT_HOME/other.example_ecc"
expect_failure
echo 'PASS: ambiguous account match refuses migration'
setup mismatched-key
cp "$WORK/cert" "$SBYG_ACCOUNT_HOME/test.example_ecc/test.example.key"
expect_failure
echo 'PASS: invalid account key refuses migration'
setup expired
openssl req -new -key "$WORK/key" -subj '/CN=test.example' \
    -addext 'subjectAltName=DNS:test.example' -out "$TEST_ROOT/request" >/dev/null 2>&1
openssl x509 -req -in "$TEST_ROOT/request" -signkey "$WORK/key" -days 0 -copy_extensions copy \
    -out "$TEST_ROOT/expected-cert" >/dev/null 2>&1
cp "$TEST_ROOT/expected-cert" "$SBYG_CERT_DIR/cert.crt"
cp "$TEST_ROOT/expected-cert" "$SBYG_ACCOUNT_HOME/test.example_ecc/fullchain.cer"
expect_failure
echo 'PASS: expired certificate refuses migration without replacing live PEM'
