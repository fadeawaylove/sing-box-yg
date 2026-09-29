#!/bin/bash
# Exercise actual menu functions without sourcing their top-level installer.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
extract() { awk -v start="$1(){" '$0 == start {p=1} p{print} p && $0 == "}" {exit}' "$ROOT/scripts/acme.sh"; }
for fn in ACMEstandaloneIP ACMEstandaloneDNS ACMEDNS acme3 ACMEDNScheck ACMEstandaloneDNScheck ACMEstandaloneIPcheck; do eval "$(extract "$fn")"; done
green() { :; }; red() { :; }; yellow() { :; }; sleep() { :; }
v4v6() { v4=127.0.0.1; v6=::1; }
checkacmeca() { :; }
checkip() { domainIP=$ADDRESS; }
checktls() { echo checked >> "$WORK/checked"; }
sbyg_issue() { printf '%s\n' "$*" >> "$WORK/calls"; return "$ISSUE_RESULT"; }
readp() {
    case "$2" in
        ym) ym=$IDENTITY;;
        cd) cd=$PROVIDER;;
        cf_choice) cf_choice=1;;
        *) printf -v "$2" '%s' fixture;;
    esac
}
total=0
for entry in ACMEstandaloneIP ACMEstandaloneDNS ACMEDNS; do
    for variant in 1 2 3; do
        IDENTITY=test.example; ADDRESS=127.0.0.1; PROVIDER=$variant
        [[ $entry != ACMEstandaloneIP ]] || IDENTITY='127.0.0.1 ::1'
        [[ $variant != 2 ]] || ADDRESS=::1
        for ISSUE_RESULT in 0 1; do
            rm -f "$WORK/calls" "$WORK/checked"
            if "$entry" > /dev/null; then result=0; else result=$?; fi
            [[ $result == "$ISSUE_RESULT" ]] || { echo "FAIL $entry result" >&2; exit 1; }
            [[ $(wc -l < "$WORK/calls") == 1 ]] || { echo "FAIL duplicate/missing issuance" >&2; exit 1; }
            if [[ $ISSUE_RESULT == 1 ]]; then
                [[ ! -f $WORK/checked ]] || { echo 'FAIL old certificate treated as success' >&2; exit 1; }
            else [[ -f $WORK/checked ]]; fi
            total=$((total+1))
        done
    done
done
SBYG_ACME="$WORK/existing-client"
echo fixture > "$SBYG_ACME"
acme3 >/dev/null
[[ -s $SBYG_ACME ]]
# WARP cleanup must not overwrite an issuance failure with a successful systemctl result.
curl() { printf 'warp=on\n'; }; systemctl() { return 0; }; pgrep() { return 1; }; kill() { return 0; }
ISSUE_RESULT=1; PROVIDER=1; ADDRESS=127.0.0.1
for entry in ACMEDNScheck ACMEstandaloneDNScheck ACMEstandaloneIPcheck; do
    IDENTITY=test.example
    [[ $entry != ACMEstandaloneIPcheck ]] || IDENTITY=127.0.0.1
    if "$entry" >/dev/null; then echo "FAIL: $entry swallowed error" >&2; exit 1; fi
    total=$((total+1))
done
echo "PASS: $total menu success/failure paths; existing ACME account/client reused"
