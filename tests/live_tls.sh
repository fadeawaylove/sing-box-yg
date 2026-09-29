#!/bin/bash
# Real sing-box, local TLS, disposable service adapters. No ACME/network issuance.
set -euo pipefail
[[ $(uname -s) == Linux ]] || { echo 'SKIP: real TLS integration requires Linux' >&2; exit 77; }
: "${SBYG_TEST_BINARY:?Set SBYG_TEST_BINARY to an existing sing-box executable}"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
cleanup() {
    if [[ -f $WORK/pid ]]; then kill "$(cat "$WORK/pid")" 2>/dev/null || true; fi
    rm -rf -- "$WORK"
}
trap cleanup EXIT
export TEST_ROOT="$WORK" SBYG_PATH="$WORK/bin:$PATH"
export SBYG_RUNTIME="$WORK/maintenance.sh" SBYG_CERT_DIR="$WORK/cert" SBYG_STATE="$WORK/state"
export SBYG_LOG_DIR="$WORK/log" SBYG_ACME="$WORK/acme" SBYG_CONFIG="$WORK/sb.json"
export SBYG_BINARY="$SBYG_TEST_BINARY" SBYG_RUN_DIR="$WORK/run"
mkdir -p "$WORK/bin" "$SBYG_CERT_DIR" "$SBYG_STATE" "$SBYG_RUN_DIR/systemd/system"
cp "$ROOT/scripts/maintenance.sh" "$SBYG_RUNTIME"
source "$SBYG_RUNTIME"
STAGE=$(sbyg_stage test.example)
mkdir -p "$STAGE"
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
export TEST_PORT=$PORT
jq -n --arg cert "$SBYG_CERT_DIR/cert.crt" --arg key "$SBYG_CERT_DIR/private.key" --argjson port "$PORT" \
    '{log:{level:"error"},inbounds:[{type:"trojan",listen:"127.0.0.1",listen_port:$port,users:[{password:"local-fixture-only"}],tls:{enabled:true,certificate_path:$cert,key_path:$key}}],outbounds:[{type:"direct"}]}' > "$SBYG_CONFIG"
cat > "$WORK/bin/systemctl" <<'SH'
#!/bin/bash
if [[ $1 == is-active ]]; then
    [[ -f $TEST_ROOT/pid ]] && kill -0 "$(cat "$TEST_ROOT/pid")" 2>/dev/null; exit
fi
[[ $1 == restart ]] || exit 90
if [[ -f $TEST_ROOT/pid ]]; then
    kill "$(cat "$TEST_ROOT/pid")" || exit 1
    sleep 0.3
fi
"$SBYG_BINARY" run -c "$SBYG_CONFIG" >> "$TEST_ROOT/kernel.log" 2>&1 &
echo $! > "$TEST_ROOT/pid"
echo restart >> "$TEST_ROOT/restarts"
sleep 0.3
kill -0 "$(cat "$TEST_ROOT/pid")"
SH
cat > "$WORK/bin/rc-service" <<'SH'
#!/bin/bash
[[ $1 == sing-box ]] || exit 90
case "$2" in
status) exec systemctl is-active --quiet sing-box;;
restart) exec systemctl restart sing-box;;
*) exit 90;;
esac
SH
printf '#!/bin/bash\nexit 0\n' > "$WORK/acme"
chmod +x "$WORK/bin/"* "$WORK/acme"
make_cert() {
    openssl req -x509 -newkey rsa:2048 -nodes -days 90 -subj '/CN=test.example' \
        -addext 'subjectAltName=DNS:test.example' -keyout "$1/private.key" -out "$1/cert.crt" >/dev/null 2>&1
}
fingerprint_live() {
    timeout 5 openssl s_client -connect "127.0.0.1:$PORT" -servername test.example </dev/null 2>/dev/null |
        openssl x509 -noout -sha256 -fingerprint
}
make_cert "$SBYG_CERT_DIR"
printf 'test.example\n' > "$SBYG_STATE/identities"
systemctl restart sing-box
before=$(fingerprint_live)
for manager in systemd openrc; do
    if [[ $manager == openrc ]]; then rm -rf "$SBYG_RUN_DIR/systemd"; mkdir "$SBYG_RUN_DIR/openrc"; fi
    make_cert "$STAGE"
    expected=$(sbyg_fingerprint "$STAGE/cert.crt")
    [[ $expected != "$before" ]]
    bash "$SBYG_RUNTIME" deploy
    actual=$(fingerprint_live)
    [[ $actual == "$expected" ]] || { echo "$manager: TLS certificate mismatch" >&2; exit 1; }
    count=$(wc -l < "$WORK/restarts")
    bash "$SBYG_RUNTIME" renew
    [[ $(wc -l < "$WORK/restarts") == "$count" ]]
    echo "PASS: $manager adapter with real sing-box: new TLS fingerprint; unchanged renewal does not restart"
    before=$actual
done
