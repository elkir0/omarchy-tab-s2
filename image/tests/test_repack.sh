#!/usr/bin/env bash
# test_repack.sh — install-side test of the repacked Omarchy repository
# (tools/repack-omarchy). Builds out/repo/armv7h first if needed, then checks,
# in an armv7h Arch Linux ARM container with the repository mounted read-only
# at /repo, that pacman:
#   - sees the [t715-omarchy] repository (declared before [core] in
#     pacman.conf with SigLevel = Optional TrustAll) and reports omarchy as
#     armv7h;
#   - resolves the whole omarchy dependency tree against t715-omarchy plus
#     the official ALARM armv7h repositories (pacman -Sp omarchy, exit 0);
#   - gets from the repacked omarchy package an .MTREE that lists exactly the
#     same file paths as the upstream aarch64 package's.
#
# Usage:
#   test_repack.sh [-h|--help]
#
# Exit status: 0 = PASS, 1 = FAIL (a check failed), 2 = setup error.
# Never touches the tablet; nothing is written outside this repository
# (the container's pacman state is disposable).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/alarm.sh
. "$SCRIPT_DIR/../lib/alarm.sh"

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) sed -n '2,19p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *)         alarm_die "unknown option: $1 (see --help)" ;;
    esac
done

REPO_OUT="$ALARM_REPO_DIR/out/repo/armv7h"
if [ ! -e "$REPO_OUT/t715-omarchy.db" ]; then
    alarm_log "no $REPO_OUT/t715-omarchy.db yet: running tools/repack-omarchy"
    "$SCRIPT_DIR/../tools/repack-omarchy" >&2 || exit 2
fi

# The repacked package name tells us which upstream file to compare against:
# omarchy-4.0.6-1.1-armv7h.pkg.tar.zst  <->  omarchy-4.0.6-1-aarch64.pkg.tar.zst
repacked=""
for f in "$REPO_OUT"/omarchy-[0-9]*-armv7h.pkg.tar.zst; do
    [ -e "$f" ] || continue
    [ -z "$repacked" ] || alarm_die "several repacked omarchy packages in $REPO_OUT"
    repacked="${f##*/}"
done
[ -n "$repacked" ] || alarm_die "no repacked omarchy package in $REPO_OUT"
pv="${repacked#omarchy-}"; pv="${pv%-armv7h.pkg.tar.zst}"
upstream_pv="${pv%.1}"
UPSTREAM_DIR="$ALARM_CACHE_DIR/omarchy-upstream/stable/aarch64"
UPSTREAM_PKG="omarchy-$upstream_pv-aarch64.pkg.tar.zst"
[ -f "$UPSTREAM_DIR/$UPSTREAM_PKG" ] \
    || alarm_die "upstream $UPSTREAM_PKG not found in $UPSTREAM_DIR (run tools/repack-omarchy --force)"
alarm_log "comparing $repacked with upstream $UPSTREAM_PKG"

alarm_setup armv7h
alarm_ensure_dev_image

alarm_log "running pacman checks in $ALARM_DEV_IMAGE (armv7h under qemu: slow)"
set +e
docker run --rm -i --platform "$ALARM_PLATFORM" \
    -v "$REPO_OUT:/repo:ro" \
    -v "$UPSTREAM_DIR:/upstream:ro" \
    -e REPACKED_PKG="$repacked" \
    -e UPSTREAM_PKG="$UPSTREAM_PKG" \
    "$ALARM_DEV_IMAGE" bash -s <<'EOS'
set -u
finish() { exit "${1:-2}"; }

# [t715-omarchy] before the first official repository ([core]).
awk -v stanza='[t715-omarchy]
SigLevel = Optional TrustAll
Server = file:///repo' '
    !done && /^\[core\]$/ { print stanza; print ""; done = 1 }
    { print }
' /etc/pacman.conf > /etc/pacman.conf.t715
if ! grep -q '^\[t715-omarchy\]' /etc/pacman.conf.t715; then
    echo "SETUP ERROR: could not insert the [t715-omarchy] stanza"; finish 2
fi
cat /etc/pacman.conf.t715 > /etc/pacman.conf
repo_line="$(grep -n '^\[t715-omarchy\]$' /etc/pacman.conf | cut -d: -f1)"
core_line="$(grep -n '^\[core\]$' /etc/pacman.conf | head -n1 | cut -d: -f1)"
if [ "${repo_line:-999999}" -ge "${core_line:-0}" ]; then
    echo "SETUP ERROR: [t715-omarchy] is not before [core]"; finish 2
fi

echo "== pacman -Sy (file:///repo + official ALARM armv7h)"
if ! pacman -Sy --noconfirm >/tmp/pacman-sy.log 2>&1; then
    tail -n 20 /tmp/pacman-sy.log | sed 's/^/   /'
    echo "SETUP ERROR: pacman -Sy failed"; finish 2
fi
grep -m1 't715-omarchy' /tmp/pacman-sy.log | sed 's/^/   /'

rc=0

echo "== pacman -Si t715-omarchy/omarchy"
pacman -Si t715-omarchy/omarchy >/tmp/si.log 2>&1
if [ $? -eq 0 ] && grep -q '^Architecture *: *armv7h *$' /tmp/si.log; then
    grep -E '^(Name|Version|Architecture|Repository)' /tmp/si.log | sed 's/^/   /'
    echo "PASS: repository reports omarchy as armv7h"
else
    cat /tmp/si.log | sed 's/^/   /'
    echo "FAIL: pacman -Si t715-omarchy/omarchy does not report Architecture armv7h"
    rc=1
fi

echo "== pacman -Sp --noconfirm omarchy (dependency resolution)"
if pacman -Sp --noconfirm omarchy >/tmp/sp.log 2>&1; then
    n="$(grep -c . /tmp/sp.log)"
    echo "PASS: dependency tree resolves: $n package(s) to install"
    echo "   from t715-omarchy: $(grep -c '^file:///repo/' /tmp/sp.log)"
    sed 's|.*/||; s/^/     /' /tmp/sp.log | head -n 8
    [ "$n" -gt 8 ] && echo "     ..."
else
    tail -n 20 /tmp/sp.log | sed 's/^/   /'
    echo "FAIL: pacman could not resolve the omarchy dependency tree"
    rc=1
fi

echo "== .MTREE file paths: repacked vs upstream"
bsdtar -xOf "/repo/$REPACKED_PKG" .MTREE | gzip -dc \
    | awk '$1 ~ /^\.\// { print $1 }' | sort > /tmp/paths.repacked
bsdtar -xOf "/upstream/$UPSTREAM_PKG" .MTREE | gzip -dc \
    | awk '$1 ~ /^\.\// { print $1 }' | sort > /tmp/paths.upstream
if cmp -s /tmp/paths.repacked /tmp/paths.upstream; then
    echo "PASS: identical file path sets ($(wc -l < /tmp/paths.upstream) paths)"
else
    diff /tmp/paths.upstream /tmp/paths.repacked | head -n 10 | sed 's/^/   /'
    echo "FAIL: the repacked .MTREE does not list the same paths as upstream"
    rc=1
fi

finish "$rc"
EOS
rc=$?
set -e

case "$rc" in
    0) printf 'RESULT: PASS\n' ;;
    1) printf 'RESULT: FAIL\n' ;;
    *) printf 'RESULT: ERROR (%s)\n' "$rc"; rc=2 ;;
esac
exit "$rc"
