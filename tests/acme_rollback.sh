#!/bin/bash
# Real official client, offline fixtures only: no issuance, installation or cron.
set -euo pipefail
: "${SBYG_TEST_ACME:?Set SBYG_TEST_ACME to the official acme.sh 3.1.2 source file}"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
export MSYS2_ARG_CONV_EXCL='/CN='
export SBYG_PATH="$PATH" SBYG_BASH="$(command -v bash)"
export SBYG_STATE="$WORK/state" SBYG_CERT_DIR="$WORK/live" SBYG_LOG_DIR="$WORK/log"
export SBYG_RUNTIME="$WORK/maintenance.sh" SBYG_ACME="$WORK/client"
export SBYG_CONFIG="$WORK/no-service.json" TEST_ACCOUNT="$WORK/account"
if command -v cygpath >/dev/null; then SBYG_TEST_ACME=$(cygpath -u "$SBYG_TEST_ACME"); fi
export SBYG_TEST_ACME
echo "c46b41a61c96f67d424e4b4e476907c964b81d53cf94358a9c1d363a4f99c3a4  $SBYG_TEST_ACME" | sha256sum -c - >/dev/null
domain="$TEST_ACCOUNT/test.example_ecc"
mkdir -p "$domain" "$SBYG_CERT_DIR"
cp "$ROOT/scripts/maintenance.sh" "$SBYG_RUNTIME"
source "$SBYG_RUNTIME"
STAGE=$(sbyg_stage test.example)
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 90 \
    -subj '/CN=test.example' -addext 'subjectAltName=DNS:test.example' \
    -keyout "$domain/test.example.key" -out "$domain/fullchain.cer" >/dev/null 2>&1
printf "Le_Domain='test.example'\nLe_Keylength='ec-256'\nLe_Webroot='dns_cf'\n" > "$domain/test.example.conf"
cat > "$SBYG_ACME" <<'SH'
#!/bin/bash
# Allow only these offline commands, even if a regression changes the caller.
case "$1" in
    --info|--install-cert) ;;
    --cron)
        # Simulate only scheduling; replay the real client's offline installation.
        for id in ${TEST_RENEW_ORDER:-}; do replay_install "$id" || exit 1; done
        exit 0;;
    *) exit 90;;
esac
exec bash "$SBYG_TEST_ACME" --home "$TEST_ACCOUNT" --config-home "$TEST_ACCOUNT" --cert-home "$TEST_ACCOUNT" "$@"
SH
bash "$SBYG_ACME" --install-cert -d test.example --ecc --key-file "$SBYG_CERT_DIR/private.key" \
    --fullchain-file "$SBYG_CERT_DIR/cert.crt" --reloadcmd true > "$WORK/bootstrap.log" 2>&1
cp "$domain/test.example.conf" "$WORK/original.conf"
cp "$SBYG_CERT_DIR/cert.crt" "$WORK/original.crt"
expect_rejected() {
    if bash "$SBYG_RUNTIME" bind "$@" > "$WORK/out" 2> "$WORK/err"; then
        echo 'FAIL: accepted invalid binding' >&2; exit 1
    fi
}
expect_rejected test.example missing.example
cmp "$domain/test.example.conf" "$WORK/original.conf"
cmp "$SBYG_CERT_DIR/cert.crt" "$WORK/original.crt"
[[ ! -e $SBYG_STATE/identities && ! -e $STAGE/cert.crt && ! -e $STAGE/private.key ]]
echo 'PASS: first rejected bind restores all official installation targets/hook and original live certificate'

bash "$SBYG_RUNTIME" bind test.example
grep -F "Le_RealFullChainPath='$STAGE/cert.crt'" "$domain/test.example.conf" >/dev/null
[[ $(cat "$SBYG_STATE/identities") == test.example ]]
cp "$domain/test.example.conf" "$WORK/managed.conf"
cp "$STAGE/cert.crt" "$WORK/stage.crt"
cp "$STAGE/private.key" "$WORK/stage.key"
echo 'PASS: successful binding commits persistent staged deployment configuration'

expect_rejected test.example missing.example
cmp "$domain/test.example.conf" "$WORK/managed.conf"
cmp "$STAGE/cert.crt" "$WORK/stage.crt"
cmp "$STAGE/private.key" "$WORK/stage.key"
[[ $(cat "$SBYG_STATE/identities") == test.example ]]
echo 'PASS: rejected rebind preserves existing managed configuration, identity and stage'

# Official installcert writes domain settings before it discovers a missing PEM.
mv "$domain/fullchain.cer" "$domain/fullchain.saved"
expect_rejected test.example
cmp "$domain/test.example.conf" "$WORK/managed.conf"
cmp "$STAGE/cert.crt" "$WORK/stage.crt"
cmp "$STAGE/private.key" "$WORK/stage.key"
echo 'PASS: official partial installation failure rolls back config and partially written stage'
mv "$domain/fullchain.saved" "$domain/fullchain.cer"

# Replay the renewal installation phase with the official client, using each
# record's persisted targets/hook. Never invoke issuance or a network renewal.
make_record() {
    local id=$1 dir="$TEST_ACCOUNT/${1}_ecc"
    mkdir -p "$dir"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 90 \
        -subj "/CN=$id" -addext "subjectAltName=DNS:$id" \
        -keyout "$dir/$id.key" -out "$dir/fullchain.cer" >/dev/null 2>&1
    [[ -f $dir/$id.conf ]] || printf "Le_Domain='%s'\nLe_Keylength='ec-256'\n" "$id" > "$dir/$id.conf"
}
replay_install() (
    local id=$1 hook
    # These configs contain only this test's generated fixtures.
    source "$TEST_ACCOUNT/${id}_ecc/$id.conf"
    hook=$(printf '%s' "$Le_ReloadCmd" | sed 's/^__ACME_BASE64__START_//;s/__ACME_BASE64__END_$//' | openssl base64 -d -A)
    bash "$SBYG_ACME" --install-cert -d "$id" --ecc \
        --key-file "$Le_RealKeyPath" --fullchain-file "$Le_RealFullChainPath" \
        --reloadcmd "$hook" > "$WORK/replay.out" 2>&1
)
export -f replay_install
export WORK
make_record z.old.example
bash "$SBYG_RUNTIME" bind z.old.example
make_record a.new.example
bash "$SBYG_RUNTIME" bind a.new.example
old_stage=$(sbyg_stage z.old.example)
new_stage=$(sbyg_stage a.new.example)
[[ $old_stage != "$new_stage" ]]
for order in 'a.new.example z.old.example' 'z.old.example a.new.example'; do
    make_record a.new.example
    make_record z.old.example
    TEST_RENEW_ORDER="$order" bash "$SBYG_RUNTIME" renew
    cmp "$TEST_ACCOUNT/a.new.example_ecc/fullchain.cer" "$SBYG_CERT_DIR/cert.crt"
    cmp "$TEST_ACCOUNT/a.new.example_ecc/fullchain.cer" "$new_stage/cert.crt"
    cmp "$TEST_ACCOUNT/z.old.example_ecc/fullchain.cer" "$old_stage/cert.crt"
    echo "PASS: deferred installation order $order deploys the current certificate"
done
cp "$SBYG_CERT_DIR/cert.crt" "$WORK/current.crt"
cp "$SBYG_LOG_DIR/maintenance.log" "$WORK/before-old.log"
make_record z.old.example
replay_install z.old.example
cmp "$WORK/current.crt" "$SBYG_CERT_DIR/cert.crt"
cmp "$WORK/before-old.log" "$SBYG_LOG_DIR/maintenance.log"
bash "$SBYG_RUNTIME" deploy
cmp "$WORK/before-old.log" "$SBYG_LOG_DIR/maintenance.log"
TEST_RENEW_ORDER='' bash "$SBYG_RUNTIME" renew
cmp "$WORK/current.crt" "$SBYG_CERT_DIR/cert.crt"
echo 'PASS: old-only renewal hook and unchanged deployment leave current certificate untouched'

# Old shared-stage records can remain in the account after upgrading/rebinding.
cp "$TEST_ACCOUNT/z.old.example_ecc/fullchain.cer" "$SBYG_STATE/stage/cert.crt"
cp "$TEST_ACCOUNT/z.old.example_ecc/z.old.example.key" "$SBYG_STATE/stage/private.key"
bash "$SBYG_RUNTIME" deploy
cmp "$WORK/current.crt" "$SBYG_CERT_DIR/cert.crt"
echo 'PASS: legacy shared stage cannot overwrite the rebound current certificate'
