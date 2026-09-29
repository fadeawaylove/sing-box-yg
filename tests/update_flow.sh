#!/bin/bash
# Exercise actual updater with downloads and /usr/bin installation redirected.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
export SBYG_RUNTIME="$WORK/runtime.sh" SBYG_PATH="$PATH"
export SBYG_BASH=$(command -v bash)
eval "$(awk '$0 == "lnsb(){" {p=1} p{print} p && $0 == "}" {exit}' "$ROOT/sb.sh")"
curl() {
    [[ ${DOWNLOAD_FAIL:-0} == 0 ]] || return 1
    local arg destination=${@: -1} source=
    for arg in "$@"; do
        case "$arg" in
            */scripts/maintenance.sh) source="$ROOT/scripts/maintenance.sh";;
            */main/sb.sh) source="$ROOT/sb.sh";;
        esac
    done
    [[ -n $source ]] || return 90
    cp "$source" "$destination"
}
install() {
    [[ $1 == -m && $2 == 755 && $4 == /usr/bin/sb ]] || return 90
    [[ ${INSTALL_FAIL:-0} == 0 ]] || return 1
    cp "$3" "$WORK/installed-sb"
}
echo previous > "$WORK/installed-sb"
DOWNLOAD_FAIL=1
if lnsb; then echo 'FAIL: download failure hidden' >&2; exit 1; fi
[[ $(cat "$WORK/installed-sb") == previous ]]
DOWNLOAD_FAIL=0; INSTALL_FAIL=1
if lnsb; then echo 'FAIL: installation failure hidden' >&2; exit 1; fi
[[ $(cat "$WORK/installed-sb") == previous ]]
INSTALL_FAIL=0
lnsb
cmp "$ROOT/sb.sh" "$WORK/installed-sb"
cmp "$ROOT/scripts/maintenance.sh" "$SBYG_RUNTIME"
# Functions must now refer to the installed helper, not the removed download temp.
sbyg_install_runtime
echo 'PASS: updater download failure, install failure, paired update, persistent helper source'
