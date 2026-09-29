#!/bin/bash
# Real certificate-selection and installer entry; no installation or network.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
body=$(awk '$0 == "inscertificate(){" {p=1} $0 == "insport(){" {p=0} p {print}' "$ROOT/sb.sh")
body=${body//\/etc\/s-box/$WORK\/s-box}
body=${body//\/root\/ygkkkca/$WORK\/cert}
eval "$body"
# Stop the real installer fragment at the first subsequent step. The rest of
# installation must never execute in this test, even when testing regressions.
entry=$(awk '$0 == "instsllsingbox(){" {p=1} p {print} p && $0 == "insport" {print "}"; exit}' "$ROOT/sb.sh")
entry=${entry//\/etc\//$WORK\/etc\/}
eval "$entry"
red(){ :; }; green(){ :; }; blue(){ :; }; yellow(){ :; }; sleep(){ :; }
readp(){ menu=$CHOICE; }
openssl(){ mkdir -p "$WORK/s-box"; touch "$WORK/s-box/cert.pem"; }
bash(){ return 1; }; curl(){ return 0; }
v6(){ :; }; openyn(){ :; }; inssb(){ :; }
insport(){ echo continued > "$WORK/continued"; }
CHOICE=2
unset tlsyn certificatec_hy2
if instsllsingbox > /dev/null; then echo 'FAIL: certificate failure did not stop installation' >&2; exit 1; fi
[[ ! -f $WORK/continued ]] || { echo 'FAIL: installer continued after certificate failure' >&2; exit 1; }
CHOICE=1
instsllsingbox > /dev/null
[[ -f $WORK/continued && $tlsyn == false && $certificatec_hy2 == "$WORK/s-box/cert.pem" ]]
echo 'PASS: certificate failure stops installer; successful self-signed selection continues with initialized TLS'
