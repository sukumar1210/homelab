#!/usr/bin/env bash
# test_homelab.sh: the lifecycle commands (install, reinstall, uninstall, update) against stand-ins, so nothing on this
# machine changes: a throwaway HOME, sudo and systemctl replaced by loggers, and a copy of this checkout that sits one
# commit behind a throwaway upstream. Run it from anywhere: ./test_homelab.sh
set -uo pipefail
SRC="$(cd "$(dirname "$(realpath "$0")")" && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
FAILS=0
check() { if eval "$2"; then echo "ok    $1"; else echo "FAIL  $1"; FAILS=$((FAILS + 1)); fi; }

# sudo logs and runs nothing; systemctl answers `cat <unit>` from $T/units and logs everything else
mkdir -p "$T/bin" "$T/units" "$T/home/.claude"
printf '#!/bin/sh\necho "$*" >> %s/sudo.log\n[ "$1" = tee ] && cat >/dev/null\nexit 0\n' "$T" > "$T/bin/sudo"
printf '#!/bin/sh\necho "$*" >> %s/systemctl.log\ncase "$*" in *cat*) for u; do :; done; [ -e "%s/units/$u" ] ;; esac\n' \
    "$T" "$T" > "$T/bin/systemctl"
chmod +x "$T/bin/sudo" "$T/bin/systemctl"
touch "$T/units/power-logger.service" "$T/units/mdns-unicast-bridge.service"   # nextboot and backup: not installed

git_() { git -c user.name=test -c user.email=test@test "$@"; }
cp -r "$SRC/." "$T/up" && rm -rf "$T/up/.git"
git_ -C "$T/up" init -q -b main && git_ -C "$T/up" add -A && git_ -C "$T/up" commit -qm base
git clone -q "$T/up" "$T/repo"
git_ -C "$T/up" commit -q --allow-empty -m next

hl() { HOME="$T/home" PATH="$T/bin:$PATH" XDG_STATE_HOME="" "$T/repo/homelab" "$@" > "$T/out" 2>&1; }
LATER="$T/home/.local/bin/later" SETTINGS="$T/home/.claude/settings.json"

hl later reinstall;  check "reinstall is install"                     '[ -x "$LATER" ]'
hl later uninstall;  check "uninstall is remove"                      '[ ! -e "$LATER" ]'
hl statusline install
hl bogus update;     check "an unknown component is refused before any pull" \
    '[ "$(git -C "$T/repo" rev-parse HEAD)" != "$(git -C "$T/up" rev-parse HEAD)" ]'

hl update;           rc=$?
check "update exits 0"                                                '[ "$rc" -eq 0 ]'
check "update fast-forwards the checkout"                             '[ "$(git -C "$T/repo" rev-parse HEAD)" = "$(git -C "$T/up" rev-parse HEAD)" ]'
check "update restarts the installed services"                        'grep -qx "systemctl restart power-logger" "$T/sudo.log" && grep -qx "systemctl restart mdns-unicast-bridge" "$T/sudo.log"'
check "update reinstalls the installed copies"                        'grep -q "^== statusline" "$T/out" && [ -x "$T/home/.claude/statusline.sh" ]'
check "update skips what is not installed"                            'grep -q "nextboot: not installed, skipped" "$T/out" && grep -q "later: not installed, skipped" "$T/out" && grep -q "backup: not installed, skipped" "$T/out"'
check "update leaves the checkout clean"                              '[ -z "$(git -C "$T/repo" status --porcelain)" ]'

hl mdns-bridge uninstall
check "uninstalling mdns-bridge keeps the repository's script"        '[ -f "$T/repo/bin/service-scripts/mdns-unicast-bridge.py" ] && [ -z "$(git -C "$T/repo" status --porcelain)" ]'

hl statusline uninstall
check "uninstalling statusline drops its setting"                     '[ "$(jq -r ".statusLine // empty" "$SETTINGS")" = "" ]'
echo '{"statusLine":{"type":"command","command":"/elsewhere.sh"}}' > "$SETTINGS"
hl statusline uninstall
check "and leaves a statusLine that is not ours"                      '[ "$(jq -r .statusLine.command "$SETTINGS")" = /elsewhere.sh ]'

git_ -C "$T/repo" commit -q --allow-empty -m local && git_ -C "$T/up" commit -q --allow-empty -m upstream
hl update;           rc=$?
check "update refuses a checkout that has diverged"                   '[ "$rc" -ne 0 ] && grep -q "could not fast-forward" "$T/out"'

[ "$FAILS" -eq 0 ] && echo "all passed" || { echo "$FAILS failed"; exit 1; }
