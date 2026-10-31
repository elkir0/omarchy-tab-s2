#!/usr/bin/env bash
# test_omarchy_headless.sh — start Hyprland (headless backend, llvmpipe) and
# the Omarchy shell (Quickshell), as Arch Linux ARM packages ship them, inside
# an aarch64 (control) or armv7h (the real question: nobody runs Hyprland on
# 32-bit ARM) container, and check that both stay up and answer IPC. Never
# touches the tablet.
#
# Usage:
#   test_omarchy_headless.sh [--arch aarch64|armv7h] [--repo DIR]
#                            [--duration SECS] [--logs DIR] [--rebuild-image]
#                            [--no-shell]
#
#   --arch           container architecture (default aarch64, native and fast).
#                    armv7h runs under qemu: allow minutes for the image build
#                    and use --duration 180 or more.
#   --repo DIR       local armv7h t715-omarchy repository produced by
#                    tools/repack-omarchy (default out/repo/armv7h). armv7h
#                    only: mounted read-only at /repo, Omarchy installed from
#                    it at run time (so the image never embeds a stale copy);
#                    must contain t715-omarchy.db.
#   --duration SECS  how long Hyprland and the shell must stay up (default 30;
#                    180+ recommended on armv7h)
#   --logs DIR       where to keep hyprland.log / shell.log / … (default
#                    cache/test-logs/omarchy-headless-<arch>-<timestamp>)
#   --rebuild-image  rebuild the cached test image (refresh repo packages)
#   --no-shell       Hyprland only: separates compositor failures from shell
#                    failures (masks omarchy-launch-shell)
#
# What the run does: versions → Hyprland started as the user `alarm` with
# setpriv + dbus-run-session (not runuser: PAM's pam_systemd spins forever
# under qemu-arm) → wait for `hyprctl version` → a headless output must exist
# (created at 1536x2048, the tablet's panel, if Hyprland made none) → the
# Omarchy shell runs through omarchy-launch-shell (a systemd-cat shim stands
# in for the missing journald) → both must survive --duration → clients /
# layers / systeminfo / a grim screenshot saved.
#
# Caveat discovered on 2026-10-28 (Docker Desktop, Apple Silicon): Hyprland
# 0.56.2 aborts at startup here with "CBackend::create() failed!" because
# aquamarine 0.15.1 creates its buffer allocator only from a DRM device fd
# and the linuxkit VM exposes no DRM device at all (/sys/class/drm is empty).
# The headless backend itself starts, but reports drmFD() == -1, so
# CBackend::start() fails with "no allocator available". Hyprland's own
# hyprtester gets away with it because its CI runners do expose /dev/dri; on
# a container host with a DRM node this script runs the full pipeline. See
# docs/image/HEADLESS_TEST.md.
#
# Exit status: 0 = PASS (everything stayed up and answered, no crash markers
# in Hyprland's log); 1 = FAIL (first failing step is named); 2 = setup error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/alarm.sh
. "$SCRIPT_DIR/../lib/alarm.sh"

ARCH=aarch64
REPO=""
DURATION=30
LOGS=""
REBUILD_IMAGE=0
NO_SHELL=0
while [ $# -gt 0 ]; do
    case "$1" in
        --arch)          ARCH="${2:?}"; shift 2 ;;
        --repo)          REPO="${2:?}"; shift 2 ;;
        --duration)      DURATION="${2:?}"; shift 2 ;;
        --logs)          LOGS="${2:?}"; shift 2 ;;
        --rebuild-image) REBUILD_IMAGE=1; shift ;;
        --no-shell)      NO_SHELL=1; shift ;;
        -h|--help)       sed -n '2,48p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *)               alarm_die "unknown option: $1 (see --help)" ;;
    esac
done
[[ "$DURATION" =~ ^[0-9]+$ ]] || alarm_die "--duration must be an integer"

alarm_setup "$ARCH"
TEST_IMAGE="t715-omarchy-test:$ARCH"

# armv7h needs the repacked local repository; Omarchy is installed from it at
# run time (never baked into the image, so a cached image cannot go stale).
INSTALL_OMARCHY_AT_RUNTIME=0
REPO_MOUNT=()
if [ "$ARCH" = armv7h ]; then
    INSTALL_OMARCHY_AT_RUNTIME=1
    REPO="${REPO:-$ALARM_REPO_DIR/out/repo/armv7h}"
    [ -d "$REPO" ] || alarm_die "armv7h needs the local t715-omarchy repository: no directory $REPO (built by tools/repack-omarchy)"
    [ -f "$REPO/t715-omarchy.db" ] || alarm_die "no $REPO/t715-omarchy.db: run tools/repack-omarchy first (or pass --repo DIR)"
    REPO="$(cd "$REPO" && pwd)"
    REPO_MOUNT=(-v "$REPO:/repo:ro")
elif [ -n "$REPO" ]; then
    alarm_log "--repo is only used for armv7h; ignoring it"
    REPO=""
fi

if [ -z "$LOGS" ]; then
    LOGS="$ALARM_CACHE_DIR/test-logs/omarchy-headless-$ARCH-$(date +%Y%m%d-%H%M%S)"
fi
mkdir -p "$LOGS"
LOGS="$(cd "$LOGS" && pwd)"

# qemu (armv7h) needs every timeout scaled up.
if [ "$ARCH" = armv7h ]; then
    POLL=5; HYPRCTL_TIMEOUT=600; SHELL_TIMEOUT=600
else
    POLL=2; HYPRCTL_TIMEOUT=120; SHELL_TIMEOUT=120
fi

# Test image: dev image + Hyprland/Quickshell/Omarchy exactly as the
# repositories ship them. aarch64 takes Omarchy from pkgs.omarchy.org
# (keyring first, signatures stay verified); armv7h takes only the ALARM
# packages here and gets Omarchy from /repo at run time.
if [ "$REBUILD_IMAGE" -eq 1 ] || ! docker image inspect "$TEST_IMAGE" >/dev/null 2>&1; then
    alarm_ensure_dev_image
    alarm_log "building $TEST_IMAGE (Hyprland + Quickshell + Omarchy for $ARCH)"
    if [ "$INSTALL_OMARCHY_AT_RUNTIME" -eq 1 ]; then
        docker build --platform "$ALARM_PLATFORM" -t "$TEST_IMAGE" - >&2 <<EOF
FROM $ALARM_DEV_IMAGE
RUN <<'EOS'
set -eu
pacman -Sy --noconfirm
pacman -S --noconfirm --needed hyprland quickshell uwsm foot mesa \
    xdg-desktop-portal-hyprland grim jq qt6-wayland qt6-svg
pacman -Scc --noconfirm >/dev/null 2>&1 || true
EOS
EOF
    else
        docker build --platform "$ALARM_PLATFORM" -t "$TEST_IMAGE" - >&2 <<EOF
FROM $ALARM_DEV_IMAGE
RUN <<'EOS'
set -eu
# Omarchy's repository: keyring package first, then pacman-key --populate;
# package signatures stay verified (no SigLevel weakening).
curl -fL -o /tmp/omarchy-keyring.pkg.tar.zst \
    https://pkgs.omarchy.org/stable/aarch64/omarchy-keyring-20251027-1-any.pkg.tar.zst
pacman -U --noconfirm /tmp/omarchy-keyring.pkg.tar.zst
pacman-key --populate omarchy
sed -i '/^\[core\]/i [omarchy]\nServer = https://pkgs.omarchy.org/stable/\$arch' /etc/pacman.conf
pacman -Sy --noconfirm
pacman -S --noconfirm --needed hyprland quickshell uwsm foot mesa \
    xdg-desktop-portal-hyprland grim jq qt6-wayland qt6-svg omarchy omarchy-settings
pacman -Scc --noconfirm >/dev/null 2>&1 || true
EOS
EOF
    fi
fi

if [ "$NO_SHELL" -eq 1 ]; then
    alarm_log "running Hyprland alone (--no-shell) for ${DURATION}s in $TEST_IMAGE"
else
    alarm_log "running Hyprland + the Omarchy shell for ${DURATION}s in $TEST_IMAGE"
fi
set +e
docker run --rm -i --platform "$ALARM_PLATFORM" \
    ${REPO_MOUNT[@]+"${REPO_MOUNT[@]}"} \
    -v "$LOGS:/logs" \
    -e DURATION="$DURATION" -e NO_SHELL="$NO_SHELL" \
    -e INSTALL_OMARCHY_AT_RUNTIME="$INSTALL_OMARCHY_AT_RUNTIME" \
    -e POLL="$POLL" -e HYPRCTL_TIMEOUT="$HYPRCTL_TIMEOUT" \
    -e SHELL_TIMEOUT="$SHELL_TIMEOUT" \
    "$TEST_IMAGE" bash -s <<'EOS'
set -u
L=/tmp/logs
mkdir -p "$L"
FAILSTEP=""
trap 'cp -f "$L"/* /logs/ 2>/dev/null || true' EXIT

step() {
    printf '%s [+%-5ss] %s\n' "$(date -u +%H:%M:%S)" "$SECONDS" "$*" | tee -a "$L/steps.log"
}
note() { # diagnostics that only go to steps.log
    printf '%s [+%-5ss]   %s\n' "$(date -u +%H:%M:%S)" "$SECONDS" "$*" >> "$L/steps.log"
}
fail() { # fail STEP MESSAGE — names the first failing step and exits 1
    FAILSTEP="$1"
    printf 'FIRST FAILING STEP: %s — %s\n' "$1" "$2" | tee -a "$L/steps.log"
    [ -n "${DIAG:-}" ] && printf 'DIAGNOSIS: %s\n' "$DIAG" | tee -a "$L/steps.log"
    exit 1
}

# --- versions -------------------------------------------------------------
step "versions"
{
    pacman -Q hyprland quickshell omarchy omarchy-settings mesa 2>&1
    echo "uname -m: $(uname -m)"
    if [ "$INSTALL_OMARCHY_AT_RUNTIME" = 0 ]; then
        echo "omarchy origin: installed in the test image from pkgs.omarchy.org (cached; --rebuild-image refreshes)"
    fi
} | tee "$L/pacman.log"

# --- DRM diagnostics (the known container limitation) ---------------------
step "DRM devices (diagnostics)"
DRM_CARDS="$(ls /sys/class/drm 2>/dev/null | grep -v '^version$' || true)"
note "/sys/class/drm: $(ls /sys/class/drm 2>/dev/null | tr '\n' ' ')"
note "/dev/dri: $(ls /dev/dri 2>&1 | tr '\n' ' ')"
if [ ! -d /dev/dri ] && [ -n "$DRM_CARDS" ]; then
    # Kernel DRM devices the container cannot see: recreate the nodes (works
    # when the device cgroup allows them; harmless otherwise).
    made=""
    for c in /sys/class/drm/*; do
        case "${c##*/}" in version) continue ;; esac
        [ -e "$c/dev" ] || continue
        majmin="$(cat "$c/dev")"
        mkdir -p /dev/dri
        if mknod "/dev/dri/${c##*/}" c "${majmin%:*}" "${majmin#*:}" 2>/dev/null; then
            made="$made ${c##*/}"
        fi
    done
    [ -n "$made" ] && note "mknod'd:$made"
    DRM_CARDS="$(ls /sys/class/drm 2>/dev/null | grep -v '^version$' || true)"
fi

DIAG=""
no_drm_diagnosis() {
    if [ -z "$DRM_CARDS" ] && [ ! -e /dev/dri/card0 ]; then
        DIAG="Hyprland aborted inside CBackend::start(): aquamarine $(pacman -Q aquamarine 2>/dev/null | awk '{print $2}') creates its buffer allocator only from a DRM device fd (Backend.cpp: 'Cannot open backend: no allocator available'); the headless backend reports drmFD() == -1 and this container sees no DRM device at all (/sys/class/drm is empty, no virtio-gpu device in the Docker Desktop VM). Hyprland's own hyprtester runs on CI machines that do expose /dev/dri. Run this test on a container host with a DRM node to exercise the full pipeline."
    fi
}

# --- session plumbing: system bus, runtime dir, home from /etc/skel -------
step "session plumbing (system D-Bus, /run/user/1000, home from /etc/skel)"
mkdir -p /run/dbus
dbus-daemon --system --fork >/dev/null 2>&1 || true
install -d -m 0700 -o alarm -g alarm /run/user/1000
rm -rf /home/alarm
mkdir -p /home/alarm
cp -a /etc/skel/. /home/alarm/
chown -R alarm:alarm /home/alarm
chown alarm:alarm "$L"

# --- Omarchy from the local repo (armv7h), at run time --------------------
if [ "$INSTALL_OMARCHY_AT_RUNTIME" = 1 ]; then
    step "installing omarchy + omarchy-settings from /repo (run time)"
    {
        sed -i '/^\[core\]/i [t715-omarchy]\nSigLevel = Optional TrustAll\nServer = file:///repo' /etc/pacman.conf
        pacman -Sy --noconfirm
        if pacman -S --noconfirm --needed omarchy omarchy-settings; then
            echo "omarchy install: normal, with dependencies"
        else
            echo "omarchy install: dependency install failed, retrying with --nodeps (-dd)"
            pacman -S --noconfirm -dd omarchy omarchy-settings \
                && echo "omarchy install: --nodeps (-dd), dependencies left to the image"
        fi
    } >> "$L/pacman.log" 2>&1 \
        || fail "omarchy install" "pacman could not install omarchy from /repo (see pacman.log)"
fi

# --- shell launcher plumbing ----------------------------------------------
# No journald in the container: omarchy-launch-shell wraps quickshell in
# `systemd-cat -t omarchy-shell --`. /usr/local/bin precedes /usr/bin in the
# session PATH (even after Omarchy prepends its own bin dir), so this shim
# takes over: it execs the command with its output kept in shell.log.
step "systemd-cat shim for omarchy-launch-shell (no journald in the container)"
touch "$L/shell.log"
chown alarm:alarm "$L/shell.log"
cat > /usr/local/bin/systemd-cat <<'SHIM'
#!/bin/bash
# test shim: no journal in the container; keep the command's output instead
while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
[ $# -gt 0 ] && shift
exec "$@" >> /tmp/logs/shell.log 2>&1
SHIM
chmod 755 /usr/local/bin/systemd-cat
note "shell start path: Hyprland autostart -> omarchy-launch-shell -> systemd-cat shim -> quickshell"
if [ "$NO_SHELL" = 1 ]; then
    printf '#!/bin/bash\n# masked by test_omarchy_headless.sh --no-shell\nexit 0\n' \
        > /usr/local/bin/omarchy-launch-shell
    chmod 755 /usr/local/bin/omarchy-launch-shell
    note "--no-shell: omarchy-launch-shell masked by a stub in /usr/local/bin"
fi

# --- helpers to run things as the session user ----------------------------
# setpriv, not runuser/su: PAM's pam_systemd spins forever under qemu-arm
# once a system bus is up (same as the Phosh test).
sig=""
discover_sig() { # newest Hyprland instance under /run/user/1000/hypr
    local d
    sig=""
    for d in $(ls -1t /run/user/1000/hypr 2>/dev/null); do
        if [ -e "/run/user/1000/hypr/$d/.instance_lock" ]; then sig="$d"; return; fi
    done
}
as_alarm() {
    local e=()
    discover_sig
    [ -n "$sig" ] && e=("HYPRLAND_INSTANCE_SIGNATURE=$sig")
    local wd
    wd="$(ls /run/user/1000 2>/dev/null | grep -m1 '^wayland' || true)"
    [ -n "$wd" ] && e+=("WAYLAND_DISPLAY=$wd")
    setpriv --reuid=alarm --regid=alarm --init-groups env -i \
        HOME=/home/alarm USER=alarm LOGNAME=alarm SHELL=/bin/bash \
        PATH=/usr/local/bin:/usr/bin LANG=C.UTF-8 \
        XDG_RUNTIME_DIR=/run/user/1000 OMARCHY_PATH=/usr/share/omarchy \
        ${e[@]+"${e[@]}"} "$@"
}

# --- start Hyprland --------------------------------------------------------
step "starting Hyprland (headless backend, LIBGL_ALWAYS_SOFTWARE=1 llvmpipe)"
setpriv --reuid=alarm --regid=alarm --init-groups env -i \
    HOME=/home/alarm USER=alarm LOGNAME=alarm SHELL=/bin/bash \
    PATH=/usr/local/bin:/usr/bin LANG=C.UTF-8 \
    XDG_RUNTIME_DIR=/run/user/1000 XDG_SESSION_TYPE=wayland \
    OMARCHY_PATH=/usr/share/omarchy \
    HYPRLAND_HEADLESS_ONLY=1 \
    LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe \
    dbus-run-session -- \
    Hyprland --config /home/alarm/.config/hypr/hyprland.lua \
    > "$L/hyprland.log" 2>&1 &
launcher_pid=$!
note "Hyprland launcher pid $launcher_pid (HYPRLAND_HEADLESS_ONLY=1, as hyprtester sets it; the Hyprland binary itself does not read that variable)"

# --- wait until hyprctl answers -------------------------------------------
step "waiting for hyprctl to answer (timeout ${HYPRCTL_TIMEOUT}s)"
ready=0
t0=$SECONDS
while [ $((SECONDS - t0)) -lt "$HYPRCTL_TIMEOUT" ]; do
    if as_alarm hyprctl version >/dev/null 2>&1; then ready=1; break; fi
    kill -0 "$launcher_pid" 2>/dev/null || break
    pgrep -x Hyprland >/dev/null 2>&1 || break
    sleep "$POLL"
done
step "hyprctl answers: $ready (after $((SECONDS - t0))s)"
if [ "$ready" != 1 ]; then
    no_drm_diagnosis
    echo "--- hyprland.log (last 30 lines) ---"
    tail -n 30 "$L/hyprland.log"
    fail "hyprctl ready" "Hyprland did not come up (full log: hyprland.log)"
fi
as_alarm hyprctl version | head -n 3 | while IFS= read -r l; do note "$l"; done

# --- a monitor must exist --------------------------------------------------
step "monitors: an output must exist (create headless 1536x2048 if none)"
as_alarm hyprctl -j monitors > "$L/hyprctl-monitors.json" 2>/dev/null || echo '[]' > "$L/hyprctl-monitors.json"
monitors=$(jq 'length' "$L/hyprctl-monitors.json" 2>/dev/null || echo 0)
if [ "${monitors:-0}" -eq 0 ] 2>/dev/null; then
    note "no output: hyprctl output create headless PANEL (1536x2048, the tablet's panel)"
    as_alarm hyprctl output create headless PANEL || true
    as_alarm hyprctl keyword monitor PANEL,1536x2048,0x0,1 || true
    sleep 2
    as_alarm hyprctl -j monitors > "$L/hyprctl-monitors.json" 2>/dev/null || true
    monitors=$(jq 'length' "$L/hyprctl-monitors.json" 2>/dev/null || echo 0)
fi
note "monitors: $(cat "$L/hyprctl-monitors.json" | tr -d '\n' | cut -c1-300)"
if ! [ "${monitors:-0}" -ge 1 ] 2>/dev/null; then
    fail "monitors" "no output present even after 'output create headless'"
fi

# --- the Omarchy shell ------------------------------------------------------
shell_path="not started (--no-shell)"
if [ "$NO_SHELL" != 1 ]; then
    step "Omarchy shell: waiting for quickshell (autostart path, timeout ${SHELL_TIMEOUT}s)"
    t0=$SECONDS
    while [ $((SECONDS - t0)) -lt "$SHELL_TIMEOUT" ]; do
        pgrep -u alarm -x quickshell >/dev/null 2>&1 && break
        kill -0 "$launcher_pid" 2>/dev/null || break
        sleep "$POLL"
    done
    if pgrep -u alarm -x quickshell >/dev/null 2>&1; then
        shell_path="omarchy-launch-shell via Hyprland autostart (systemd-cat shim)"
    else
        note "autostart did not start the shell; fallback: hyprctl exec omarchy-launch-shell"
        as_alarm hyprctl exec omarchy-launch-shell || true
        t0=$SECONDS
        while [ $((SECONDS - t0)) -lt "$SHELL_TIMEOUT" ]; do
            pgrep -u alarm -x quickshell >/dev/null 2>&1 && break
            kill -0 "$launcher_pid" 2>/dev/null || break
            sleep "$POLL"
        done
        pgrep -u alarm -x quickshell >/dev/null 2>&1 \
            && shell_path="omarchy-launch-shell via hyprctl exec fallback (systemd-cat shim)"
    fi
    step "shell process: $(pgrep -u alarm -x quickshell | tr '\n' ' ')"
    if ! pgrep -u alarm -x quickshell >/dev/null 2>&1; then
        echo "--- shell.log (last 20 lines) ---"
        tail -n 20 "$L/shell.log" 2>/dev/null
        fail "shell start" "quickshell is not running (shell.log)"
    fi
fi

# --- stay up ---------------------------------------------------------------
step "staying up for ${DURATION}s (Hyprland$( [ "$NO_SHELL" = 1 ] || echo ' + shell'))"
ok=1
failinfo=""
hyprctl_misses=0
i=0
t0=$SECONDS
while [ $((SECONDS - t0)) -lt "$DURATION" ]; do
    sleep "$POLL"
    i=$((i + 1))
    if ! pgrep -x Hyprland >/dev/null 2>&1; then
        ok=0; failinfo="the Hyprland process exited after $((SECONDS - t0))s"; break
    fi
    if [ "$NO_SHELL" != 1 ] && ! pgrep -u alarm -x quickshell >/dev/null 2>&1; then
        ok=0; failinfo="the quickshell process exited after $((SECONDS - t0))s"; break
    fi
    # a busy compositor can miss a query: three misses in a row means gone
    if [ $((i % 5)) -eq 0 ]; then
        if as_alarm hyprctl version >/dev/null 2>&1; then
            hyprctl_misses=0
        else
            hyprctl_misses=$((hyprctl_misses + 1))
            [ "$hyprctl_misses" -ge 3 ] && { ok=0; failinfo="hyprctl stopped answering after $((SECONDS - t0))s"; break; }
        fi
    fi
done
step "stay-up phase done after $((SECONDS - t0))s (ok=$ok)"
if [ "$ok" != 1 ]; then
    no_drm_diagnosis
    { echo "--- hyprland.log (last 20 lines) ---"; tail -n 20 "$L/hyprland.log"; \
      [ "$NO_SHELL" = 1 ] || { echo "--- shell.log (last 20 lines) ---"; tail -n 20 "$L/shell.log" 2>/dev/null; }; } || true
    fail "stay up" "$failinfo"
fi

# --- state at the end --------------------------------------------------------
step "final IPC state: clients, layers, systeminfo"
as_alarm hyprctl version >/dev/null 2>&1 \
    || fail "final hyprctl" "hyprctl does not answer at the end of the run"
as_alarm hyprctl -j clients > "$L/hyprctl-clients.json" 2>/dev/null || echo '[]' > "$L/hyprctl-clients.json"
as_alarm hyprctl -j layers  > "$L/hyprctl-layers.json"  2>/dev/null || echo '{}' > "$L/hyprctl-layers.json"
if ! as_alarm hyprctl systeminfo > "$L/systeminfo.txt" 2>&1; then
    echo "hyprctl systeminfo unavailable on this Hyprland" > "$L/systeminfo.txt"
fi
if [ -n "$sig" ] && [ -f "/run/user/1000/hypr/$sig/hyprland.log" ]; then
    cp "/run/user/1000/hypr/$sig/hyprland.log" "$L/hyprland-instance.log"
fi

step "screenshot with grim (best effort)"
if as_alarm grim "$L/screenshot.png" 2>>"$L/steps.log"; then
    note "screenshot.png saved"
else
    note "warning: grim failed (not a failure by itself)"
fi

# --- informational: GL context and QML errors --------------------------------
step "informational: GL context version"
gl="$(grep -hE 'GL ver|GLES|OpenGL' "$L/systeminfo.txt" "$L/hyprland-instance.log" "$L/hyprland.log" 2>/dev/null | head -n 3)"
if [ -n "$gl" ]; then echo "$gl" | while IFS= read -r l; do note "$l"; done
else note "no GL version line found"; fi

if [ "$NO_SHELL" != 1 ]; then
    step "informational: QML errors in shell.log"
    qml_errors=$(grep -cE 'ERROR|TypeError' "$L/shell.log" 2>/dev/null || echo 0)
    note "QML ERROR/TypeError lines: $qml_errors"
    grep -m5 -E 'ERROR|TypeError' "$L/shell.log" 2>/dev/null | while IFS= read -r l; do note "  $l"; done || true
fi

# --- verdict -------------------------------------------------------------------
step "verdict"
crash="$(grep -nE -i 'Segmentation fault|RASSERT|Aborting|terminate called after throwing|crash report' \
    "$L/hyprland.log" "$L/hyprland-instance.log" 2>/dev/null | head -n 5 || true)"
note "shell start path: $shell_path"
if [ -n "$crash" ]; then
    echo "$crash" | while IFS= read -r l; do note "$l"; done
    fail "compositor log" "crash markers found in Hyprland's log"
fi
echo "PASS: Hyprland$( [ "$NO_SHELL" = 1 ] || echo ' + Omarchy shell') up for ${DURATION}s, hyprctl answering, no crash markers"
exit 0
EOS
rc=$?
set -e

alarm_log "logs: $LOGS"
case "$rc" in
    0) printf 'RESULT: PASS\n' ;;
    1) printf 'RESULT: FAIL\n' ;;
    *) printf 'RESULT: ERROR (%s)\n' "$rc"; rc=2 ;;
esac
exit "$rc"
