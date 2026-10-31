#!/usr/bin/env bash
# test_hyprgraphics.sh — off-device test of the patched hyprgraphics package
# (pkg/hyprgraphics, built by tools/build-pkg; see docs/image/PACKAGES.md). Builds
# it first if out/repo/armv7h does not hold it, then, in an armv7h Arch Linux
# ARM container with the repository mounted read-only at /repo
# ([t715-omarchy] before [core], SigLevel = Optional TrustAll), checks that:
#   - pacman -Si hyprgraphics resolves to the pkg/hyprgraphics version
#     (0.5.1-4.1) from t715-omarchy;
#   - pacman -Sp hyprland takes that hyprgraphics from t715-omarchy;
#   - the deadlock reproducer tests/hyprgraphics-repro/repro.cpp, built
#     against the installed package (pkg-config, /usr/lib, no
#     LD_LIBRARY_PATH), completes 20000 enqueue()+await() rounds without a
#     hang, unpinned and pinned to one CPU (taskset -c 0);
#   - negative control: with ALARM's stock hyprgraphics installed instead,
#     the same binary, pinned, hangs (up to 3 attempts), which shows that the
#     harness detects the bug. --no-control skips it.
# Every harness run is bounded by timeout(1): 300 s, while the harness itself
# reports a hang (exit 2) after 12 s without a returning await().
#
# Usage:
#   test_hyprgraphics.sh [--no-control] [-h|--help]
#
# Exit status: 0 = PASS, 1 = FAIL (a check failed), 2 = setup error.
# Never touches the tablet; nothing is written outside this repository
# (the container is disposable).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/alarm.sh
. "$SCRIPT_DIR/../lib/alarm.sh"

CONTROL=1
while [ $# -gt 0 ]; do
    case "$1" in
        --no-control) CONTROL=0; shift ;;
        -h|--help)    sed -n '2,25p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *)            alarm_die "unknown option: $1 (see --help)" ;;
    esac
done

REPO_OUT="$ALARM_REPO_DIR/out/repo/armv7h"
HARNESS="$SCRIPT_DIR/hyprgraphics-repro"
[ -f "$HARNESS/repro.cpp" ] || alarm_die "no $HARNESS/repro.cpp"
EXPECT_VER="$(pkgbuild_version "$ALARM_REPO_DIR/pkg/hyprgraphics")"
EXPECT_FILE="hyprgraphics-$EXPECT_VER-armv7h.pkg.tar.zst"

if [ ! -f "$REPO_OUT/$EXPECT_FILE" ] || [ ! -e "$REPO_OUT/t715-omarchy.db" ]; then
    alarm_log "no $EXPECT_FILE in $REPO_OUT yet: running tools/build-pkg hyprgraphics (slow)"
    "$SCRIPT_DIR/../tools/build-pkg" hyprgraphics >&2 || exit 2
fi

alarm_setup armv7h
alarm_ensure_dev_image

IFS= read -r -d '' TEST_SCRIPT <<'EOS' || true
set -u
finish() { exit "${1:-2}"; }
H=/tmp/hg
mkdir -p "$H"
unset LD_LIBRARY_PATH

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
if ! pacman -Sy --noconfirm >"$H/sy.log" 2>&1; then
    tail -n 20 "$H/sy.log" | sed 's/^/   /'
    echo "SETUP ERROR: pacman -Sy failed"; finish 2
fi

rc=0

echo "== pacman -Si hyprgraphics"
pacman -Si hyprgraphics >"$H/si.log" 2>&1
si_repo="$(sed -n 's/^Repository *: *//p' "$H/si.log" | head -n1)"
si_ver="$(sed -n 's/^Version *: *//p' "$H/si.log" | head -n1)"
grep -E '^(Repository|Name|Version|Architecture|Packager)' "$H/si.log" | head -n5 | sed 's/^/   /'
if [ "$si_repo" = t715-omarchy ] && [ "$si_ver" = "$EXPECT_VER" ]; then
    echo "PASS: hyprgraphics resolves to $EXPECT_VER from t715-omarchy"
else
    echo "FAIL: hyprgraphics resolves to '$si_ver' from '$si_repo', expected $EXPECT_VER from t715-omarchy"
    rc=1
fi

echo "== pacman -Sp --noconfirm hyprland"
if pacman -Sp --noconfirm hyprland >"$H/sp.log" 2>&1; then
    grep -E '/hyprgraphics-[^/]*\.pkg\.tar\.[a-z]+$' "$H/sp.log" | sed 's/^/   /'
    if grep -qx "file:///repo/$EXPECT_FILE" "$H/sp.log"; then
        echo "PASS: hyprland pulls $EXPECT_FILE from t715-omarchy ($(grep -c . "$H/sp.log") packages in all)"
    else
        echo "FAIL: hyprland does not pull file:///repo/$EXPECT_FILE"
        rc=1
    fi
else
    tail -n 20 "$H/sp.log" | sed 's/^/   /'
    echo "FAIL: pacman could not resolve hyprland"
    rc=1
fi

echo "== install hyprgraphics (t715-omarchy) and build the harness against it"
if ! pacman -Syu --noconfirm --needed --noprogressbar hyprgraphics pkgconf >"$H/install.log" 2>&1; then
    tail -n 20 "$H/install.log" | sed 's/^/   /'
    echo "SETUP ERROR: cannot install hyprgraphics"; finish 2
fi
echo "   installed: $(pacman -Q hyprgraphics)"
if [ "$(pacman -Q hyprgraphics)" != "hyprgraphics $EXPECT_VER" ]; then
    echo "FAIL: installed hyprgraphics is not $EXPECT_VER"
    finish 1
fi
if pacman -Qkk hyprgraphics >"$H/qkk.log" 2>&1; then
    echo "   files: $(tail -n1 "$H/qkk.log")"
else
    tail -n 5 "$H/qkk.log" | sed 's/^/   /'
    echo "FAIL: installed files differ from the package (pacman -Qkk)"
    rc=1
fi
if ! flags="$(pkg-config --cflags --libs hyprgraphics hyprutils pangocairo 2>"$H/pc.log")"; then
    cat "$H/pc.log" | sed 's/^/   /'
    echo "SETUP ERROR: pkg-config cannot find hyprgraphics/hyprutils/pangocairo"; finish 2
fi
# shellcheck disable=SC2086
if ! timeout 1200 g++ -std=c++23 -O2 -march=armv7-a -mfloat-abi=hard -mfpu=neon \
        -o "$H/repro" /harness/repro.cpp $flags -pthread >"$H/gxx.log" 2>&1; then
    tail -n 20 "$H/gxx.log" | sed 's/^/   /'
    echo "SETUP ERROR: the harness does not build"; finish 2
fi
so="$(ldd "$H/repro" | awk '/libhyprgraphics\.so/ { print $3; exit }')"
echo "   repro links $so ($(pacman -Qo "$so" 2>&1 | sed 's/^.* is owned by //'))"
case "$so" in
    /usr/lib/libhyprgraphics.so*) ;;
    *) echo "SETUP ERROR: repro does not resolve libhyprgraphics from /usr/lib"; finish 2 ;;
esac

RUN_RC=0
run_repro() { # CMD...: one bounded harness run; output indented, RUN_RC set
    echo "   \$ timeout 300 $*"
    (cd "$H" && timeout 300 "$@") >"$H/run.log" 2>&1
    RUN_RC=$?
    sed 's/^/     /' "$H/run.log"
    echo "     exit $RUN_RC"
}
expect_ok() { # LABEL
    if [ "$RUN_RC" -eq 0 ] && grep -q '^OK: ' "$H/run.log"; then
        echo "PASS: $1: no hang"
    else
        echo "FAIL: $1: exit $RUN_RC (2 = HANG reported, 124 = timeout)"
        rc=1
    fi
}

echo "== reproducer, patched hyprgraphics $EXPECT_VER"
run_repro ./repro 20000 0 12
expect_ok "unpinned"
run_repro taskset -c 0 ./repro 20000 0 12
expect_ok "pinned to CPU 0"

if [ "$CONTROL" = 1 ]; then
    stock_repo="$(pacman -Sl | awk '$2 == "hyprgraphics" && $1 != "t715-omarchy" { print $1; exit }')"
    echo "== negative control: ALARM's stock hyprgraphics ($stock_repo), same binary, pinned"
    if [ -z "$stock_repo" ] \
       || ! pacman -S --noconfirm --noprogressbar "$stock_repo/hyprgraphics" >"$H/stock.log" 2>&1; then
        tail -n 20 "$H/stock.log" 2>/dev/null | sed 's/^/   /'
        echo "SETUP ERROR: cannot install the stock hyprgraphics"; finish 2
    fi
    echo "   installed: $(pacman -Q hyprgraphics) from $stock_repo"
    echo "   repro links $(ldd "$H/repro" | awk '/libhyprgraphics\.so/ { print $3; exit }')"
    hung=0
    for attempt in 1 2 3; do
        run_repro taskset -c 0 ./repro 20000 0 12
        if [ "$RUN_RC" -eq 2 ] && grep -q '^HANG: ' "$H/run.log"; then
            hung="$attempt"; break
        elif [ "$RUN_RC" -eq 124 ]; then
            echo "     (timed out after 300 s: counted as a hang)"
            hung="$attempt"; break
        fi
    done
    if [ "$hung" != 0 ]; then
        echo "PASS: the stock library hangs (attempt $hung of 3): the harness detects the bug"
    else
        echo "FAIL: the stock library did not hang in 3 pinned runs: this test cannot tell a fixed library from a broken one"
        rc=1
    fi
else
    echo "== negative control skipped (--no-control)"
fi

finish "$rc"
EOS

alarm_log "running the hyprgraphics checks in $ALARM_DEV_IMAGE (armv7h under qemu: slow)"
set +e
docker run --rm --platform "$ALARM_PLATFORM" \
    -v "$REPO_OUT:/repo:ro" \
    -v "$HARNESS:/harness:ro" \
    -e EXPECT_VER="$EXPECT_VER" \
    -e EXPECT_FILE="$EXPECT_FILE" \
    -e CONTROL="$CONTROL" \
    "$ALARM_DEV_IMAGE" bash -c "$TEST_SCRIPT" test_hyprgraphics </dev/null
rc=$?
set -e

case "$rc" in
    0) printf 'RESULT: PASS\n' ;;
    1) printf 'RESULT: FAIL\n' ;;
    *) printf 'RESULT: ERROR (%s)\n' "$rc"; rc=2 ;;
esac
exit "$rc"
